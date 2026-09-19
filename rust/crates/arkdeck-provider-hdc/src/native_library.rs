//! `deploy.native-library.app-owned@1`'s device actions as Swift's HDC
//! provider (`HDCObservationProviderAdapter`, `nativeLibraryAction`) chooses,
//! lowers and judges them: a leased, host-verified native library staged
//! into the target application's own data directory together with the
//! bundled code-sign helper, the current library backed up by a hard link,
//! the replacement published atomically by the helper (which enables the
//! platform's attestation when the file it replaces carries one), the
//! target stopped and started, the loaded library proved through the
//! process's own maps, and the staging cleaned by name — with the rollback
//! and the read-only inspections that let a crash-interrupted deployment be
//! concluded or undone without resending a mutation.
//!
//! The provider-owned namespace is derived here from the bundle, the ABI and
//! the Job; no caller supplies a device path. The library's facts come from
//! [`crate::native_elf::validate_elf`] over its bytes, never from a caller.
use crate::capture_files::{FileActionError, FilePlan, FileReceipt, Invocation, path_presence};
use crate::debug_hap::{
    BundleReference, PersistedArguments, ResolvedArtifact, bounded_process_diagnostic,
};
use crate::native_elf::{CodeSignFacts, NativeAbi, NativeLibraryFacts, validate_elf};
use crate::{Outcome, Receipt};
use serde_json::{Map, Value, json};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::time::Duration;

/// Swift `HDCAppOwnedNativeLibraryDeployment.entryAbility` / `userID` /
/// `moduleName`.
const ENTRY_ABILITY: &str = "EntryAbility";
const USER_ID: &str = "100";
const MODULE_NAME: &str = "entry";
/// Swift `HDCObservationProviderAdapter.loaderNotObserved`.
const LOADER_NOT_OBSERVED: &str = "notObserved";
/// The helper's markers and the errnos that mean "present, unattested".
const VERIFIED_MARKER: &str = "ARKDECK_CODE_SIGN_VERIFIED";
const PUBLISHED_MARKER: &str = "ARKDECK_CODE_SIGN_PUBLISHED";
const UNATTESTED_ERRNO_FIELDS: [&str; 2] = ["errno=61", "errno=95"];

/// Swift `HDCNativeRestartProfile`.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RestartProfile {
    RestartAbility,
    RestartProcess,
    None,
}

impl RestartProfile {
    pub fn raw(self) -> &'static str {
        match self {
            Self::RestartAbility => "restartAbility",
            Self::RestartProcess => "restartProcess",
            Self::None => "none",
        }
    }

    pub fn parse(raw: &str) -> Option<Self> {
        match raw {
            "restartAbility" => Some(Self::RestartAbility),
            "restartProcess" => Some(Self::RestartProcess),
            "none" => Some(Self::None),
            _ => Option::None,
        }
    }
}

/// Swift `HDCNativeVerificationProfile`.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum VerificationProfile {
    HashOnly,
    HashAndProcess,
    HashProcessAndMaps,
}

impl VerificationProfile {
    pub fn raw(self) -> &'static str {
        match self {
            Self::HashOnly => "hashOnly",
            Self::HashAndProcess => "hashAndProcess",
            Self::HashProcessAndMaps => "hashProcessAndMaps",
        }
    }

    pub fn parse(raw: &str) -> Option<Self> {
        match raw {
            "hashOnly" => Some(Self::HashOnly),
            "hashAndProcess" => Some(Self::HashAndProcess),
            "hashProcessAndMaps" => Some(Self::HashProcessAndMaps),
            _ => None,
        }
    }
}

/// Swift `HDCNativeRollbackPolicy`.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RollbackPolicy {
    AutoRollback,
    RetainBackup,
}

impl RollbackPolicy {
    pub fn raw(self) -> &'static str {
        match self {
            Self::AutoRollback => "autoRollback",
            Self::RetainBackup => "retainBackup",
        }
    }

    pub fn parse(raw: &str) -> Option<Self> {
        match raw {
            "autoRollback" => Some(Self::AutoRollback),
            "retainBackup" => Some(Self::RetainBackup),
            _ => None,
        }
    }
}

/// Swift `HDCNativeLibraryInspection`: the read-only questions a deployment
/// answers about its own state.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Inspection {
    StagingMatchesArtifact,
    BackupMatchesTarget,
    TargetMatchesArtifact,
    TargetStopped,
    TargetStarted,
    TargetLoaded,
    CleanupComplete,
    RollbackRestored,
}

impl Inspection {
    pub fn raw(self) -> &'static str {
        match self {
            Self::StagingMatchesArtifact => "stagingMatchesArtifact",
            Self::BackupMatchesTarget => "backupMatchesTarget",
            Self::TargetMatchesArtifact => "targetMatchesArtifact",
            Self::TargetStopped => "targetStopped",
            Self::TargetStarted => "targetStarted",
            Self::TargetLoaded => "targetLoaded",
            Self::CleanupComplete => "cleanupComplete",
            Self::RollbackRestored => "rollbackRestored",
        }
    }

    pub fn parse(raw: &str) -> Option<Self> {
        [
            Self::StagingMatchesArtifact,
            Self::BackupMatchesTarget,
            Self::TargetMatchesArtifact,
            Self::TargetStopped,
            Self::TargetStarted,
            Self::TargetLoaded,
            Self::CleanupComplete,
            Self::RollbackRestored,
        ]
        .into_iter()
        .find(|inspection| inspection.raw() == raw)
    }
}

/// Swift `HDCNativeCodeSignHelperFacts`: the bundled helper as the host
/// verified it — an arm64 static executable carrying no mutable signature.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CodeSignHelperFacts {
    pub abi: NativeAbi,
    pub build_id: String,
    pub sha256: String,
    pub byte_count: i64,
}

/// The helper as the provider holds it: its facts and where its bytes are
/// on the host (that path reaches the `file send` argv).
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CodeSignHelper {
    pub facts: CodeSignHelperFacts,
    pub host_path: PathBuf,
}

/// Swift `HDCAppOwnedNativeLibraryExactPaths`: the paths persisted with a
/// native action, which recovery validates against the closed namespace and
/// then reuses verbatim.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ExactPaths {
    pub directory_path: String,
    pub target_path: String,
    pub loader_visible_path: String,
    pub staging_directory_path: Option<String>,
    pub staging_path: String,
    pub backup_path: String,
    pub rollback_staging_path: String,
    pub code_sign_helper_remote_path: Option<String>,
}

/// Swift `HDCAppOwnedNativeLibraryDeployment`: the fully provider-owned
/// profile of one deployment. Inputs select only a bundle and a logical
/// library name; the remote namespace is derived here.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Deployment {
    pub job_id: String,
    pub artifact_lease_id: String,
    pub artifact_id: String,
    pub bundle: BundleReference,
    pub library_logical_name: String,
    pub artifact_facts: NativeLibraryFacts,
    pub restart_profile: RestartProfile,
    pub verification_profile: VerificationProfile,
    pub rollback_policy: RollbackPolicy,
    pub directory_path: String,
    pub target_path: String,
    pub loader_visible_path: String,
    pub staging_directory_path: String,
    pub staging_directory_is_job_owned: bool,
    pub staging_path: String,
    pub backup_path: String,
    pub rollback_staging_path: String,
    pub code_sign_helper_facts: Option<CodeSignHelperFacts>,
    pub code_sign_helper_remote_path: Option<String>,
}

fn unsupported<T>(detail: &str) -> Result<T, FileActionError> {
    Err(FileActionError::Unsupported(detail.to_owned()))
}

fn bounded_job_id(job_id: &str) -> bool {
    job_id
        .bytes()
        .next()
        .is_some_and(|first| first.is_ascii_alphanumeric())
        && job_id.len() <= 128
        && job_id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
}

/// Swift's `^lib[A-Za-z0-9_.-]+\.so$` of at most 128 characters.
fn bounded_logical_name(name: &str) -> bool {
    name.chars().count() <= 128
        && name
            .strip_prefix("lib")
            .and_then(|rest| rest.strip_suffix(".so"))
            .is_some_and(|middle| {
                !middle.is_empty()
                    && middle
                        .bytes()
                        .all(|byte| byte.is_ascii_alphanumeric() || b"_.-".contains(&byte))
            })
}

impl Deployment {
    /// Swift's initializer: the closed namespace derived from the bundle, the
    /// ABI and the Job, or — for a durable intent being recovered — the
    /// persisted paths accepted only when they are exactly what the
    /// namespace would have produced (the historical `arm64` directory
    /// included, the legacy sibling staging included).
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        job_id: &str,
        artifact_lease_id: &str,
        artifact_id: &str,
        bundle: BundleReference,
        library_logical_name: &str,
        artifact_facts: NativeLibraryFacts,
        restart_profile: RestartProfile,
        verification_profile: VerificationProfile,
        rollback_policy: RollbackPolicy,
        code_sign_helper_facts: Option<CodeSignHelperFacts>,
        exact_paths: Option<&ExactPaths>,
    ) -> Result<Self, FileActionError> {
        if !bounded_job_id(job_id) {
            return unsupported("native deployment job identity is invalid");
        }
        if !bounded_logical_name(library_logical_name) {
            return unsupported("native library logical name is invalid");
        }
        let (current_abi_directory, accepted): (&str, &[&str]) = match artifact_facts.abi {
            // OpenHarmony's installed-bundle layout has used both names; exact
            // recovery accepts the historical closed directory, never an
            // arbitrary recorded path.
            NativeAbi::Arm64 => ("arm", &["arm", "arm64"]),
            NativeAbi::Arm32 => ("arm", &["arm"]),
            NativeAbi::X86_64 => ("x86_64", &["x86_64"]),
        };
        let bundle_install_root = format!("/data/app/el1/bundle/public/{}", bundle.bundle_name());
        let libraries_root = format!("{bundle_install_root}/libs");
        let staging_directory = format!(
            "/data/app/el2/{USER_ID}/base/{}/haps/{MODULE_NAME}/files/arkdeck-native/{job_id}",
            bundle.bundle_name()
        );
        let paths = if let Some(exact) = exact_paths {
            let uses_job_owned = exact.staging_directory_path.as_deref()
                == Some(staging_directory.as_str())
                && exact.staging_path
                    == format!("{staging_directory}/{library_logical_name}.staging");
            let uses_legacy_sibling = exact.staging_directory_path.is_none()
                && exact.staging_path
                    == format!(
                        "{}/.{library_logical_name}.arkdeck-{job_id}.staging",
                        exact.directory_path
                    );
            let expected_helper = (uses_job_owned && code_sign_helper_facts.is_some())
                .then(|| format!("{staging_directory}/arkdeck-code-sign-enable"));
            let abi_directory = accepted
                .iter()
                .find(|directory| exact.directory_path == format!("{libraries_root}/{directory}"));
            let valid = abi_directory.is_some_and(|abi_directory| {
                exact.target_path == format!("{}/{library_logical_name}", exact.directory_path)
                    && exact.loader_visible_path
                        == format!(
                            "/data/storage/el1/bundle/libs/{abi_directory}/{library_logical_name}"
                        )
                    && (uses_job_owned || uses_legacy_sibling)
                    && exact.backup_path
                        == format!(
                            "{}/.{library_logical_name}.arkdeck-{job_id}.backup",
                            exact.directory_path
                        )
                    && exact.rollback_staging_path
                        == format!(
                            "{}/.{library_logical_name}.arkdeck-{job_id}.rollback",
                            exact.directory_path
                        )
                    && exact.code_sign_helper_remote_path == expected_helper
            });
            if !valid {
                return unsupported(
                    "persisted native deployment paths escape the provider-owned namespace",
                );
            }
            (
                exact.directory_path.clone(),
                exact.target_path.clone(),
                exact.loader_visible_path.clone(),
                exact
                    .staging_directory_path
                    .clone()
                    .unwrap_or_else(|| exact.directory_path.clone()),
                uses_job_owned,
                exact.staging_path.clone(),
                exact.backup_path.clone(),
                exact.rollback_staging_path.clone(),
                exact.code_sign_helper_remote_path.clone(),
            )
        } else {
            let directory = format!("{libraries_root}/{current_abi_directory}");
            (
                directory.clone(),
                format!("{directory}/{library_logical_name}"),
                format!(
                    "/data/storage/el1/bundle/libs/{current_abi_directory}/{library_logical_name}"
                ),
                staging_directory.clone(),
                true,
                format!("{staging_directory}/{library_logical_name}.staging"),
                format!("{directory}/.{library_logical_name}.arkdeck-{job_id}.backup"),
                format!("{directory}/.{library_logical_name}.arkdeck-{job_id}.rollback"),
                code_sign_helper_facts
                    .as_ref()
                    .map(|_| format!("{staging_directory}/arkdeck-code-sign-enable")),
            )
        };
        Ok(Self {
            job_id: job_id.to_owned(),
            artifact_lease_id: artifact_lease_id.to_owned(),
            artifact_id: artifact_id.to_owned(),
            bundle,
            library_logical_name: library_logical_name.to_owned(),
            artifact_facts,
            restart_profile,
            verification_profile,
            rollback_policy,
            directory_path: paths.0,
            target_path: paths.1,
            loader_visible_path: paths.2,
            staging_directory_path: paths.3,
            staging_directory_is_job_owned: paths.4,
            staging_path: paths.5,
            backup_path: paths.6,
            rollback_staging_path: paths.7,
            code_sign_helper_facts,
            code_sign_helper_remote_path: paths.8,
        })
    }

    /// Swift `nativeLibraryAction`'s inputs and admission: the leased
    /// library named by `libraryArtifactLease` resolved to `resolved`, its
    /// bytes verified as the expected ABI's code-signed ELF (the facts come
    /// from the bytes, never from a caller), the profiles defaulted as Swift
    /// defaults them, the bundled helper required.
    pub fn from_inputs(
        inputs: &Map<String, Value>,
        job_id: &str,
        resolved: Option<&ResolvedArtifact>,
        library_bytes: &[u8],
        helper: Option<&CodeSignHelper>,
    ) -> Result<Self, FileActionError> {
        let string = |key: &str| inputs.get(key).and_then(Value::as_str);
        let Some(lease) = string("libraryArtifactLease") else {
            return unsupported("libraryArtifactLease input is required");
        };
        let Some(target_bundle) = string("targetBundle") else {
            return unsupported("targetBundle input is required");
        };
        let Some(logical_name) = string("libraryLogicalName") else {
            return unsupported("libraryLogicalName input is required");
        };
        let Some(expected_abi) = string("expectedABI").and_then(NativeAbi::parse) else {
            return unsupported("expectedABI input is invalid");
        };
        let profile = |key: &str| string(key);
        let restart = match profile("restartProfile") {
            None => RestartProfile::RestartAbility,
            Some(raw) => match RestartProfile::parse(raw) {
                Some(profile) => profile,
                None => return unsupported("native deployment profile is invalid"),
            },
        };
        // Deliberately at least the Catalog's default: a deployment that
        // proves less must say so, not default to saying less.
        let verification = match profile("verificationProfile") {
            None => VerificationProfile::HashProcessAndMaps,
            Some(raw) => match VerificationProfile::parse(raw) {
                Some(profile) => profile,
                None => return unsupported("native deployment profile is invalid"),
            },
        };
        let rollback = match profile("rollbackPolicy") {
            None => RollbackPolicy::AutoRollback,
            Some(raw) => match RollbackPolicy::parse(raw) {
                Some(policy) => policy,
                None => return unsupported("native deployment profile is invalid"),
            },
        };
        let bundle = BundleReference::new(target_bundle)?;
        if restart != RestartProfile::RestartAbility {
            return unsupported(&format!(
                "{} has no complete app-owned restart/readback plan; refusing before authorization",
                restart.raw()
            ));
        }
        let Some(resolved) =
            resolved.filter(|resolved| lease.ends_with(&format!(":{}", resolved.artifact_id)))
        else {
            return unsupported("native deployment requires an engine-resolved Artifact lease");
        };
        let facts = validate_elf(library_bytes, Some(expected_abi), true)
            .map_err(|error| FileActionError::Unsupported(error.to_string()))?;
        if facts.sha256 != resolved.sha256 || facts.byte_count != library_bytes.len() as i64 {
            return unsupported("leased native Artifact bytes drifted during materialization");
        }
        let Some(helper) = helper else {
            return unsupported("native deployment code-sign helper is unavailable");
        };
        Self::new(
            job_id,
            lease,
            &resolved.artifact_id,
            bundle,
            logical_name,
            facts,
            restart,
            verification,
            rollback,
            Some(helper.facts.clone()),
            None,
        )
    }

    /// Swift `nativeLibrariesRootPath`.
    pub fn native_libraries_root_path(&self) -> String {
        format!(
            "/data/app/el1/bundle/public/{}/libs",
            self.bundle.bundle_name()
        )
    }

    /// The persisted paths of this deployment, for a durable intent.
    pub fn exact_paths(&self) -> ExactPaths {
        ExactPaths {
            directory_path: self.directory_path.clone(),
            target_path: self.target_path.clone(),
            loader_visible_path: self.loader_visible_path.clone(),
            staging_directory_path: self
                .staging_directory_is_job_owned
                .then(|| self.staging_directory_path.clone()),
            staging_path: self.staging_path.clone(),
            backup_path: self.backup_path.clone(),
            rollback_staging_path: self.rollback_staging_path.clone(),
            code_sign_helper_remote_path: self.code_sign_helper_remote_path.clone(),
        }
    }
}

/// Swift `materialize()`'s `nativeDeployment()`: the profiles first, then the
/// ELF machine, the code-sign facts and the helper's facts, each complete or
/// absent, then the deployment built over its recorded exact paths, every
/// argument read in Swift's order.
fn deployment(persisted: &PersistedArguments<'_>) -> Result<Deployment, FileActionError> {
    let unknown_profile = || persisted.refuse("carries an unknown native deployment profile");
    let Some(abi) = NativeAbi::parse(persisted.string("abi")?) else {
        return unknown_profile();
    };
    let Some(restart_profile) = RestartProfile::parse(persisted.string("restartProfile")?) else {
        return unknown_profile();
    };
    let Some(verification_profile) =
        VerificationProfile::parse(persisted.string("verificationProfile")?)
    else {
        return unknown_profile();
    };
    let Some(rollback_policy) = RollbackPolicy::parse(persisted.string("rollbackPolicy")?) else {
        return unknown_profile();
    };
    let Ok(machine) = u16::try_from(persisted.integer("machine")?) else {
        return persisted.refuse("native ELF machine is outside UInt16");
    };
    let code_sign = match persisted.optional_integer("codeSignFormatVersion")? {
        None => None,
        Some(format_version) => {
            // Swift's `guard let` reads each fact only while the ones before
            // it were present.
            let incomplete = || persisted.refuse("carries incomplete native code-sign facts");
            let Some(code_sign_version) = persisted.optional_integer("codeSignVersion")? else {
                return incomplete();
            };
            let Some(signed_data_byte_count) = persisted.optional_integer("signedDataByteCount")?
            else {
                return incomplete();
            };
            let Some(signature_byte_count) = persisted.optional_integer("signatureByteCount")?
            else {
                return incomplete();
            };
            Some(CodeSignFacts {
                format_version,
                code_sign_version,
                signed_data_byte_count,
                signature_byte_count,
            })
        }
    };
    let helper = match persisted.optional_string("codeSignHelperABI")? {
        None => None,
        Some(raw) => {
            let incomplete = || persisted.refuse("carries incomplete code-sign helper facts");
            let Some(abi) = NativeAbi::parse(raw) else {
                return incomplete();
            };
            let Some(build_id) = persisted.optional_string("codeSignHelperBuildId")? else {
                return incomplete();
            };
            let Some(sha256) = persisted.optional_string("codeSignHelperSha256")? else {
                return incomplete();
            };
            let Some(byte_count) = persisted.optional_integer("codeSignHelperByteCount")? else {
                return incomplete();
            };
            if persisted
                .optional_string("codeSignHelperRemotePath")?
                .is_none()
            {
                return incomplete();
            }
            Some(CodeSignHelperFacts {
                abi,
                build_id: build_id.to_owned(),
                sha256: sha256.to_owned(),
                byte_count,
            })
        }
    };
    let job_id = persisted.string("jobId")?;
    let artifact_lease_id = persisted.string("artifactLeaseId")?;
    let artifact_id = persisted.string("artifactId")?;
    let bundle = persisted.bundle()?;
    let library_logical_name = persisted.string("libraryLogicalName")?;
    let artifact_facts = NativeLibraryFacts {
        abi,
        elf_class_bits: persisted.integer("elfClassBits")?,
        machine,
        build_id: persisted.string("buildId")?.to_owned(),
        sha256: persisted.string("sha256")?.to_owned(),
        byte_count: persisted.integer("byteCount")?,
        code_sign,
    };
    let exact_paths = ExactPaths {
        directory_path: persisted.string("directoryPath")?.to_owned(),
        target_path: persisted.string("targetPath")?.to_owned(),
        loader_visible_path: persisted.string("loaderVisiblePath")?.to_owned(),
        staging_directory_path: persisted
            .optional_string("stagingDirectoryPath")?
            .map(str::to_owned),
        staging_path: persisted.string("stagingPath")?.to_owned(),
        backup_path: persisted.string("backupPath")?.to_owned(),
        rollback_staging_path: persisted.string("rollbackStagingPath")?.to_owned(),
        code_sign_helper_remote_path: persisted
            .optional_string("codeSignHelperRemotePath")?
            .map(str::to_owned),
    };
    Deployment::new(
        job_id,
        artifact_lease_id,
        artifact_id,
        bundle,
        library_logical_name,
        artifact_facts,
        restart_profile,
        verification_profile,
        rollback_policy,
        helper,
        Some(&exact_paths),
    )
}

/// Swift `HDCNativeFileIdentity`: what `ls -ln` shows of a file.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct NativeFileIdentity {
    pub mode: String,
    pub user_id: u32,
    pub group_id: u32,
}

/// Swift `TypedProviderAction.hdc` for the native family.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum NativeAction {
    SendToStaging(Deployment),
    Backup(Deployment),
    Publish(Deployment),
    StopTarget(Deployment),
    StartTarget(Deployment),
    Cleanup(Deployment),
    Rollback(Deployment),
    Inspect(Deployment, Inspection),
}

/// Swift `ProviderReconcileOutcome` for a native readback.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum Reconcile {
    ConfirmedCompleted(BTreeMap<String, String>),
    ConfirmedNotExecuted,
    StillUnknown(String),
}

impl NativeAction {
    /// Swift `nativeLibraryAction`'s step switch (by step id): the eight
    /// steps of the operation, and the two the engine synthesizes for the
    /// compensation. `None` is a host-only step (`verify-elf-locally`,
    /// `hash-library`, `finalize-session`).
    pub fn for_step(
        step_id: &str,
        deployment: &Deployment,
    ) -> Result<Option<Self>, FileActionError> {
        let deployment = deployment.clone();
        Ok(Some(match step_id {
            "send-to-staging" => Self::SendToStaging(deployment),
            "verify-remote-staging" => {
                Self::Inspect(deployment, Inspection::StagingMatchesArtifact)
            }
            "backup-current-version" => Self::Backup(deployment),
            "atomic-publish" => Self::Publish(deployment),
            "restart-target" => Self::StopTarget(deployment),
            "start-target" => Self::StartTarget(deployment),
            "verify-loaded-library" => Self::Inspect(deployment, Inspection::TargetLoaded),
            "cleanup-staging-and-backup" | "cleanup-native-library-compensation" => {
                Self::Cleanup(deployment)
            }
            "rollback-native-library" => Self::Rollback(deployment),
            "verify-elf-locally" | "hash-library" | "finalize-session" => return Ok(None),
            other => {
                return Err(FileActionError::Unsupported(format!(
                    "{other} has no app-owned native-library action"
                )));
            }
        }))
    }

    pub fn deployment(&self) -> &Deployment {
        match self {
            Self::SendToStaging(deployment)
            | Self::Backup(deployment)
            | Self::Publish(deployment)
            | Self::StopTarget(deployment)
            | Self::StartTarget(deployment)
            | Self::Cleanup(deployment)
            | Self::Rollback(deployment)
            | Self::Inspect(deployment, _) => deployment,
        }
    }

    /// Swift `TypedProviderAction.effect`.
    pub fn effect(&self) -> &'static str {
        match self {
            Self::Inspect(..) => "readOnly",
            _ => "deviceMutation",
        }
    }

    /// Swift `PersistedTypedProviderAction`'s `nativeArguments`, the same
    /// object for every native kind, plus the inspection's expectation.
    pub fn persisted(&self) -> (&'static str, Map<String, Value>) {
        let deployment = self.deployment();
        let facts = &deployment.artifact_facts;
        let mut arguments = json!({
            "jobId": deployment.job_id,
            "artifactLeaseId": deployment.artifact_lease_id,
            "artifactId": deployment.artifact_id,
            "bundleName": deployment.bundle.bundle_name(),
            "libraryLogicalName": deployment.library_logical_name,
            "abi": facts.abi.raw(),
            "elfClassBits": facts.elf_class_bits,
            "machine": facts.machine,
            "buildId": facts.build_id,
            "sha256": facts.sha256,
            "byteCount": facts.byte_count,
            "restartProfile": deployment.restart_profile.raw(),
            "verificationProfile": deployment.verification_profile.raw(),
            "rollbackPolicy": deployment.rollback_policy.raw(),
            "directoryPath": deployment.directory_path,
            "targetPath": deployment.target_path,
            "loaderVisiblePath": deployment.loader_visible_path,
            "stagingPath": deployment.staging_path,
            "backupPath": deployment.backup_path,
            "rollbackStagingPath": deployment.rollback_staging_path,
        });
        if deployment.staging_directory_is_job_owned {
            arguments["stagingDirectoryPath"] = json!(deployment.staging_directory_path);
        }
        if let Some(code_sign) = &facts.code_sign {
            arguments["codeSignFormatVersion"] = json!(code_sign.format_version);
            arguments["codeSignVersion"] = json!(code_sign.code_sign_version);
            arguments["signedDataByteCount"] = json!(code_sign.signed_data_byte_count);
            arguments["signatureByteCount"] = json!(code_sign.signature_byte_count);
        }
        if let (Some(helper), Some(remote)) = (
            &deployment.code_sign_helper_facts,
            &deployment.code_sign_helper_remote_path,
        ) {
            arguments["codeSignHelperABI"] = json!(helper.abi.raw());
            arguments["codeSignHelperBuildId"] = json!(helper.build_id);
            arguments["codeSignHelperSha256"] = json!(helper.sha256);
            arguments["codeSignHelperByteCount"] = json!(helper.byte_count);
            arguments["codeSignHelperRemotePath"] = json!(remote);
        }
        let kind = match self {
            Self::SendToStaging(_) => "hdc.sendNativeLibraryToStaging",
            Self::Backup(_) => "hdc.backupNativeLibrary",
            Self::Publish(_) => "hdc.publishNativeLibrary",
            Self::StopTarget(_) => "hdc.stopNativeTarget",
            Self::StartTarget(_) => "hdc.startNativeTarget",
            Self::Cleanup(_) => "hdc.cleanupNativeLibrary",
            Self::Rollback(_) => "hdc.rollbackNativeLibrary",
            Self::Inspect(_, expectation) => {
                arguments["expectation"] = json!(expectation.raw());
                "hdc.inspectNativeLibrary"
            }
        };
        let Value::Object(arguments) = arguments else {
            unreachable!("an object literal")
        };
        (kind, arguments)
    }

    /// Swift `PersistedTypedProviderAction.materialize()` for the native
    /// family: the deployment rebuilt from its persisted arguments (its
    /// recorded paths accepted only when they are exactly the namespace's),
    /// refused as Swift refuses it. `None` is a kind of another family.
    pub fn from_persisted(
        kind: &str,
        arguments: &Map<String, Value>,
    ) -> Result<Option<Self>, FileActionError> {
        let persisted = PersistedArguments { kind, arguments };
        Ok(Some(match kind {
            "hdc.sendNativeLibraryToStaging" => Self::SendToStaging(deployment(&persisted)?),
            "hdc.backupNativeLibrary" => Self::Backup(deployment(&persisted)?),
            "hdc.publishNativeLibrary" => Self::Publish(deployment(&persisted)?),
            "hdc.stopNativeTarget" => Self::StopTarget(deployment(&persisted)?),
            "hdc.startNativeTarget" => Self::StartTarget(deployment(&persisted)?),
            "hdc.cleanupNativeLibrary" => Self::Cleanup(deployment(&persisted)?),
            "hdc.rollbackNativeLibrary" => Self::Rollback(deployment(&persisted)?),
            "hdc.inspectNativeLibrary" => {
                let Some(expectation) = Inspection::parse(persisted.string("expectation")?) else {
                    return Err(FileActionError::Unsupported(
                        "persisted native inspection expectation is unknown".into(),
                    ));
                };
                Self::Inspect(deployment(&persisted)?, expectation)
            }
            _ => return Ok(None),
        }))
    }

    /// Swift `lower` (`nativeSequence` / `nativeInspectionPlan`): every
    /// native action is a sequence; a send needs the same engine-resolved
    /// Artifact and the verified helper, the publish and the target
    /// inspections a persisted helper path.
    pub fn lower(
        &self,
        step_id: &str,
        connect_key: Option<&str>,
        resolved: Option<&ResolvedArtifact>,
        resolved_byte_count: Option<i64>,
        helper: Option<&CodeSignHelper>,
    ) -> Result<FilePlan, String> {
        let Some(key) = connect_key.filter(|key| !key.is_empty()) else {
            return Err(format!(
                "factsUnavailable(\"{step_id} has no descriptor-bound target connect key\")"
            ));
        };
        let unsupported = |detail: &str| format!("unsupportedAction(\"{detail}\")");
        let host = |path: &Path| path.to_string_lossy().into_owned();
        let deployment = self.deployment();
        let bundle = deployment.bundle.bundle_name();
        let mut commands: Vec<(Vec<String>, bool, u64)> = Vec::new();
        let mut push = |argv: Vec<&str>, continues: bool, seconds: u64| {
            commands.push((
                argv.into_iter().map(str::to_owned).collect(),
                continues,
                seconds,
            ));
        };
        match self {
            Self::SendToStaging(deployment) => {
                let Some(resolved) = resolved.filter(|resolved| {
                    deployment.artifact_id == resolved.artifact_id
                        && deployment.artifact_facts.sha256 == resolved.sha256
                        && Some(deployment.artifact_facts.byte_count) == resolved_byte_count
                }) else {
                    return Err(unsupported(
                        "native send requires the same engine-resolved Artifact and a job-owned staging directory",
                    ));
                };
                let (Some(expected_helper), Some(helper_remote), Some(helper)) = (
                    &deployment.code_sign_helper_facts,
                    &deployment.code_sign_helper_remote_path,
                    helper,
                ) else {
                    return Err(unsupported(
                        "native send requires the same engine-resolved Artifact and a job-owned staging directory",
                    ));
                };
                if !deployment.staging_directory_is_job_owned || helper.facts != *expected_helper {
                    return Err(unsupported(
                        "native send requires the same engine-resolved Artifact and a job-owned staging directory",
                    ));
                }
                let library_host = host(&resolved.path);
                let helper_host = host(&helper.host_path);
                push(
                    vec!["shell", "mkdir", "-p", &deployment.staging_directory_path],
                    false,
                    30,
                );
                push(
                    vec!["file", "send", &library_host, &deployment.staging_path],
                    false,
                    300,
                );
                push(vec!["file", "send", &helper_host, helper_remote], false, 60);
                push(vec!["shell", "chmod", "700", helper_remote], false, 30);
                push(vec!["shell", "sha256sum", helper_remote], false, 30);
            }
            Self::Backup(deployment) => {
                let root = deployment.native_libraries_root_path();
                push(
                    vec!["shell", "ls", "-ld", &deployment.directory_path],
                    false,
                    15,
                );
                push(
                    vec!["shell", "ls", "-l", &deployment.target_path],
                    false,
                    15,
                );
                push(
                    vec!["shell", "sha256sum", &deployment.target_path],
                    false,
                    30,
                );
                push(
                    vec!["shell", "rm", "-f", &deployment.backup_path],
                    false,
                    30,
                );
                push(
                    vec![
                        "shell",
                        "ln",
                        &deployment.target_path,
                        &deployment.backup_path,
                    ],
                    false,
                    30,
                );
                push(
                    vec!["shell", "sha256sum", &deployment.backup_path],
                    false,
                    30,
                );
                push(
                    vec!["shell", "ls", "-l", &deployment.backup_path],
                    false,
                    15,
                );
                // Firmware-layout diagnosis stays inside this typed action;
                // failure reporting exposes only a bounded hex prefix.
                push(vec!["shell", "ls", "-la", &root], true, 15);
            }
            Self::Publish(deployment) => {
                let (Some(helper_remote), Some(_)) = (
                    &deployment.code_sign_helper_remote_path,
                    &deployment.code_sign_helper_facts,
                ) else {
                    return Err(unsupported(
                        "native publish has no persisted code-sign helper identity",
                    ));
                };
                push(
                    vec!["shell", "ls", "-ln", &deployment.target_path],
                    false,
                    15,
                );
                // The backup is a hard link to the file about to be replaced,
                // so it keeps that file's attestation across the rename.
                push(
                    vec!["shell", helper_remote, "verify", &deployment.backup_path],
                    true,
                    30,
                );
                push(
                    vec![
                        "shell",
                        helper_remote,
                        "publish",
                        &deployment.staging_path,
                        &deployment.target_path,
                        &deployment.rollback_staging_path,
                    ],
                    false,
                    60,
                );
                push(
                    vec!["shell", "sha256sum", &deployment.target_path],
                    false,
                    30,
                );
                push(
                    vec!["shell", helper_remote, "verify", &deployment.target_path],
                    true,
                    30,
                );
                push(
                    vec!["shell", "ls", "-ln", &deployment.target_path],
                    false,
                    15,
                );
            }
            Self::StopTarget(_) => {
                push(vec!["shell", "aa", "force-stop", bundle], true, 60);
                push(vec!["shell", "pidof", bundle], true, 30);
                push(vec!["shell", "sleep", "2"], true, 5);
                push(vec!["shell", "pidof", bundle], true, 30);
            }
            Self::StartTarget(_) => {
                push(
                    vec!["shell", "aa", "start", "-b", bundle, "-a", ENTRY_ABILITY],
                    true,
                    60,
                );
                push(vec!["shell", "sleep", "2"], true, 5);
                push(vec!["shell", "pidof", bundle], true, 30);
            }
            Self::Cleanup(deployment) => {
                let paths = deployment.cleanup_paths();
                for path in &paths {
                    let command = if *path == deployment.staging_directory_path {
                        "rmdir"
                    } else {
                        "rm"
                    };
                    if command == "rmdir" {
                        push(vec!["shell", "rmdir", path], true, 30);
                    } else {
                        push(vec!["shell", "rm", "-f", path], true, 30);
                    }
                }
                for path in &paths {
                    push(vec!["shell", "ls", "-ld", path], true, 15);
                }
            }
            Self::Rollback(deployment) => {
                push(
                    vec!["shell", "sha256sum", &deployment.backup_path],
                    false,
                    30,
                );
                push(vec!["shell", "aa", "force-stop", bundle], true, 60);
                push(vec!["shell", "pidof", bundle], true, 30);
                push(vec!["shell", "sleep", "2"], true, 5);
                push(vec!["shell", "pidof", bundle], true, 30);
                push(
                    vec!["shell", "rm", "-f", &deployment.rollback_staging_path],
                    true,
                    30,
                );
                push(
                    vec![
                        "shell",
                        "ln",
                        &deployment.backup_path,
                        &deployment.rollback_staging_path,
                    ],
                    true,
                    60,
                );
                push(
                    vec![
                        "shell",
                        "mv",
                        "-f",
                        &deployment.rollback_staging_path,
                        &deployment.target_path,
                    ],
                    true,
                    60,
                );
                push(
                    vec!["shell", "sha256sum", &deployment.target_path],
                    true,
                    30,
                );
                push(
                    vec!["shell", "aa", "start", "-b", bundle, "-a", ENTRY_ABILITY],
                    true,
                    60,
                );
                push(vec!["shell", "sleep", "2"], true, 5);
                push(vec!["shell", "pidof", bundle], true, 30);
                push(
                    vec![
                        "shell",
                        "grep",
                        "-F",
                        &deployment.loader_visible_path,
                        "/proc/*/maps",
                    ],
                    true,
                    30,
                );
            }
            Self::Inspect(deployment, expectation) => match expectation {
                Inspection::StagingMatchesArtifact => {
                    push(
                        vec!["shell", "sha256sum", &deployment.staging_path],
                        true,
                        30,
                    );
                    push(
                        vec!["shell", "ls", "-l", &deployment.staging_path],
                        true,
                        15,
                    );
                }
                Inspection::BackupMatchesTarget => {
                    push(
                        vec!["shell", "sha256sum", &deployment.target_path],
                        true,
                        30,
                    );
                    push(
                        vec!["shell", "sha256sum", &deployment.backup_path],
                        true,
                        30,
                    );
                }
                Inspection::TargetMatchesArtifact | Inspection::TargetLoaded => {
                    let Some(helper_remote) = &deployment.code_sign_helper_remote_path else {
                        return Err(unsupported(if *expectation == Inspection::TargetLoaded {
                            "native loader inspection has no persisted code-sign helper path"
                        } else {
                            "native target inspection has no persisted code-sign helper path"
                        }));
                    };
                    push(
                        vec!["shell", "sha256sum", &deployment.target_path],
                        true,
                        30,
                    );
                    push(
                        vec!["shell", helper_remote, "verify", &deployment.backup_path],
                        true,
                        30,
                    );
                    push(
                        vec!["shell", helper_remote, "verify", &deployment.target_path],
                        true,
                        30,
                    );
                    if *expectation == Inspection::TargetLoaded {
                        if deployment.verification_profile != VerificationProfile::HashOnly {
                            push(vec!["shell", "pidof", bundle], true, 30);
                        }
                        if deployment.verification_profile
                            == VerificationProfile::HashProcessAndMaps
                        {
                            push(
                                vec![
                                    "shell",
                                    "grep",
                                    "-F",
                                    &deployment.loader_visible_path,
                                    "/proc/*/maps",
                                ],
                                true,
                                30,
                            );
                        }
                    }
                }
                Inspection::TargetStopped | Inspection::TargetStarted => {
                    push(vec!["shell", "pidof", bundle], true, 30);
                }
                Inspection::CleanupComplete => {
                    for path in deployment.cleanup_paths() {
                        push(vec!["shell", "ls", "-ld", &path], true, 15);
                    }
                }
                Inspection::RollbackRestored => {
                    push(
                        vec!["shell", "sha256sum", &deployment.target_path],
                        true,
                        30,
                    );
                    push(
                        vec!["shell", "sha256sum", &deployment.backup_path],
                        true,
                        30,
                    );
                    push(vec!["shell", "pidof", bundle], true, 30);
                    if deployment.verification_profile == VerificationProfile::HashProcessAndMaps {
                        push(
                            vec![
                                "shell",
                                "grep",
                                "-F",
                                &deployment.loader_visible_path,
                                "/proc/*/maps",
                            ],
                            true,
                            30,
                        );
                    }
                }
            },
        }
        Ok(FilePlan::Sequence(
            commands
                .into_iter()
                .map(|(tail, continue_after_non_zero, seconds)| {
                    let mut arguments = vec!["-t".to_owned(), key.to_owned()];
                    arguments.extend(tail);
                    Invocation {
                        arguments,
                        timeout: Duration::from_secs(seconds),
                        continue_after_non_zero,
                    }
                })
                .collect(),
        ))
    }

    /// Swift `verify` for the native actions and `verifyNativeInspection`.
    pub fn verify(&self, receipt: &FileReceipt) -> Outcome {
        let subprocesses = &receipt.subprocesses;
        // Swift's aggregate exit status of a sequence is its last process's.
        let aggregate_exit = subprocesses.last().map(|process| process.exit_status);
        match self {
            Self::SendToStaging(deployment) => {
                let clean = aggregate_exit == Some(0)
                    && subprocesses.len() == 5
                    && deployment
                        .code_sign_helper_facts
                        .as_ref()
                        .is_some_and(|helper| {
                            sha256_token(&subprocesses[4]).as_deref()
                                == Some(helper.sha256.as_str())
                        });
                if !clean {
                    return failed(
                        "nativeSendFailed",
                        "native library and the pinned code-sign helper did not both transfer cleanly",
                    );
                }
                Outcome::Unknown("native staging send requires remote hash readback".into())
            }
            Self::Backup(deployment) => {
                if subprocesses.len() != 8 {
                    return Outcome::Unknown(
                        "native backup did not produce its complete readback sequence".into(),
                    );
                }
                if path_presence(&subprocesses[0]) == Some(false) {
                    return failed(
                        "nativeAppOwnedDirectoryMissing",
                        "the target bundle has no app-owned native library directory; install the signed application before deploying its library",
                    );
                }
                let target_hash = sha256_token(&subprocesses[2]);
                let backup_hash = sha256_token(&subprocesses[5]);
                let backup_matches = backup_hash.is_some() && backup_hash == target_hash;
                let valid = is_directory_listing(&subprocesses[0])
                    && is_regular_file_listing(&subprocesses[1])
                    && backup_matches
                    && subprocesses[3].exit_status == 0
                    && subprocesses[4].exit_status == 0
                    && is_regular_file_listing(&subprocesses[6]);
                let (Some(backup_hash), true) = (backup_hash, valid) else {
                    let diagnostics = subprocesses
                        .iter()
                        .enumerate()
                        .map(|(index, process)| {
                            format!("{index}:{}", bounded_process_diagnostic(process))
                        })
                        .collect::<Vec<_>>()
                        .join(";");
                    return Outcome::Failed {
                        code: "nativeBackupMismatch",
                        detail: format!(
                            "app-owned directory, original file or verified backup snapshot is invalid (directoryExit={}, directoryListed={}, targetExit={}, targetListed={}, targetHashExit={}, targetHashPresent={}, removeOldBackupExit={}, hardLinkExit={}, backupHashExit={}, backupHashMatches={}, backupExit={}, backupListed={}, diagnostics={diagnostics})",
                            subprocesses[0].exit_status,
                            is_directory_listing(&subprocesses[0]),
                            subprocesses[1].exit_status,
                            is_regular_file_listing(&subprocesses[1]),
                            subprocesses[2].exit_status,
                            target_hash.is_some(),
                            subprocesses[3].exit_status,
                            subprocesses[4].exit_status,
                            subprocesses[5].exit_status,
                            backup_matches,
                            subprocesses[6].exit_status,
                            is_regular_file_listing(&subprocesses[6]),
                        ),
                    };
                };
                verified([
                    ("backupSha256", backup_hash),
                    ("backupPath", deployment.backup_path.clone()),
                ])
            }
            Self::Publish(deployment) => {
                let publish_failure = || {
                    let diagnostics = subprocesses
                        .iter()
                        .enumerate()
                        .map(|(index, process)| {
                            format!("{index}:{}", bounded_process_diagnostic(process))
                        })
                        .collect::<Vec<_>>()
                        .join(";");
                    Outcome::Failed {
                        code: "nativePublishMismatch",
                        detail: format!(
                            "atomic publish did not preserve app-owned mode/uid/gid, read back the leased ELF hash, or leave the published library at least as attested as the one it replaced (subprocessCount={}, diagnostics={diagnostics})",
                            subprocesses.len()
                        ),
                    }
                };
                if subprocesses.len() != 6 {
                    return publish_failure();
                }
                let (Some(original), Some(published)) = (
                    native_file_identity(&subprocesses[0]),
                    native_file_identity(&subprocesses[5]),
                ) else {
                    return publish_failure();
                };
                if original != published
                    || sha256_token(&subprocesses[3]).as_deref()
                        != Some(deployment.artifact_facts.sha256.as_str())
                {
                    return publish_failure();
                }
                let mut summary = BTreeMap::from([
                    (
                        "publishedSha256".to_owned(),
                        deployment.artifact_facts.sha256.clone(),
                    ),
                    (
                        "buildId".to_owned(),
                        deployment.artifact_facts.build_id.clone(),
                    ),
                    ("targetPath".to_owned(), deployment.target_path.clone()),
                    ("mode".to_owned(), original.mode.clone()),
                    ("uid".to_owned(), original.user_id.to_string()),
                    ("gid".to_owned(), original.group_id.to_string()),
                ]);
                let published_attestation = readback_attestation(&subprocesses[4]);
                match readback_attestation(&subprocesses[1]) {
                    // Not an answer about the replaced file, so nothing here
                    // can say the replacement matches it.
                    Attestation::Unreadable => publish_failure(),
                    // An attested original demands an attested replacement,
                    // and the helper's own digest must agree with what the
                    // device reads back afterwards.
                    Attestation::Attested(_) => {
                        let Some(announced) = code_sign_digest(&subprocesses[2], PUBLISHED_MARKER)
                        else {
                            return publish_failure();
                        };
                        if published_attestation != Attestation::Attested(announced.clone()) {
                            return publish_failure();
                        }
                        summary.insert("fsVerityDigest".to_owned(), announced);
                        summary.insert("attestation".to_owned(), "fsVerity".to_owned());
                        Outcome::Verified(summary)
                    }
                    // At this instant the helper is the only thing that touched
                    // the file: if it reports having enabled nothing and the
                    // device reads back an attestation anyway, something
                    // unaccounted for wrote the library. No `fsVerityDigest`
                    // key at all: a record that carries the field is read as
                    // having the property.
                    Attestation::Absent => {
                        if !published_without_attestation(&subprocesses[2])
                            || published_attestation != Attestation::Absent
                        {
                            return publish_failure();
                        }
                        summary.insert(
                            "attestation".to_owned(),
                            "matchesReplacedFile:none".to_owned(),
                        );
                        Outcome::Verified(summary)
                    }
                }
            }
            Self::StopTarget(deployment) => {
                if subprocesses.len() != 4 {
                    return Outcome::Unknown(
                        "native stop did not produce its complete bounded readback sequence".into(),
                    );
                }
                let readback = &subprocesses[3];
                if !process_is_absent(readback) {
                    return Outcome::Failed {
                        code: "nativeTargetStillRunning",
                        detail: format!(
                            "{} remained live after stop (forceStopExit={}, pidofExit={}, pids={}, stdoutBytes={}, stderrBytes={})",
                            deployment.bundle.bundle_name(),
                            subprocesses[0].exit_status,
                            readback.exit_status,
                            pid_summary(readback),
                            readback.stdout.len(),
                            readback.stderr.len()
                        ),
                    };
                }
                verified([("stopped", deployment.bundle.bundle_name().to_owned())])
            }
            Self::StartTarget(deployment) => {
                let pids = (subprocesses.len() == 3)
                    .then(|| process_ids(&subprocesses[2]))
                    .flatten();
                let Some(pids) = pids.filter(|pids| !pids.is_empty()) else {
                    return Outcome::Failed {
                        code: "nativeTargetNotRunning",
                        detail: format!("{} did not start", deployment.bundle.bundle_name()),
                    };
                };
                verified([
                    ("started", deployment.bundle.bundle_name().to_owned()),
                    ("processIds", join_pids(&pids)),
                ])
            }
            Self::Cleanup(deployment) => {
                let absence = deployment.cleanup_paths().len();
                let clean = subprocesses.len() >= absence
                    && subprocesses[subprocesses.len() - absence..]
                        .iter()
                        .all(|process| path_presence(process) == Some(false));
                if !clean {
                    return failed(
                        "cleanupDebt",
                        "native staging or backup path remains after cleanup",
                    );
                }
                verified([
                    ("cleaned", deployment.staging_path.clone()),
                    (
                        "backupRetained",
                        (deployment.rollback_policy == RollbackPolicy::RetainBackup).to_string(),
                    ),
                ])
            }
            Self::Rollback(deployment) => {
                if subprocesses.len() != 13 {
                    return Outcome::Unknown(
                        "native rollback did not produce its complete bounded readback sequence"
                            .into(),
                    );
                }
                let backup_hash = sha256_token(&subprocesses[0]);
                let stop_readback = &subprocesses[4];
                let restored_hash = sha256_token(&subprocesses[8]);
                let pids = process_ids(&subprocesses[11]);
                let maps_matched = pids.as_ref().is_some_and(|pids| {
                    maps_contain(&subprocesses[12], &deployment.loader_visible_path, pids)
                });
                let hashes_match = restored_hash.is_some() && restored_hash == backup_hash;
                let (Some(backup_hash), Some(pids)) = (backup_hash.clone(), pids.clone()) else {
                    return rollback_failure(
                        subprocesses,
                        stop_readback,
                        hashes_match,
                        &pids,
                        maps_matched,
                    );
                };
                if !process_is_absent(stop_readback)
                    || !hashes_match
                    || pids.is_empty()
                    || !maps_matched
                {
                    return rollback_failure(
                        subprocesses,
                        stop_readback,
                        hashes_match,
                        &Some(pids),
                        maps_matched,
                    );
                }
                verified([
                    ("restoredSha256", backup_hash),
                    ("restored", "true".to_owned()),
                    ("processIds", join_pids(&pids)),
                ])
            }
            Self::Inspect(deployment, expectation) => {
                inspect(deployment, *expectation, subprocesses)
            }
        }
    }

    /// Swift `reconciliationReadback`: the inspection that concludes this
    /// mutation without resending it; nothing for an inspection.
    pub fn readback(&self) -> Option<Self> {
        let deployment = self.deployment().clone();
        let expectation = match self {
            Self::SendToStaging(_) => Inspection::StagingMatchesArtifact,
            Self::Backup(_) => Inspection::BackupMatchesTarget,
            Self::Publish(_) => Inspection::TargetMatchesArtifact,
            Self::StopTarget(_) => Inspection::TargetStopped,
            Self::StartTarget(_) => Inspection::TargetStarted,
            Self::Cleanup(_) => Inspection::CleanupComplete,
            Self::Rollback(_) => Inspection::RollbackRestored,
            Self::Inspect(..) => return None,
        };
        Some(Self::Inspect(deployment, expectation))
    }

    /// Swift `verifyReconciliationReadback`'s native arms: what a readback's
    /// verdict concludes about the original mutation — a failed readback is
    /// "not executed" for the idempotent mutations, but never for a publish
    /// (its state is not safe to replay) nor a rollback.
    pub fn reconcile(&self, readback_outcome: Outcome) -> Reconcile {
        match readback_outcome {
            Outcome::Verified(summary) => Reconcile::ConfirmedCompleted(summary),
            Outcome::Failed { code, detail } => match self {
                Self::Publish(_) => Reconcile::StillUnknown(format!(
                    "{code}: {detail}; publish state is not safe to replay"
                )),
                Self::Rollback(_) => Reconcile::StillUnknown(format!("{code}: {detail}")),
                Self::Inspect(..) => {
                    Reconcile::StillUnknown("original action has no dedicated readback".into())
                }
                _ => Reconcile::ConfirmedNotExecuted,
            },
            Outcome::Unknown(reason) | Outcome::Unsupported(reason) => {
                Reconcile::StillUnknown(reason)
            }
        }
    }
}

impl Deployment {
    /// The paths a cleanup removes and then proves absent, in Swift's order:
    /// the staging file, the helper (when there is one), the job-owned
    /// staging directory (when it is), the rollback staging, the backup
    /// (under `autoRollback`).
    fn cleanup_paths(&self) -> Vec<String> {
        let mut paths = vec![self.staging_path.clone()];
        if let Some(helper) = &self.code_sign_helper_remote_path {
            paths.push(helper.clone());
        }
        if self.staging_directory_is_job_owned {
            paths.push(self.staging_directory_path.clone());
        }
        paths.push(self.rollback_staging_path.clone());
        if self.rollback_policy == RollbackPolicy::AutoRollback {
            paths.push(self.backup_path.clone());
        }
        paths
    }
}

fn rollback_failure(
    subprocesses: &[Receipt],
    stop_readback: &Receipt,
    hashes_match: bool,
    pids: &Option<Vec<u32>>,
    maps_matched: bool,
) -> Outcome {
    Outcome::Failed {
        code: "nativeRollbackVerificationFailed",
        detail: format!(
            "previous library bytes and loader state were not both restored (forceStopExit={}, pidofExit={}, stopPids={}, targetHashMatches={hashes_match}, startExit={}, startedPids={}, mapsMatched={maps_matched})",
            subprocesses[1].exit_status,
            stop_readback.exit_status,
            pid_summary(stop_readback),
            subprocesses[9].exit_status,
            pids.as_ref()
                .map_or("none".to_owned(), |pids| join_pids(pids)),
        ),
    }
}

/// Swift `verifyNativeInspection`.
fn inspect(deployment: &Deployment, expectation: Inspection, subprocesses: &[Receipt]) -> Outcome {
    let facts = &deployment.artifact_facts;
    match expectation {
        Inspection::StagingMatchesArtifact => {
            let hash = subprocesses.first().and_then(sha256_token);
            let hash_exit = subprocesses
                .first()
                .map_or("missing".to_owned(), |process| {
                    process.exit_status.to_string()
                });
            let listing = subprocesses.get(1);
            let listing_exit = listing.map_or("missing".to_owned(), |process| {
                process.exit_status.to_string()
            });
            let regular = listing.is_some_and(is_regular_file_listing);
            let matches = hash.as_deref() == Some(facts.sha256.as_str());
            if subprocesses.len() != 2 || !matches || !regular {
                return Outcome::Failed {
                    code: "nativeStagingMismatch",
                    detail: format!(
                        "remote staging bytes do not match the leased ELF (hashExit={hash_exit}, hashMatches={matches}, listingExit={listing_exit}, regularFile={regular})"
                    ),
                };
            }
            verified([
                ("remoteSha256", facts.sha256.clone()),
                ("remoteByteCount", facts.byte_count.to_string()),
                ("buildId", facts.build_id.clone()),
            ])
        }
        Inspection::BackupMatchesTarget => {
            let target = (subprocesses.len() == 2)
                .then(|| sha256_token(&subprocesses[0]))
                .flatten();
            match target {
                Some(target)
                    if sha256_token(&subprocesses[1]).as_deref() == Some(target.as_str()) =>
                {
                    verified([("backupSha256", target)])
                }
                _ => failed(
                    "nativeBackupMismatch",
                    "backup differs from the current target",
                ),
            }
        }
        Inspection::TargetMatchesArtifact => {
            let attestation = (subprocesses.len() == 3
                && sha256_token(&subprocesses[0]).as_deref() == Some(facts.sha256.as_str()))
            .then(|| attestation_at_least_replaced(&subprocesses[1], &subprocesses[2]))
            .flatten();
            let Some(attestation) = attestation else {
                return failed(
                    "nativeTargetHashMismatch",
                    "published target hash differs, or it is less attested than the library it replaced",
                );
            };
            let mut summary =
                BTreeMap::from([("publishedSha256".to_owned(), facts.sha256.clone())]);
            summary.extend(attestation);
            Outcome::Verified(summary)
        }
        Inspection::TargetStopped => {
            if subprocesses.len() != 1 || !process_is_absent(&subprocesses[0]) {
                return failed(
                    "nativeTargetStillRunning",
                    "target process is still present",
                );
            }
            verified([("running", "false".to_owned())])
        }
        Inspection::TargetStarted => {
            let pids = (subprocesses.len() == 1)
                .then(|| process_ids(&subprocesses[0]))
                .flatten();
            let Some(pids) = pids.filter(|pids| !pids.is_empty()) else {
                return failed("nativeTargetNotRunning", "target process is absent");
            };
            verified([
                ("running", "true".to_owned()),
                ("processIds", join_pids(&pids)),
            ])
        }
        Inspection::TargetLoaded => {
            let attestation = (subprocesses.len() >= 3
                && sha256_token(&subprocesses[0]).as_deref() == Some(facts.sha256.as_str()))
            .then(|| attestation_at_least_replaced(&subprocesses[1], &subprocesses[2]))
            .flatten();
            let Some(attestation) = attestation else {
                return failed(
                    "nativeTargetHashMismatch",
                    "loader verification target hash differs from the leased ELF, or it is less attested than the library it replaced",
                );
            };
            let mut summary = BTreeMap::from([
                ("publishedSha256".to_owned(), facts.sha256.clone()),
                ("buildId".to_owned(), facts.build_id.clone()),
                ("abi".to_owned(), facts.abi.raw().to_owned()),
            ]);
            summary.extend(attestation);
            // Always stated, never left to an absent key: under a profile
            // below `hashProcessAndMaps` this step reads no `/proc/*/maps`, and
            // silence would be indistinguishable from a run that proved it.
            summary.insert("loaderVerified".to_owned(), LOADER_NOT_OBSERVED.to_owned());
            if deployment.verification_profile != VerificationProfile::HashOnly {
                let pids = (subprocesses.len() >= 4)
                    .then(|| process_ids(&subprocesses[3]))
                    .flatten();
                let Some(pids) = pids.filter(|pids| !pids.is_empty()) else {
                    return failed(
                        "nativeTargetNotRunning",
                        "loader verification found no target process",
                    );
                };
                summary.insert("processIds".to_owned(), join_pids(&pids));
                if deployment.verification_profile == VerificationProfile::HashProcessAndMaps {
                    if subprocesses.len() != 5
                        || !maps_contain(&subprocesses[4], &deployment.loader_visible_path, &pids)
                    {
                        return failed(
                            "nativeLibraryNotLoaded",
                            "target process maps do not contain the published app-owned library",
                        );
                    }
                    summary.insert("loaderVerified".to_owned(), "true".to_owned());
                }
            }
            Outcome::Verified(summary)
        }
        Inspection::CleanupComplete => {
            let expected = deployment.cleanup_paths().len();
            if subprocesses.len() != expected
                || !subprocesses
                    .iter()
                    .all(|process| path_presence(process) == Some(false))
            {
                return failed(
                    "nativeCleanupIncomplete",
                    "one or more provider-owned native paths still exist",
                );
            }
            verified([("cleanupComplete", "true".to_owned())])
        }
        Inspection::RollbackRestored => {
            let with_maps =
                deployment.verification_profile == VerificationProfile::HashProcessAndMaps;
            let expected = if with_maps { 4 } else { 3 };
            let target = (subprocesses.len() == expected)
                .then(|| sha256_token(&subprocesses[0]))
                .flatten();
            let pids = (subprocesses.len() == expected)
                .then(|| process_ids(&subprocesses[2]))
                .flatten();
            let (Some(target), Some(pids)) = (target, pids.filter(|pids| !pids.is_empty())) else {
                return Outcome::Unknown(
                    "rollback readback cannot prove restored bytes and process".into(),
                );
            };
            if sha256_token(&subprocesses[1]).as_deref() != Some(target.as_str()) {
                return Outcome::Unknown(
                    "rollback readback cannot prove restored bytes and process".into(),
                );
            }
            if with_maps && !maps_contain(&subprocesses[3], &deployment.loader_visible_path, &pids)
            {
                return Outcome::Unknown(
                    "rollback bytes exist but restored loader state is unproven".into(),
                );
            }
            verified([
                ("restoredSha256", target),
                ("restored", "true".to_owned()),
                (
                    "loaderVerified",
                    if with_maps {
                        "true"
                    } else {
                        LOADER_NOT_OBSERVED
                    }
                    .to_owned(),
                ),
            ])
        }
    }
}

/// Swift `sha256(_:)`: the first token of a clean `sha256sum` answer, if it
/// is 64 lowercase hex digits.
pub fn sha256_token(receipt: &Receipt) -> Option<String> {
    if receipt.exit_status != 0 || receipt.truncated {
        return None;
    }
    let text = std::str::from_utf8(&receipt.stdout).ok()?;
    let token = text
        .split(char::is_whitespace)
        .find(|token| !token.is_empty())?;
    hex_digest(token).then(|| token.to_owned())
}

fn hex_digest(value: &str) -> bool {
    value.chars().count() == 64
        && value
            .chars()
            .all(|character| character.is_numeric() || ('a'..='f').contains(&character))
}

/// Swift `isDirectoryListing`: a clean `ls -ld` whose first byte is `d`.
pub fn is_directory_listing(receipt: &Receipt) -> bool {
    receipt.exit_status == 0 && !receipt.truncated && receipt.stdout.first() == Some(&b'd')
}

/// Swift `isRegularFileListing`: a clean `ls -l` whose first byte is `-`.
pub fn is_regular_file_listing(receipt: &Receipt) -> bool {
    receipt.exit_status == 0 && !receipt.truncated && receipt.stdout.first() == Some(&b'-')
}

/// Swift `nativeFileIdentity`: the mode, uid and gid of an `ls -ln` line.
pub fn native_file_identity(receipt: &Receipt) -> Option<NativeFileIdentity> {
    if receipt.exit_status != 0 || receipt.truncated || !receipt.stderr.is_empty() {
        return None;
    }
    let text = std::str::from_utf8(&receipt.stdout).ok()?;
    let fields: Vec<&str> = text
        .split(char::is_whitespace)
        .filter(|field| !field.is_empty())
        .collect();
    if fields.len() < 4 || !fields[0].starts_with('-') {
        return None;
    }
    Some(NativeFileIdentity {
        mode: fields[0].to_owned(),
        user_id: fields[2].parse().ok()?,
        group_id: fields[3].parse().ok()?,
    })
}

/// Swift `mapsContain`: the loader-visible path appears in some process's
/// maps, and one of the given processes' maps files is among the matches.
pub fn maps_contain(receipt: &Receipt, target_path: &str, pids: &[u32]) -> bool {
    if receipt.exit_status != 0 || receipt.truncated {
        return false;
    }
    let Ok(text) = std::str::from_utf8(&receipt.stdout) else {
        return false;
    };
    text.contains(target_path)
        && pids
            .iter()
            .any(|pid| text.contains(&format!("/proc/{pid}/maps:")))
}

/// Swift `processIDs`: every token of a clean `pidof` answer as a live PID.
pub fn process_ids(receipt: &Receipt) -> Option<Vec<u32>> {
    if receipt.exit_status != 0 || receipt.truncated {
        return None;
    }
    let text = std::str::from_utf8(&receipt.stdout).ok()?;
    let tokens: Vec<&str> = text
        .split(char::is_whitespace)
        .filter(|token| !token.is_empty())
        .collect();
    let values: Vec<u32> = tokens
        .iter()
        .filter_map(|token| token.parse().ok())
        .collect();
    (!values.is_empty() && values.iter().all(|value| *value > 0) && values.len() == tokens.len())
        .then_some(values)
}

/// Swift `processIsAbsent`: `pidof` answered nothing, cleanly (exit 0 or 1,
/// nothing on stderr).
pub fn process_is_absent(receipt: &Receipt) -> bool {
    (receipt.exit_status == 0 || receipt.exit_status == 1)
        && !receipt.truncated
        && receipt.stderr.is_empty()
        && std::str::from_utf8(&receipt.stdout)
            .is_ok_and(|text| text.split(char::is_whitespace).all(str::is_empty))
}

fn pid_summary(receipt: &Receipt) -> String {
    process_ids(receipt).map_or("none".to_owned(), |pids| join_pids(&pids))
}

fn join_pids(pids: &[u32]) -> String {
    pids.iter()
        .map(u32::to_string)
        .collect::<Vec<_>>()
        .join(",")
}

/// Swift `ReadbackAttestation`: what a helper `verify` readback established
/// about one file — three-way on purpose.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum Attestation {
    Attested(String),
    /// The device positively answered: the file is there and carries none.
    Absent,
    /// No answer: a missing file, a truncated readback, an unexpected errno.
    Unreadable,
}

/// Swift `readbackAttestation`: the verified digest, else the helper's
/// `ENODATA`/`EOPNOTSUPP` error line read from either stream regardless of
/// the exit status (HDC merges a remote command's streams and reports its
/// own exit), else nothing.
pub fn readback_attestation(receipt: &Receipt) -> Attestation {
    if let Some(digest) = code_sign_digest(receipt, VERIFIED_MARKER) {
        return Attestation::Attested(digest);
    }
    if receipt.truncated {
        return Attestation::Unreadable;
    }
    let (Ok(out), Ok(err)) = (
        std::str::from_utf8(&receipt.stdout),
        std::str::from_utf8(&receipt.stderr),
    ) else {
        return Attestation::Unreadable;
    };
    let joined = format!("{out}{err}");
    let lines: Vec<&str> = joined
        .split(swift_newline)
        .filter(|line| !line.is_empty())
        .collect();
    let [line] = lines.as_slice() else {
        return Attestation::Unreadable;
    };
    let fields: Vec<&str> = line
        .split(char::is_whitespace)
        .filter(|field| !field.is_empty())
        .collect();
    if fields.len() == 4
        && fields[0] == "ARKDECK_CODE_SIGN_ERROR"
        && fields[1] == "stage=verify"
        && fields[2] == "code=30"
        && UNATTESTED_ERRNO_FIELDS.contains(&fields[3])
    {
        Attestation::Absent
    } else {
        Attestation::Unreadable
    }
}

/// Swift `attestationAtLeastReplaced`: the published library must be at
/// least as attested as the one it replaced — a floor, not an equality.
pub fn attestation_at_least_replaced(
    replaced: &Receipt,
    published: &Receipt,
) -> Option<BTreeMap<String, String>> {
    let replaced = readback_attestation(replaced);
    if replaced == Attestation::Unreadable {
        return None;
    }
    match readback_attestation(published) {
        Attestation::Attested(digest) => Some(BTreeMap::from([
            ("fsVerityDigest".to_owned(), digest),
            ("attestation".to_owned(), "fsVerity".to_owned()),
        ])),
        Attestation::Absent if replaced == Attestation::Absent => Some(BTreeMap::from([(
            "attestation".to_owned(),
            "matchesReplacedFile:none".to_owned(),
        )])),
        _ => None,
    }
}

/// Swift `publishedWithoutAttestation`: the helper's own marker for a
/// publish that enabled nothing because the replaced file carried none.
pub fn published_without_attestation(receipt: &Receipt) -> bool {
    single_clean_line(receipt).is_some_and(|line| {
        line.split(char::is_whitespace)
            .filter(|field| !field.is_empty())
            .collect::<Vec<_>>()
            == [
                "ARKDECK_CODE_SIGN_PUBLISHED_UNATTESTED",
                "replaced-file-had-none",
            ]
    })
}

/// Swift `codeSignDigest`: `<marker> sha256:<64 hex>` as the one clean line.
pub fn code_sign_digest(receipt: &Receipt, marker: &str) -> Option<String> {
    let line = single_clean_line(receipt)?;
    let fields: Vec<&str> = line
        .split(char::is_whitespace)
        .filter(|field| !field.is_empty())
        .collect();
    if fields.len() != 2 || fields[0] != marker {
        return None;
    }
    let digest = fields[1].strip_prefix("sha256:")?;
    hex_digest(digest).then(|| digest.to_owned())
}

/// A clean exit, nothing on stderr, exactly one non-empty line on stdout.
fn single_clean_line(receipt: &Receipt) -> Option<String> {
    if receipt.exit_status != 0 || receipt.truncated || !receipt.stderr.is_empty() {
        return None;
    }
    let text = std::str::from_utf8(&receipt.stdout).ok()?;
    let lines: Vec<&str> = text
        .split(swift_newline)
        .filter(|line| !line.is_empty())
        .collect();
    let [line] = lines.as_slice() else {
        return None;
    };
    Some((*line).to_owned())
}

/// Swift `Character.isNewline`.
fn swift_newline(character: char) -> bool {
    matches!(
        character,
        '\n' | '\u{0B}' | '\u{0C}' | '\r' | '\u{85}' | '\u{2028}' | '\u{2029}'
    )
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::capture_files::Landed;
    use std::path::Path;
    use std::time::Duration;

    const KEY: &str = "150100424a544e4600";
    const JOB: &str = "job-186c8faffebe3b9cb8b0150ef9a645b2";
    const LEASE: &str = "lease-v1:job-input-native-library:ART-469c10579b3c5461ab4d0a891c316397";
    const ARTIFACT: &str = "ART-469c10579b3c5461ab4d0a891c316397";
    const LIBRARY_SHA256: &str = "f8cd1ccd46071323e6b3b8e1a6b2246b7b4ea5d5f71d6ea9990e33ec722f5b53";
    const HELPER_SHA256: &str = "86497e1a8f9b586169218df912895785c1c0f2d8bb3f87b2b700f6f86264f5c1";
    const REPLACED: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

    fn library() -> Vec<u8> {
        std::fs::read(Path::new(env!("CARGO_MANIFEST_DIR")).join(
            "../../tests/fixtures/deploy-native-library/artifacts/job-input-native-library/ART-469c10579b3c5461ab4d0a891c316397",
        ))
        .unwrap()
    }

    fn resolved() -> ResolvedArtifact {
        ResolvedArtifact {
            artifact_id: ARTIFACT.into(),
            sha256: LIBRARY_SHA256.into(),
            path: PathBuf::from(
                "/private/tmp/arkdeck-hdc-oracle/artifacts/job-input-native-library/ART-469c10579b3c5461ab4d0a891c316397",
            ),
        }
    }

    fn helper() -> CodeSignHelper {
        CodeSignHelper {
            facts: CodeSignHelperFacts {
                abi: NativeAbi::Arm64,
                build_id: "4e6f5302a74bab03fa0ecb72a4f96b9b4fa45323".into(),
                sha256: HELPER_SHA256.into(),
                byte_count: 214_016,
            },
            host_path: PathBuf::from(
                "/private/tmp/arkdeck-hdc-oracle/host/arkdeck-code-sign-enable",
            ),
        }
    }

    fn inputs(extra: &[(&str, &str)]) -> Map<String, Value> {
        let mut inputs = json!({
            "libraryArtifactLease": LEASE, "targetBundle": "com.example.demo",
            "libraryLogicalName": "libexample.so", "expectedABI": "arm64-v8a",
        });
        for (key, value) in extra {
            inputs[*key] = json!(value);
        }
        inputs.as_object().cloned().unwrap()
    }

    fn deployment() -> Deployment {
        Deployment::from_inputs(
            &inputs(&[]),
            JOB,
            Some(&resolved()),
            &library(),
            Some(&helper()),
        )
        .unwrap()
    }

    fn sub(stdout: &str, exit_status: i32) -> Receipt {
        Receipt {
            exit_status,
            stdout: stdout.as_bytes().to_vec(),
            stderr: Vec::new(),
            truncated: false,
            duration: Duration::from_millis(5),
        }
    }

    fn with_stderr(stdout: &str, stderr: &str, exit_status: i32) -> Receipt {
        Receipt {
            stderr: stderr.as_bytes().to_vec(),
            ..sub(stdout, exit_status)
        }
    }

    fn receipt(subprocesses: Vec<Receipt>) -> FileReceipt {
        FileReceipt {
            subprocesses,
            landed: None::<Landed>,
        }
    }

    fn argv(action: &NativeAction, step: &str) -> Vec<Vec<String>> {
        let FilePlan::Sequence(invocations) = action
            .lower(
                step,
                Some(KEY),
                Some(&resolved()),
                Some(588),
                Some(&helper()),
            )
            .unwrap()
        else {
            panic!("a sequence")
        };
        invocations
            .into_iter()
            .map(|invocation| invocation.arguments)
            .collect()
    }

    /// The namespace: derived from the bundle, the ABI and the Job; persisted
    /// paths accepted only when they are exactly that (the historical arm64
    /// directory and the legacy sibling staging included).
    #[test]
    fn the_namespace_is_derived_and_persisted_paths_must_match_it() {
        let deployment = deployment();
        let stg = "/data/app/el2/100/base/com.example.demo/haps/entry/files/arkdeck-native/job-186c8faffebe3b9cb8b0150ef9a645b2";
        assert_eq!(
            deployment.directory_path,
            "/data/app/el1/bundle/public/com.example.demo/libs/arm"
        );
        assert_eq!(
            deployment.target_path,
            "/data/app/el1/bundle/public/com.example.demo/libs/arm/libexample.so"
        );
        assert_eq!(
            deployment.loader_visible_path,
            "/data/storage/el1/bundle/libs/arm/libexample.so"
        );
        assert_eq!(deployment.staging_directory_path, stg);
        assert!(deployment.staging_directory_is_job_owned);
        assert_eq!(
            deployment.staging_path,
            format!("{stg}/libexample.so.staging")
        );
        assert_eq!(
            deployment.backup_path,
            "/data/app/el1/bundle/public/com.example.demo/libs/arm/.libexample.so.arkdeck-job-186c8faffebe3b9cb8b0150ef9a645b2.backup"
        );
        assert_eq!(
            deployment.rollback_staging_path,
            "/data/app/el1/bundle/public/com.example.demo/libs/arm/.libexample.so.arkdeck-job-186c8faffebe3b9cb8b0150ef9a645b2.rollback"
        );
        assert_eq!(
            deployment.code_sign_helper_remote_path.as_deref(),
            Some(format!("{stg}/arkdeck-code-sign-enable").as_str())
        );
        assert_eq!(
            deployment.native_libraries_root_path(),
            "/data/app/el1/bundle/public/com.example.demo/libs"
        );
        let rebuild = |exact: &ExactPaths| {
            Deployment::new(
                JOB,
                LEASE,
                ARTIFACT,
                BundleReference::new("com.example.demo").unwrap(),
                "libexample.so",
                deployment.artifact_facts.clone(),
                RestartProfile::RestartAbility,
                VerificationProfile::HashProcessAndMaps,
                RollbackPolicy::AutoRollback,
                deployment.code_sign_helper_facts.clone(),
                Some(exact),
            )
        };
        let exact = deployment.exact_paths();
        assert_eq!(rebuild(&exact).unwrap(), deployment);
        let mut historical = exact.clone();
        historical.directory_path =
            "/data/app/el1/bundle/public/com.example.demo/libs/arm64".into();
        historical.target_path = format!("{}/libexample.so", historical.directory_path);
        historical.loader_visible_path = "/data/storage/el1/bundle/libs/arm64/libexample.so".into();
        historical.backup_path = format!(
            "{}/.libexample.so.arkdeck-{JOB}.backup",
            historical.directory_path
        );
        historical.rollback_staging_path = format!(
            "{}/.libexample.so.arkdeck-{JOB}.rollback",
            historical.directory_path
        );
        assert_eq!(
            rebuild(&historical).unwrap().directory_path,
            historical.directory_path
        );
        let mut legacy = exact.clone();
        legacy.staging_directory_path = None;
        legacy.staging_path = format!(
            "{}/.libexample.so.arkdeck-{JOB}.staging",
            exact.directory_path
        );
        legacy.code_sign_helper_remote_path = None;
        let legacy_deployment = rebuild(&legacy).unwrap();
        assert!(!legacy_deployment.staging_directory_is_job_owned);
        assert_eq!(
            legacy_deployment.staging_directory_path,
            exact.directory_path
        );
        let mut foreign = exact.clone();
        foreign.backup_path = "/data/local/tmp/backup".into();
        assert_eq!(
            rebuild(&foreign).unwrap_err().to_string(),
            "unsupportedAction(\"persisted native deployment paths escape the provider-owned namespace\")"
        );
        let mut other_abi = exact;
        other_abi.directory_path =
            "/data/app/el1/bundle/public/com.example.demo/libs/x86_64".into();
        assert!(rebuild(&other_abi).is_err());
        let bad_job = Deployment::new(
            "job/1",
            LEASE,
            ARTIFACT,
            BundleReference::new("com.example.demo").unwrap(),
            "libexample.so",
            deployment.artifact_facts.clone(),
            RestartProfile::RestartAbility,
            VerificationProfile::HashProcessAndMaps,
            RollbackPolicy::AutoRollback,
            None,
            None,
        );
        assert_eq!(
            bad_job.unwrap_err().to_string(),
            "unsupportedAction(\"native deployment job identity is invalid\")"
        );
        let bad_name = Deployment::new(
            JOB,
            LEASE,
            ARTIFACT,
            BundleReference::new("com.example.demo").unwrap(),
            "example.so",
            deployment.artifact_facts.clone(),
            RestartProfile::RestartAbility,
            VerificationProfile::HashProcessAndMaps,
            RollbackPolicy::AutoRollback,
            None,
            None,
        );
        assert_eq!(
            bad_name.unwrap_err().to_string(),
            "unsupportedAction(\"native library logical name is invalid\")"
        );
        let no_helper = Deployment::new(
            JOB,
            LEASE,
            ARTIFACT,
            BundleReference::new("com.example.demo").unwrap(),
            "libexample.so",
            deployment.artifact_facts.clone(),
            RestartProfile::RestartAbility,
            VerificationProfile::HashProcessAndMaps,
            RollbackPolicy::AutoRollback,
            None,
            None,
        )
        .unwrap();
        assert_eq!(no_helper.code_sign_helper_remote_path, None);
    }

    /// Swift's admission over the inputs, in its order of refusals.
    #[test]
    fn admission_refuses_what_swift_refuses_in_its_order() {
        let refused = |inputs: Map<String, Value>,
                       resolved: Option<&ResolvedArtifact>,
                       bytes: &[u8],
                       helper: Option<&CodeSignHelper>| {
            Deployment::from_inputs(&inputs, JOB, resolved, bytes, helper)
                .unwrap_err()
                .to_string()
        };
        let bytes = library();
        let mut missing = inputs(&[]);
        missing.remove("libraryArtifactLease");
        assert_eq!(
            refused(missing, Some(&resolved()), &bytes, Some(&helper())),
            "unsupportedAction(\"libraryArtifactLease input is required\")"
        );
        let mut missing = inputs(&[]);
        missing.remove("targetBundle");
        assert_eq!(
            refused(missing, Some(&resolved()), &bytes, Some(&helper())),
            "unsupportedAction(\"targetBundle input is required\")"
        );
        let mut missing = inputs(&[]);
        missing.remove("libraryLogicalName");
        assert_eq!(
            refused(missing, Some(&resolved()), &bytes, Some(&helper())),
            "unsupportedAction(\"libraryLogicalName input is required\")"
        );
        assert_eq!(
            refused(
                inputs(&[("expectedABI", "mips")]),
                Some(&resolved()),
                &bytes,
                Some(&helper())
            ),
            "unsupportedAction(\"expectedABI input is invalid\")"
        );
        assert_eq!(
            refused(
                inputs(&[("restartProfile", "reboot")]),
                Some(&resolved()),
                &bytes,
                Some(&helper())
            ),
            "unsupportedAction(\"native deployment profile is invalid\")"
        );
        assert_eq!(
            refused(
                inputs(&[("restartProfile", "restartProcess")]),
                Some(&resolved()),
                &bytes,
                Some(&helper())
            ),
            "unsupportedAction(\"restartProcess has no complete app-owned restart/readback plan; refusing before authorization\")"
        );
        assert_eq!(
            refused(inputs(&[]), None, &bytes, Some(&helper())),
            "unsupportedAction(\"native deployment requires an engine-resolved Artifact lease\")"
        );
        let other = ResolvedArtifact {
            artifact_id: "ART-other".into(),
            ..resolved()
        };
        assert_eq!(
            refused(inputs(&[]), Some(&other), &bytes, Some(&helper())),
            "unsupportedAction(\"native deployment requires an engine-resolved Artifact lease\")"
        );
        assert_eq!(
            refused(
                inputs(&[("expectedABI", "x86_64")]),
                Some(&resolved()),
                &bytes,
                Some(&helper())
            ),
            "unsupportedAction(\"native library ABI arm64-v8a does not match expected x86_64\")"
        );
        let drifted = ResolvedArtifact {
            sha256: "0".repeat(64),
            ..resolved()
        };
        assert_eq!(
            refused(inputs(&[]), Some(&drifted), &bytes, Some(&helper())),
            "unsupportedAction(\"leased native Artifact bytes drifted during materialization\")"
        );
        assert_eq!(
            refused(inputs(&[]), Some(&resolved()), &bytes, None),
            "unsupportedAction(\"native deployment code-sign helper is unavailable\")"
        );
        let weaker = Deployment::from_inputs(
            &inputs(&[
                ("verificationProfile", "hashOnly"),
                ("rollbackPolicy", "retainBackup"),
            ]),
            JOB,
            Some(&resolved()),
            &bytes,
            Some(&helper()),
        )
        .unwrap();
        assert_eq!(weaker.verification_profile, VerificationProfile::HashOnly);
        assert_eq!(weaker.rollback_policy, RollbackPolicy::RetainBackup);
        assert_eq!(
            deployment().verification_profile,
            VerificationProfile::HashProcessAndMaps,
            "the default is at least the Catalog's"
        );
    }

    /// Every step's action, the shape of every lowering, and the refusals
    /// of a send or an inspection without what it needs.
    #[test]
    fn steps_map_to_actions_and_every_action_lowers_to_swift_s_sequence() {
        let deployment = deployment();
        let counts = [
            ("send-to-staging", 5),
            ("verify-remote-staging", 2),
            ("backup-current-version", 8),
            ("atomic-publish", 6),
            ("restart-target", 4),
            ("start-target", 3),
            ("verify-loaded-library", 5),
            ("cleanup-staging-and-backup", 10),
            ("cleanup-native-library-compensation", 10),
            ("rollback-native-library", 13),
        ];
        for (step, count) in counts {
            let action = NativeAction::for_step(step, &deployment).unwrap().unwrap();
            assert_eq!(argv(&action, step).len(), count, "{step}");
            assert!(
                argv(&action, step)
                    .iter()
                    .all(|arguments| arguments[..2] == ["-t".to_owned(), KEY.to_owned()])
            );
        }
        for step in ["verify-elf-locally", "hash-library", "finalize-session"] {
            assert_eq!(NativeAction::for_step(step, &deployment).unwrap(), None);
        }
        assert_eq!(
            NativeAction::for_step("other", &deployment)
                .unwrap_err()
                .to_string(),
            "unsupportedAction(\"other has no app-owned native-library action\")"
        );
        let send = NativeAction::SendToStaging(deployment.clone());
        let stg = &deployment.staging_directory_path;
        assert_eq!(
            argv(&send, "send-to-staging"),
            vec![
                ["-t", KEY, "shell", "mkdir", "-p", stg].map(str::to_owned).to_vec(),
                ["-t", KEY, "file", "send", "/private/tmp/arkdeck-hdc-oracle/artifacts/job-input-native-library/ART-469c10579b3c5461ab4d0a891c316397", &deployment.staging_path].map(str::to_owned).to_vec(),
                ["-t", KEY, "file", "send", "/private/tmp/arkdeck-hdc-oracle/host/arkdeck-code-sign-enable", &format!("{stg}/arkdeck-code-sign-enable")].map(str::to_owned).to_vec(),
                ["-t", KEY, "shell", "chmod", "700", &format!("{stg}/arkdeck-code-sign-enable")].map(str::to_owned).to_vec(),
                ["-t", KEY, "shell", "sha256sum", &format!("{stg}/arkdeck-code-sign-enable")].map(str::to_owned).to_vec(),
            ]
        );
        let FilePlan::Sequence(invocations) = send
            .lower(
                "send-to-staging",
                Some(KEY),
                Some(&resolved()),
                Some(588),
                Some(&helper()),
            )
            .unwrap()
        else {
            panic!()
        };
        assert_eq!(
            invocations
                .iter()
                .map(|invocation| invocation.timeout.as_secs())
                .collect::<Vec<_>>(),
            vec![30, 300, 60, 30, 30]
        );
        assert!(
            invocations
                .iter()
                .all(|invocation| !invocation.continue_after_non_zero)
        );
        assert_eq!(
            send.lower(
                "send-to-staging",
                Some(KEY),
                Some(&resolved()),
                Some(587),
                Some(&helper())
            )
            .unwrap_err(),
            "unsupportedAction(\"native send requires the same engine-resolved Artifact and a job-owned staging directory\")"
        );
        assert!(
            send.lower("send-to-staging", Some(KEY), None, None, Some(&helper()))
                .is_err()
        );
        assert!(
            send.lower(
                "send-to-staging",
                Some(KEY),
                Some(&resolved()),
                Some(588),
                None
            )
            .is_err()
        );
        assert!(
            send.lower(
                "send-to-staging",
                None,
                Some(&resolved()),
                Some(588),
                Some(&helper())
            )
            .unwrap_err()
            .contains("factsUnavailable")
        );
        let backup = NativeAction::Backup(deployment.clone());
        let FilePlan::Sequence(invocations) =
            backup.lower("b", Some(KEY), None, None, None).unwrap()
        else {
            panic!()
        };
        assert_eq!(
            invocations
                .iter()
                .map(|invocation| invocation.continue_after_non_zero)
                .collect::<Vec<_>>(),
            vec![false, false, false, false, false, false, false, true]
        );
        assert_eq!(
            invocations[7].arguments[2..],
            [
                "shell",
                "ls",
                "-la",
                "/data/app/el1/bundle/public/com.example.demo/libs"
            ]
            .map(str::to_owned)
        );
        let publish = NativeAction::Publish(deployment.clone());
        let FilePlan::Sequence(invocations) =
            publish.lower("p", Some(KEY), None, None, None).unwrap()
        else {
            panic!()
        };
        assert_eq!(
            invocations[2].arguments[2..],
            [
                "shell",
                &format!("{stg}/arkdeck-code-sign-enable"),
                "publish",
                &deployment.staging_path,
                &deployment.target_path,
                &deployment.rollback_staging_path
            ]
            .map(str::to_owned)
        );
        assert_eq!(
            invocations
                .iter()
                .map(|invocation| (
                    invocation.continue_after_non_zero,
                    invocation.timeout.as_secs()
                ))
                .collect::<Vec<_>>(),
            vec![
                (false, 15),
                (true, 30),
                (false, 60),
                (false, 30),
                (true, 30),
                (false, 15)
            ]
        );
        let stop = NativeAction::StopTarget(deployment.clone());
        let FilePlan::Sequence(invocations) = stop.lower("s", Some(KEY), None, None, None).unwrap()
        else {
            panic!()
        };
        assert_eq!(
            invocations
                .iter()
                .map(|invocation| invocation.timeout.as_secs())
                .collect::<Vec<_>>(),
            vec![60, 30, 5, 30]
        );
        let cleanup = NativeAction::Cleanup(deployment.clone());
        let lines = argv(&cleanup, "c");
        assert_eq!(lines[2][2..], ["shell", "rmdir", stg].map(str::to_owned));
        assert_eq!(
            lines[9][2..],
            ["shell", "ls", "-ld", &deployment.backup_path].map(str::to_owned)
        );
        let mut retained = deployment.clone();
        retained.rollback_policy = RollbackPolicy::RetainBackup;
        assert_eq!(argv(&NativeAction::Cleanup(retained), "c").len(), 8);
        let rollback = NativeAction::Rollback(deployment.clone());
        let lines = argv(&rollback, "r");
        assert_eq!(
            lines[6][2..],
            [
                "shell",
                "ln",
                &deployment.backup_path,
                &deployment.rollback_staging_path
            ]
            .map(str::to_owned)
        );
        assert_eq!(
            lines[12][2..],
            [
                "shell",
                "grep",
                "-F",
                &deployment.loader_visible_path,
                "/proc/*/maps"
            ]
            .map(str::to_owned)
        );
        let FilePlan::Sequence(invocations) =
            rollback.lower("r", Some(KEY), None, None, None).unwrap()
        else {
            panic!()
        };
        assert!(
            !invocations[0].continue_after_non_zero
                && invocations[1..]
                    .iter()
                    .all(|invocation| invocation.continue_after_non_zero)
        );
        let mut hash_only = deployment.clone();
        hash_only.verification_profile = VerificationProfile::HashOnly;
        assert_eq!(
            argv(
                &NativeAction::Inspect(hash_only.clone(), Inspection::TargetLoaded),
                "v"
            )
            .len(),
            3
        );
        assert_eq!(
            argv(
                &NativeAction::Inspect(hash_only.clone(), Inspection::RollbackRestored),
                "v"
            )
            .len(),
            3
        );
        hash_only.verification_profile = VerificationProfile::HashAndProcess;
        assert_eq!(
            argv(
                &NativeAction::Inspect(hash_only, Inspection::TargetLoaded),
                "v"
            )
            .len(),
            4
        );
        let mut helperless = deployment.clone();
        helperless.code_sign_helper_remote_path = None;
        assert_eq!(
            NativeAction::Inspect(helperless.clone(), Inspection::TargetLoaded)
                .lower("v", Some(KEY), None, None, None)
                .unwrap_err(),
            "unsupportedAction(\"native loader inspection has no persisted code-sign helper path\")"
        );
        assert_eq!(
            NativeAction::Inspect(helperless.clone(), Inspection::TargetMatchesArtifact)
                .lower("v", Some(KEY), None, None, None)
                .unwrap_err(),
            "unsupportedAction(\"native target inspection has no persisted code-sign helper path\")"
        );
        assert_eq!(
            NativeAction::Publish(helperless)
                .lower("p", Some(KEY), None, None, None)
                .unwrap_err(),
            "unsupportedAction(\"native publish has no persisted code-sign helper identity\")"
        );
        for (inspection, count) in [
            (Inspection::StagingMatchesArtifact, 2),
            (Inspection::BackupMatchesTarget, 2),
            (Inspection::TargetMatchesArtifact, 3),
            (Inspection::TargetStopped, 1),
            (Inspection::TargetStarted, 1),
            (Inspection::CleanupComplete, 5),
            (Inspection::RollbackRestored, 4),
        ] {
            assert_eq!(
                argv(&NativeAction::Inspect(deployment.clone(), inspection), "v").len(),
                count,
                "{inspection:?}"
            );
        }
    }

    /// The journal form: one object for every kind, the inspection's
    /// expectation added.
    #[test]
    fn persisted_forms_follow_swift() {
        let deployment = deployment();
        let (kind, arguments) = NativeAction::Publish(deployment.clone()).persisted();
        assert_eq!(kind, "hdc.publishNativeLibrary");
        for key in [
            "jobId",
            "artifactLeaseId",
            "artifactId",
            "bundleName",
            "libraryLogicalName",
            "abi",
            "elfClassBits",
            "machine",
            "buildId",
            "sha256",
            "byteCount",
            "restartProfile",
            "verificationProfile",
            "rollbackPolicy",
            "directoryPath",
            "targetPath",
            "loaderVisiblePath",
            "stagingPath",
            "backupPath",
            "rollbackStagingPath",
            "stagingDirectoryPath",
            "codeSignFormatVersion",
            "codeSignVersion",
            "signedDataByteCount",
            "signatureByteCount",
            "codeSignHelperABI",
            "codeSignHelperBuildId",
            "codeSignHelperSha256",
            "codeSignHelperByteCount",
            "codeSignHelperRemotePath",
        ] {
            assert!(arguments.contains_key(key), "{key}");
        }
        assert_eq!(arguments["machine"], 183);
        assert_eq!(arguments["elfClassBits"], 64);
        assert_eq!(arguments["abi"], "arm64-v8a");
        assert_eq!(arguments["codeSignHelperABI"], "arm64-v8a");
        assert!(!arguments.contains_key("expectation"));
        let (kind, arguments) =
            NativeAction::Inspect(deployment.clone(), Inspection::TargetLoaded).persisted();
        assert_eq!(kind, "hdc.inspectNativeLibrary");
        assert_eq!(arguments["expectation"], "targetLoaded");
        let mut plain = deployment.clone();
        plain.artifact_facts.code_sign = None;
        plain.code_sign_helper_facts = None;
        plain.code_sign_helper_remote_path = None;
        plain.staging_directory_is_job_owned = false;
        let (_, arguments) = NativeAction::Cleanup(plain).persisted();
        for key in [
            "codeSignFormatVersion",
            "codeSignHelperABI",
            "stagingDirectoryPath",
        ] {
            assert!(!arguments.contains_key(key), "{key}");
        }
        assert_eq!(
            NativeAction::Inspect(deployment.clone(), Inspection::TargetStopped).effect(),
            "readOnly"
        );
        assert_eq!(NativeAction::Backup(deployment).effect(), "deviceMutation");
    }

    /// Swift `materialize()`: every persisted native form reads back as the
    /// action that wrote it, with or without the helper and the code-sign
    /// facts, and each missing, foreign or moved fact is refused as Swift
    /// refuses it.
    #[test]
    fn persisted_forms_materialize_as_swift_materializes_them() {
        let deployment = deployment();
        let mut facts = deployment.artifact_facts.clone();
        facts.code_sign = None;
        let plain = Deployment::new(
            JOB,
            LEASE,
            ARTIFACT,
            deployment.bundle.clone(),
            "libexample.so",
            facts,
            RestartProfile::RestartAbility,
            VerificationProfile::HashOnly,
            RollbackPolicy::RetainBackup,
            None,
            None,
        )
        .unwrap();
        let mut actions = Vec::new();
        for deployment in [deployment.clone(), plain] {
            actions.extend([
                NativeAction::SendToStaging(deployment.clone()),
                NativeAction::Backup(deployment.clone()),
                NativeAction::Publish(deployment.clone()),
                NativeAction::StopTarget(deployment.clone()),
                NativeAction::StartTarget(deployment.clone()),
                NativeAction::Cleanup(deployment.clone()),
                NativeAction::Rollback(deployment.clone()),
            ]);
            actions.extend(
                [
                    Inspection::StagingMatchesArtifact,
                    Inspection::BackupMatchesTarget,
                    Inspection::TargetMatchesArtifact,
                    Inspection::TargetStopped,
                    Inspection::TargetStarted,
                    Inspection::TargetLoaded,
                    Inspection::CleanupComplete,
                    Inspection::RollbackRestored,
                ]
                .map(|expectation| NativeAction::Inspect(deployment.clone(), expectation)),
            );
        }
        for action in actions {
            let (kind, arguments) = action.persisted();
            assert_eq!(
                NativeAction::from_persisted(kind, &arguments).unwrap(),
                Some(action),
                "{kind}"
            );
        }

        let (kind, arguments) = NativeAction::Cleanup(deployment.clone()).persisted();
        let refused = |change: &dyn Fn(&mut Map<String, Value>)| {
            let mut changed = arguments.clone();
            change(&mut changed);
            NativeAction::from_persisted(kind, &changed)
                .unwrap_err()
                .to_string()
        };
        let prefix = "unsupportedAction(\"persisted hdc.cleanupNativeLibrary";
        assert_eq!(
            refused(&|arguments| {
                arguments.remove("abi");
            }),
            format!("{prefix} is missing string abi\")")
        );
        assert_eq!(
            refused(&|arguments| {
                arguments.insert("rollbackPolicy".into(), json!("never"));
            }),
            format!("{prefix} carries an unknown native deployment profile\")")
        );
        assert_eq!(
            refused(&|arguments| {
                arguments.insert("machine".into(), json!(65_536));
            }),
            format!("{prefix} native ELF machine is outside UInt16\")")
        );
        assert_eq!(
            refused(&|arguments| {
                arguments.remove("signedDataByteCount");
            }),
            format!("{prefix} carries incomplete native code-sign facts\")")
        );
        assert_eq!(
            refused(&|arguments| {
                arguments.remove("codeSignHelperRemotePath");
            }),
            format!("{prefix} carries incomplete code-sign helper facts\")")
        );
        assert_eq!(
            refused(&|arguments| {
                arguments.insert("byteCount".into(), json!("588"));
            }),
            format!("{prefix} is missing integer byteCount\")")
        );
        assert_eq!(
            refused(&|arguments| {
                arguments.insert("stagingPath".into(), json!("/data/local/tmp/libexample.so"));
            }),
            "unsupportedAction(\"persisted native deployment paths escape the provider-owned \
             namespace\")"
        );
        let mut inspected = NativeAction::Inspect(deployment, Inspection::CleanupComplete)
            .persisted()
            .1;
        inspected.insert("expectation".into(), json!("cleanupSkipped"));
        assert_eq!(
            NativeAction::from_persisted("hdc.inspectNativeLibrary", &inspected)
                .unwrap_err()
                .to_string(),
            "unsupportedAction(\"persisted native inspection expectation is unknown\")"
        );
        assert_eq!(
            NativeAction::from_persisted("hdc.uninstallPackage", &arguments).unwrap(),
            None
        );
    }

    /// The parsers on their own.
    #[test]
    fn the_parsers_read_as_swift_reads() {
        assert_eq!(
            sha256_token(&sub(&format!("{REPLACED}  /x\n"), 0)).as_deref(),
            Some(REPLACED)
        );
        assert_eq!(sha256_token(&sub(REPLACED, 1)), None);
        assert_eq!(sha256_token(&sub(&REPLACED.to_uppercase(), 0)), None);
        assert_eq!(
            sha256_token(&sub("sha256sum: x: No such file or directory\n", 0)),
            None
        );
        assert!(is_directory_listing(&sub(
            "drwx------ 2 20010050 20010050 3452 2026-09-14 00:00 /x\n",
            0
        )));
        assert!(!is_directory_listing(&sub(
            "-rw------- 1 20010050 20010050 256 2026 /x\n",
            0
        )));
        assert!(is_regular_file_listing(&sub(
            "-rw------- 1 20010050 20010050 256 2026 /x\n",
            0
        )));
        assert!(!is_regular_file_listing(&sub(
            "-rw------- 1 20010050 20010050 256 2026 /x\n",
            1
        )));
        assert_eq!(
            native_file_identity(&sub(
                "-rw------- 1 20010050 20010050 256 2026-09-14 00:00 /x\n",
                0
            )),
            Some(NativeFileIdentity {
                mode: "-rw-------".into(),
                user_id: 20010050,
                group_id: 20010050
            })
        );
        assert_eq!(
            native_file_identity(&with_stderr("-rw------- 1 1 1 2 x\n", "warn", 0)),
            None
        );
        assert_eq!(
            native_file_identity(&sub("drwx------ 2 1 1 2 x\n", 0)),
            None
        );
        assert_eq!(
            native_file_identity(&sub("-rw------- 1 a b 2 x\n", 0)),
            None
        );
        assert!(maps_contain(
            &sub(
                "/proc/4321/maps:7f000 /data/storage/el1/bundle/libs/arm/libexample.so\n",
                0
            ),
            "/data/storage/el1/bundle/libs/arm/libexample.so",
            &[4321]
        ));
        assert!(!maps_contain(
            &sub(
                "/proc/4321/maps:7f000 /data/storage/el1/bundle/libs/arm/libexample.so\n",
                0
            ),
            "/data/storage/el1/bundle/libs/arm/libexample.so",
            &[1]
        ));
        assert!(!maps_contain(
            &sub("/proc/4321/maps:7f000 /other.so\n", 0),
            "/data/storage/el1/bundle/libs/arm/libexample.so",
            &[4321]
        ));
        assert!(!maps_contain(
            &sub(
                "/proc/4321/maps:7f000 /data/storage/el1/bundle/libs/arm/libexample.so\n",
                1
            ),
            "/data/storage/el1/bundle/libs/arm/libexample.so",
            &[4321]
        ));
        assert_eq!(process_ids(&sub("4321 4322\n", 0)), Some(vec![4321, 4322]));
        assert_eq!(process_ids(&sub("4321 abc\n", 0)), None);
        assert_eq!(process_ids(&sub("0\n", 0)), None);
        assert_eq!(process_ids(&sub("", 0)), None);
        assert_eq!(process_ids(&sub("4321", 1)), None);
        assert!(process_is_absent(&sub("", 1)));
        assert!(process_is_absent(&sub("\n", 0)));
        assert!(!process_is_absent(&sub("", 2)));
        assert!(!process_is_absent(&with_stderr("", "x", 1)));
        assert!(!process_is_absent(&sub("4321", 0)));
        assert_eq!(
            readback_attestation(&sub(
                &format!("ARKDECK_CODE_SIGN_VERIFIED sha256:{REPLACED}\n"),
                0
            )),
            Attestation::Attested(REPLACED.into())
        );
        assert_eq!(
            readback_attestation(&with_stderr(
                "",
                "ARKDECK_CODE_SIGN_ERROR stage=verify code=30 errno=61\n",
                30
            )),
            Attestation::Absent
        );
        assert_eq!(
            readback_attestation(&sub(
                "ARKDECK_CODE_SIGN_ERROR stage=verify code=30 errno=95\n",
                0
            )),
            Attestation::Absent
        );
        assert_eq!(
            readback_attestation(&sub(
                "ARKDECK_CODE_SIGN_ERROR stage=verify code=30 errno=2\n",
                30
            )),
            Attestation::Unreadable
        );
        assert_eq!(
            readback_attestation(&sub(
                "ARKDECK_CODE_SIGN_ERROR stage=verify code=30 errno=61\nmore\n",
                30
            )),
            Attestation::Unreadable
        );
        assert_eq!(readback_attestation(&sub("", 0)), Attestation::Unreadable);
        assert_eq!(
            code_sign_digest(
                &sub(
                    &format!("ARKDECK_CODE_SIGN_PUBLISHED sha256:{REPLACED}\n"),
                    0
                ),
                "ARKDECK_CODE_SIGN_PUBLISHED"
            )
            .as_deref(),
            Some(REPLACED)
        );
        assert_eq!(
            code_sign_digest(
                &with_stderr(
                    &format!("ARKDECK_CODE_SIGN_PUBLISHED sha256:{REPLACED}\n"),
                    "x",
                    0
                ),
                "ARKDECK_CODE_SIGN_PUBLISHED"
            ),
            None
        );
        assert_eq!(
            code_sign_digest(
                &sub(
                    &format!("ARKDECK_CODE_SIGN_PUBLISHED sha256:{REPLACED}\n"),
                    0
                ),
                "ARKDECK_CODE_SIGN_VERIFIED"
            ),
            None
        );
        assert_eq!(
            code_sign_digest(
                &sub("ARKDECK_CODE_SIGN_PUBLISHED sha256:abc\n", 0),
                "ARKDECK_CODE_SIGN_PUBLISHED"
            ),
            None
        );
        assert!(published_without_attestation(&sub(
            "ARKDECK_CODE_SIGN_PUBLISHED_UNATTESTED replaced-file-had-none\n",
            0
        )));
        assert!(!published_without_attestation(&sub(
            "ARKDECK_CODE_SIGN_PUBLISHED_UNATTESTED\n",
            0
        )));
        let attested = sub(
            &format!("ARKDECK_CODE_SIGN_VERIFIED sha256:{REPLACED}\n"),
            0,
        );
        let absent = sub(
            "ARKDECK_CODE_SIGN_ERROR stage=verify code=30 errno=61\n",
            30,
        );
        let unreadable = sub("", 0);
        assert_eq!(
            attestation_at_least_replaced(&absent, &attested),
            Some(BTreeMap::from([
                ("fsVerityDigest".to_owned(), REPLACED.to_owned()),
                ("attestation".to_owned(), "fsVerity".to_owned())
            ])),
            "a floor, not an equality"
        );
        assert_eq!(
            attestation_at_least_replaced(&absent, &absent),
            Some(BTreeMap::from([(
                "attestation".to_owned(),
                "matchesReplacedFile:none".to_owned()
            )]))
        );
        assert_eq!(attestation_at_least_replaced(&attested, &absent), None);
        assert_eq!(attestation_at_least_replaced(&unreadable, &attested), None);
        assert_eq!(attestation_at_least_replaced(&absent, &unreadable), None);
    }

    /// The verdicts Swift reaches that the oracle's five Jobs do not cover.
    #[test]
    fn the_remaining_verdicts_follow_swift() {
        let deployment = deployment();
        let listing = |mode: &str| {
            sub(
                &format!("{mode} 1 20010050 20010050 256 2026-09-14 00:00 /x\n"),
                0,
            )
        };
        let send = NativeAction::SendToStaging(deployment.clone());
        assert_eq!(
            send.verify(&receipt(vec![
                sub("", 0),
                sub("FileTransfer finish\n", 0),
                sub("FileTransfer finish\n", 0),
                sub("", 0),
                sub(&format!("{HELPER_SHA256}  /h\n"), 0)
            ])),
            Outcome::Unknown("native staging send requires remote hash readback".into())
        );
        assert!(matches!(
            send.verify(&receipt(vec![
                sub("", 0),
                sub("", 0),
                sub("", 0),
                sub("", 0),
                sub(&format!("{REPLACED}  /h\n"), 0)
            ])),
            Outcome::Failed {
                code: "nativeSendFailed",
                ..
            }
        ));
        assert!(matches!(
            send.verify(&receipt(vec![
                sub("", 0),
                sub("", 0),
                sub("", 0),
                sub("", 0),
                sub(&format!("{HELPER_SHA256}  /h\n"), 1)
            ])),
            Outcome::Failed {
                code: "nativeSendFailed",
                ..
            }
        ));
        let backup = NativeAction::Backup(deployment.clone());
        assert!(matches!(
            backup.verify(&receipt(vec![sub("", 0)])),
            Outcome::Unknown(_)
        ));
        let Outcome::Failed {
            code: "nativeBackupMismatch",
            detail,
        } = backup.verify(&receipt(vec![
            listing("drwx------"),
            listing("-rw-------"),
            sub(&format!("{REPLACED}  /t\n"), 0),
            sub("", 0),
            sub("", 1),
            sub(&format!("{REPLACED}  /b\n"), 0),
            listing("-rw-------"),
            sub("total 4\n", 0),
        ]))
        else {
            panic!("a failed hard link")
        };
        assert!(
            detail.contains("hardLinkExit=1")
                && detail.contains("backupHashMatches=true")
                && detail.contains("diagnostics=0:outBytes="),
            "{detail}"
        );
        let stop = NativeAction::StopTarget(deployment.clone());
        let Outcome::Failed {
            code: "nativeTargetStillRunning",
            detail,
        } = stop.verify(&receipt(vec![
            sub("", 0),
            sub("4321\n", 0),
            sub("", 0),
            sub("4321\n", 0),
        ]))
        else {
            panic!("still running")
        };
        assert_eq!(
            detail,
            "com.example.demo remained live after stop (forceStopExit=0, pidofExit=0, pids=4321, stdoutBytes=5, stderrBytes=0)"
        );
        assert!(matches!(
            stop.verify(&receipt(vec![sub("", 0)])),
            Outcome::Unknown(_)
        ));
        let start = NativeAction::StartTarget(deployment.clone());
        assert!(matches!(
            start.verify(&receipt(vec![sub("", 0), sub("", 0), sub("", 1)])),
            Outcome::Failed {
                code: "nativeTargetNotRunning",
                ..
            }
        ));
        let cleanup = NativeAction::Cleanup(deployment.clone());
        let gone = sub("ls: /x: No such file or directory\n", 0);
        assert_eq!(
            cleanup.verify(&receipt(vec![
                sub("", 0),
                sub("", 0),
                sub("", 0),
                sub("", 0),
                sub("", 0),
                gone.clone(),
                gone.clone(),
                gone.clone(),
                gone.clone(),
                gone.clone()
            ])),
            Outcome::Verified(BTreeMap::from([
                ("cleaned".to_owned(), deployment.staging_path.clone()),
                ("backupRetained".to_owned(), "false".to_owned())
            ]))
        );
        assert!(matches!(
            cleanup.verify(&receipt(vec![
                gone.clone(),
                gone.clone(),
                gone.clone(),
                gone.clone(),
                listing("-rw-------")
            ])),
            Outcome::Failed {
                code: "cleanupDebt",
                ..
            }
        ));
        let rollback = NativeAction::Rollback(deployment.clone());
        assert!(matches!(
            rollback.verify(&receipt(vec![sub("", 0)])),
            Outcome::Unknown(_)
        ));
        let mut thirteen: Vec<Receipt> = (0..13).map(|_| sub("", 0)).collect();
        thirteen[0] = sub(&format!("{REPLACED}  /b\n"), 0);
        thirteen[4] = sub("", 1);
        thirteen[8] = sub(&format!("{REPLACED}  /t\n"), 0);
        thirteen[11] = sub("4321\n", 0);
        thirteen[12] = sub(
            "/proc/4321/maps:7f000 /data/storage/el1/bundle/libs/arm/libexample.so\n",
            0,
        );
        assert!(matches!(
            rollback.verify(&receipt(thirteen.clone())),
            Outcome::Verified(_)
        ));
        thirteen[8] = sub(&format!("{LIBRARY_SHA256}  /t\n"), 0);
        let Outcome::Failed {
            code: "nativeRollbackVerificationFailed",
            detail,
        } = rollback.verify(&receipt(thirteen))
        else {
            panic!("bytes not restored")
        };
        assert!(
            detail.contains("targetHashMatches=false")
                && detail.contains("startedPids=4321")
                && detail.contains("mapsMatched=true"),
            "{detail}"
        );
        // Inspections beyond the oracle: a weaker profile states what it did
        // not observe; a rollback readback stays unknown rather than failed.
        let mut hash_only = deployment.clone();
        hash_only.verification_profile = VerificationProfile::HashOnly;
        let attested = sub(
            &format!("ARKDECK_CODE_SIGN_VERIFIED sha256:{REPLACED}\n"),
            0,
        );
        let loaded = NativeAction::Inspect(hash_only.clone(), Inspection::TargetLoaded).verify(
            &receipt(vec![
                sub(&format!("{LIBRARY_SHA256}  /t\n"), 0),
                attested.clone(),
                attested.clone(),
            ]),
        );
        let Outcome::Verified(summary) = loaded else {
            panic!("{loaded:?}")
        };
        assert_eq!(summary["loaderVerified"], "notObserved");
        assert!(!summary.contains_key("processIds"));
        assert_eq!(summary["attestation"], "fsVerity");
        let restored =
            NativeAction::Inspect(hash_only, Inspection::RollbackRestored).verify(&receipt(vec![
                sub(&format!("{REPLACED}  /t\n"), 0),
                sub(&format!("{REPLACED}  /b\n"), 0),
                sub("4321\n", 0),
            ]));
        let Outcome::Verified(summary) = restored else {
            panic!("{restored:?}")
        };
        assert_eq!(summary["loaderVerified"], "notObserved");
        let unproven = NativeAction::Inspect(deployment.clone(), Inspection::RollbackRestored)
            .verify(&receipt(vec![
                sub(&format!("{REPLACED}  /t\n"), 0),
                sub(&format!("{REPLACED}  /b\n"), 0),
                sub("4321\n", 0),
                sub("/proc/1/maps:x\n", 0),
            ]));
        assert_eq!(
            unproven,
            Outcome::Unknown("rollback bytes exist but restored loader state is unproven".into())
        );
        let staging = NativeAction::Inspect(deployment.clone(), Inspection::StagingMatchesArtifact);
        let Outcome::Failed {
            code: "nativeStagingMismatch",
            detail,
        } = staging.verify(&receipt(vec![sub(&format!("{REPLACED}  /s\n"), 0)]))
        else {
            panic!()
        };
        assert_eq!(
            detail,
            "remote staging bytes do not match the leased ELF (hashExit=0, hashMatches=false, listingExit=missing, regularFile=false)"
        );
        assert!(matches!(
            NativeAction::Inspect(deployment.clone(), Inspection::BackupMatchesTarget).verify(
                &receipt(vec![
                    sub(&format!("{REPLACED}  /t\n"), 0),
                    sub(&format!("{LIBRARY_SHA256}  /b\n"), 0)
                ])
            ),
            Outcome::Failed {
                code: "nativeBackupMismatch",
                ..
            }
        ));
        assert_eq!(
            NativeAction::Inspect(deployment.clone(), Inspection::TargetStopped)
                .verify(&receipt(vec![sub("", 1)])),
            Outcome::Verified(BTreeMap::from([("running".to_owned(), "false".to_owned())]))
        );
        assert!(matches!(
            NativeAction::Inspect(deployment.clone(), Inspection::TargetStarted)
                .verify(&receipt(vec![sub("", 1)])),
            Outcome::Failed {
                code: "nativeTargetNotRunning",
                ..
            }
        ));
        assert!(matches!(
            NativeAction::Inspect(deployment.clone(), Inspection::CleanupComplete)
                .verify(&receipt(vec![gone.clone(); 4])),
            Outcome::Failed {
                code: "nativeCleanupIncomplete",
                ..
            }
        ));
        // Readbacks and their conclusions.
        assert_eq!(
            NativeAction::Publish(deployment.clone()).readback(),
            Some(NativeAction::Inspect(
                deployment.clone(),
                Inspection::TargetMatchesArtifact
            ))
        );
        assert_eq!(
            NativeAction::Inspect(deployment.clone(), Inspection::TargetStopped).readback(),
            None
        );
        let failed = Outcome::Failed {
            code: "nativeTargetHashMismatch",
            detail: "d".into(),
        };
        assert_eq!(
            NativeAction::Publish(deployment.clone()).reconcile(failed.clone()),
            Reconcile::StillUnknown(
                "nativeTargetHashMismatch: d; publish state is not safe to replay".into()
            )
        );
        assert_eq!(
            NativeAction::Rollback(deployment.clone()).reconcile(failed.clone()),
            Reconcile::StillUnknown("nativeTargetHashMismatch: d".into())
        );
        assert_eq!(
            NativeAction::Backup(deployment.clone()).reconcile(failed),
            Reconcile::ConfirmedNotExecuted
        );
        assert_eq!(
            NativeAction::Backup(deployment.clone()).reconcile(Outcome::Unknown("u".into())),
            Reconcile::StillUnknown("u".into())
        );
        assert_eq!(
            NativeAction::Backup(deployment).reconcile(Outcome::Verified(BTreeMap::new())),
            Reconcile::ConfirmedCompleted(BTreeMap::new())
        );
    }
}
