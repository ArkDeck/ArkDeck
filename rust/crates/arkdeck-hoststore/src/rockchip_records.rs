//! Swift `RockchipRuntimeActionRecordStore` and
//! `DurableRockchipRuntimeActionHost` (`RockchipRuntimeActionHost.swift`):
//! the write-ahead records of every action the Rockchip host runs itself,
//! under `…/Agentd/rockchip-runtime/<job>/<step>/`, and the host that runs an
//! action only behind them.
//!
//! An action's intent is durable before it runs. Asked again for the same
//! step, the host replays a matching receipt rather than running the action a
//! second time; a read-only action without one runs again, while a device
//! mutation without one is an unknown outcome and is never resent. A record
//! whose identity drifted, or that cannot be read back, refuses — failed for
//! a read, unknown for a mutation. Every record is canonical JSON, owner-only,
//! written through a synchronized rename.

use crate::arktrace_profile::swift_sha256;
use crate::rockchip_action::RockchipAction;
use crate::session_graphemes::graphemes;
use crate::strict_json::swift_quoted;
use arkdeck_contract::sha256_hex;
use arkdeck_provider_arkforge::{HostAction, LaneFailure};
use serde_json::{Map, Value, json};
use std::collections::BTreeMap;
use std::io::{Read, Write};
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::{Component, Path, PathBuf};

/// Swift's record size bound.
const MAXIMUM_RECORD_BYTES: u64 = 1_048_576;

/// Swift `RockchipRuntimeActionExecutionResult`: what an action produced.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ExecutionResult {
    pub summary: BTreeMap<String, String>,
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
    pub stdout_truncated: bool,
    pub subprocess_count: usize,
}

/// Swift `RockchipRuntimeActionExecuting`: what performs an action once its
/// intent is durable, in the action's own record directory.
pub trait RockchipActionExecutor: Send + Sync {
    fn unavailable_reason(&self) -> Option<String>;

    fn execute(
        &self,
        action: &RockchipAction,
        descriptor: &HostAction,
        action_directory: &Path,
    ) -> Result<ExecutionResult, LaneFailure>;
}

/// Swift `RockchipRuntimeActionRecordStore` over `root`.
#[derive(Clone, Debug)]
pub struct RockchipRecordStore {
    root: PathBuf,
}

/// Swift `RockchipRuntimeHostPreparation`.
enum Preparation {
    Execute(PathBuf),
    Replay(ExecutionResult),
}

impl RockchipRecordStore {
    pub fn new(root: &Path) -> Self {
        Self {
            root: root.to_path_buf(),
        }
    }

    /// Swift `unavailableReason()`: the root prepared as the store prepares
    /// it, or why it cannot be.
    pub fn unavailable_reason(&self) -> Option<String> {
        prepare_directory(&self.root, true).err().map(|detail| {
            format!(
                "durable Rockchip host record root is unavailable: {}",
                described(&LaneFailure::Failed(detail))
            )
        })
    }

    /// Swift `prepare(descriptor:action:)`: a new step's intent made
    /// durable, or an existing step's receipt replayed, or why neither may
    /// happen.
    fn prepare(
        &self,
        descriptor: &HostAction,
        action: &RockchipAction,
    ) -> Result<Preparation, LaneFailure> {
        validate_component(&descriptor.job_id, "jobID")?;
        validate_component(&descriptor.step_id, "stepID")?;
        prepare_directory(&self.root, true).map_err(LaneFailure::Failed)?;
        let job_directory = self.root.join(&descriptor.job_id);
        prepare_directory(&job_directory, true).map_err(LaneFailure::Failed)?;
        let action_directory = job_directory.join(&descriptor.step_id);
        let intent = intent_record(descriptor, action);
        let mutation = action.mutates();
        let unknown_or_failed = |mutation_detail: String, read_detail: String| {
            if mutation {
                LaneFailure::OutcomeUnknown(mutation_detail)
            } else {
                LaneFailure::Failed(read_detail)
            }
        };
        match std::fs::DirBuilder::new()
            .mode(0o700)
            .create(&action_directory)
        {
            Ok(()) => {
                synchronize_directory(&job_directory).map_err(LaneFailure::Failed)?;
                write_record(&intent, &action_directory.join("intent.json")).map_err(|detail| {
                    LaneFailure::Failed(format!(
                        "cannot persist Rockchip host intent before dispatch: {}",
                        described(&LaneFailure::Failed(detail))
                    ))
                })?;
                return Ok(Preparation::Execute(action_directory));
            }
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {}
            Err(error) => {
                return Err(LaneFailure::Failed(format!(
                    "cannot create Rockchip record directory (errno {})",
                    error.raw_os_error().unwrap_or(0)
                )));
            }
        }
        prepare_directory(&action_directory, true).map_err(LaneFailure::Failed)?;
        let existing =
            read_record(&action_directory.join("intent.json"), &INTENT_KEYS).map_err(|detail| {
                let detail = described(&LaneFailure::Failed(detail));
                unknown_or_failed(
                    format!("durable Rockchip mutation intent cannot be recovered: {detail}"),
                    format!("durable Rockchip read-only intent cannot be recovered: {detail}"),
                )
            })?;
        if !same_members(&existing, &intent, &INTENT_KEYS) {
            return Err(unknown_or_failed(
                "durable Rockchip mutation intent identity drifted; original not resent".into(),
                "durable Rockchip read-only intent identity drifted".into(),
            ));
        }
        let receipt_path = action_directory.join("receipt.json");
        match std::fs::symlink_metadata(&receipt_path) {
            Ok(_) => {
                let receipt = read_record(&receipt_path, &RECEIPT_KEYS).map_err(|detail| {
                    let detail = described(&LaneFailure::Failed(detail));
                    unknown_or_failed(
                        format!("durable Rockchip mutation receipt cannot be recovered: {detail}"),
                        format!("durable Rockchip read-only receipt cannot be recovered: {detail}"),
                    )
                })?;
                let Some(replayed) = replayable(&receipt, descriptor) else {
                    return Err(unknown_or_failed(
                        "durable Rockchip mutation receipt is invalid; original not resent".into(),
                        "durable Rockchip read-only receipt is invalid".into(),
                    ));
                };
                let mut summary = replayed.summary;
                summary.insert("recordID".into(), record_id(descriptor));
                Ok(Preparation::Replay(ExecutionResult {
                    summary,
                    stdout_truncated: replayed.stdout_truncated,
                    ..ExecutionResult::default()
                }))
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                if mutation {
                    return Err(LaneFailure::OutcomeUnknown(
                        "durable Rockchip mutation intent has no receipt; original not resent"
                            .into(),
                    ));
                }
                Ok(Preparation::Execute(action_directory))
            }
            Err(error) => Err(LaneFailure::Failed(format!(
                "cannot inspect durable Rockchip receipt (errno {})",
                error.raw_os_error().unwrap_or(0)
            ))),
        }
    }

    /// Swift `finish(descriptor:result:actionDirectory:)`: the receipt made
    /// durable beside its intent; its record id.
    fn finish(
        &self,
        descriptor: &HostAction,
        result: &ExecutionResult,
        action_directory: &Path,
    ) -> Result<String, String> {
        let receipt = json!({
            "schemaVersion": "1.0.0",
            "jobID": descriptor.job_id,
            "stepID": descriptor.step_id,
            "targetID": descriptor.target_id,
            "bindingRevision": descriptor.binding_revision,
            "stableIdentitySHA256": descriptor.expected_identity_sha256,
            "providerExecutableSHA256": descriptor.provider_executable_sha256,
            "actionSHA256": descriptor.action_sha256,
            "summary": result.summary,
            "stdoutSHA256": sha256_hex(&result.stdout),
            "stdoutByteCount": result.stdout.len(),
            "stderrSHA256": sha256_hex(&result.stderr),
            "stderrByteCount": result.stderr.len(),
            "stdoutTruncated": result.stdout_truncated,
            "subprocessCount": result.subprocess_count,
        });
        write_record(&receipt, &action_directory.join("receipt.json"))?;
        Ok(record_id(descriptor))
    }
}

/// Swift `RockchipRuntimeActionHosting`: what runs a host-managed Rockchip
/// action for the dispatcher, and for the ArkForge lane's managed control.
pub trait RockchipActionHosting: Send + Sync {
    fn unavailable_reason(&self) -> Option<String>;

    /// The result, its summary naming the durable receipt (`recordID`).
    fn execute(
        &self,
        action: &RockchipAction,
        descriptor: &HostAction,
        provider_executable_sha256: &str,
    ) -> Result<ExecutionResult, LaneFailure>;
}

/// Swift `RefusingRockchipRuntimeActionHost`: every action refused for one
/// reason, which is also its unavailability.
pub struct RefusingRockchipHost(pub String);

impl RockchipActionHosting for RefusingRockchipHost {
    fn unavailable_reason(&self) -> Option<String> {
        Some(self.0.clone())
    }

    fn execute(
        &self,
        _action: &RockchipAction,
        _descriptor: &HostAction,
        _provider_executable_sha256: &str,
    ) -> Result<ExecutionResult, LaneFailure> {
        Err(LaneFailure::Failed(self.0.clone()))
    }
}

/// Swift `DurableRockchipRuntimeActionHost`: an action validated against its
/// descriptor, then run only behind its durable intent, or replayed from
/// its receipt.
pub struct DurableRockchipHost<E: RockchipActionExecutor> {
    executor: E,
    records: RockchipRecordStore,
}

impl<E: RockchipActionExecutor> DurableRockchipHost<E> {
    pub fn new(executor: E, records: RockchipRecordStore) -> Self {
        Self { executor, records }
    }
}

impl<E: RockchipActionExecutor> RockchipActionHosting for DurableRockchipHost<E> {
    /// Swift `unavailableReason()`: the executor's, then the records'.
    fn unavailable_reason(&self) -> Option<String> {
        self.executor
            .unavailable_reason()
            .or_else(|| self.records.unavailable_reason())
    }

    /// Swift `execute(action:descriptor:providerExecutable:)`.
    fn execute(
        &self,
        action: &RockchipAction,
        descriptor: &HostAction,
        provider_executable_sha256: &str,
    ) -> Result<ExecutionResult, LaneFailure> {
        if descriptor.binding_revision <= 0
            || !swift_sha256(&descriptor.expected_identity_sha256)
            || descriptor.provider_executable_sha256 != provider_executable_sha256
        {
            return Err(LaneFailure::Failed(
                "host-managed target/binding/executable correlation is incomplete or drifted"
                    .into(),
            ));
        }
        if action.sha256() != descriptor.action_sha256 {
            return Err(LaneFailure::Failed(
                "host-managed typed action digest drifted after materialization".into(),
            ));
        }
        if !action.matches(descriptor) {
            return Err(LaneFailure::Failed(
                "host-managed typed action does not match its target/descriptor".into(),
            ));
        }
        let action_directory = match self.records.prepare(descriptor, action)? {
            Preparation::Replay(result) => return Ok(result),
            Preparation::Execute(directory) => directory,
        };
        let mut result = self
            .executor
            .execute(action, descriptor, &action_directory)?;
        match self.records.finish(descriptor, &result, &action_directory) {
            Ok(record) => {
                result.summary.insert("recordID".into(), record);
                Ok(result)
            }
            Err(detail) => {
                let detail = described(&LaneFailure::Failed(detail));
                Err(if action.mutates() {
                    LaneFailure::OutcomeUnknown(format!(
                        "external effect completed but its durable host receipt could not be \
                         persisted: {detail}"
                    ))
                } else {
                    LaneFailure::Failed(format!(
                        "read-only host receipt could not be persisted: {detail}"
                    ))
                })
            }
        }
    }
}

/// The type a record field must decode as.
#[derive(Clone, Copy)]
enum Field {
    Text,
    Integer,
    Flag,
    /// `[String: String]`.
    Summary,
    /// `PersistedTypedProviderAction`: a kind and an object of arguments.
    Action,
}

/// Swift `RockchipRuntimeHostIntentRecord`'s fields.
const INTENT_KEYS: [(&str, Field); 9] = [
    ("action", Field::Action),
    ("actionSHA256", Field::Text),
    ("bindingRevision", Field::Integer),
    ("jobID", Field::Text),
    ("providerExecutableSHA256", Field::Text),
    ("schemaVersion", Field::Text),
    ("stableIdentitySHA256", Field::Text),
    ("stepID", Field::Text),
    ("targetID", Field::Text),
];

/// Swift `RockchipRuntimeHostReceiptRecord`'s fields.
const RECEIPT_KEYS: [(&str, Field); 15] = [
    ("actionSHA256", Field::Text),
    ("bindingRevision", Field::Integer),
    ("jobID", Field::Text),
    ("providerExecutableSHA256", Field::Text),
    ("schemaVersion", Field::Text),
    ("stableIdentitySHA256", Field::Text),
    ("stderrByteCount", Field::Integer),
    ("stderrSHA256", Field::Text),
    ("stdoutByteCount", Field::Integer),
    ("stdoutSHA256", Field::Text),
    ("stdoutTruncated", Field::Flag),
    ("stepID", Field::Text),
    ("subprocessCount", Field::Integer),
    ("summary", Field::Summary),
    ("targetID", Field::Text),
];

impl Field {
    fn holds(self, value: &Value) -> bool {
        match self {
            Self::Text => value.is_string(),
            Self::Integer => value.is_i64() || value.is_u64(),
            Self::Flag => value.is_boolean(),
            Self::Summary => value
                .as_object()
                .is_some_and(|summary| summary.values().all(Value::is_string)),
            Self::Action => value.as_object().is_some_and(|action| {
                action.get("kind").is_some_and(Value::is_string)
                    && action.get("arguments").is_some_and(Value::is_object)
            }),
        }
    }
}

/// Swift `RockchipRuntimeHostIntentRecord`.
fn intent_record(descriptor: &HostAction, action: &RockchipAction) -> Value {
    json!({
        "schemaVersion": "1.0.0",
        "jobID": descriptor.job_id,
        "stepID": descriptor.step_id,
        "targetID": descriptor.target_id,
        "bindingRevision": descriptor.binding_revision,
        "stableIdentitySHA256": descriptor.expected_identity_sha256,
        "providerExecutableSHA256": descriptor.provider_executable_sha256,
        "actionSHA256": descriptor.action_sha256,
        "action": action.persisted(),
    })
}

/// What a well-formed receipt of this descriptor lets the host replay.
struct Replayed {
    summary: BTreeMap<String, String>,
    stdout_truncated: bool,
}

/// Swift `RockchipRuntimeHostReceiptRecord.matches(descriptor:)` and
/// `isWellFormed`: the receipt's identity is the descriptor's, its stream
/// digests 64 lowercase hexadecimal Characters, its counts non-negative, and
/// its summary 1-64 entries of keys and values bounded in Characters.
fn replayable(receipt: &Map<String, Value>, descriptor: &HostAction) -> Option<Replayed> {
    let text = |key: &str| receipt.get(key).and_then(Value::as_str);
    let count = |key: &str| receipt.get(key).and_then(Value::as_i64);
    let matches = text("schemaVersion") == Some("1.0.0")
        && text("jobID") == Some(descriptor.job_id.as_str())
        && text("stepID") == Some(descriptor.step_id.as_str())
        && text("targetID") == Some(descriptor.target_id.as_str())
        && count("bindingRevision") == Some(descriptor.binding_revision)
        && text("stableIdentitySHA256") == Some(descriptor.expected_identity_sha256.as_str())
        && text("providerExecutableSHA256") == Some(descriptor.provider_executable_sha256.as_str())
        && text("actionSHA256") == Some(descriptor.action_sha256.as_str());
    let summary: BTreeMap<String, String> = receipt
        .get("summary")?
        .as_object()?
        .iter()
        .map(|(key, value)| Some((key.clone(), value.as_str()?.to_owned())))
        .collect::<Option<_>>()?;
    let well_formed = text("stdoutSHA256").is_some_and(swift_sha256)
        && text("stderrSHA256").is_some_and(swift_sha256)
        && count("stdoutByteCount").is_some_and(|count| count >= 0)
        && count("stderrByteCount").is_some_and(|count| count >= 0)
        && count("subprocessCount").is_some_and(|count| count >= 0)
        && !summary.is_empty()
        && summary.len() <= 64
        && summary.iter().all(|(key, value)| {
            !key.is_empty()
                && graphemes(key).take(129).count() <= 128
                && graphemes(value).take(4_097).count() <= 4_096
        });
    let stdout_truncated = receipt.get("stdoutTruncated")?.as_bool()?;
    (matches && well_formed).then_some(Replayed {
        summary,
        stdout_truncated,
    })
}

/// Swift's record id, `rockchip-runtime/<job>/<step>/receipt.json`.
fn record_id(descriptor: &HostAction) -> String {
    format!(
        "rockchip-runtime/{}/{}/receipt.json",
        descriptor.job_id, descriptor.step_id
    )
}

/// Swift `validateComponent(_:field:)`: `^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$`.
fn validate_component(value: &str, field: &str) -> Result<(), LaneFailure> {
    let bytes = value.as_bytes();
    let bounded = (1..=128).contains(&bytes.len())
        && bytes[0].is_ascii_alphanumeric()
        && bytes[1..]
            .iter()
            .all(|byte| byte.is_ascii_alphanumeric() || b"._-".contains(byte));
    if bounded {
        Ok(())
    } else {
        Err(LaneFailure::Failed(format!(
            "{field} is not a bounded path component"
        )))
    }
}

/// Swift `prepareDirectory(_:allowExisting:)`: `path` created owner-only
/// when missing, its parent then synchronized, and otherwise required to be
/// an owner-only real directory. Swift compares the path with its
/// standardized form; here it must be absolute, name no parent, and be
/// spelled exactly as its components rebuild it. Declared difference:
/// Foundation also strips `/private` from an existing `/private/tmp/…` path,
/// so Swift refuses such a root once it exists; this one does not.
pub(crate) fn prepare_directory(path: &Path, allow_existing: bool) -> Result<(), String> {
    let canonical = path.is_absolute()
        && !path
            .components()
            .any(|component| component == Component::ParentDir)
        && path.components().collect::<PathBuf>().as_os_str() == path.as_os_str();
    if !canonical {
        return Err("Rockchip record path is not canonical".into());
    }
    let created = match std::fs::DirBuilder::new().mode(0o700).create(path) {
        Ok(()) => true,
        Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
            if !allow_existing {
                return Err(
                    "durable Rockchip action directory already exists; refusing duplicate \
                     dispatch"
                        .into(),
                );
            }
            false
        }
        Err(error) => {
            return Err(format!(
                "cannot create Rockchip record directory (errno {})",
                error.raw_os_error().unwrap_or(0)
            ));
        }
    };
    let owner_only = std::fs::symlink_metadata(path).is_ok_and(|metadata| {
        metadata.file_type().is_dir() && metadata.permissions().mode() & 0o077 == 0
    });
    if !owner_only {
        return Err("Rockchip record directory is not an owner-only real directory".into());
    }
    if created {
        synchronize_directory(path.parent().unwrap_or(path))?;
    }
    Ok(())
}

/// Swift `synchronizeDirectory(_:)`.
fn synchronize_directory(path: &Path) -> Result<(), String> {
    let directory = std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path)
        .map_err(|_| "cannot open Rockchip record directory for synchronization".to_owned())?;
    directory.sync_all().map_err(|error| {
        format!(
            "cannot synchronize Rockchip record directory (errno {})",
            error.raw_os_error().unwrap_or(0)
        )
    })
}

/// Swift `write(_:to:)`: canonical JSON into an owner-only temporary file
/// created exclusively beside `path`, synchronized, renamed over it, and the
/// directory synchronized.
fn write_record(value: &Value, path: &Path) -> Result<(), String> {
    let bytes = crate::session_json::encode(value)
        .map_err(|_| "cannot encode Rockchip record".to_owned())?;
    let directory = path.parent().unwrap_or(path);
    let name = path
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_default();
    let nonce: [u8; 16] = arkdeck_platform::random_bytes().map_err(|error| {
        format!(
            "cannot create owner-only Rockchip record (errno {})",
            error.raw_os_error().unwrap_or(0)
        )
    })?;
    let temporary = directory.join(format!(".{name}.{}.tmp", uuid_text(&nonce)));
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(&temporary)
        .map_err(|error| {
            format!(
                "cannot create owner-only Rockchip record (errno {})",
                error.raw_os_error().unwrap_or(0)
            )
        })?;
    let written = file
        .write_all(&bytes)
        .map_err(|error| {
            format!(
                "cannot write Rockchip record (errno {})",
                error.raw_os_error().unwrap_or(0)
            )
        })
        .and_then(|()| {
            file.sync_all().map_err(|error| {
                format!(
                    "cannot synchronize Rockchip record (errno {})",
                    error.raw_os_error().unwrap_or(0)
                )
            })
        });
    drop(file);
    if let Err(detail) = written {
        let _ = std::fs::remove_file(&temporary);
        return Err(detail);
    }
    if let Err(error) = std::fs::rename(&temporary, path) {
        let _ = std::fs::remove_file(&temporary);
        return Err(format!(
            "cannot publish Rockchip record (errno {})",
            error.raw_os_error().unwrap_or(0)
        ));
    }
    synchronize_directory(directory)
}

/// A lowercase UUID's text from 16 random bytes, as Swift names its
/// temporary files.
fn uuid_text(bytes: &[u8; 16]) -> String {
    let hex: String = bytes.iter().map(|byte| format!("{byte:02x}")).collect();
    format!(
        "{}-{}-{}-{}-{}",
        &hex[0..8],
        &hex[8..12],
        &hex[12..16],
        &hex[16..20],
        &hex[20..32]
    )
}

/// Swift `read(_:from:)`: a bounded owner-only regular file, never through a
/// symbolic link, decoded as the record whose `fields` it must carry, each of
/// its type; fields the record does not declare are not decoded. A record
/// that does not decode is refused in these words rather than Swift's
/// `DecodingError` (declared).
fn read_record(path: &Path, fields: &[(&str, Field)]) -> Result<Map<String, Value>, String> {
    let mut file = std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path)
        .map_err(|error| {
            format!(
                "cannot open Rockchip record (errno {})",
                error.raw_os_error().unwrap_or(0)
            )
        })?;
    let metadata = file.metadata().map_err(|error| {
        format!(
            "cannot open Rockchip record (errno {})",
            error.raw_os_error().unwrap_or(0)
        )
    })?;
    if !metadata.file_type().is_file()
        || metadata.mode() & 0o077 != 0
        || metadata.len() == 0
        || metadata.len() > MAXIMUM_RECORD_BYTES
    {
        return Err("Rockchip record is not a bounded owner-only regular file".into());
    }
    let mut bytes = Vec::with_capacity(metadata.len() as usize);
    file.read_to_end(&mut bytes).map_err(|error| {
        format!(
            "cannot read complete Rockchip record (errno {})",
            error.raw_os_error().unwrap_or(0)
        )
    })?;
    let record = serde_json::from_slice::<Value>(&bytes)
        .ok()
        .and_then(|value| value.as_object().cloned())
        .filter(|record| {
            fields
                .iter()
                .all(|(key, field)| record.get(*key).is_some_and(|value| field.holds(value)))
        })
        .ok_or_else(|| "the Rockchip record does not decode".to_owned())?;
    Ok(record)
}

/// Swift's `==` of two decoded records: every field the record type
/// declares; keys it does not declare are not decoded.
fn same_members(existing: &Map<String, Value>, expected: &Value, fields: &[(&str, Field)]) -> bool {
    fields
        .iter()
        .all(|(key, _)| existing.get(*key) == expected.get(*key))
}

/// Swift's `"\(error)"` of a lane or host failure, as a skipped step's reason
/// quotes it. A diagnostic prints as Swift prints an enum case inside
/// another's payload, qualified by its module and type.
pub(crate) fn described(failure: &LaneFailure) -> String {
    let quoted = swift_quoted;
    match failure {
        LaneFailure::Failed(reason) => format!("failed({})", quoted(reason)),
        LaneFailure::ConfirmedNotExecuted(reason) => {
            format!("confirmedNotExecuted({})", quoted(reason))
        }
        LaneFailure::ConfirmedNotExecutedWithDiagnostic { reason, diagnostic } => format!(
            "confirmedNotExecutedWithDiagnostic({}, diagnostic: \
             ArkDeckWorkflows.RockchipFlashRuntimeDiagnostic.{diagnostic})",
            quoted(reason)
        ),
        LaneFailure::OutcomeUnknown(reason) => format!("outcomeUnknown({})", quoted(reason)),
        LaneFailure::Other(description) => description.clone(),
    }
}

#[cfg(test)]
mod tests;
