//! The reads of Swift's `RuntimeDebugInvocationController`
//! (`RuntimeDebugInvocation.swift`), the protected Flash recovery broker:
//! `debug.status` and `recovery.flash-invocation.list` over the invocation
//! documents it keeps in `<state>/runtime-debug-invocations/`, paged through
//! `<state>/runtime-debug-invocation-snapshots/`.
//!
//! One document per invocation, `<invocationID>.json`, in the one current
//! layout (`schemaVersion` `1.0.0`). A document is read as Swift's
//! `CurrentDurableJSON` reads it: no duplicate member, every field of the
//! current shape with its type, and nothing else — the JSON must be exactly
//! what the typed document encodes back to. A document that fails any of that
//! is answered as absent, as Swift answers it; one that decodes but names
//! another schema, another identity or an epoch count outside the budget is
//! unreadable. The file must be the Runtime user's private single-link
//! regular file, opened through no link, in a private directory.
//!
//! A read never writes except the list's immutable snapshot. Starting,
//! evaluating and expiring an invocation are the broker's own
//! (`debug.start`, `debug.evaluate`; `flash_invocation_broker.rs`).
use crate::operation_request::OperationRequest;
use crate::snapshot_pager::SnapshotPager;
use crate::strict_json::{self, swift_quoted};
use crate::swift_decoding::{swift_integer, swift_value};
use arkdeck_contract::WireError;
use serde_json::{Map, Value, json};
use std::io::{self, Read};
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::sync::Mutex;

#[path = "flash_invocation_broker.rs"]
mod broker;
pub use broker::InvocationBroker;

/// Swift `RuntimeDebugInvocationController.maximumDestructiveEpochs`.
pub const MAXIMUM_DESTRUCTIVE_EPOCHS: i64 = 16;
const MAXIMUM_RECORDS: usize = 4_096;
const MAXIMUM_DOCUMENT_BYTES: u64 = 16 * 1_024 * 1_024;
const DIRECTORY: &str = "runtime-debug-invocations";
const SNAPSHOTS: &str = "runtime-debug-invocation-snapshots";
const SCHEMA_VERSION: &str = "1.0.0";
const OUTCOMES: [&str; 5] = [
    "succeeded",
    "safeToReflash",
    "outcomeUnknown",
    "failedKnown",
    "refused",
];

/// Swift `RuntimeDebugInvocationError`'s two cases a read raises, as the
/// daemon answers them (`debugInvocationErrorCode`): no details.
enum ReadError {
    NotFound(String),
    Persistence(&'static str),
}

impl ReadError {
    fn wire(self) -> WireError {
        let (code, message) = match self {
            Self::NotFound(identity) => (
                "notFound",
                format!("invocationNotFound({})", swift_quoted(&identity)),
            ),
            Self::Persistence(detail) => (
                "recordUnreadable",
                format!("persistenceFailure({})", swift_quoted(detail)),
            ),
        };
        WireError {
            code: code.into(),
            message,
            details: None,
        }
    }
}

/// Any other error, as the daemon's catch-all answers it: no details.
fn internal(message: &str) -> WireError {
    WireError {
        code: "internalError".into(),
        message: message.into(),
        details: None,
    }
}

/// An `AgentExecutionControlFailure` as the daemon answers it: with empty
/// details.
fn control_failure(code: &str, message: &str) -> WireError {
    WireError {
        code: code.into(),
        message: message.into(),
        details: Some(Map::new()),
    }
}

fn invalid_params(message: &str) -> WireError {
    WireError {
        code: "invalidParams".into(),
        message: message.into(),
        details: None,
    }
}

/// One decoded document: the typed request it pins and the fields a read
/// projects, the evaluations as they were stored.
struct Document {
    state: String,
    seed: OperationRequest,
    fingerprint: String,
    baseline: String,
    created: String,
    expires: String,
    epochs: i64,
    evaluations: Vec<Value>,
}

/// The owner of the invocation documents' reads under one state directory.
/// Swift's controller is an actor, so its requests never overlap; neither do
/// these, which is what lets the pager keep no lock of its own.
pub struct FlashInvocations {
    directory: PathBuf,
    pages: SnapshotPager,
    serial: Mutex<()>,
    /// The invocations being evaluated now (Swift's `activeEvaluations`).
    active: Mutex<std::collections::BTreeSet<String>>,
}

impl FlashInvocations {
    /// Swift `RuntimeDebugInvocationController.init`'s storage: the snapshot
    /// directory and the invocation directory created owner-only when absent,
    /// and the invocation directory required to be a private Runtime
    /// directory, which fails the daemon's start as Swift's does.
    pub fn open(state: &Path) -> io::Result<Self> {
        let snapshots = state.join(SNAPSHOTS);
        let directory = state.join(DIRECTORY);
        for path in [&snapshots, &directory] {
            std::fs::DirBuilder::new()
                .recursive(true)
                .mode(0o700)
                .create(path)?;
        }
        if !private_directory(&directory) {
            return Err(io::Error::other(
                "Flash invocation store is not a private Runtime directory",
            ));
        }
        Ok(Self {
            directory,
            pages: SnapshotPager::open_serialized(&snapshots)?,
            serial: Mutex::new(()),
            active: Mutex::new(std::collections::BTreeSet::new()),
        })
    }

    /// `debug.status` and `recovery.flash-invocation.list` from the frame's
    /// parameters, checked as Swift's handler checks them once its owner is
    /// composed.
    pub fn handle(&self, method: &str, params: &Map<String, Value>) -> Result<Value, WireError> {
        let _serial = self
            .serial
            .lock()
            .map_err(|_| internal("Flash invocation owner is poisoned"))?;
        match method {
            "debug.status" => {
                let identity = match params.get("invocationId") {
                    Some(Value::String(identity)) if params.len() == 1 => identity,
                    _ => {
                        return Err(invalid_params("debug.status accepts exactly invocationId"));
                    }
                };
                let document = self.load(identity).map_err(ReadError::wire)?;
                Ok(status(identity, &document))
            }
            "recovery.flash-invocation.list" => {
                if params
                    .keys()
                    .any(|key| key != "pageSize" && key != "cursor")
                {
                    return Err(invalid_params(
                        "Flash invocation list accepts only pageSize and cursor",
                    ));
                }
                let page_size = match params.get("pageSize") {
                    None => 100,
                    Some(value) => match value.as_number().and_then(swift_integer) {
                        Some(size) if (1..=1_000).contains(&size) => size as usize,
                        _ => return Err(invalid_params("pageSize must be between 1 and 1000")),
                    },
                };
                let cursor = match params.get("cursor") {
                    None => None,
                    Some(Value::String(text)) if text.len() <= 256 => Some(text.as_str()),
                    Some(_) => {
                        return Err(control_failure(
                            "invalidCursor",
                            "cursor must be a bounded opaque string",
                        ));
                    }
                };
                self.list(page_size, cursor)
            }
            _ => Err(internal("not a Flash invocation read")),
        }
    }

    /// Swift `list(pageSize:cursor:)`: a fixed snapshot of every invocation's
    /// compact row, newest first, ties by identity. A refusal of the rows is
    /// the broker's own; the pager's are Swift's pager's, with empty details.
    fn list(&self, page_size: usize, cursor: Option<&str>) -> Result<Value, WireError> {
        let mut refused = None;
        let answer = self.pages.page(
            "recovery.flash-invocation.list",
            "createdAtDescInvocationIdAsc",
            page_size,
            cursor,
            || {
                self.rows()
                    .inspect_err(|error| refused = Some(error.clone()))
            },
        );
        answer.map_err(|error| match refused.take() {
            Some(error) => error,
            None if error.code == "invalidCursor" => control_failure(
                "invalidCursor",
                "cursor is invalid, belongs to another query or its snapshot was reclaimed",
            ),
            None => control_failure(&error.code, &error.message),
        })
    }

    fn rows(&self) -> Result<Vec<Value>, WireError> {
        if !private_directory(&self.directory) {
            return Err(ReadError::Persistence(
                "Flash invocation store is not a private Runtime directory",
            )
            .wire());
        }
        let names = std::fs::read_dir(&self.directory)
            .and_then(|entries| {
                entries
                    .map(|entry| entry.map(|entry| entry.file_name()))
                    .collect::<io::Result<Vec<_>>>()
            })
            .map_err(|error| internal(&error.to_string()))?;
        if names.len() > MAXIMUM_RECORDS {
            return Err(control_failure(
                "operationUnavailable",
                "Flash invocation inventory exceeds its resource bound",
            ));
        }
        let mut rows = Vec::with_capacity(names.len());
        for name in names {
            let Some(identity) = name.to_str().and_then(|name| name.strip_suffix(".json")) else {
                return Err(ReadError::Persistence(
                    "Flash invocation directory contains an unknown entry",
                )
                .wire());
            };
            if !valid_identity(identity) {
                return Err(ReadError::Persistence(
                    "Flash invocation directory contains an invalid identity",
                )
                .wire());
            }
            let document = self.load(identity).map_err(ReadError::wire)?;
            rows.push((
                document.created.clone(),
                identity.to_owned(),
                json!({
                    "schemaVersion": "arkdeck.recovery.flash-invocation-summary/1",
                    "invocationId": identity,
                    "state": document.state,
                    "operationReference": document.seed.reference(),
                    "targetId": document.seed.target_id,
                    "bindingRevision": document.seed.expected_binding_revision,
                    "createdAtUtc": document.created,
                    "expiresAtUtc": document.expires,
                    "destructiveEpochsUsed": document.epochs,
                    "maximumDestructiveEpochs": MAXIMUM_DESTRUCTIVE_EPOCHS,
                }),
            ));
        }
        rows.sort_by(|left, right| right.0.cmp(&left.0).then_with(|| left.1.cmp(&right.1)));
        Ok(rows.into_iter().map(|(_, _, row)| row).collect())
    }

    /// Swift `load(_:)`.
    fn load(&self, identity: &str) -> Result<Document, ReadError> {
        if !valid_identity(identity) {
            return Err(ReadError::NotFound(identity.to_owned()));
        }
        let bytes = self.read(identity)?;
        let document = decode(&bytes).ok_or_else(|| ReadError::NotFound(identity.to_owned()))?;
        let (schema, stored_identity) = document.1;
        let document = document.0;
        if schema != SCHEMA_VERSION
            || stored_identity != identity
            || !(0..=MAXIMUM_DESTRUCTIVE_EPOCHS).contains(&document.epochs)
        {
            return Err(ReadError::Persistence("invalid invocation document"));
        }
        Ok(document)
    }

    /// Swift `readInvocation(_:)`.
    fn read(&self, identity: &str) -> Result<Vec<u8>, ReadError> {
        if !private_directory(&self.directory) {
            return Err(ReadError::Persistence(
                "Flash invocation store is not a private Runtime directory",
            ));
        }
        // Swift `open(…, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)`: a link is
        // refused, not followed (the standard library sets `O_CLOEXEC`).
        let file = match std::fs::OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW)
            .open(self.directory.join(format!("{identity}.json")))
        {
            Ok(file) => file,
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                return Err(ReadError::NotFound(identity.to_owned()));
            }
            Err(_) => {
                return Err(ReadError::Persistence(
                    "Flash invocation document cannot be opened",
                ));
            }
        };
        let identity_or_size = || {
            ReadError::Persistence("Flash invocation document failed identity or size validation")
        };
        let metadata = file.metadata().map_err(|_| identity_or_size())?;
        if !metadata.is_file()
            || metadata.uid() != arkdeck_platform::effective_user_id()
            || metadata.mode() & 0o077 != 0
            || metadata.nlink() != 1
            || metadata.len() == 0
            || metadata.len() > MAXIMUM_DOCUMENT_BYTES
        {
            return Err(identity_or_size());
        }
        let mut bytes = Vec::with_capacity(metadata.len() as usize);
        (&file)
            .take(MAXIMUM_DOCUMENT_BYTES + 1)
            .read_to_end(&mut bytes)
            .map_err(|_| ReadError::Persistence("Flash invocation document read failed"))?;
        if bytes.len() as u64 > MAXIMUM_DOCUMENT_BYTES {
            return Err(ReadError::Persistence(
                "Flash invocation document exceeded its size bound",
            ));
        }
        if bytes.len() as u64 != metadata.len() {
            return Err(ReadError::Persistence(
                "Flash invocation document changed while it was read",
            ));
        }
        Ok(bytes)
    }
}

/// Swift `validInvocationID(_:)`: at most 128 bytes, a lowercase ASCII
/// letter, then ASCII letters, digits, dots and hyphens.
fn valid_identity(identity: &str) -> bool {
    let bytes = identity.as_bytes();
    bytes.len() <= 128
        && bytes.first().is_some_and(u8::is_ascii_lowercase)
        && bytes[1..]
            .iter()
            .all(|byte| byte.is_ascii_alphanumeric() || *byte == b'.' || *byte == b'-')
}

/// Swift `validateInvocationDirectory(_:)`: a directory reached through no
/// link, the effective user's, closed to group and others.
fn private_directory(directory: &Path) -> bool {
    std::fs::symlink_metadata(directory).is_ok_and(|metadata| {
        metadata.is_dir()
            && metadata.uid() == arkdeck_platform::effective_user_id()
            && metadata.mode() & 0o077 == 0
    })
}

/// Swift `RuntimeDebugInvocationStatus` of a document.
fn status(identity: &str, document: &Document) -> Value {
    let mut fields = Map::new();
    fields.insert("invocationID".into(), json!(identity));
    fields.insert("state".into(), json!(document.state));
    fields.insert(
        "operationReference".into(),
        json!(document.seed.reference()),
    );
    fields.insert("targetID".into(), json!(document.seed.target_id));
    if let Some(revision) = document.seed.expected_binding_revision {
        fields.insert("bindingRevision".into(), json!(revision));
    }
    fields.insert(
        "seedRequestFingerprintSHA256".into(),
        json!(document.fingerprint),
    );
    fields.insert(
        "baselineMaterializedPlanDigest".into(),
        json!(document.baseline),
    );
    fields.insert("createdAtUTC".into(), json!(document.created));
    fields.insert("expiresAtUTC".into(), json!(document.expires));
    fields.insert("destructiveEpochsUsed".into(), json!(document.epochs));
    fields.insert(
        "maximumDestructiveEpochs".into(),
        json!(MAXIMUM_DESTRUCTIVE_EPOCHS),
    );
    fields.insert(
        "evaluations".into(),
        Value::Array(document.evaluations.clone()),
    );
    Value::Object(fields)
}

/// Swift `CurrentDurableJSON.decode(RuntimeDebugInvocationDocument.self, …)`:
/// no duplicate member; every field decoded with its type; and the JSON
/// exactly what the typed document encodes back to, so an unknown member, an
/// explicit null or a value Swift reads another way is refused. The document
/// with its stored schema and identity, which `load` checks.
fn decode(bytes: &[u8]) -> Option<(Document, (String, String))> {
    strict_json::validate(bytes).ok()?;
    let supplied: Value = serde_json::from_slice(bytes).ok()?;
    let object = supplied.as_object()?;
    let seed_value = object.get("seedRequest")?;
    let seed = OperationRequest::decode(&serde_json::to_vec(seed_value).ok()?).ok()?;
    let evaluations = object
        .get("evaluations")?
        .as_array()?
        .iter()
        .map(evaluation)
        .collect::<Option<Vec<_>>>()?;
    let document = Document {
        state: text(object, "state")?,
        seed,
        fingerprint: text(object, "seedRequestFingerprintSHA256")?,
        baseline: text(object, "baselineMaterializedPlanDigest")?,
        created: text(object, "createdAtUTC")?,
        expires: text(object, "expiresAtUTC")?,
        epochs: integer(object, "destructiveEpochsUsed")?,
        evaluations,
    };
    let schema = text(object, "schemaVersion")?;
    let identity = text(object, "invocationID")?;
    let current = stored(&schema, &identity, &document);
    (swift_value(&supplied) == current).then_some((document, (schema, identity)))
}

/// Swift `RuntimeDebugInvocationDocument` as it encodes: the value a read
/// requires the stored JSON to be, and the one the broker writes.
fn stored(schema: &str, identity: &str, document: &Document) -> Value {
    json!({
        "schemaVersion": schema,
        "invocationID": identity,
        "state": document.state,
        "seedRequest": document.seed.canonical_value(),
        "seedRequestFingerprintSHA256": document.fingerprint,
        "baselineMaterializedPlanDigest": document.baseline,
        "createdAtUTC": document.created,
        "expiresAtUTC": document.expires,
        "destructiveEpochsUsed": document.epochs,
        "evaluations": document.evaluations,
    })
}

/// Swift `RuntimeDebugEvaluation`, re-encoded as Swift encodes it (a nil
/// optional omitted), with its `RuntimeDebugObservation`.
fn evaluation(value: &Value) -> Option<Value> {
    let object = value.as_object()?;
    let mut fields = Map::new();
    fields.insert("ordinal".into(), json!(integer(object, "ordinal")?));
    optional_integer(object, "destructiveEpoch", &mut fields)?;
    for key in [
        "candidateSourceSHA256",
        "candidateBuildSHA256",
        "candidateActionSHA256",
        "candidateAction",
    ] {
        fields.insert(key.into(), json!(text(object, key)?));
    }
    for key in ["requestID", "idempotencyKey", "jobID"] {
        optional_text(object, key, &mut fields)?;
    }
    match object.get("outcome") {
        None | Some(Value::Null) => {}
        Some(Value::String(outcome)) if OUTCOMES.contains(&outcome.as_str()) => {
            fields.insert("outcome".into(), json!(outcome));
        }
        Some(_) => return None,
    }
    for key in ["disposition", "detail", "evaluatedAtUTC"] {
        fields.insert(key.into(), json!(text(object, key)?));
    }
    match object.get("observation") {
        None | Some(Value::Null) => {}
        Some(observation) => {
            let observation = observation.as_object()?;
            let mut encoded = Map::new();
            for key in ["observationID", "materializedPlanDigest", "targetID"] {
                encoded.insert(key.into(), json!(text(observation, key)?));
            }
            optional_integer(observation, "bindingRevision", &mut encoded)?;
            optional_text(observation, "stableIdentitySHA256", &mut encoded)?;
            encoded.insert(
                "dispatchDisposition".into(),
                json!(text(observation, "dispatchDisposition")?),
            );
            fields.insert("observation".into(), Value::Object(encoded));
        }
    }
    Some(Value::Object(fields))
}

fn text(object: &Map<String, Value>, key: &str) -> Option<String> {
    object.get(key)?.as_str().map(str::to_owned)
}

fn integer(object: &Map<String, Value>, key: &str) -> Option<i64> {
    swift_integer(object.get(key)?.as_number()?)
}

/// A present optional member keeps its typed value; a missing or null one is
/// nil (and encodes as absent); a present one of another type fails.
fn optional_text(
    object: &Map<String, Value>,
    key: &str,
    into: &mut Map<String, Value>,
) -> Option<()> {
    match object.get(key) {
        None | Some(Value::Null) => Some(()),
        Some(Value::String(text)) => {
            into.insert(key.into(), json!(text));
            Some(())
        }
        Some(_) => None,
    }
}

fn optional_integer(
    object: &Map<String, Value>,
    key: &str,
    into: &mut Map<String, Value>,
) -> Option<()> {
    match object.get(key) {
        None | Some(Value::Null) => Some(()),
        Some(Value::Number(number)) => {
            into.insert(key.into(), json!(swift_integer(number)?));
            Some(())
        }
        Some(_) => None,
    }
}
