//! `debug.hap@1`'s device actions as Swift's HDC provider
//! (`HDCObservationProviderAdapter`, `debugHAPAction`) chooses, lowers and
//! judges them: a package staged to a provider-owned path (`file send`) or a
//! set of packages to a provider-owned directory, installed (`bm install -p
//! … -r`) and believed only through its readback (`bm dump -n`), the ability
//! started (`aa start`) and believed only through its process readback
//! (`pidof`), stopped (`aa force-stop` + `pidof`) and uninstalled
//! (`uninstall` + `bm dump`) each judged by its paired readback rather than
//! by the mutation's own exit, and the staging cleaned by name. The
//! recovery-only presence reads (`readPackagePresence`, `readProcessPresence`,
//! `readOwnedPathPresence`, `readOwnedDirectoryPresence`) and the table that
//! pairs a mutation with its readback and the presence it wanted are here
//! too, so a Job resumed after a crash can conclude a mutation without
//! resending it.
//!
//! What runs a lowered plan is [`crate::run`] over an [`crate::HdcDispatch`];
//! the plan shapes, the owned paths and the parsers are shared with
//! [`crate::FileAction`]. The Artifact a `file send` transfers is resolved by
//! the Job owner from its lease and handed in as a [`ResolvedArtifact`]; this
//! module never reads a store.
use crate::capture_files::{
    DirectoryPurpose, FileActionError, FilePlan, FileReceipt, ImageType, Invocation,
    OwnedRemoteDirectory, OwnedRemotePath, path_presence,
};
use crate::{Outcome, ProcessPlan, Receipt, RequestError};
use serde_json::{Map, Value, json};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::time::Duration;

/// Swift `DescriptorBoundProcessDispatcher`'s default capture.
const CAPTURE_BYTES: usize = 8 * 1024 * 1024;
/// Swift `boundedProcessDiagnostic`'s prefix of each stream.
const DIAGNOSTIC_BYTES: usize = 512;
/// Swift `HDCStagedPackageSet`: 2 to 17 packages.
const PACKAGE_SET_BOUNDS: std::ops::RangeInclusive<usize> = 2..=17;

/// Swift `HDCBundleReference`: a reverse-DNS bundle name.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct BundleReference(String);

impl BundleReference {
    pub fn new(bundle_name: &str) -> Result<Self, RequestError> {
        let components: Vec<&str> = bundle_name.split('.').collect();
        let valid = !bundle_name.is_empty()
            && bundle_name.chars().count() <= 200
            && components.len() >= 2
            && components.iter().all(|component| {
                component
                    .bytes()
                    .next()
                    .is_some_and(|first| first.is_ascii_alphabetic())
                    && component
                        .bytes()
                        .all(|byte| byte.is_ascii_alphanumeric() || byte == b'_')
            });
        if !valid {
            return Err(RequestError::Malformed {
                field: "bundleName",
                detail: "reverse-DNS identifier expected",
            });
        }
        Ok(Self(bundle_name.to_owned()))
    }

    pub fn bundle_name(&self) -> &str {
        &self.0
    }
}

/// Swift `HDCAbilityReference`.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AbilityReference {
    pub bundle: BundleReference,
    pub ability_name: String,
}

impl AbilityReference {
    pub fn new(bundle: BundleReference, ability_name: &str) -> Result<Self, RequestError> {
        let valid = !ability_name.is_empty()
            && ability_name.chars().count() <= 200
            && ability_name
                .bytes()
                .next()
                .is_some_and(|first| first.is_ascii_alphabetic())
            && ability_name
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || byte == b'.' || byte == b'_');
        if !valid {
            return Err(RequestError::Malformed {
                field: "abilityName",
                detail: "identifier expected",
            });
        }
        Ok(Self {
            bundle,
            ability_name: ability_name.to_owned(),
        })
    }
}

/// Swift `HDCStagedArtifact`: the provider-owned staging path of a leased
/// Artifact, and the hash the resolved bytes must have before anything is
/// sent (absent while the plan is only materialized for admission).
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct StagedArtifact {
    pub path: OwnedRemotePath,
    pub artifact_lease_id: String,
    pub expected_sha256: Option<String>,
}

/// Swift `HDCStagedPackage`: one package of a set, at
/// `<directory>/<artifactID>.hap`.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct StagedPackage {
    pub remote_path: String,
    pub artifact_lease_id: String,
    pub expected_sha256: Option<String>,
}

impl StagedPackage {
    /// Swift `HDCOwnedRemoteDirectory.packagePath(artifactID:)`: a bounded
    /// identifier, never a path.
    pub fn new(
        directory: &OwnedRemoteDirectory,
        artifact_id: &str,
        artifact_lease_id: &str,
        expected_sha256: Option<&str>,
    ) -> Result<Self, RequestError> {
        let bounded = artifact_id
            .bytes()
            .next()
            .is_some_and(|first| first.is_ascii_alphanumeric())
            && artifact_id.len() <= 128
            && artifact_id
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || b"._-".contains(&byte));
        if !bounded {
            return Err(RequestError::Malformed {
                field: "artifactID",
                detail: "package file names are bounded identifiers",
            });
        }
        Ok(Self {
            remote_path: format!("{}/{artifact_id}.hap", directory.remote_path),
            artifact_lease_id: artifact_lease_id.to_owned(),
            expected_sha256: expected_sha256.map(str::to_owned),
        })
    }
}

/// Swift `HDCStagedPackageSet`: several packages of one bundle in one
/// provider-owned directory — the shape `bm install -p <dir>` requires for a
/// multi-module application. Entry package first, then the caller's order,
/// never fewer than two.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct StagedPackageSet {
    pub directory: OwnedRemoteDirectory,
    pub packages: Vec<StagedPackage>,
}

impl StagedPackageSet {
    pub fn new(
        directory: OwnedRemoteDirectory,
        packages: Vec<StagedPackage>,
    ) -> Result<Self, RequestError> {
        if !PACKAGE_SET_BOUNDS.contains(&packages.len()) {
            return Err(RequestError::OutOfBounds {
                field: "packages",
                detail: "a staged package set holds 2...17 packages".into(),
            });
        }
        let prefix = format!("{}/", directory.remote_path);
        let mut seen = std::collections::BTreeSet::new();
        for package in &packages {
            if !seen.insert(package.remote_path.as_str()) {
                return Err(RequestError::Malformed {
                    field: "packages",
                    detail: "two packages cannot stage to one path",
                });
            }
            if !package.remote_path.starts_with(&prefix) {
                return Err(RequestError::Malformed {
                    field: "packages",
                    detail: "every package must stage inside the owned directory",
                });
            }
        }
        Ok(Self {
            directory,
            packages,
        })
    }
}

/// An input Artifact the Job owner resolved from its lease immediately
/// before the step (Swift `ProviderExecutionContext.resolvedInputArtifact`
/// / `additionalInputArtifacts`): its identity, its digest and where its
/// bytes are on the host.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ResolvedArtifact {
    pub artifact_id: String,
    pub sha256: String,
    pub path: PathBuf,
}

/// Swift `TypedProviderAction.hdc` for `debug.hap@1`.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum HapAction {
    SendArtifactToStaging(StagedArtifact),
    SendPackageSetToStaging(StagedPackageSet),
    InstallPackage {
        staged: StagedArtifact,
        bundle: BundleReference,
    },
    InstallPackageSet {
        set: StagedPackageSet,
        bundle: BundleReference,
    },
    CleanupStagedPackageSet(StagedPackageSet),
    CleanupOwnedRemotePath {
        path: OwnedRemotePath,
    },
    QueryPackageReadback(BundleReference),
    StartAbility(AbilityReference),
    VerifyProcessState(BundleReference),
    StopAbility(AbilityReference),
    UninstallPackage(BundleReference),
    /// Recovery-only reads: never substitutes for the original mutation.
    ReadPackagePresence(BundleReference),
    ReadProcessPresence(BundleReference),
    ReadOwnedPathPresence {
        path: OwnedRemotePath,
    },
    ReadOwnedDirectoryPresence(OwnedRemoteDirectory),
}

fn string_input<'a>(inputs: &'a Map<String, Value>, key: &str) -> Option<&'a str> {
    inputs.get(key).and_then(Value::as_str)
}

fn unsupported<T>(detail: &str) -> Result<T, FileActionError> {
    Err(FileActionError::Unsupported(detail.to_owned()))
}

/// The arguments of a persisted action of `kind`, read as Swift's
/// `PersistedTypedProviderAction.materialize()` reads them: each reader
/// refuses as its Swift namesake does, and the owned references are rebuilt
/// through their constructors.
pub(crate) struct PersistedArguments<'a> {
    pub(crate) kind: &'a str,
    pub(crate) arguments: &'a Map<String, Value>,
}

impl PersistedArguments<'_> {
    pub(crate) fn refuse<T>(&self, detail: &str) -> Result<T, FileActionError> {
        unsupported(&format!("persisted {} {detail}", self.kind))
    }

    pub(crate) fn string(&self, key: &str) -> Result<&str, FileActionError> {
        match self.arguments.get(key) {
            Some(Value::String(text)) => Ok(text),
            _ => self.refuse(&format!("is missing string {key}")),
        }
    }

    pub(crate) fn integer(&self, key: &str) -> Result<i64, FileActionError> {
        match self.arguments.get(key).and_then(Value::as_i64) {
            Some(value) => Ok(value),
            None => self.refuse(&format!("is missing integer {key}")),
        }
    }

    pub(crate) fn optional_string(&self, key: &str) -> Result<Option<&str>, FileActionError> {
        match self.arguments.get(key) {
            None => Ok(None),
            Some(Value::String(text)) => Ok(Some(text)),
            Some(_) => unsupported(&format!("persisted {}.{key} is not a string", self.kind)),
        }
    }

    pub(crate) fn optional_integer(&self, key: &str) -> Result<Option<i64>, FileActionError> {
        match self.arguments.get(key) {
            None => Ok(None),
            Some(value) => match value.as_i64() {
                Some(number) => Ok(Some(number)),
                None => unsupported(&format!("persisted {}.{key} is not an integer", self.kind)),
            },
        }
    }

    /// Swift's `path()`: the owned path rebuilt from its components, which
    /// must name exactly the recorded path.
    fn path(&self) -> Result<OwnedRemotePath, FileActionError> {
        let path = OwnedRemotePath::new(
            self.string("jobId")?,
            self.string("stepId")?,
            self.string("nonce")?,
            ImageType::Png,
        )?;
        if path.remote_path != self.string("remotePath")? {
            return self.refuse("remote path does not match its owned components");
        }
        Ok(path)
    }

    pub(crate) fn bundle(&self) -> Result<BundleReference, FileActionError> {
        Ok(BundleReference::new(self.string("bundleName")?)?)
    }

    fn ability(&self) -> Result<AbilityReference, FileActionError> {
        let bundle = self.bundle()?;
        Ok(AbilityReference::new(bundle, self.string("abilityName")?)?)
    }

    fn staged(&self) -> Result<StagedArtifact, FileActionError> {
        Ok(StagedArtifact {
            path: self.path()?,
            artifact_lease_id: self.string("artifactLeaseId")?.to_owned(),
            expected_sha256: self.optional_string("expectedSha256")?.map(str::to_owned),
        })
    }

    fn directory(&self) -> Result<OwnedRemoteDirectory, FileActionError> {
        Ok(OwnedRemoteDirectory::new(
            self.string("jobId")?,
            self.string("stepId")?,
            self.string("nonce")?,
            DirectoryPurpose::Packages,
        )?)
    }

    /// Swift's `packageSet()`: each package named by its path's last
    /// component without `.hap`, its recorded path otherwise unread, and a
    /// hash that is not text read as none.
    fn package_set(&self) -> Result<StagedPackageSet, FileActionError> {
        let directory = self.directory()?;
        let Some(Value::Array(entries)) = self.arguments.get("packages") else {
            return self.refuse("carries no staged package list");
        };
        let mut packages = Vec::with_capacity(entries.len());
        for entry in entries {
            let (Some(remote_path), Some(lease)) = (
                entry.get("remotePath").and_then(Value::as_str),
                entry.get("artifactLeaseId").and_then(Value::as_str),
            ) else {
                return self.refuse("carries a malformed staged package");
            };
            let Some(last) = remote_path.split('/').rfind(|part| !part.is_empty()) else {
                return self.refuse("carries a malformed staged package");
            };
            packages.push(StagedPackage::new(
                &directory,
                &last.replace(".hap", ""),
                lease,
                entry.get("sha256").and_then(Value::as_str),
            )?);
        }
        Ok(StagedPackageSet::new(directory, packages)?)
    }
}

/// Swift `stagedPackageSet(inputs:context:)`: the set exists only when the
/// request carried additional leases; the identity of each package comes
/// from its lease (`lease-v1:<job>:<artifactID>`), the hash from the
/// resolved Artifact when one is already there, and `lower` is where the
/// resolved bytes must match before anything is sent.
fn staged_package_set(
    inputs: &Map<String, Value>,
    job_id: &str,
    resolved: &[ResolvedArtifact],
) -> Result<Option<StagedPackageSet>, FileActionError> {
    let Some(additional) = inputs
        .get("additionalHapArtifactLeases")
        .and_then(Value::as_array)
        .filter(|leases| !leases.is_empty())
    else {
        return Ok(None);
    };
    let Some(entry) = string_input(inputs, "hapArtifactLease") else {
        return unsupported("hapArtifactLease input is required");
    };
    let mut leases = vec![entry];
    for value in additional {
        let Some(lease) = value.as_str() else {
            return unsupported("additionalHapArtifactLeases must be artifact leases");
        };
        leases.push(lease);
    }
    let directory =
        OwnedRemoteDirectory::new(job_id, "send-hap", "owned", DirectoryPurpose::Packages)?;
    let mut packages = Vec::with_capacity(leases.len());
    for (index, lease) in leases.iter().enumerate() {
        let Some(artifact_id) = lease.rsplit(':').next().filter(|_| lease.contains(':')) else {
            return unsupported("malformed artifact lease");
        };
        let artifact = resolved.get(index);
        if artifact.is_some_and(|artifact| artifact.artifact_id != artifact_id) {
            return unsupported(&format!(
                "resolved Artifact does not match the lease at position {index}"
            ));
        }
        packages.push(StagedPackage::new(
            &directory,
            artifact_id,
            lease,
            artifact.map(|artifact| artifact.sha256.as_str()),
        )?);
    }
    Ok(Some(StagedPackageSet::new(directory, packages)?))
}

impl HapAction {
    /// Swift `debugHAPAction(for:inputs:context:)` (and the `packageInfo`
    /// arm of `approvedRemoteReadAction`, and `cleanupOwnedRemotePath` for
    /// this operation): the action a `debug.hap@1` step of the given kind
    /// names, from the request's inputs, the Job the owned paths are minted
    /// for and the Artifacts already resolved. `None` is a step of another
    /// owner (the observe steps, the bounded HiLog capture); an error is
    /// Swift's refusal.
    pub fn for_step(
        step_id: &str,
        kind: &str,
        action_id: Option<&str>,
        inputs: &Map<String, Value>,
        job_id: &str,
        resolved: &[ResolvedArtifact],
    ) -> Result<Option<Self>, FileActionError> {
        let _ = step_id;
        if !matches!(
            kind,
            "sendFile"
                | "installPackage"
                | "startApplication"
                | "stopApplication"
                | "uninstallPackage"
                | "verifyRemoteState"
                | "cleanupOwnedRemotePath"
        ) && !(kind == "runApprovedRemoteRead" && action_id == Some("packageInfo"))
        {
            return Ok(None);
        }
        let Some(bundle_name) = string_input(inputs, "bundleName") else {
            return unsupported("bundleName input is required");
        };
        let bundle = BundleReference::new(bundle_name)?;
        let package_set = staged_package_set(inputs, job_id, resolved)?;
        let staged = || -> Result<StagedArtifact, FileActionError> {
            let Some(lease) = string_input(inputs, "hapArtifactLease") else {
                return unsupported("hapArtifactLease input is required");
            };
            Ok(StagedArtifact {
                path: OwnedRemotePath::stable(job_id, "send-hap", ImageType::Png)?,
                artifact_lease_id: lease.to_owned(),
                expected_sha256: resolved.first().map(|artifact| artifact.sha256.clone()),
            })
        };
        let ability = || -> Result<AbilityReference, FileActionError> {
            let Some(ability_name) = string_input(inputs, "abilityName") else {
                return unsupported("abilityName input is required");
            };
            Ok(AbilityReference::new(bundle.clone(), ability_name)?)
        };
        Ok(Some(match kind {
            "sendFile" => match package_set {
                Some(set) => Self::SendPackageSetToStaging(set),
                None => Self::SendArtifactToStaging(staged()?),
            },
            "installPackage" => match package_set {
                Some(set) => Self::InstallPackageSet { set, bundle },
                None => Self::InstallPackage {
                    staged: staged()?,
                    bundle,
                },
            },
            "runApprovedRemoteRead" => Self::QueryPackageReadback(bundle),
            "startApplication" => Self::StartAbility(ability()?),
            "verifyRemoteState" => Self::VerifyProcessState(bundle),
            "stopApplication" => Self::StopAbility(ability()?),
            "uninstallPackage" => Self::UninstallPackage(bundle),
            _ => match package_set {
                Some(set) => Self::CleanupStagedPackageSet(set),
                None => Self::CleanupOwnedRemotePath {
                    path: OwnedRemotePath::stable(job_id, "send-hap", ImageType::Png)?,
                },
            },
        }))
    }

    /// Swift `TypedProviderAction.effect`.
    pub fn effect(&self) -> &'static str {
        match self {
            Self::QueryPackageReadback(_)
            | Self::VerifyProcessState(_)
            | Self::ReadPackagePresence(_)
            | Self::ReadProcessPresence(_)
            | Self::ReadOwnedPathPresence { .. }
            | Self::ReadOwnedDirectoryPresence(_) => "readOnly",
            _ => "deviceMutation",
        }
    }

    /// Swift `PersistedTypedProviderAction`: the kind and arguments a Job
    /// record keeps before the action's intent can be dispatched.
    pub fn persisted(&self) -> (&'static str, Map<String, Value>) {
        let path_arguments = |path: &OwnedRemotePath| {
            json!({
                "jobId": path.job_id, "stepId": path.step_id, "nonce": path.nonce,
                "remotePath": path.remote_path,
            })
        };
        let set_arguments = |set: &StagedPackageSet| {
            json!({
                "jobId": set.directory.job_id, "stepId": set.directory.step_id,
                "nonce": set.directory.nonce, "directoryPath": set.directory.remote_path,
                "packages": set.packages.iter().map(|package| json!({
                    "remotePath": package.remote_path,
                    "artifactLeaseId": package.artifact_lease_id,
                    "sha256": package.expected_sha256,
                })).collect::<Vec<_>>(),
            })
        };
        let staged_arguments = |staged: &StagedArtifact| {
            let mut arguments = path_arguments(&staged.path);
            arguments["artifactLeaseId"] = json!(staged.artifact_lease_id);
            if let Some(expected) = &staged.expected_sha256 {
                arguments["expectedSha256"] = json!(expected);
            }
            arguments
        };
        let (kind, value) = match self {
            Self::SendArtifactToStaging(staged) => {
                ("hdc.sendArtifactToStaging", staged_arguments(staged))
            }
            Self::SendPackageSetToStaging(set) => {
                ("hdc.sendPackageSetToStaging", set_arguments(set))
            }
            Self::InstallPackage { staged, bundle } => {
                let mut arguments = staged_arguments(staged);
                arguments["bundleName"] = json!(bundle.bundle_name());
                ("hdc.installPackage", arguments)
            }
            Self::InstallPackageSet { set, bundle } => {
                let mut arguments = set_arguments(set);
                arguments["bundleName"] = json!(bundle.bundle_name());
                ("hdc.installPackageSet", arguments)
            }
            Self::CleanupStagedPackageSet(set) => {
                ("hdc.cleanupStagedPackageSet", set_arguments(set))
            }
            Self::CleanupOwnedRemotePath { path } => {
                ("hdc.cleanupOwnedRemotePath", path_arguments(path))
            }
            Self::QueryPackageReadback(bundle) => (
                "hdc.queryPackageReadback",
                json!({"bundleName": bundle.bundle_name()}),
            ),
            Self::StartAbility(ability) => (
                "hdc.startAbility",
                json!({"bundleName": ability.bundle.bundle_name(), "abilityName": ability.ability_name}),
            ),
            Self::VerifyProcessState(bundle) => (
                "hdc.verifyProcessState",
                json!({"bundleName": bundle.bundle_name()}),
            ),
            Self::StopAbility(ability) => (
                "hdc.stopAbility",
                json!({"bundleName": ability.bundle.bundle_name(), "abilityName": ability.ability_name}),
            ),
            Self::UninstallPackage(bundle) => (
                "hdc.uninstallPackage",
                json!({"bundleName": bundle.bundle_name()}),
            ),
            Self::ReadPackagePresence(bundle) => (
                "hdc.readPackagePresence",
                json!({"bundleName": bundle.bundle_name()}),
            ),
            Self::ReadProcessPresence(bundle) => (
                "hdc.readProcessPresence",
                json!({"bundleName": bundle.bundle_name()}),
            ),
            Self::ReadOwnedPathPresence { path } => {
                ("hdc.readOwnedPathPresence", path_arguments(path))
            }
            Self::ReadOwnedDirectoryPresence(directory) => (
                "hdc.readOwnedDirectoryPresence",
                json!({
                    "jobId": directory.job_id, "stepId": directory.step_id,
                    "nonce": directory.nonce, "directoryPath": directory.remote_path,
                }),
            ),
        };
        let Value::Object(arguments) = value else {
            unreachable!("an object literal")
        };
        (kind, arguments)
    }

    /// Swift `PersistedTypedProviderAction.materialize()` for this family:
    /// the action a persisted kind and its arguments name, rebuilt through
    /// the same constructors and refused as Swift refuses it. `None` is a
    /// kind of another family.
    pub fn from_persisted(
        kind: &str,
        arguments: &Map<String, Value>,
    ) -> Result<Option<Self>, FileActionError> {
        let persisted = PersistedArguments { kind, arguments };
        Ok(Some(match kind {
            "hdc.cleanupOwnedRemotePath" => Self::CleanupOwnedRemotePath {
                path: persisted.path()?,
            },
            "hdc.sendArtifactToStaging" => Self::SendArtifactToStaging(persisted.staged()?),
            "hdc.installPackage" => Self::InstallPackage {
                staged: persisted.staged()?,
                bundle: persisted.bundle()?,
            },
            "hdc.sendPackageSetToStaging" => {
                Self::SendPackageSetToStaging(persisted.package_set()?)
            }
            "hdc.installPackageSet" => Self::InstallPackageSet {
                set: persisted.package_set()?,
                bundle: persisted.bundle()?,
            },
            "hdc.cleanupStagedPackageSet" => {
                Self::CleanupStagedPackageSet(persisted.package_set()?)
            }
            "hdc.readOwnedDirectoryPresence" => {
                Self::ReadOwnedDirectoryPresence(persisted.directory()?)
            }
            "hdc.queryPackageReadback" => Self::QueryPackageReadback(persisted.bundle()?),
            "hdc.startAbility" => Self::StartAbility(persisted.ability()?),
            "hdc.verifyProcessState" => Self::VerifyProcessState(persisted.bundle()?),
            "hdc.stopAbility" => Self::StopAbility(persisted.ability()?),
            "hdc.uninstallPackage" => Self::UninstallPackage(persisted.bundle()?),
            "hdc.readPackagePresence" => Self::ReadPackagePresence(persisted.bundle()?),
            "hdc.readProcessPresence" => Self::ReadProcessPresence(persisted.bundle()?),
            "hdc.readOwnedPathPresence" => Self::ReadOwnedPathPresence {
                path: persisted.path()?,
            },
            _ => return Ok(None),
        }))
    }

    /// Swift `lower`: the process or sequence the executor runs. A device
    /// action names its target by the binding's connect key and has none
    /// without one; a send has nothing to send unless the Artifacts it
    /// stages are the resolved ones — identity through the lease's suffix,
    /// bytes through the hash pinned when the plan was materialized.
    pub fn lower(
        &self,
        step_id: &str,
        connect_key: Option<&str>,
        resolved: &[ResolvedArtifact],
    ) -> Result<FilePlan, String> {
        let Some(key) = connect_key.filter(|key| !key.is_empty()) else {
            return Err(format!(
                "factsUnavailable(\"{step_id} has no descriptor-bound target connect key\")"
            ));
        };
        let device = |tail: Vec<String>| -> Vec<String> {
            let mut arguments = vec!["-t".to_owned(), key.to_owned()];
            arguments.extend(tail);
            arguments
        };
        let owned = |tail: &[&str]| device(tail.iter().map(|part| (*part).to_owned()).collect());
        let process = |arguments: Vec<String>, seconds: u64| {
            FilePlan::Process(ProcessPlan {
                arguments,
                timeout: Duration::from_secs(seconds),
                capture_bytes: CAPTURE_BYTES,
            })
        };
        let invocation =
            |arguments: Vec<String>, seconds: u64, continue_after_non_zero: bool| Invocation {
                arguments,
                timeout: Duration::from_secs(seconds),
                continue_after_non_zero,
            };
        let host = |path: &Path| path.to_string_lossy().into_owned();
        Ok(match self {
            Self::SendArtifactToStaging(staged) => {
                let Some(artifact) = resolved.first().filter(|artifact| {
                    staged
                        .artifact_lease_id
                        .ends_with(&format!(":{}", artifact.artifact_id))
                        && staged.expected_sha256.as_deref() == Some(artifact.sha256.as_str())
                }) else {
                    return Err(
                        "unsupportedAction(\"sendFile requires an engine-resolved Artifact lease\")"
                            .to_owned(),
                    );
                };
                process(
                    device(vec![
                        "file".into(),
                        "send".into(),
                        host(&artifact.path),
                        staged.path.remote_path.clone(),
                    ]),
                    300,
                )
            }
            // One directory, then one send per package.
            Self::SendPackageSetToStaging(set) => {
                if resolved.len() != set.packages.len() || resolved.is_empty() {
                    return Err(
                        "unsupportedAction(\"package-set send requires the engine-resolved lease for every package\")"
                            .to_owned(),
                    );
                }
                let mut invocations = vec![invocation(
                    owned(&["shell", "mkdir", "-p", &set.directory.remote_path]),
                    30,
                    false,
                )];
                for (package, artifact) in set.packages.iter().zip(resolved) {
                    if package.expected_sha256.as_deref() != Some(artifact.sha256.as_str()) {
                        return Err(
                            "unsupportedAction(\"staged package does not match its engine-resolved Artifact\")"
                                .to_owned(),
                        );
                    }
                    invocations.push(invocation(
                        device(vec![
                            "file".into(),
                            "send".into(),
                            host(&artifact.path),
                            package.remote_path.clone(),
                        ]),
                        300,
                        false,
                    ));
                }
                FilePlan::Sequence(invocations)
            }
            Self::InstallPackage { staged, .. } => process(
                owned(&[
                    "shell",
                    "bm",
                    "install",
                    "-p",
                    &staged.path.remote_path,
                    "-r",
                ]),
                300,
            ),
            Self::InstallPackageSet { set, .. } => process(
                owned(&[
                    "shell",
                    "bm",
                    "install",
                    "-p",
                    &set.directory.remote_path,
                    "-r",
                ]),
                300,
            ),
            // Every package by name, the directory by `rmdir`, then the
            // presence readback that decides.
            Self::CleanupStagedPackageSet(set) => {
                let mut invocations: Vec<Invocation> = set
                    .packages
                    .iter()
                    .map(|package| {
                        invocation(
                            owned(&["shell", "rm", "-f", &package.remote_path]),
                            30,
                            true,
                        )
                    })
                    .collect();
                invocations.push(invocation(
                    owned(&["shell", "rmdir", &set.directory.remote_path]),
                    30,
                    false,
                ));
                invocations.push(invocation(
                    owned(&["shell", "ls", "-ld", &set.directory.remote_path]),
                    15,
                    false,
                ));
                FilePlan::Sequence(invocations)
            }
            Self::CleanupOwnedRemotePath { path } => {
                process(owned(&["shell", "rm", "-f", &path.remote_path]), 15)
            }
            Self::QueryPackageReadback(bundle) | Self::ReadPackagePresence(bundle) => process(
                owned(&["shell", "bm", "dump", "-n", bundle.bundle_name()]),
                30,
            ),
            Self::StartAbility(ability) => process(
                owned(&[
                    "shell",
                    "aa",
                    "start",
                    "-b",
                    ability.bundle.bundle_name(),
                    "-a",
                    &ability.ability_name,
                ]),
                60,
            ),
            Self::VerifyProcessState(bundle) | Self::ReadProcessPresence(bundle) => {
                process(owned(&["shell", "pidof", bundle.bundle_name()]), 30)
            }
            // Both mutations carry their own readback: `hdc shell`'s exit
            // status is the client's, and `bm uninstall` answers cleanly for
            // a bundle that was never there.
            Self::StopAbility(ability) => FilePlan::Sequence(vec![
                invocation(
                    owned(&["shell", "aa", "force-stop", ability.bundle.bundle_name()]),
                    60,
                    true,
                ),
                invocation(
                    owned(&["shell", "pidof", ability.bundle.bundle_name()]),
                    30,
                    false,
                ),
            ]),
            Self::UninstallPackage(bundle) => FilePlan::Sequence(vec![
                invocation(owned(&["uninstall", bundle.bundle_name()]), 120, true),
                invocation(
                    owned(&["shell", "bm", "dump", "-n", bundle.bundle_name()]),
                    30,
                    false,
                ),
            ]),
            Self::ReadOwnedPathPresence { path } => {
                process(owned(&["shell", "ls", "-ld", &path.remote_path]), 15)
            }
            Self::ReadOwnedDirectoryPresence(directory) => {
                process(owned(&["shell", "ls", "-ld", &directory.remote_path]), 15)
            }
        })
    }

    /// Swift `verify` for these actions. `resolved_sha256` is the digest of
    /// the Artifact the Job resolved for its entry lease, which the package
    /// readback binds its verdict to (Swift `context.resolvedInputArtifact`).
    pub fn verify(&self, receipt: &FileReceipt, resolved_sha256: Option<&str>) -> Outcome {
        let sole = receipt.subprocesses.first();
        match self {
            Self::SendArtifactToStaging(staged) => match sole {
                Some(process) if process.exit_status == 0 => {
                    verified([("stagedAt", staged.path.remote_path.clone())])
                }
                _ => failed("sendFailed", "artifact transfer did not complete"),
            },
            Self::SendPackageSetToStaging(set) => {
                if receipt.subprocesses.len() != set.packages.len() + 1 {
                    return Outcome::Unknown(
                        "package-set send did not produce one result per package".into(),
                    );
                }
                if !receipt
                    .subprocesses
                    .iter()
                    .all(|process| process.exit_status == 0)
                {
                    return failed(
                        "sendFailed",
                        "one package of the set did not transfer cleanly",
                    );
                }
                verified([
                    ("stagedAt", set.directory.remote_path.clone()),
                    ("packageCount", set.packages.len().to_string()),
                ])
            }
            // Deliberately never verified: an install is only as true as its
            // readback, and hardware has shown `hdc install` exiting zero
            // without installing.
            Self::InstallPackage { .. } | Self::InstallPackageSet { .. } => {
                install_dispatch_outcome(receipt)
            }
            Self::CleanupStagedPackageSet(set) => {
                let Some(present) = receipt.subprocesses.last().and_then(path_presence) else {
                    return Outcome::Unknown(
                        "staged directory readback has no definite result".into(),
                    );
                };
                if present {
                    return Outcome::Failed {
                        code: "cleanupDebt",
                        detail: format!(
                            "staged package directory {} still exists",
                            set.directory.remote_path
                        ),
                    };
                }
                verified([("cleaned", set.directory.remote_path.clone())])
            }
            Self::CleanupOwnedRemotePath { path } => match sole {
                Some(process) if process.exit_status == 0 => {
                    verified([("cleaned", path.remote_path.clone())])
                }
                _ => Outcome::Failed {
                    code: "cleanupDebt",
                    detail: format!("remote cleanup failed for {}", path.remote_path),
                },
            },
            Self::QueryPackageReadback(bundle) => {
                let Some(process) = sole else {
                    return Outcome::Unknown("package readback produced no process result".into());
                };
                if process.truncated {
                    return failed("truncated", "package readback exceeded its budget");
                }
                let Ok(text) = std::str::from_utf8(&process.stdout) else {
                    return failed("invalidEncoding", "package readback is not UTF-8");
                };
                if !lists_bundle(text, bundle.bundle_name()) {
                    return Outcome::Failed {
                        code: "packageNotInstalled",
                        detail: format!("readback does not list {}", bundle.bundle_name()),
                    };
                }
                let mut summary = BTreeMap::new();
                summary.insert("bundleName".to_owned(), bundle.bundle_name().to_owned());
                summary.insert("installed".to_owned(), "true".to_owned());
                // Bound to the exact immutable Artifact whose lease this Job
                // resolved: a repairing caller compares it with the
                // build-output digest before it may enter VERIFYING.
                if let Some(digest) = resolved_sha256 {
                    summary.insert("deployedArtifactSha256".to_owned(), digest.to_owned());
                }
                append_native_library_facts(text, &mut summary);
                Outcome::Verified(summary)
            }
            Self::StartAbility(_) => match sole {
                None => Outcome::Unknown("start produced no process result".into()),
                Some(process) if process.exit_status != 0 => {
                    failed("startFailed", "start process reported failure")
                }
                Some(_) => Outcome::Unknown(
                    "start requires process readback before it can be believed".into(),
                ),
            },
            Self::VerifyProcessState(bundle) => {
                let Some(text) = sole.and_then(|process| std::str::from_utf8(&process.stdout).ok())
                else {
                    return failed("invalidEncoding", "process readback is not UTF-8");
                };
                let tokens: Vec<&str> = text
                    .split(char::is_whitespace)
                    .filter(|token| !token.is_empty())
                    .collect();
                if tokens.is_empty() || !tokens.iter().all(|token| live_pid(token)) {
                    return Outcome::Failed {
                        code: "processNotRunning",
                        detail: format!("no live process for {}", bundle.bundle_name()),
                    };
                }
                verified([
                    ("bundleName", bundle.bundle_name().to_owned()),
                    ("running", "true".to_owned()),
                ])
            }
            Self::StopAbility(ability) => {
                let [_, readback] = receipt.subprocesses.as_slice() else {
                    return Outcome::Unknown("stop did not produce its process readback".into());
                };
                let Some(running) = process_presence(readback) else {
                    return Outcome::Unknown(format!(
                        "process readback for {} is ambiguous",
                        ability.bundle.bundle_name()
                    ));
                };
                if running {
                    return Outcome::Failed {
                        code: "stopIneffective",
                        detail: format!(
                            "{} is still running after force-stop",
                            ability.bundle.bundle_name()
                        ),
                    };
                }
                verified([("stopped", ability.bundle.bundle_name().to_owned())])
            }
            Self::UninstallPackage(bundle) => {
                let [_, readback] = receipt.subprocesses.as_slice() else {
                    return Outcome::Unknown(
                        "uninstall did not produce its package readback".into(),
                    );
                };
                let Some(installed) = package_presence(readback, bundle.bundle_name()) else {
                    return Outcome::Unknown(format!(
                        "package readback for {} is ambiguous",
                        bundle.bundle_name()
                    ));
                };
                if installed {
                    return Outcome::Failed {
                        code: "uninstallIneffective",
                        detail: format!(
                            "{} is still installed after uninstall",
                            bundle.bundle_name()
                        ),
                    };
                }
                verified([("uninstalled", bundle.bundle_name().to_owned())])
            }
            Self::ReadPackagePresence(_)
            | Self::ReadProcessPresence(_)
            | Self::ReadOwnedPathPresence { .. }
            | Self::ReadOwnedDirectoryPresence(_) => match self.presence(receipt) {
                Some(present) => {
                    verified([("present", if present { "true" } else { "false" }.to_owned())])
                }
                None => Outcome::Unknown(
                    match self {
                        Self::ReadPackagePresence(_) => {
                            "package presence readback is not trustworthy"
                        }
                        Self::ReadProcessPresence(_) => "process presence readback is ambiguous",
                        Self::ReadOwnedPathPresence { .. } => {
                            "owned-path presence readback has no definite result"
                        }
                        _ => "owned-directory presence readback has no definite result",
                    }
                    .into(),
                ),
            },
        }
    }

    /// Swift's three-valued reading of a presence probe's receipt: what the
    /// device shows, or nothing when the probe is not trustworthy.
    pub fn presence(&self, receipt: &FileReceipt) -> Option<bool> {
        let sole = receipt.subprocesses.first()?;
        match self {
            Self::ReadPackagePresence(bundle) => package_presence(sole, bundle.bundle_name()),
            Self::ReadProcessPresence(_) => process_presence(sole),
            Self::ReadOwnedPathPresence { .. } | Self::ReadOwnedDirectoryPresence(_) => {
                path_presence(sole)
            }
            _ => None,
        }
    }

    /// Swift `reconciliationReadback`: the read-only probe that concludes a
    /// mutation whose outcome was never observed, without resending it.
    pub fn readback(&self) -> Option<Self> {
        Some(match self {
            Self::SendArtifactToStaging(staged) => Self::ReadOwnedPathPresence {
                path: staged.path.clone(),
            },
            Self::CleanupOwnedRemotePath { path } => {
                Self::ReadOwnedPathPresence { path: path.clone() }
            }
            Self::InstallPackage { bundle, .. }
            | Self::InstallPackageSet { bundle, .. }
            | Self::UninstallPackage(bundle) => Self::ReadPackagePresence(bundle.clone()),
            Self::SendPackageSetToStaging(set) | Self::CleanupStagedPackageSet(set) => {
                Self::ReadOwnedDirectoryPresence(set.directory.clone())
            }
            Self::StartAbility(ability) | Self::StopAbility(ability) => {
                Self::ReadProcessPresence(ability.bundle.clone())
            }
            _ => return None,
        })
    }

    /// Swift `desiredPresence`: what the readback must show for the mutation
    /// to count as done — present after a send, install or start; absent
    /// after a cleanup, stop or uninstall; nothing for a read.
    pub fn desired_presence(&self) -> Option<bool> {
        match self {
            Self::SendArtifactToStaging(_)
            | Self::SendPackageSetToStaging(_)
            | Self::InstallPackage { .. }
            | Self::InstallPackageSet { .. }
            | Self::StartAbility(_) => Some(true),
            Self::CleanupOwnedRemotePath { .. }
            | Self::CleanupStagedPackageSet(_)
            | Self::StopAbility(_)
            | Self::UninstallPackage(_) => Some(false),
            _ => None,
        }
    }
}

/// Swift `UInt32(token) > 0`.
fn live_pid(token: &str) -> bool {
    token.parse::<u32>().is_ok_and(|value| value > 0)
}

/// Swift `processPresence`: `pidof`'s answer as three values — no tokens is
/// stopped, only live PIDs is running, anything else is no answer. The exit
/// status is deliberately not read.
pub fn process_presence(receipt: &Receipt) -> Option<bool> {
    if receipt.truncated {
        return None;
    }
    let text = std::str::from_utf8(&receipt.stdout).ok()?;
    let tokens: Vec<&str> = text
        .split(char::is_whitespace)
        .filter(|token| !token.is_empty())
        .collect();
    if tokens.is_empty() {
        return Some(false);
    }
    tokens.iter().all(|token| live_pid(token)).then_some(true)
}

/// Swift `packagePresence`: a `bm dump -n` probe read three ways — the
/// bundle listed on its own boundaries, not listed, or not trustworthy
/// (a non-zero exit, a truncated or non-UTF-8 answer).
pub fn package_presence(receipt: &Receipt, bundle_name: &str) -> Option<bool> {
    if receipt.exit_status != 0 || receipt.truncated {
        return None;
    }
    let text = std::str::from_utf8(&receipt.stdout).ok()?;
    Some(lists_bundle(text, bundle_name))
}

/// Swift's `(^|[^A-Za-z0-9_.])<bundle>([^A-Za-z0-9_.]|$)`: the name on its
/// own boundaries, so `com.example.demo` is not found inside
/// `com.example.demo.helper`.
fn lists_bundle(text: &str, bundle_name: &str) -> bool {
    let boundary = |character: Option<char>| {
        character.is_none_or(|character| {
            !(character.is_ascii_alphanumeric() || character == '_' || character == '.')
        })
    };
    text.match_indices(bundle_name).any(|(start, found)| {
        boundary(text[..start].chars().next_back())
            && boundary(text[start + found.len()..].chars().next())
    })
}

/// Swift `installDispatchOutcome`: an install is never verified here — it
/// is only as true as its readback — but its failures are named: a non-zero
/// exit, truncated output, the device refusing the signing profile (`bm`
/// code 9568423), or any other answer than the success line.
pub fn install_dispatch_outcome(receipt: &FileReceipt) -> Outcome {
    let Some(process) = receipt.subprocesses.first() else {
        return Outcome::Unknown("install produced no process result".into());
    };
    if process.exit_status != 0 {
        return Outcome::Failed {
            code: "installFailed",
            detail: format!(
                "install process reported failure; {}",
                bounded_process_diagnostic(process)
            ),
        };
    }
    if process.truncated {
        return Outcome::Failed {
            code: "installOutputTruncated",
            detail: bounded_process_diagnostic(process),
        };
    }
    const BELIEVED: &str = "install requires package readback before it can be believed";
    if let Ok(text) = std::str::from_utf8(&process.stdout) {
        let lowered = text.to_lowercase();
        if lowered.contains("install bundle successfully") {
            return Outcome::Unknown(BELIEVED.into());
        }
        if text.contains("code:9568423") && lowered.contains("device is unauthorized") {
            return failed(
                "deviceUDIDUnauthorized",
                "package signing profile does not authorize the connected device (bm code 9568423)",
            );
        }
    }
    if !process.stdout.is_empty() || !process.stderr.is_empty() {
        return Outcome::Failed {
            code: "installRejected",
            detail: bounded_process_diagnostic(process),
        };
    }
    Outcome::Unknown(BELIEVED.into())
}

/// Swift `boundedProcessDiagnostic`: provider diagnostics are persisted in
/// Job failures, so only a bounded hex prefix of each stream is exposed.
pub fn bounded_process_diagnostic(receipt: &Receipt) -> String {
    let field = |bytes: &[u8]| hex(&bytes[..bytes.len().min(DIAGNOSTIC_BYTES)]);
    format!(
        "outBytes={},outHex={},errBytes={},errHex={},truncated={}",
        receipt.stdout.len(),
        field(&receipt.stdout),
        receipt.stderr.len(),
        field(&receipt.stderr),
        receipt.truncated
    )
}

/// Swift `appendNativeLibraryFacts`: what the device did with the packaged
/// native libraries, read from the `bm dump` document after the
/// `<bundleName>:` line — the library path and ABI the application got, and
/// how many library files the modules took. Empty values are the finding;
/// a document this cannot decode changes no verdict.
pub fn append_native_library_facts(text: &str, summary: &mut BTreeMap<String, String>) {
    let Some(start) = text.find('{') else {
        return;
    };
    let Ok(Value::Object(parsed)) = serde_json::from_str::<Value>(&text[start..]) else {
        return;
    };
    if let Some(Value::Object(application)) = parsed.get("applicationInfo") {
        if let Some(path) = application.get("nativeLibraryPath").and_then(Value::as_str) {
            summary.insert("nativeLibraryPath".to_owned(), path.to_owned());
        }
        if let Some(abi) = application.get("cpuAbi").and_then(Value::as_str) {
            summary.insert("cpuAbi".to_owned(), abi.to_owned());
        }
    }
    if let Some(Value::Array(modules)) = parsed.get("hapModuleInfos") {
        let counted: usize = modules
            .iter()
            .filter_map(|module| {
                module
                    .get("nativeLibraryFileNames")
                    .and_then(Value::as_array)
            })
            .map(Vec::len)
            .sum();
        summary.insert("nativeLibraryFileCount".to_owned(), counted.to_string());
    }
}

fn failed(code: &'static str, detail: &str) -> Outcome {
    Outcome::Failed {
        code,
        detail: detail.to_owned(),
    }
}

fn verified<const N: usize>(facts: [(&str, String); N]) -> Outcome {
    Outcome::Verified(
        facts
            .into_iter()
            .map(|(key, value)| (key.to_owned(), value))
            .collect(),
    )
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::capture_files::Landed;
    use serde_json::json;

    const KEY: &str = "150100424a544e4600";
    const JOB: &str = "job-hap-1";
    const LEASE: &str = "lease-v1:job-input-hap:ART-ce40ab95d8ec5ac89835a46e2d301004";
    const FEATURE: &str = "lease-v1:job-input-hap:ART-2ab8ee3a91b3198ef6404e610ed5179f";

    fn inputs(value: Value) -> Map<String, Value> {
        value.as_object().cloned().unwrap()
    }

    fn sub(stdout: &str, exit_status: i32) -> Receipt {
        Receipt {
            exit_status,
            stdout: stdout.as_bytes().to_vec(),
            stderr: Vec::new(),
            truncated: false,
            duration: Duration::from_millis(10),
        }
    }

    fn receipt(receipts: Vec<Receipt>) -> FileReceipt {
        FileReceipt {
            subprocesses: receipts,
            landed: None::<Landed>,
        }
    }

    fn resolved(id: &str, sha: char) -> ResolvedArtifact {
        ResolvedArtifact {
            artifact_id: id.to_owned(),
            sha256: sha.to_string().repeat(64),
            path: PathBuf::from(format!("/private/tmp/artifacts/{id}")),
        }
    }

    fn entry() -> ResolvedArtifact {
        resolved("ART-ce40ab95d8ec5ac89835a46e2d301004", 'a')
    }

    fn feature() -> ResolvedArtifact {
        resolved("ART-2ab8ee3a91b3198ef6404e610ed5179f", 'b')
    }

    fn single_inputs() -> Map<String, Value> {
        inputs(
            json!({"bundleName": "com.example.demo", "abilityName": "EntryAbility",
            "hapArtifactLease": LEASE}),
        )
    }

    fn set_inputs() -> Map<String, Value> {
        inputs(
            json!({"bundleName": "com.example.demo", "abilityName": "EntryAbility",
            "hapArtifactLease": LEASE, "additionalHapArtifactLeases": [FEATURE]}),
        )
    }

    fn arguments(plan: &FilePlan) -> Vec<Vec<String>> {
        match plan {
            FilePlan::Process(process) | FilePlan::Receive { process, .. } => {
                vec![process.arguments.clone()]
            }
            FilePlan::Sequence(invocations) => invocations
                .iter()
                .map(|invocation| invocation.arguments.clone())
                .collect(),
        }
    }

    fn strings(parts: &[&str]) -> Vec<String> {
        parts.iter().map(|part| (*part).to_owned()).collect()
    }

    fn step(
        kind: &str,
        action_id: Option<&str>,
        inputs: &Map<String, Value>,
        resolved: &[ResolvedArtifact],
    ) -> HapAction {
        HapAction::for_step("step", kind, action_id, inputs, JOB, resolved)
            .unwrap()
            .unwrap()
    }

    /// The single-package steps name one staged path across send, install
    /// and cleanup; the set form appears only with additional leases.
    #[test]
    fn steps_map_to_actions_over_one_staged_path_or_one_staged_set() {
        let single = single_inputs();
        let staged = "/data/local/tmp/arkdeck-job-hap-1-send-hap-owned.hap";
        let HapAction::SendArtifactToStaging(sent) = step("sendFile", None, &single, &[entry()])
        else {
            panic!()
        };
        assert_eq!(sent.path.remote_path, staged);
        assert_eq!(sent.artifact_lease_id, LEASE);
        assert_eq!(
            sent.expected_sha256.as_deref(),
            Some("a".repeat(64).as_str())
        );
        let HapAction::InstallPackage {
            staged: installed,
            bundle,
        } = step("installPackage", None, &single, &[])
        else {
            panic!()
        };
        assert_eq!(installed.path, sent.path);
        assert_eq!(
            installed.expected_sha256, None,
            "absent before any lease is resolved"
        );
        assert_eq!(bundle.bundle_name(), "com.example.demo");
        assert_eq!(
            step("cleanupOwnedRemotePath", None, &single, &[]),
            HapAction::CleanupOwnedRemotePath {
                path: sent.path.clone()
            }
        );
        assert_eq!(
            step("runApprovedRemoteRead", Some("packageInfo"), &single, &[]),
            HapAction::QueryPackageReadback(BundleReference::new("com.example.demo").unwrap())
        );
        assert!(matches!(
            step("startApplication", None, &single, &[]),
            HapAction::StartAbility(_)
        ));
        assert!(matches!(
            step("verifyRemoteState", None, &single, &[]),
            HapAction::VerifyProcessState(_)
        ));
        assert!(matches!(
            step("stopApplication", None, &single, &[]),
            HapAction::StopAbility(_)
        ));
        assert!(matches!(
            step("uninstallPackage", None, &single, &[]),
            HapAction::UninstallPackage(_)
        ));
        assert_eq!(
            HapAction::for_step("probe-device", "probeDevice", None, &single, JOB, &[]).unwrap(),
            None
        );
        assert_eq!(
            HapAction::for_step(
                "read",
                "runApprovedRemoteRead",
                Some("deviceModel"),
                &single,
                JOB,
                &[]
            )
            .unwrap(),
            None
        );
        let set = set_inputs();
        let HapAction::SendPackageSetToStaging(staged_set) =
            step("sendFile", None, &set, &[entry(), feature()])
        else {
            panic!()
        };
        assert_eq!(
            staged_set.directory.remote_path,
            "/data/local/tmp/arkdeck-job-hap-1-send-hap-owned-packages"
        );
        assert_eq!(
            staged_set
                .packages
                .iter()
                .map(|package| package.remote_path.as_str())
                .collect::<Vec<_>>(),
            vec![
                "/data/local/tmp/arkdeck-job-hap-1-send-hap-owned-packages/ART-ce40ab95d8ec5ac89835a46e2d301004.hap",
                "/data/local/tmp/arkdeck-job-hap-1-send-hap-owned-packages/ART-2ab8ee3a91b3198ef6404e610ed5179f.hap",
            ]
        );
        assert_eq!(
            staged_set.packages[1].expected_sha256.as_deref(),
            Some("b".repeat(64).as_str())
        );
        assert!(matches!(
            step("installPackage", None, &set, &[]),
            HapAction::InstallPackageSet { .. }
        ));
        assert!(matches!(
            step("cleanupOwnedRemotePath", None, &set, &[]),
            HapAction::CleanupStagedPackageSet(_)
        ));
        // Refusals.
        let refused = |inputs: Map<String, Value>, resolved: &[ResolvedArtifact], kind: &str| {
            HapAction::for_step("step", kind, None, &inputs, JOB, resolved)
                .unwrap_err()
                .to_string()
        };
        assert_eq!(
            refused(inputs(json!({"abilityName": "x"})), &[], "sendFile"),
            "unsupportedAction(\"bundleName input is required\")"
        );
        assert_eq!(
            refused(
                inputs(json!({"bundleName": "com.example.demo"})),
                &[],
                "sendFile"
            ),
            "unsupportedAction(\"hapArtifactLease input is required\")"
        );
        assert_eq!(
            refused(
                inputs(json!({"bundleName": "com.example.demo", "hapArtifactLease": LEASE})),
                &[],
                "startApplication"
            ),
            "unsupportedAction(\"abilityName input is required\")"
        );
        assert_eq!(
            refused(
                inputs(
                    json!({"bundleName": "com.example.demo", "hapArtifactLease": LEASE,
                "additionalHapArtifactLeases": [7]})
                ),
                &[],
                "sendFile"
            ),
            "unsupportedAction(\"additionalHapArtifactLeases must be artifact leases\")"
        );
        assert_eq!(
            refused(set_inputs(), &[feature(), entry()], "sendFile"),
            "unsupportedAction(\"resolved Artifact does not match the lease at position 0\")"
        );
        assert!(
            refused(
                inputs(json!({"bundleName": "demo", "hapArtifactLease": LEASE})),
                &[],
                "sendFile"
            )
            .starts_with("malformed(field: \"bundleName\"")
        );
        assert!(BundleReference::new("com.9example").is_err());
        assert!(
            AbilityReference::new(
                BundleReference::new("com.example.demo").unwrap(),
                "1Ability"
            )
            .is_err()
        );
        let directory =
            OwnedRemoteDirectory::new(JOB, "send-hap", "owned", DirectoryPurpose::Packages)
                .unwrap();
        assert!(StagedPackage::new(&directory, "../x", LEASE, None).is_err());
        let one = StagedPackage::new(&directory, "ART-1", LEASE, None).unwrap();
        assert!(StagedPackageSet::new(directory.clone(), vec![one.clone()]).is_err());
        assert!(StagedPackageSet::new(directory.clone(), vec![one.clone(), one.clone()]).is_err());
        let other = StagedPackage {
            remote_path: "/data/local/tmp/elsewhere/ART-2.hap".into(),
            artifact_lease_id: FEATURE.into(),
            expected_sha256: None,
        };
        assert!(StagedPackageSet::new(directory, vec![one, other]).is_err());
    }

    /// The exact argv, budgets and continue flags of every action; a send
    /// without its resolved Artifact lowers to nothing.
    #[test]
    fn the_actions_lower_to_swift_s_exact_arguments() {
        let single = single_inputs();
        let send = step("sendFile", None, &single, &[entry()]);
        let plan = send.lower("send-hap", Some(KEY), &[entry()]).unwrap();
        let staged = "/data/local/tmp/arkdeck-job-hap-1-send-hap-owned.hap";
        assert_eq!(
            arguments(&plan),
            vec![strings(&[
                "-t",
                KEY,
                "file",
                "send",
                "/private/tmp/artifacts/ART-ce40ab95d8ec5ac89835a46e2d301004",
                staged
            ])]
        );
        let FilePlan::Process(process) = &plan else {
            panic!()
        };
        assert_eq!(process.timeout, Duration::from_secs(300));
        assert_eq!(
            send.lower("send-hap", Some(KEY), &[]).unwrap_err(),
            "unsupportedAction(\"sendFile requires an engine-resolved Artifact lease\")"
        );
        assert!(
            send.lower(
                "send-hap",
                Some(KEY),
                &[resolved("ART-ce40ab95d8ec5ac89835a46e2d301004", 'f')]
            )
            .is_err(),
            "the bytes must be the pinned ones"
        );
        assert!(
            send.lower("send-hap", Some(KEY), &[feature()]).is_err(),
            "the identity must be the lease's"
        );
        assert!(
            send.lower("send-hap", None, &[entry()])
                .unwrap_err()
                .contains("factsUnavailable")
        );
        assert_eq!(
            arguments(
                &step("installPackage", None, &single, &[])
                    .lower("install-hap", Some(KEY), &[])
                    .unwrap()
            ),
            vec![strings(&[
                "-t", KEY, "shell", "bm", "install", "-p", staged, "-r"
            ])]
        );
        assert_eq!(
            arguments(
                &step("runApprovedRemoteRead", Some("packageInfo"), &single, &[])
                    .lower("package-readback", Some(KEY), &[])
                    .unwrap()
            ),
            vec![strings(&[
                "-t",
                KEY,
                "shell",
                "bm",
                "dump",
                "-n",
                "com.example.demo"
            ])]
        );
        assert_eq!(
            arguments(
                &step("startApplication", None, &single, &[])
                    .lower("start-ability", Some(KEY), &[])
                    .unwrap()
            ),
            vec![strings(&[
                "-t",
                KEY,
                "shell",
                "aa",
                "start",
                "-b",
                "com.example.demo",
                "-a",
                "EntryAbility"
            ])]
        );
        assert_eq!(
            arguments(
                &step("verifyRemoteState", None, &single, &[])
                    .lower("process-readback", Some(KEY), &[])
                    .unwrap()
            ),
            vec![strings(&["-t", KEY, "shell", "pidof", "com.example.demo"])]
        );
        let stop = step("stopApplication", None, &single, &[])
            .lower("stop-ability", Some(KEY), &[])
            .unwrap();
        assert_eq!(
            arguments(&stop),
            vec![
                strings(&["-t", KEY, "shell", "aa", "force-stop", "com.example.demo"]),
                strings(&["-t", KEY, "shell", "pidof", "com.example.demo"]),
            ]
        );
        let FilePlan::Sequence(invocations) = &stop else {
            panic!()
        };
        assert_eq!(
            (
                invocations[0].timeout.as_secs(),
                invocations[0].continue_after_non_zero
            ),
            (60, true)
        );
        assert_eq!(
            (
                invocations[1].timeout.as_secs(),
                invocations[1].continue_after_non_zero
            ),
            (30, false)
        );
        let uninstall = step("uninstallPackage", None, &single, &[])
            .lower("cleanup-uninstall", Some(KEY), &[])
            .unwrap();
        assert_eq!(
            arguments(&uninstall),
            vec![
                strings(&["-t", KEY, "uninstall", "com.example.demo"]),
                strings(&["-t", KEY, "shell", "bm", "dump", "-n", "com.example.demo"]),
            ]
        );
        let FilePlan::Sequence(invocations) = &uninstall else {
            panic!()
        };
        assert_eq!(
            (
                invocations[0].timeout.as_secs(),
                invocations[0].continue_after_non_zero
            ),
            (120, true)
        );
        assert_eq!(
            arguments(
                &step("cleanupOwnedRemotePath", None, &single, &[])
                    .lower("cleanup-remote-staging", Some(KEY), &[])
                    .unwrap()
            ),
            vec![strings(&["-t", KEY, "shell", "rm", "-f", staged])]
        );
        // The set: a directory, one send per package, the install of the
        // directory, and the cleanup by name ending in the presence readback.
        let set = set_inputs();
        let both = [entry(), feature()];
        let directory = "/data/local/tmp/arkdeck-job-hap-1-send-hap-owned-packages";
        let sent = step("sendFile", None, &set, &both)
            .lower("send-hap", Some(KEY), &both)
            .unwrap();
        assert_eq!(
            arguments(&sent),
            vec![
                strings(&["-t", KEY, "shell", "mkdir", "-p", directory]),
                strings(&[
                    "-t",
                    KEY,
                    "file",
                    "send",
                    "/private/tmp/artifacts/ART-ce40ab95d8ec5ac89835a46e2d301004",
                    &format!("{directory}/ART-ce40ab95d8ec5ac89835a46e2d301004.hap")
                ]),
                strings(&[
                    "-t",
                    KEY,
                    "file",
                    "send",
                    "/private/tmp/artifacts/ART-2ab8ee3a91b3198ef6404e610ed5179f",
                    &format!("{directory}/ART-2ab8ee3a91b3198ef6404e610ed5179f.hap")
                ]),
            ]
        );
        assert_eq!(
            step("sendFile", None, &set, &both)
                .lower("send-hap", Some(KEY), &[entry()])
                .unwrap_err(),
            "unsupportedAction(\"package-set send requires the engine-resolved lease for every package\")"
        );
        assert_eq!(
            step("sendFile", None, &set, &both)
                .lower(
                    "send-hap",
                    Some(KEY),
                    &[
                        entry(),
                        resolved("ART-2ab8ee3a91b3198ef6404e610ed5179f", 'c')
                    ]
                )
                .unwrap_err(),
            "unsupportedAction(\"staged package does not match its engine-resolved Artifact\")"
        );
        assert_eq!(
            arguments(
                &step("installPackage", None, &set, &both)
                    .lower("install-hap", Some(KEY), &[])
                    .unwrap()
            ),
            vec![strings(&[
                "-t", KEY, "shell", "bm", "install", "-p", directory, "-r"
            ])]
        );
        let cleanup = step("cleanupOwnedRemotePath", None, &set, &both)
            .lower("cleanup-remote-staging", Some(KEY), &[])
            .unwrap();
        assert_eq!(
            arguments(&cleanup),
            vec![
                strings(&[
                    "-t",
                    KEY,
                    "shell",
                    "rm",
                    "-f",
                    &format!("{directory}/ART-ce40ab95d8ec5ac89835a46e2d301004.hap")
                ]),
                strings(&[
                    "-t",
                    KEY,
                    "shell",
                    "rm",
                    "-f",
                    &format!("{directory}/ART-2ab8ee3a91b3198ef6404e610ed5179f.hap")
                ]),
                strings(&["-t", KEY, "shell", "rmdir", directory]),
                strings(&["-t", KEY, "shell", "ls", "-ld", directory]),
            ]
        );
        let FilePlan::Sequence(invocations) = &cleanup else {
            panic!()
        };
        assert_eq!(
            invocations
                .iter()
                .map(|invocation| (
                    invocation.timeout.as_secs(),
                    invocation.continue_after_non_zero
                ))
                .collect::<Vec<_>>(),
            vec![(30, true), (30, true), (30, false), (15, false)]
        );
        // The recovery reads.
        let bundle = BundleReference::new("com.example.demo").unwrap();
        assert_eq!(
            arguments(
                &HapAction::ReadPackagePresence(bundle.clone())
                    .lower("r", Some(KEY), &[])
                    .unwrap()
            ),
            vec![strings(&[
                "-t",
                KEY,
                "shell",
                "bm",
                "dump",
                "-n",
                "com.example.demo"
            ])]
        );
        assert_eq!(
            arguments(
                &HapAction::ReadProcessPresence(bundle)
                    .lower("r", Some(KEY), &[])
                    .unwrap()
            ),
            vec![strings(&["-t", KEY, "shell", "pidof", "com.example.demo"])]
        );
        let path = OwnedRemotePath::stable(JOB, "send-hap", ImageType::Png).unwrap();
        assert_eq!(
            arguments(
                &HapAction::ReadOwnedPathPresence { path }
                    .lower("r", Some(KEY), &[])
                    .unwrap()
            ),
            vec![strings(&["-t", KEY, "shell", "ls", "-ld", staged])]
        );
        let directory =
            OwnedRemoteDirectory::new(JOB, "send-hap", "owned", DirectoryPurpose::Packages)
                .unwrap();
        assert_eq!(
            arguments(
                &HapAction::ReadOwnedDirectoryPresence(directory)
                    .lower("r", Some(KEY), &[])
                    .unwrap()
            ),
            vec![strings(&[
                "-t",
                KEY,
                "shell",
                "ls",
                "-ld",
                "/data/local/tmp/arkdeck-job-hap-1-send-hap-owned-packages"
            ])]
        );
    }

    /// Swift's verdicts: the mutations believed only through their readbacks.
    #[test]
    fn mutations_are_believed_only_through_their_readbacks() {
        let single = single_inputs();
        let send = step("sendFile", None, &single, &[entry()]);
        let staged = "/data/local/tmp/arkdeck-job-hap-1-send-hap-owned.hap".to_owned();
        assert_eq!(
            send.verify(&receipt(vec![sub("FileTransfer finish\n", 0)]), None),
            verified([("stagedAt", staged.clone())])
        );
        assert!(matches!(
            send.verify(&receipt(vec![sub("", 1)]), None),
            Outcome::Failed {
                code: "sendFailed",
                ..
            }
        ));
        let install = step("installPackage", None, &single, &[]);
        assert_eq!(
            install.verify(
                &receipt(vec![sub("install bundle successfully.\n", 0)]),
                None
            ),
            Outcome::Unknown("install requires package readback before it can be believed".into())
        );
        assert_eq!(
            install.verify(&receipt(vec![sub("", 0)]), None),
            Outcome::Unknown("install requires package readback before it can be believed".into())
        );
        let Outcome::Failed {
            code: "installFailed",
            detail,
        } = install.verify(&receipt(vec![sub("error\n", 1)]), None)
        else {
            panic!()
        };
        assert_eq!(
            detail,
            "install process reported failure; outBytes=6,outHex=6572726f720a,errBytes=0,errHex=,truncated=false"
        );
        let mut truncated = sub("x", 0);
        truncated.truncated = true;
        assert!(matches!(
            install.verify(&receipt(vec![truncated]), None),
            Outcome::Failed {
                code: "installOutputTruncated",
                ..
            }
        ));
        assert!(matches!(
            install.verify(
                &receipt(vec![sub(
                    "error: failed to install bundle. code:9568423 error: Device is unauthorized\n",
                    0
                )]),
                None
            ),
            Outcome::Failed {
                code: "deviceUDIDUnauthorized",
                ..
            }
        ));
        let Outcome::Failed {
            code: "installRejected",
            detail,
        } = install.verify(&receipt(vec![sub("error: signature\n", 0)]), None)
        else {
            panic!()
        };
        assert!(detail.starts_with("outBytes=17,outHex="), "{detail}");
        let mut long = sub("", 0);
        long.stdout = vec![b'z'; 1000];
        let Outcome::Failed { detail, .. } = install.verify(&receipt(vec![long]), None) else {
            panic!()
        };
        assert!(detail.contains(&format!("outBytes=1000,outHex={}", "7a".repeat(512))));
        assert!(matches!(
            install.verify(&receipt(vec![]), None),
            Outcome::Unknown(_)
        ));
        // The package readback: the bundle on its own boundaries, the
        // deployed digest, and the native-library facts.
        let readback = step("runApprovedRemoteRead", Some("packageInfo"), &single, &[]);
        let dump = "com.example.demo:\n{\"applicationInfo\":{\"nativeLibraryPath\":\"libs/arm64\",\"cpuAbi\":\"arm64-v8a\"},\"hapModuleInfos\":[{\"nativeLibraryFileNames\":[\"libentry.so\"]},{\"nativeLibraryFileNames\":[]}]}\n";
        let Outcome::Verified(summary) =
            readback.verify(&receipt(vec![sub(dump, 0)]), Some("d".repeat(64).as_str()))
        else {
            panic!()
        };
        assert_eq!(summary["bundleName"], "com.example.demo");
        assert_eq!(summary["installed"], "true");
        assert_eq!(summary["deployedArtifactSha256"], "d".repeat(64));
        assert_eq!(summary["nativeLibraryPath"], "libs/arm64");
        assert_eq!(summary["cpuAbi"], "arm64-v8a");
        assert_eq!(summary["nativeLibraryFileCount"], "1");
        let Outcome::Verified(summary) =
            readback.verify(&receipt(vec![sub("com.example.demo:\n", 0)]), None)
        else {
            panic!()
        };
        assert_eq!(summary.len(), 2);
        assert!(matches!(
            readback.verify(&receipt(vec![sub("com.example.demo.helper:\n", 0)]), None),
            Outcome::Failed {
                code: "packageNotInstalled",
                ..
            }
        ));
        assert!(matches!(
            readback.verify(&receipt(vec![sub("", 0)]), None),
            Outcome::Failed {
                code: "packageNotInstalled",
                ..
            }
        ));
        assert!(
            matches!(
                readback.verify(&receipt(vec![sub("xcom.example.demo\n", 1)]), None),
                Outcome::Failed {
                    code: "packageNotInstalled",
                    ..
                }
            ),
            "the readback verdict ignores the exit status; the boundary decides"
        );
        let mut binary = sub("", 0);
        binary.stdout = vec![0xFF];
        assert!(matches!(
            readback.verify(&receipt(vec![binary]), None),
            Outcome::Failed {
                code: "invalidEncoding",
                ..
            }
        ));
        // Start: never verified; failure by exit.
        let start = step("startApplication", None, &single, &[]);
        assert_eq!(
            start.verify(&receipt(vec![sub("start ability successfully\n", 0)]), None),
            Outcome::Unknown("start requires process readback before it can be believed".into())
        );
        assert!(matches!(
            start.verify(&receipt(vec![sub("", 1)]), None),
            Outcome::Failed {
                code: "startFailed",
                ..
            }
        ));
        assert!(matches!(
            start.verify(&receipt(vec![]), None),
            Outcome::Unknown(_)
        ));
        // Process state.
        let process = step("verifyRemoteState", None, &single, &[]);
        assert_eq!(
            process.verify(&receipt(vec![sub("3421 3422\n", 0)]), None),
            verified([
                ("bundleName", "com.example.demo".into()),
                ("running", "true".into())
            ])
        );
        for answer in ["", "\n", "3421 abc", "0"] {
            assert!(
                matches!(
                    process.verify(&receipt(vec![sub(answer, 0)]), None),
                    Outcome::Failed {
                        code: "processNotRunning",
                        ..
                    }
                ),
                "{answer:?}"
            );
        }
        // Stop and uninstall: judged by the second process, three-valued.
        let stop = step("stopApplication", None, &single, &[]);
        assert_eq!(
            stop.verify(&receipt(vec![sub("", 0), sub("", 1)]), None),
            verified([("stopped", "com.example.demo".into())])
        );
        assert!(matches!(
            stop.verify(&receipt(vec![sub("", 0), sub("3421\n", 0)]), None),
            Outcome::Failed {
                code: "stopIneffective",
                ..
            }
        ));
        assert!(matches!(
            stop.verify(&receipt(vec![sub("", 0), sub("3421 x\n", 0)]), None),
            Outcome::Unknown(_)
        ));
        assert!(matches!(
            stop.verify(&receipt(vec![sub("", 0)]), None),
            Outcome::Unknown(_)
        ));
        let uninstall = step("uninstallPackage", None, &single, &[]);
        assert_eq!(
            uninstall.verify(
                &receipt(vec![sub("uninstall bundle successfully\n", 0), sub("", 0)]),
                None
            ),
            verified([("uninstalled", "com.example.demo".into())])
        );
        assert!(matches!(
            uninstall.verify(
                &receipt(vec![sub("", 0), sub("com.example.demo:\n{}\n", 0)]),
                None
            ),
            Outcome::Failed {
                code: "uninstallIneffective",
                ..
            }
        ));
        assert!(matches!(
            uninstall.verify(&receipt(vec![sub("", 0), sub("", 1)]), None),
            Outcome::Unknown(_)
        ));
        // Cleanups.
        let cleanup = step("cleanupOwnedRemotePath", None, &single, &[]);
        assert_eq!(
            cleanup.verify(&receipt(vec![sub("", 0)]), None),
            verified([("cleaned", staged)])
        );
        assert!(matches!(
            cleanup.verify(&receipt(vec![sub("", 1)]), None),
            Outcome::Failed {
                code: "cleanupDebt",
                ..
            }
        ));
        let set_cleanup = step(
            "cleanupOwnedRemotePath",
            None,
            &set_inputs(),
            &[entry(), feature()],
        );
        let directory = "/data/local/tmp/arkdeck-job-hap-1-send-hap-owned-packages";
        let gone = format!("ls: {directory}: No such file or directory\n");
        assert_eq!(
            set_cleanup.verify(
                &receipt(vec![sub("", 0), sub("", 0), sub("", 0), sub(&gone, 0)]),
                None
            ),
            verified([("cleaned", directory.into())])
        );
        assert!(matches!(
            set_cleanup.verify(
                &receipt(vec![
                    sub("", 0),
                    sub("", 0),
                    sub("", 1),
                    sub(
                        &format!("drwxr-xr-x 2 shell shell 3452 2026-09-14 00:00 {directory}\n"),
                        0
                    )
                ]),
                None
            ),
            Outcome::Failed {
                code: "cleanupDebt",
                ..
            }
        ));
        assert!(matches!(
            set_cleanup.verify(&receipt(vec![sub("", 0)]), None),
            Outcome::Unknown(_)
        ));
        let set_send = step("sendFile", None, &set_inputs(), &[entry(), feature()]);
        assert_eq!(
            set_send.verify(&receipt(vec![sub("", 0), sub("", 0), sub("", 0)]), None),
            verified([("stagedAt", directory.into()), ("packageCount", "2".into())])
        );
        assert!(matches!(
            set_send.verify(&receipt(vec![sub("", 0), sub("", 1), sub("", 0)]), None),
            Outcome::Failed {
                code: "sendFailed",
                ..
            }
        ));
        assert!(matches!(
            set_send.verify(&receipt(vec![sub("", 0), sub("", 0)]), None),
            Outcome::Unknown(_)
        ));
    }

    /// The recovery table: which read concludes which mutation, what it must
    /// show, and how each read is judged.
    #[test]
    fn a_mutation_is_concluded_by_its_paired_read_and_the_presence_it_wanted() {
        let single = single_inputs();
        let set = set_inputs();
        let bundle = BundleReference::new("com.example.demo").unwrap();
        let path = OwnedRemotePath::stable(JOB, "send-hap", ImageType::Png).unwrap();
        let directory =
            OwnedRemoteDirectory::new(JOB, "send-hap", "owned", DirectoryPurpose::Packages)
                .unwrap();
        let cases = [
            (
                step("sendFile", None, &single, &[entry()]),
                Some(HapAction::ReadOwnedPathPresence { path: path.clone() }),
                Some(true),
            ),
            (
                step("installPackage", None, &single, &[]),
                Some(HapAction::ReadPackagePresence(bundle.clone())),
                Some(true),
            ),
            (
                step("startApplication", None, &single, &[]),
                Some(HapAction::ReadProcessPresence(bundle.clone())),
                Some(true),
            ),
            (
                step("stopApplication", None, &single, &[]),
                Some(HapAction::ReadProcessPresence(bundle.clone())),
                Some(false),
            ),
            (
                step("uninstallPackage", None, &single, &[]),
                Some(HapAction::ReadPackagePresence(bundle.clone())),
                Some(false),
            ),
            (
                step("cleanupOwnedRemotePath", None, &single, &[]),
                Some(HapAction::ReadOwnedPathPresence { path }),
                Some(false),
            ),
            (
                step("sendFile", None, &set, &[entry(), feature()]),
                Some(HapAction::ReadOwnedDirectoryPresence(directory.clone())),
                Some(true),
            ),
            (
                step("installPackage", None, &set, &[]),
                Some(HapAction::ReadPackagePresence(bundle.clone())),
                Some(true),
            ),
            (
                step("cleanupOwnedRemotePath", None, &set, &[]),
                Some(HapAction::ReadOwnedDirectoryPresence(directory)),
                Some(false),
            ),
            (
                step("runApprovedRemoteRead", Some("packageInfo"), &single, &[]),
                None,
                None,
            ),
            (step("verifyRemoteState", None, &single, &[]), None, None),
        ];
        for (action, readback, desired) in cases {
            assert_eq!(action.readback(), readback, "{action:?}");
            assert_eq!(action.desired_presence(), desired, "{action:?}");
            assert_eq!(
                action.effect(),
                if desired.is_some() {
                    "deviceMutation"
                } else {
                    "readOnly"
                }
            );
        }
        let package = HapAction::ReadPackagePresence(bundle.clone());
        assert_eq!(
            package.verify(&receipt(vec![sub("com.example.demo:\n{}\n", 0)]), None),
            verified([("present", "true".into())])
        );
        assert_eq!(
            package.verify(&receipt(vec![sub("", 0)]), None),
            verified([("present", "false".into())])
        );
        assert_eq!(
            package.verify(&receipt(vec![sub("", 1)]), None),
            Outcome::Unknown("package presence readback is not trustworthy".into())
        );
        assert_eq!(
            package.presence(&receipt(vec![sub("com.example.demo.helper:\n", 0)])),
            Some(false)
        );
        let process = HapAction::ReadProcessPresence(bundle);
        assert_eq!(
            process.verify(&receipt(vec![sub("3421\n", 0)]), None),
            verified([("present", "true".into())])
        );
        assert_eq!(
            process.verify(&receipt(vec![sub("", 1)]), None),
            verified([("present", "false".into())]),
            "the exit status is not read"
        );
        assert_eq!(
            process.verify(&receipt(vec![sub("3421 x\n", 0)]), None),
            Outcome::Unknown("process presence readback is ambiguous".into())
        );
        let path = HapAction::ReadOwnedPathPresence {
            path: OwnedRemotePath::stable(JOB, "send-hap", ImageType::Png).unwrap(),
        };
        assert_eq!(
            path.verify(
                &receipt(vec![sub(
                    "-rw-r--r-- 1 shell shell 24 2026-09-14 00:00 x\n",
                    0
                )]),
                None
            ),
            verified([("present", "true".into())])
        );
        assert_eq!(
            path.verify(
                &receipt(vec![sub("ls: x: No such file or directory\n", 0)]),
                None
            ),
            verified([("present", "false".into())])
        );
        assert_eq!(
            path.verify(&receipt(vec![sub("", 0)]), None),
            Outcome::Unknown("owned-path presence readback has no definite result".into())
        );
        let directory = HapAction::ReadOwnedDirectoryPresence(
            OwnedRemoteDirectory::new(JOB, "send-hap", "owned", DirectoryPurpose::Packages)
                .unwrap(),
        );
        assert_eq!(
            directory.verify(
                &receipt(vec![sub(
                    "drwxr-xr-x 2 shell shell 3452 2026-09-14 00:00 x\n",
                    0
                )]),
                None
            ),
            verified([("present", "true".into())])
        );
        assert_eq!(
            directory.verify(&receipt(vec![sub("", 0)]), None),
            Outcome::Unknown("owned-directory presence readback has no definite result".into())
        );
    }

    /// Swift `materialize()`: every persisted form of the family reads back
    /// as the action that wrote it, and what Swift refuses is refused.
    #[test]
    fn persisted_forms_materialize_as_swift_materializes_them() {
        let (single, set) = (single_inputs(), set_inputs());
        let mut actions: Vec<HapAction> = [
            ("sendFile", None, &single),
            ("installPackage", None, &single),
            ("cleanupOwnedRemotePath", None, &single),
            ("sendFile", None, &set),
            ("installPackage", None, &set),
            ("cleanupOwnedRemotePath", None, &set),
            ("startApplication", None, &single),
            ("verifyRemoteState", None, &single),
            ("stopApplication", None, &single),
            ("uninstallPackage", None, &single),
            ("runApprovedRemoteRead", Some("packageInfo"), &single),
        ]
        .into_iter()
        .map(|(kind, action, inputs)| step(kind, action, inputs, &[entry(), feature()]))
        .collect();
        let readbacks: Vec<HapAction> = actions.iter().filter_map(HapAction::readback).collect();
        actions.extend(readbacks);
        for action in actions {
            let (kind, arguments) = action.persisted();
            assert_eq!(
                HapAction::from_persisted(kind, &arguments).unwrap(),
                Some(action),
                "{kind}"
            );
        }

        let refused = |kind: &str, arguments: Value| {
            HapAction::from_persisted(kind, arguments.as_object().unwrap())
                .unwrap_err()
                .to_string()
        };
        assert_eq!(
            refused("hdc.uninstallPackage", json!({})),
            "unsupportedAction(\"persisted hdc.uninstallPackage is missing string bundleName\")"
        );
        assert_eq!(
            refused("hdc.uninstallPackage", json!({"bundleName": "demo"})),
            "malformed(field: \"bundleName\", detail: \"reverse-DNS identifier expected\")"
        );
        let cleanup = step("cleanupOwnedRemotePath", None, &single, &[])
            .persisted()
            .1;
        let mut moved = Value::Object(cleanup);
        moved["remotePath"] = json!("/data/local/tmp/elsewhere.hap");
        assert_eq!(
            refused("hdc.cleanupOwnedRemotePath", moved),
            "unsupportedAction(\"persisted hdc.cleanupOwnedRemotePath remote path does not \
             match its owned components\")"
        );
        let mut hashed = Value::Object(step("sendFile", None, &single, &[]).persisted().1);
        hashed["expectedSha256"] = json!(1);
        assert_eq!(
            refused("hdc.sendArtifactToStaging", hashed),
            "unsupportedAction(\"persisted hdc.sendArtifactToStaging.expectedSha256 is not a \
             string\")"
        );
        let mut listed = Value::Object(
            step("cleanupOwnedRemotePath", None, &set, &[])
                .persisted()
                .1,
        );
        let packages = listed["packages"].clone();
        listed.as_object_mut().unwrap().remove("packages");
        assert_eq!(
            refused("hdc.cleanupStagedPackageSet", listed.clone()),
            "unsupportedAction(\"persisted hdc.cleanupStagedPackageSet carries no staged package \
             list\")"
        );
        listed["packages"] = packages;
        listed["packages"][1]
            .as_object_mut()
            .unwrap()
            .remove("artifactLeaseId");
        assert_eq!(
            refused("hdc.cleanupStagedPackageSet", listed),
            "unsupportedAction(\"persisted hdc.cleanupStagedPackageSet carries a malformed staged \
             package\")"
        );
        // Another family's kind is not this family's to read.
        assert_eq!(
            HapAction::from_persisted("hdc.injectPointerInput", &Map::new()).unwrap(),
            None
        );
    }

    /// The journal forms Swift persists.
    #[test]
    fn persisted_forms_follow_swift() {
        let single = single_inputs();
        let (kind, arguments) = step("sendFile", None, &single, &[entry()]).persisted();
        assert_eq!(kind, "hdc.sendArtifactToStaging");
        assert_eq!(
            Value::Object(arguments),
            json!({"jobId": JOB, "stepId": "send-hap", "nonce": "owned",
                "remotePath": "/data/local/tmp/arkdeck-job-hap-1-send-hap-owned.hap",
                "artifactLeaseId": LEASE, "expectedSha256": "a".repeat(64)})
        );
        let (kind, arguments) = step("installPackage", None, &single, &[]).persisted();
        assert_eq!(kind, "hdc.installPackage");
        assert_eq!(arguments["bundleName"], "com.example.demo");
        assert!(!arguments.contains_key("expectedSha256"));
        let (kind, arguments) = step("sendFile", None, &set_inputs(), &[entry()]).persisted();
        assert_eq!(kind, "hdc.sendPackageSetToStaging");
        assert_eq!(
            arguments["directoryPath"],
            "/data/local/tmp/arkdeck-job-hap-1-send-hap-owned-packages"
        );
        assert_eq!(
            arguments["packages"],
            json!([
                {"remotePath": "/data/local/tmp/arkdeck-job-hap-1-send-hap-owned-packages/ART-ce40ab95d8ec5ac89835a46e2d301004.hap", "artifactLeaseId": LEASE, "sha256": "a".repeat(64)},
                {"remotePath": "/data/local/tmp/arkdeck-job-hap-1-send-hap-owned-packages/ART-2ab8ee3a91b3198ef6404e610ed5179f.hap", "artifactLeaseId": FEATURE, "sha256": null},
            ])
        );
        assert_eq!(
            step("installPackage", None, &set_inputs(), &[])
                .persisted()
                .0,
            "hdc.installPackageSet"
        );
        assert_eq!(
            step("cleanupOwnedRemotePath", None, &set_inputs(), &[])
                .persisted()
                .0,
            "hdc.cleanupStagedPackageSet"
        );
        let (kind, arguments) = step("startApplication", None, &single, &[]).persisted();
        assert_eq!(kind, "hdc.startAbility");
        assert_eq!(
            Value::Object(arguments),
            json!({"bundleName": "com.example.demo", "abilityName": "EntryAbility"})
        );
        assert_eq!(
            step("stopApplication", None, &single, &[]).persisted().0,
            "hdc.stopAbility"
        );
        assert_eq!(
            step("uninstallPackage", None, &single, &[]).persisted().0,
            "hdc.uninstallPackage"
        );
        assert_eq!(
            step("verifyRemoteState", None, &single, &[]).persisted().0,
            "hdc.verifyProcessState"
        );
        assert_eq!(
            step("runApprovedRemoteRead", Some("packageInfo"), &single, &[])
                .persisted()
                .0,
            "hdc.queryPackageReadback"
        );
        let directory =
            OwnedRemoteDirectory::new(JOB, "send-hap", "owned", DirectoryPurpose::Packages)
                .unwrap();
        let (kind, arguments) = HapAction::ReadOwnedDirectoryPresence(directory).persisted();
        assert_eq!(kind, "hdc.readOwnedDirectoryPresence");
        assert_eq!(
            arguments["directoryPath"],
            "/data/local/tmp/arkdeck-job-hap-1-send-hap-owned-packages"
        );
    }

    /// The parsers on their own.
    #[test]
    fn the_parsers_read_as_swift_reads() {
        assert_eq!(process_presence(&sub("", 1)), Some(false));
        assert_eq!(process_presence(&sub("3421 3422", 0)), Some(true));
        assert_eq!(process_presence(&sub("0", 0)), None);
        let mut truncated = sub("3421", 0);
        truncated.truncated = true;
        assert_eq!(process_presence(&truncated), None);
        assert_eq!(
            package_presence(&sub("com.example.demo:\n", 0), "com.example.demo"),
            Some(true)
        );
        assert_eq!(
            package_presence(&sub("com.example.demo.helper:\n", 0), "com.example.demo"),
            Some(false)
        );
        assert_eq!(
            package_presence(&sub("xcom.example.demo\n", 0), "com.example.demo"),
            Some(false)
        );
        assert_eq!(
            package_presence(&sub("a com.example.demo b\n", 0), "com.example.demo"),
            Some(true)
        );
        assert_eq!(
            package_presence(&sub("com.example.demo", 0), "com.example.demo"),
            Some(true)
        );
        assert_eq!(
            package_presence(&sub("com.example.demo:\n", 1), "com.example.demo"),
            None
        );
        let mut summary = BTreeMap::new();
        append_native_library_facts("not json", &mut summary);
        assert!(summary.is_empty());
        append_native_library_facts(
            "x:\n{\"applicationInfo\":{\"nativeLibraryPath\":\"\",\"cpuAbi\":\"arm64-v8a\"},\"hapModuleInfos\":[]}",
            &mut summary,
        );
        assert_eq!(summary["nativeLibraryPath"], "", "empty is the finding");
        assert_eq!(summary["nativeLibraryFileCount"], "0");
        assert_eq!(
            bounded_process_diagnostic(&sub("ab", 0)),
            "outBytes=2,outHex=6162,errBytes=0,errHex=,truncated=false"
        );
    }
}
