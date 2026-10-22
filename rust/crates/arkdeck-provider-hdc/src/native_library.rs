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
use crate::operation::device_arguments;
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

impl CodeSignHelper {
    /// Swift `HDCNativeCodeSignHelperArtifact.bundled()`, without its
    /// resource lookup: the bytes a composition found are an arm64 ELF the
    /// library validator accepts, carry no mutable input signature, and are a
    /// static executable. The facts are the ones the device actions name.
    /// A refusal is Swift's `unsupportedAction` text, which a composition
    /// reports as its reason for leaving the operation unavailable.
    pub fn verified(data: &[u8], host_path: PathBuf) -> Result<Self, String> {
        let facts = validate_elf(data, Some(NativeAbi::Arm64), false)
            .map_err(|error| format!("bundled code-sign helper is invalid: {error}"))?;
        if facts.code_sign.is_some() {
            return Err(
                "bundled code-sign helper unexpectedly carries a mutable input signature".into(),
            );
        }
        if !crate::native_elf::static_executable(data) {
            return Err("bundled code-sign helper is not a static arm64 executable".into());
        }
        Ok(Self {
            facts: CodeSignHelperFacts {
                abi: facts.abi,
                build_id: facts.build_id,
                sha256: facts.sha256,
                byte_count: facts.byte_count,
            },
            host_path,
        })
    }
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

// NativeAction execution. Included so this stays the same module.
include!("native_library_parts/actions.rs");

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
// Tests. Included so they stay in this module.
include!("native_library_parts/tests.rs");
