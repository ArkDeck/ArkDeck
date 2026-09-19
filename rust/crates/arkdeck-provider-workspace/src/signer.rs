//! Swift `OpenHarmonySigningWorkspaceDispatcher.dispatch` after its plan
//! checks, `verifyAndRecord` and `readVerifiedResult`: sign one staged HAP
//! through the preset's registered Java launcher and hap-sign-tool, answer
//! the signer's two password prompts on a pseudo-terminal, verify the product
//! with `verify-app` and record the verification as `signing-result.json`.
//!
//! The Java launcher runs through its retained inode with its SHA-256 pinned;
//! the JAR and the staged input stay open as [`VerifiedSource`]s and the JAR
//! is named by its `/.vol` inode alias, as Swift's descriptor-bound executor
//! names it. Both passwords come from [`SigningSecrets`] and travel only
//! through the terminal: they are in no argument, no environment, no receipt,
//! no record and no error.
//!
//! Failure classes follow Swift: anything refused before the signer runs is
//! [`SigningFailure::Refused`] (zero dispatch, the attempt directory removed);
//! from the spawn on every failure is [`SigningFailure::OutcomeUnknown`] and
//! needs readback, never a replay.
use crate::SigningError;
use crate::file_identity::{hash_file, hex};
use crate::signing_action::SigningAction;
use crate::signing_preset::{SigningPresetStore, SigningSecrets, remeasure_for_dispatch};
use arkdeck_platform::{
    PtyError, PtyInteraction, PtyRequest, ToolLimits, ToolRequest, ToolTermination, VerifiedSource,
    VerifiedTool, wipe,
};
use serde::Deserialize;
use serde_json::{Map, Value};
use std::collections::BTreeMap;
use std::ffi::OsString;
use std::io::Read;
use std::os::unix::fs::{DirBuilderExt, MetadataExt, PermissionsExt};
use std::path::Path;
use std::time::{Duration, Instant};

pub const KEYSTORE_PROMPT: &[u8] = b"please input KeystorePwd (timeout 30 seconds):";
pub const KEY_PROMPT: &[u8] = b"please input KeyPwd (timeout 30 seconds):";
pub const RESULT_SCHEMA: &str = "arkdeck-openharmony-signing-result/v1";
pub const SIGN_TIMEOUT: Duration = Duration::from_secs(600);
pub const VERIFY_TIMEOUT: Duration = Duration::from_secs(120);
const PTY_OUTPUT_BUDGET: usize = 1_048_576;
const VERIFY_CAPTURE_BYTES: usize = 256 * 1024;
const MAX_HAP_BYTES: u64 = 64 * 1024 * 1024;
const MAX_CHAIN_BYTES: u64 = 4 * 1024 * 1024;
const MAX_PROFILE_BYTES: u64 = 16 * 1024 * 1024;
const MAX_RECORD_BYTES: usize = 1024 * 1024;
const ZIP_MAGIC: [u8; 4] = [0x50, 0x4b, 0x03, 0x04];
/// Every key `verifyAndRecord` writes, and the only keys a record may carry.
pub const SUMMARY_KEYS: [&str; 15] = [
    "appCertificateSha256",
    "certificateChainReadbackSha256",
    "javaSha256",
    "keystoreSha256",
    "profileReadbackSha256",
    "projectRef",
    "signedHapByteCount",
    "signedHapSha256",
    "signedProfileSha256",
    "signerJarSha256",
    "signingPresetRef",
    "sourceArtifactId",
    "sourceByteCount",
    "sourceSha256",
    "verification",
];

/// Swift `RuntimeDispatchFailure` for this dispatcher. The text is
/// diagnostic (T2) and never carries a secret.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SigningFailure {
    /// `.failed`: refused before the signer was spawned.
    Refused(String),
    /// `.outcomeUnknown`: the signer may have run; its output needs readback.
    OutcomeUnknown(String),
}

/// A verified, recorded product: what Swift returns as the receipt's
/// host-managed record, summary and landed Artifact.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SignedHap {
    pub summary: BTreeMap<String, String>,
    pub result_record: String,
    pub signed_hap: String,
    pub byte_count: u64,
    pub sha256: String,
    pub duration: Duration,
}

/// Signs `action` once. `cancelled` is asked while the signer runs.
pub fn sign_hap(
    action: &SigningAction,
    store: &SigningPresetStore,
    secrets: &dyn SigningSecrets,
    cancelled: &dyn Fn() -> bool,
) -> Result<SignedHap, SigningFailure> {
    let current = store
        .load_validated(&action.preset.preset_id, true, secrets)
        .and_then(|current| {
            if current == action.preset {
                Ok(current)
            } else {
                Err(SigningError::drift("preset receipt"))
            }
        })
        .map_err(|error| {
            SigningFailure::Refused(format!(
                "signing preset unavailable before dispatch: {error}"
            ))
        })?;
    let signer_jar = VerifiedSource::open(
        Path::new(&current.signer_jar.path),
        &current.signer_jar.sha256,
        current.signer_jar.byte_count,
    )
    .map_err(|_| {
        SigningFailure::Refused("signing JAR identity unavailable before dispatch".into())
    })?;
    let pair = store.secret_pair(&current, secrets).map_err(|_| {
        SigningFailure::Refused("signing Keychain secret unavailable before dispatch".into())
    })?;

    let mut created = false;
    let admitted = (|| -> Result<(), SigningError> {
        let input = measured_hap(&action.input_file_path, MAX_HAP_BYTES)?;
        if input.0 != action.input_byte_count || input.1 != action.input_sha256 {
            return Err(SigningError::drift("input HAP"));
        }
        std::fs::DirBuilder::new()
            .mode(0o700)
            .create(&action.output.directory)
            .map_err(|error| SigningError::io(error.to_string()))?;
        created = true;
        stage_unsigned_hap(action)
    })();
    if let Err(error) = admitted {
        if created {
            let _ = std::fs::remove_dir_all(&action.output.directory);
        }
        return Err(SigningFailure::Refused(format!(
            "signing admission refused before spawn: {error}"
        )));
    }
    let staged = VerifiedSource::open(
        Path::new(&action.output.staged_unsigned_hap()),
        &action.input_sha256,
        action.input_byte_count,
    )
    .map_err(|_| {
        let _ = std::fs::remove_dir_all(&action.output.directory);
        SigningFailure::Refused("staged signing input identity unavailable before dispatch".into())
    })?;

    let started = Instant::now();
    let arguments = identity_bound_jar_arguments(&action.sign_arguments(), action, &signer_jar)
        .map_err(|error| {
            SigningFailure::OutcomeUnknown(format!(
                "signing PTY outcome requires readback: {error}"
            ))
        })?;
    let mut interactions = [
        PtyInteraction {
            expected_prompt: KEYSTORE_PROMPT.to_vec(),
            secret: pair.keystore.as_bytes().to_vec(),
        },
        PtyInteraction {
            expected_prompt: KEY_PROMPT.to_vec(),
            secret: pair.key.as_bytes().to_vec(),
        },
    ];
    drop(pair);
    let exchange = VerifiedTool::open(
        &action.preset.java_executable.path,
        &action.preset.java_executable.sha256,
    )
    .map_err(|_| PtyError::LaunchFailed(std::io::Error::other("java identity")))
    .and_then(|java| {
        java.run_pty_exchange(
            &PtyRequest {
                arguments: &arguments,
                environment: &[],
                working_directory: Some(Path::new(&action.output.directory)),
                timeout: SIGN_TIMEOUT,
            },
            &interactions,
            PTY_OUTPUT_BUDGET,
            cancelled,
        )
    });
    for interaction in &mut interactions {
        wipe(&mut interaction.secret);
    }
    drop(staged);
    drop(signer_jar);
    let execution = exchange.map_err(|error| match error {
        PtyError::SecretEchoDetected => {
            SigningFailure::OutcomeUnknown("signing PTY privacyFailure requires readback".into())
        }
        other => SigningFailure::OutcomeUnknown(format!(
            "signing PTY outcome requires readback: {}",
            safe_pty_error(&other)
        )),
    })?;
    if execution.termination != ToolTermination::Exited(0) {
        return Err(SigningFailure::OutcomeUnknown(format!(
            "hapsigner did not exit successfully (termination={}; completedPrompts={}; \
             observedOutputBytes={}; diagnosticCode={}); output requires readback",
            safe_termination(&execution.termination),
            execution.completed_interactions,
            execution.observed_output_byte_count,
            execution.failure_category.as_str()
        )));
    }
    let summary = verify_and_record(action).map_err(|error| {
        SigningFailure::OutcomeUnknown(format!(
            "signed output postflight requires recovery: {error}"
        ))
    })?;
    let (byte_count, sha256) =
        measured_hap(&action.output.signed_hap, MAX_HAP_BYTES).map_err(|error| {
            SigningFailure::OutcomeUnknown(format!(
                "signed output postflight requires recovery: {error}"
            ))
        })?;
    Ok(SignedHap {
        summary,
        result_record: action.output.result_record.clone(),
        signed_hap: action.output.signed_hap.clone(),
        byte_count,
        sha256,
        duration: started.elapsed(),
    })
}

/// Swift `verifyAndRecord(action:)`: re-measure the preset, run `verify-app`
/// once with the JAR bound by its inode, measure the product and both
/// readbacks, and publish the record next to them.
pub fn verify_and_record(action: &SigningAction) -> Result<BTreeMap<String, String>, SigningError> {
    remeasure_for_dispatch(&action.preset)?;
    let signer_jar = VerifiedSource::open(
        Path::new(&action.preset.signer_jar.path),
        &action.preset.signer_jar.sha256,
        action.preset.signer_jar.byte_count,
    )
    .map_err(|error| SigningError::io(error.to_string()))?;
    for path in [
        action.output.supported_certificate_chain_readback(),
        action.output.profile_readback.clone(),
    ] {
        match std::fs::remove_file(&path) {
            Err(error) if error.kind() != std::io::ErrorKind::NotFound => {
                return Err(SigningError::io(error.to_string()));
            }
            _ => {}
        }
    }
    let arguments = identity_bound_jar_arguments(&action.verify_arguments(), action, &signer_jar)?;
    let java = VerifiedTool::open(
        &action.preset.java_executable.path,
        &action.preset.java_executable.sha256,
    )
    .map_err(|error| SigningError::io(error.to_string()))?;
    let execution = java
        .run_tool(
            &ToolRequest {
                arguments: &arguments,
                environment: &[],
                working_directory: Some(Path::new(&action.output.directory)),
                limits: ToolLimits {
                    timeout: VERIFY_TIMEOUT,
                    capture_bytes: VERIFY_CAPTURE_BYTES,
                },
            },
            &|| false,
        )
        .map_err(|_| SigningError::io("verify-app did not complete exactly"))?;
    drop(signer_jar);
    if execution.termination != ToolTermination::Exited(0) || execution.truncated {
        return Err(SigningError::io("verify-app did not complete exactly"));
    }
    let signed = measured_hap(&action.output.signed_hap, MAX_HAP_BYTES)?;
    let chain = measured_regular_file(
        &action.output.supported_certificate_chain_readback(),
        MAX_CHAIN_BYTES,
    )?;
    let profile = measured_regular_file(&action.output.profile_readback, MAX_PROFILE_BYTES)?;
    let preset = &action.preset;
    let summary: BTreeMap<String, String> = [
        ("verification", "verified".to_owned()),
        ("projectRef", action.project_ref.clone()),
        (
            "signingPresetRef",
            action.selected_signing_preset_ref().to_owned(),
        ),
        ("sourceArtifactId", action.input_artifact_id.clone()),
        ("sourceSha256", action.input_sha256.clone()),
        ("sourceByteCount", action.input_byte_count.to_string()),
        ("javaSha256", preset.java_executable.sha256.clone()),
        ("signerJarSha256", preset.signer_jar.sha256.clone()),
        ("keystoreSha256", preset.keystore.sha256.clone()),
        (
            "appCertificateSha256",
            preset.app_certificate.sha256.clone(),
        ),
        ("signedProfileSha256", preset.signed_profile.sha256.clone()),
        ("signedHapSha256", signed.1),
        ("signedHapByteCount", signed.0.to_string()),
        ("certificateChainReadbackSha256", chain.1),
        ("profileReadbackSha256", profile.1),
    ]
    .into_iter()
    .map(|(key, value)| (key.to_owned(), value))
    .collect();
    write_record(action, &summary)?;
    Ok(summary)
}

/// Swift `readVerifiedResult(action:)`: a recorded verification is honoured
/// only for this action's source and preset, and only while the signed HAP
/// still measures as recorded. The record decodes with exactly Swift's keys.
pub fn read_verified_result(
    action: &SigningAction,
) -> Result<BTreeMap<String, String>, SigningError> {
    #[derive(Deserialize)]
    #[serde(deny_unknown_fields)]
    struct Record {
        #[serde(rename = "schemaVersion")]
        schema_version: String,
        summary: BTreeMap<String, String>,
    }
    let malformed = || SigningError::io("signing result record is malformed");
    let bytes = std::fs::read(&action.output.result_record).map_err(|_| malformed())?;
    if bytes.len() > MAX_RECORD_BYTES {
        return Err(malformed());
    }
    let record: Record = serde_json::from_slice(&bytes).map_err(|_| malformed())?;
    let summary = record.summary;
    if record.schema_version != RESULT_SCHEMA
        || !summary
            .keys()
            .all(|key| SUMMARY_KEYS.contains(&key.as_str()))
        || summary.get("sourceArtifactId") != Some(&action.input_artifact_id)
        || summary.get("sourceSha256") != Some(&action.input_sha256)
        || summary.get("signingPresetRef").map(String::as_str)
            != Some(action.selected_signing_preset_ref())
    {
        return Err(malformed());
    }
    let expected = summary.get("signedHapSha256").ok_or_else(malformed)?;
    let signed = measured_hap(&action.output.signed_hap, MAX_HAP_BYTES)?;
    if &signed.1 != expected || summary.get("signedHapByteCount") != Some(&signed.0.to_string()) {
        return Err(SigningError::drift("signed HAP recovery output"));
    }
    Ok(summary)
}

/// Swift `identityBoundJARArguments`: the argv must name the preset's JAR at
/// index 1, which is replaced by the retained descriptor's inode alias.
pub fn identity_bound_jar_arguments(
    arguments: &[String],
    action: &SigningAction,
    jar: &VerifiedSource,
) -> Result<Vec<OsString>, SigningError> {
    if arguments.len() < 2
        || arguments[0] != "-jar"
        || arguments[1] != action.preset.signer_jar.path
    {
        return Err(SigningError::drift("signer JAR arguments"));
    }
    let mut bound: Vec<OsString> = arguments.iter().map(OsString::from).collect();
    bound[1] = OsString::from(jar.inode_path());
    Ok(bound)
}

fn stage_unsigned_hap(action: &SigningAction) -> Result<(), SigningError> {
    let destination = action.output.staged_unsigned_hap();
    std::fs::copy(&action.input_file_path, &destination)
        .map_err(|error| SigningError::io(error.to_string()))?;
    std::fs::set_permissions(&destination, std::fs::Permissions::from_mode(0o600))
        .map_err(|error| SigningError::io(error.to_string()))?;
    let staged = measured_hap(&destination, MAX_HAP_BYTES)?;
    if staged.0 != action.input_byte_count || staged.1 != action.input_sha256 {
        return Err(SigningError::drift("staged input HAP"));
    }
    Ok(())
}

fn write_record(
    action: &SigningAction,
    summary: &BTreeMap<String, String>,
) -> Result<(), SigningError> {
    let record = Value::Object(Map::from_iter([
        (
            "schemaVersion".to_owned(),
            Value::String(RESULT_SCHEMA.to_owned()),
        ),
        (
            "summary".to_owned(),
            Value::Object(
                summary
                    .iter()
                    .map(|(key, value)| (key.clone(), Value::String(value.clone())))
                    .collect(),
            ),
        ),
    ]));
    let bytes = crate::canonical_json::encode(&record)
        .ok_or_else(|| SigningError::io("signing result record could not be encoded"))?;
    let token = arkdeck_platform::random_bytes::<16>()
        .map_err(|error| SigningError::io(error.to_string()))?;
    let temporary = format!(
        "{}/.signing-result-{}.tmp",
        action.output.directory,
        hex(&token).to_uppercase()
    );
    let result = (|| -> std::io::Result<()> {
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temporary)?;
        std::io::Write::write_all(&mut file, &bytes)?;
        file.set_permissions(std::fs::Permissions::from_mode(0o600))?;
        file.sync_all()?;
        drop(file);
        // Foundation `moveItem` refuses an existing destination; a hard link
        // does too, atomically.
        std::fs::hard_link(&temporary, &action.output.result_record)
    })();
    let _ = std::fs::remove_file(&temporary);
    result.map_err(|error| SigningError::io(error.to_string()))
}

/// Swift `measuredRegularFile(at:maximumBytes:)`: `(byteCount, sha256)`.
fn measured_regular_file(path: &str, maximum: u64) -> Result<(u64, String), SigningError> {
    let invalid = || SigningError::unsafe_file("postflight file is absent or invalid");
    if !path.starts_with('/') {
        return Err(invalid());
    }
    let metadata = std::fs::symlink_metadata(path).map_err(|_| invalid())?;
    if !metadata.file_type().is_file() || metadata.size() == 0 || metadata.size() > maximum {
        return Err(invalid());
    }
    let (sha256, count) = hash_file(path)
        .map_err(|_| SigningError::drift("postflight file changed while hashing"))?;
    if count != metadata.size() {
        return Err(SigningError::drift("postflight file changed while hashing"));
    }
    Ok((count, sha256))
}

/// Swift `measuredHAP(at:maximumBytes:)`: a measured file that begins with a
/// ZIP local header.
fn measured_hap(path: &str, maximum: u64) -> Result<(u64, String), SigningError> {
    let measured = measured_regular_file(path, maximum)?;
    let mut magic = [0u8; 4];
    std::fs::File::open(path)
        .and_then(|mut file| file.read_exact(&mut magic))
        .map_err(|_| SigningError::unsafe_file("HAP is not a ZIP container"))?;
    if magic != ZIP_MAGIC {
        return Err(SigningError::unsafe_file("HAP is not a ZIP container"));
    }
    Ok(measured)
}

/// Swift `safePTYError(_:)`.
fn safe_pty_error(error: &PtyError) -> &'static str {
    match error {
        PtyError::InvalidInteraction => "invalidInteraction",
        PtyError::Refused(_) | PtyError::LaunchFailed(_) => "launchFailed",
        PtyError::PromptProtocolViolation => "promptProtocolViolation",
        PtyError::SecretEchoDetected => "secretEchoDetected",
        PtyError::OutputBudgetExceeded => "outputBudgetExceeded",
        PtyError::TimedOut => "timedOut",
        PtyError::Cancelled => "cancelled",
        PtyError::WaitFailed(_) => "waitFailed",
    }
}

/// Swift `safeTermination(_:)`.
fn safe_termination(termination: &ToolTermination) -> String {
    match termination {
        ToolTermination::Exited(status) => format!("exit:{status}"),
        ToolTermination::Signalled(signal) => format!("signal:{signal}"),
        ToolTermination::TimedOut => "timedOut".into(),
        ToolTermination::Cancelled { .. } => "cancelled".into(),
    }
}
