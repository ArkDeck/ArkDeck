//! Swift `RecoveryManifestContract.swift`: the `recovery` member of a Session
//! manifest, read and written as Swift's `RecoveryManifestCodec` does.
//!
//! This is the last carrier row of ADR-0009 decision 4 in the CHG-2026-074
//! decision package (`evidence/adr-0009-decision-package-20260914.md` §2),
//! which the maintainer ruled on 2026-09-19 is ported unchanged: a hazard's
//! certainty is `confirmed` or `outcomeUnknown` and nothing else, a `known`
//! device mode refuses to decode without its value and evidence, and every
//! level refuses a member it does not name.
//!
//! Decoding follows Swift's order, so a document with more than one fault is
//! refused for the same reason: the strict-JSON check, the record's exact
//! member set, every unexecuted compensation as the typed
//! `CompensationDescriptor` decodes it, their declared policies, then each
//! member in declaration order and the record's own invariants. Encoding is
//! `CanonicalJSONEncoders.canonical()` of the decoded record: sorted keys, no
//! whitespace, no escaped solidus, a compensation's hash in lowercase.
//!
//! Nothing in production writes a non-null recovery manifest, in Swift or
//! here: the Session composer seals `recovery: null` and refuses an unresolved
//! Job (`session_publication.rs`, Swift `RuntimeSessionPublication.swift`).
//! The Session manifest reader decodes the member with this codec and then
//! checks its relations to the Session's steps.
use crate::session_json;
use crate::session_step_arguments;
use crate::session_time::session_timestamp;
use crate::strict_json;
use crate::swift_decoding::swift_value;
use arkdeck_contract::sha256_hex;
use serde_json::{Map, Value, json};

type Object = Map<String, Value>;

/// Why Swift's `RecoveryManifestCodec.decode` refuses a document, by kind.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum RecoveryManifestError {
    /// `RecoveryManifestContractError.unknownOrMissingFields`: an object's
    /// member set is not exactly the one its type names.
    UnknownOrMissingFields,
    /// `RecoveryManifestContractError.invalidField(_)`, with Swift's field.
    InvalidField(&'static str),
    /// `StrictJSONError`: a member name repeated in one object, or bytes that
    /// are not one JSON document.
    StrictJson,
    /// `DecodingError`: a member of the wrong JSON type, a required key a
    /// non-strict container does not find, or a closed-vocabulary word that
    /// is not in it.
    Decoding,
    /// `WorkflowStepValidationError`, thrown by the typed compensation
    /// descriptor: an unexpected member, a kind that does not compensate, an
    /// identifier, digest or argument set its kind does not accept.
    Compensation,
}

impl RecoveryManifestError {
    /// The spelling of the shared oracle's `outcome`.
    pub fn outcome(&self) -> String {
        match self {
            Self::UnknownOrMissingFields => "unknownOrMissingFields".into(),
            Self::InvalidField(field) => format!("invalidField({field})"),
            Self::StrictJson => "strictJSON".into(),
            Self::Decoding => "decoding".into(),
            Self::Compensation => "compensation".into(),
        }
    }
}

type Result<T> = std::result::Result<T, RecoveryManifestError>;

/// Swift `RecoveryManifestHazard`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RecoveryManifestHazard {
    pub code: String,
    pub summary: String,
    pub severity: String,
    pub outcome_certainty: String,
}

/// Swift `RecoveryManifestDeviceMode`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum RecoveryManifestDeviceMode {
    Unknown,
    Known { value: String, evidence: String },
}

/// Swift `RecoveryManifestGuide`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RecoveryManifestGuide {
    pub provider_identity: String,
    pub automatic_recovery_available: bool,
    pub summary: String,
    pub steps: Vec<String>,
}

/// Swift `RecoveryManifestAbandonConfirmation`: the user, and only the user,
/// archived the interrupted Session.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RecoveryManifestAbandonConfirmation {
    pub confirmation_id: String,
    pub confirmed_at: String,
}

/// Swift `RecoveryManifestRecord`. A compensation is held as the object the
/// typed descriptor encodes: its declared policy is the kind's normalised
/// one (the decoder refuses an understated one) and its hash is lowercase.
#[derive(Clone, Debug, PartialEq)]
pub struct RecoveryManifest {
    pub needs_attention: bool,
    pub interrupted_reason: Option<String>,
    pub device_hazards: Vec<RecoveryManifestHazard>,
    pub abandon_audit_event_ids: Vec<String>,
    pub last_confirmed_step_id: Option<String>,
    pub last_device_mode: RecoveryManifestDeviceMode,
    pub managed_host_process_state: String,
    pub recovery_guide: RecoveryManifestGuide,
    pub unexecuted_compensations: Vec<Object>,
    pub user_confirmation: Option<RecoveryManifestAbandonConfirmation>,
    pub recovery_of_session_id: Option<String>,
    pub recovery_of_job_id: Option<String>,
}

const RECORD_KEYS: [&str; 12] = [
    "needsAttention",
    "interruptedReason",
    "deviceHazards",
    "abandonAuditEventIds",
    "lastConfirmedStepId",
    "lastDeviceMode",
    "managedHostProcessState",
    "recoveryGuide",
    "unexecutedCompensations",
    "userConfirmation",
    "recoveryOfSessionId",
    "recoveryOfJobId",
];
const HAZARD_KEYS: [&str; 4] = ["code", "summary", "severity", "outcomeCertainty"];
const GUIDE_KEYS: [&str; 4] = [
    "providerIdentity",
    "automaticRecoveryAvailable",
    "summary",
    "steps",
];
const CONFIRMATION_KEYS: [&str; 4] = ["confirmationId", "actor", "decision", "confirmedAt"];
const DESCRIPTOR_KEYS: [&str; 8] = [
    "id",
    "kind",
    "effect",
    "cancellation",
    "bindingRequirement",
    "trigger",
    "arguments",
    "argumentsHash",
];
const PROCESS_STATES: [&str; 5] = [
    "notStarted",
    "notRunning",
    "stoppedAtSafeBoundary",
    "stillRunningUnknown",
    "notApplicable",
];

/// Swift `WorkflowStepKind`: a raw kind outside it is refused by
/// `WorkflowStepValidator.resolveKind` before any other member is read.
const STEP_KINDS: [&str; 43] = [
    "probeHostTool",
    "probeHDCServer",
    "mutateHDCServerLifecycle",
    "probeDevice",
    "captureRemoteStdout",
    "captureRemoteFile",
    "stopRemoteCapture",
    "sendFile",
    "receiveFile",
    "snapshotParameter",
    "setParameter",
    "restoreParameter",
    "waitForDisconnect",
    "waitForReconnect",
    "verifyRemoteState",
    "verifyArtifact",
    "preflightHostStorage",
    "preflightDeviceStorage",
    "hashFile",
    "postprocessArtifact",
    "cleanupOwnedRemotePath",
    "requestConfirmation",
    "installPackage",
    "uninstallPackage",
    "startApplication",
    "stopApplication",
    "createPortForward",
    "removePortForward",
    "injectPointerInput",
    "clearLogBuffer",
    "resizeLogBuffer",
    "startDeviceLogPersist",
    "runApprovedRemoteRead",
    "runApprovedRemoteMutation",
    "rebootDevice",
    "enterUpdater",
    "flashPartition",
    "updatePackage",
    "erasePartition",
    "formatPartition",
    "unlockDevice",
    "finalizeSession",
    "inspectWorkspaceSource",
];
/// Swift `CompensationDescriptor.allowedKinds`.
const COMPENSATING_KINDS: [&str; 6] = [
    "stopRemoteCapture",
    "restoreParameter",
    "cleanupOwnedRemotePath",
    "removePortForward",
    "stopApplication",
    "uninstallPackage",
];
const EFFECTS: [&str; 4] = ["hostOnly", "readOnly", "deviceMutation", "destructive"];
const CANCELLATIONS: [&str; 3] = ["immediate", "atSafeBoundary", "criticalNonInterruptible"];
const BINDINGS: [&str; 2] = ["none", "confirmedDevice"];
const TRIGGERS: [&str; 4] = ["onSuccess", "onFailure", "onCancel", "onAnyTerminal"];

/// Swift `matchesManifestID`: `^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$`.
fn manifest_id(value: &str) -> bool {
    (1..=128).contains(&value.len())
        && value.as_bytes()[0].is_ascii_alphanumeric()
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || b"._:-".contains(&byte))
}

/// Swift `WorkflowStepValidator.isValidSHA256`: 64 hexadecimal digits in
/// either case.
fn sha256_digits(value: &str) -> bool {
    value.len() == 64 && value.bytes().all(|byte| byte.is_ascii_hexdigit())
}

/// Swift's `strictContainer`: the object's member names are exactly `keys`.
fn strict<'a>(value: &'a Value, keys: &[&str]) -> Result<&'a Object> {
    let object = value.as_object().ok_or(RecoveryManifestError::Decoding)?;
    if object.len() != keys.len() || !keys.iter().all(|key| object.contains_key(*key)) {
        return Err(RecoveryManifestError::UnknownOrMissingFields);
    }
    Ok(object)
}

fn string(object: &Object, key: &str) -> Result<String> {
    object
        .get(key)
        .and_then(Value::as_str)
        .map(str::to_owned)
        .ok_or(RecoveryManifestError::Decoding)
}

fn optional_string(object: &Object, key: &str) -> Result<Option<String>> {
    match object.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(text)) => Ok(Some(text.clone())),
        Some(_) => Err(RecoveryManifestError::Decoding),
    }
}

fn boolean(object: &Object, key: &str) -> Result<bool> {
    object
        .get(key)
        .and_then(Value::as_bool)
        .ok_or(RecoveryManifestError::Decoding)
}

fn strings(object: &Object, key: &str) -> Result<Vec<String>> {
    object
        .get(key)
        .and_then(Value::as_array)
        .ok_or(RecoveryManifestError::Decoding)?
        .iter()
        .map(|item| {
            item.as_str()
                .map(str::to_owned)
                .ok_or(RecoveryManifestError::Decoding)
        })
        .collect()
}

fn array<'a>(object: &'a Object, key: &str) -> Result<&'a Vec<Value>> {
    object
        .get(key)
        .and_then(Value::as_array)
        .ok_or(RecoveryManifestError::Decoding)
}

/// A closed-vocabulary word as a Swift `RawRepresentable` enum decodes it:
/// its rank in `words`, or a `DecodingError`.
fn word(object: &Object, key: &str, words: &[&str]) -> Result<usize> {
    let raw = string(object, key)?;
    words
        .iter()
        .position(|candidate| *candidate == raw)
        .ok_or(RecoveryManifestError::Decoding)
}

/// Swift `CompensationDescriptor.init(from:)`: the typed descriptor, its
/// policy raised to its kind's minimum and its hash lowercased. Returns the
/// descriptor as it encodes, with the normalised policy.
fn compensation(value: &Value) -> Result<Object> {
    use RecoveryManifestError::{Compensation, Decoding};
    let row = value.as_object().ok_or(Decoding)?;
    if row
        .keys()
        .any(|key| !DESCRIPTOR_KEYS.contains(&key.as_str()))
    {
        return Err(Compensation);
    }
    let kind = string(row, "kind")?;
    if !STEP_KINDS.contains(&kind.as_str()) {
        return Err(Compensation);
    }
    let id = string(row, "id")?;
    let effect = word(row, "effect", &EFFECTS)?;
    let cancellation = word(row, "cancellation", &CANCELLATIONS)?;
    let binding = word(row, "bindingRequirement", &BINDINGS)?;
    word(row, "trigger", &TRIGGERS)?;
    let arguments = row
        .get("arguments")
        .and_then(Value::as_object)
        .ok_or(Decoding)?;
    let hash = string(row, "argumentsHash")?;
    if !COMPENSATING_KINDS.contains(&kind.as_str()) || !manifest_id(&id) || !sha256_digits(&hash) {
        return Err(Compensation);
    }
    let minimum = session_step_arguments::validate(&kind, arguments).map_err(|_| Compensation)?;
    let mut normalised = row.clone();
    normalised.insert("effect".into(), EFFECTS[effect.max(minimum.effect)].into());
    normalised.insert(
        "cancellation".into(),
        CANCELLATIONS[cancellation.max(minimum.cancellation)].into(),
    );
    normalised.insert(
        "bindingRequirement".into(),
        BINDINGS[binding.max(minimum.binding)].into(),
    );
    normalised.insert(
        "arguments".into(),
        Value::Object(
            arguments
                .iter()
                .map(|(key, value)| (key.clone(), swift_value(value)))
                .collect(),
        ),
    );
    normalised.insert("argumentsHash".into(), hash.to_ascii_lowercase().into());
    Ok(normalised)
}

fn hazard(value: &Value) -> Result<RecoveryManifestHazard> {
    let row = strict(value, &HAZARD_KEYS)?;
    let hazard = RecoveryManifestHazard {
        code: string(row, "code")?,
        summary: string(row, "summary")?,
        severity: string(row, "severity")?,
        outcome_certainty: string(row, "outcomeCertainty")?,
    };
    if !manifest_id(&hazard.code)
        || hazard.summary.is_empty()
        || !["warning", "blocking", "possibleBrick"].contains(&hazard.severity.as_str())
        || !["confirmed", "outcomeUnknown"].contains(&hazard.outcome_certainty.as_str())
    {
        return Err(RecoveryManifestError::InvalidField("hazard"));
    }
    Ok(hazard)
}

fn device_mode(value: &Value) -> Result<RecoveryManifestDeviceMode> {
    let row = value.as_object().ok_or(RecoveryManifestError::Decoding)?;
    match string(row, "state")?.as_str() {
        "unknown" => {
            if row.len() != 1 {
                return Err(RecoveryManifestError::UnknownOrMissingFields);
            }
            Ok(RecoveryManifestDeviceMode::Unknown)
        }
        "known" => {
            let text = |key: &str| {
                row.get(key)
                    .and_then(Value::as_str)
                    .filter(|s| !s.is_empty())
            };
            match (row.len() == 3, text("value"), text("evidence")) {
                (true, Some(value), Some(evidence)) => Ok(RecoveryManifestDeviceMode::Known {
                    value: value.to_owned(),
                    evidence: evidence.to_owned(),
                }),
                _ => Err(RecoveryManifestError::InvalidField("lastDeviceMode")),
            }
        }
        _ => Err(RecoveryManifestError::InvalidField("lastDeviceMode.state")),
    }
}

fn guide(value: &Value) -> Result<RecoveryManifestGuide> {
    let row = strict(value, &GUIDE_KEYS)?;
    let guide = RecoveryManifestGuide {
        provider_identity: string(row, "providerIdentity")?,
        automatic_recovery_available: boolean(row, "automaticRecoveryAvailable")?,
        summary: string(row, "summary")?,
        steps: strings(row, "steps")?,
    };
    if guide.provider_identity.is_empty()
        || guide.summary.is_empty()
        || guide.steps.is_empty()
        || guide.steps.iter().any(String::is_empty)
    {
        return Err(RecoveryManifestError::InvalidField("recoveryGuide"));
    }
    Ok(guide)
}

fn confirmation(value: &Value) -> Result<Option<RecoveryManifestAbandonConfirmation>> {
    if value.is_null() {
        return Ok(None);
    }
    let row = strict(value, &CONFIRMATION_KEYS)?;
    let actor = string(row, "actor")?;
    let decision = string(row, "decision")?;
    if actor != "user" || decision != "archiveInterrupted" {
        return Err(RecoveryManifestError::InvalidField("userConfirmation"));
    }
    let confirmation = RecoveryManifestAbandonConfirmation {
        confirmation_id: string(row, "confirmationId")?,
        confirmed_at: string(row, "confirmedAt")?,
    };
    if !manifest_id(&confirmation.confirmation_id)
        || session_timestamp(&confirmation.confirmed_at).is_none()
    {
        return Err(RecoveryManifestError::InvalidField("userConfirmation"));
    }
    Ok(Some(confirmation))
}

impl RecoveryManifest {
    /// Swift `RecoveryManifestCodec.decode`: the strict-JSON check, then the
    /// typed record.
    pub fn decode(bytes: &[u8]) -> Result<Self> {
        strict_json::validate(bytes).map_err(|_| RecoveryManifestError::StrictJson)?;
        let value: Value =
            serde_json::from_slice(bytes).map_err(|_| RecoveryManifestError::Decoding)?;
        Self::from_value(&value)
    }

    /// The typed record of an already parsed member, as Swift's Session
    /// validation decodes the canonical bytes of the member it holds.
    pub fn from_value(value: &Value) -> Result<Self> {
        let row = strict(value, &RECORD_KEYS)?;
        let compensations = array(row, "unexecutedCompensations")?
            .iter()
            .map(compensation)
            .collect::<Result<Vec<_>>>()?;
        for (raw, typed) in array(row, "unexecutedCompensations")?
            .iter()
            .zip(&compensations)
        {
            let declared = |key: &str| raw.get(key) == typed.get(key);
            if !declared("effect") || !declared("cancellation") || !declared("bindingRequirement") {
                return Err(RecoveryManifestError::InvalidField(
                    "unexecutedCompensations.policy",
                ));
            }
        }
        let record = Self {
            needs_attention: boolean(row, "needsAttention")?,
            interrupted_reason: optional_string(row, "interruptedReason")?,
            device_hazards: array(row, "deviceHazards")?
                .iter()
                .map(hazard)
                .collect::<Result<_>>()?,
            abandon_audit_event_ids: strings(row, "abandonAuditEventIds")?,
            last_confirmed_step_id: optional_string(row, "lastConfirmedStepId")?,
            last_device_mode: device_mode(&row["lastDeviceMode"])?,
            managed_host_process_state: string(row, "managedHostProcessState")?,
            recovery_guide: guide(&row["recoveryGuide"])?,
            unexecuted_compensations: compensations,
            user_confirmation: confirmation(&row["userConfirmation"])?,
            recovery_of_session_id: optional_string(row, "recoveryOfSessionId")?,
            recovery_of_job_id: optional_string(row, "recoveryOfJobId")?,
        };
        let ids = &record.abandon_audit_event_ids;
        let unique = ids.iter().collect::<std::collections::BTreeSet<_>>().len() == ids.len();
        let optional_id = |id: &Option<String>| id.as_deref().is_none_or(manifest_id);
        if record.interrupted_reason.as_deref() == Some("")
            || !unique
            || !ids.iter().all(|id| manifest_id(id))
            || !optional_id(&record.last_confirmed_step_id)
            || !PROCESS_STATES.contains(&record.managed_host_process_state.as_str())
            || !optional_id(&record.recovery_of_session_id)
            || !optional_id(&record.recovery_of_job_id)
            || (!ids.is_empty() && record.user_confirmation.is_none())
        {
            return Err(RecoveryManifestError::InvalidField("recovery"));
        }
        Ok(record)
    }

    /// The record as Swift's synthesized encoders spell it.
    pub fn to_value(&self) -> Value {
        let optional = |text: &Option<String>| text.clone().map_or(Value::Null, Value::String);
        json!({
            "needsAttention": self.needs_attention,
            "interruptedReason": optional(&self.interrupted_reason),
            "deviceHazards": self.device_hazards.iter().map(|hazard| json!({
                "code": hazard.code,
                "summary": hazard.summary,
                "severity": hazard.severity,
                "outcomeCertainty": hazard.outcome_certainty,
            })).collect::<Vec<_>>(),
            "abandonAuditEventIds": self.abandon_audit_event_ids,
            "lastConfirmedStepId": optional(&self.last_confirmed_step_id),
            "lastDeviceMode": match &self.last_device_mode {
                RecoveryManifestDeviceMode::Unknown => json!({"state": "unknown"}),
                RecoveryManifestDeviceMode::Known { value, evidence } => {
                    json!({"state": "known", "value": value, "evidence": evidence})
                }
            },
            "managedHostProcessState": self.managed_host_process_state,
            "recoveryGuide": {
                "providerIdentity": self.recovery_guide.provider_identity,
                "automaticRecoveryAvailable": self.recovery_guide.automatic_recovery_available,
                "summary": self.recovery_guide.summary,
                "steps": self.recovery_guide.steps,
            },
            "unexecutedCompensations": self.unexecuted_compensations,
            "userConfirmation": self.user_confirmation.as_ref().map_or(Value::Null, |confirmation| {
                json!({
                    "confirmationId": confirmation.confirmation_id,
                    "actor": "user",
                    "decision": "archiveInterrupted",
                    "confirmedAt": confirmation.confirmed_at,
                })
            }),
            "recoveryOfSessionId": optional(&self.recovery_of_session_id),
            "recoveryOfJobId": optional(&self.recovery_of_job_id),
        })
    }

    /// Swift `RecoveryManifestCodec.encode`: `CanonicalJSONEncoders.canonical()`.
    pub fn encode(&self) -> Vec<u8> {
        session_json::encode(&self.to_value())
            .expect("a decoded recovery manifest holds only encodable numbers")
    }
}

/// Swift Session validation's `validateCompensationDescriptorHash`: the hash
/// a compensation declares is the SHA-256 of its arguments' canonical bytes.
pub(crate) fn compensation_hash_matches(descriptor: &Object) -> bool {
    let (Some(Value::Object(arguments)), Some(Value::String(hash))) =
        (descriptor.get("arguments"), descriptor.get("argumentsHash"))
    else {
        return false;
    };
    session_json::encode(&Value::Object(arguments.clone()))
        .is_ok_and(|bytes| hash.to_ascii_lowercase() == sha256_hex(&bytes))
}

#[cfg(test)]
mod tests {
    //! Replays the shared recovery-manifest oracle (`rust/tests/fixtures/
    //! recovery-manifest`, recorded by Swift `RecoveryManifestOracleContractTests`).
    use super::*;
    use std::path::{Path, PathBuf};

    fn fixtures() -> PathBuf {
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/fixtures")
    }

    fn read(path: &str) -> Vec<u8> {
        std::fs::read(fixtures().join("recovery-manifest").join(path)).unwrap()
    }

    fn cases() -> Vec<Value> {
        let cases: Value = serde_json::from_slice(&read("cases.json")).unwrap();
        cases.as_array().unwrap().clone()
    }

    fn case(name: &str) -> Value {
        cases()
            .into_iter()
            .find(|case| case["name"] == name)
            .unwrap_or_else(|| panic!("no oracle case {name}"))
    }

    fn document(name: &str) -> Vec<u8> {
        read(case(name)["document"].as_str().unwrap())
    }

    fn canonical(name: &str) -> Vec<u8> {
        read(case(name)["canonical"].as_str().unwrap())
    }

    #[test]
    fn every_swift_decision_and_canonical_encoding_is_reproduced() {
        let cases = cases();
        assert!(cases.len() >= 69, "{} cases", cases.len());
        for case in &cases {
            let name = case["name"].as_str().unwrap();
            let outcome = case["outcome"].as_str().unwrap();
            match RecoveryManifest::decode(&read(case["document"].as_str().unwrap())) {
                Ok(record) => {
                    assert_eq!(outcome, "accepted", "{name}");
                    let canonical = canonical(name);
                    assert_eq!(record.encode(), canonical, "{name}");
                    let again = RecoveryManifest::decode(&canonical).unwrap();
                    assert_eq!(again, record, "{name}");
                    assert_eq!(again.encode(), canonical, "{name}");
                }
                Err(error) => assert_eq!(error.outcome(), outcome, "{name}"),
            }
        }
    }

    /// The writer, not only the re-encoder: a record built field by field
    /// encodes as the bytes Swift wrote for the same record.
    #[test]
    fn a_record_rust_builds_encodes_as_swift_encodes_it() {
        let record = RecoveryManifest {
            needs_attention: true,
            interrupted_reason: Some("fixture interruption".into()),
            device_hazards: vec![RecoveryManifestHazard {
                code: "fixture.hazard".into(),
                summary: "fixture hazard".into(),
                severity: "possibleBrick".into(),
                outcome_certainty: "outcomeUnknown".into(),
            }],
            abandon_audit_event_ids: vec!["event-abandon".into()],
            last_confirmed_step_id: Some("step-probe".into()),
            last_device_mode: RecoveryManifestDeviceMode::Known {
                value: "loader".into(),
                evidence: "fixture observation".into(),
            },
            managed_host_process_state: "notRunning".into(),
            recovery_guide: RecoveryManifestGuide {
                provider_identity: "fixture-provider".into(),
                automatic_recovery_available: false,
                summary: "fixture recovery".into(),
                steps: vec!["fixture guidance".into()],
            },
            unexecuted_compensations: vec![],
            user_confirmation: Some(RecoveryManifestAbandonConfirmation {
                confirmation_id: "confirmation-abandon".into(),
                confirmed_at: "2026-01-01T00:00:00Z".into(),
            }),
            recovery_of_session_id: None,
            recovery_of_job_id: None,
        };
        assert_eq!(record.encode(), canonical("base"));
        assert_eq!(
            RecoveryManifest::decode(&canonical("base")).unwrap(),
            record
        );
    }

    /// Rust writes an accepted record with one member more, or one fewer, at
    /// each level. The bytes are exactly the document Swift refused, and Rust
    /// refuses them for Swift's reason.
    #[test]
    fn a_member_more_or_less_written_by_rust_is_the_document_swift_refused() {
        let base = RecoveryManifest::decode(&document("base")).unwrap();
        let unknown_mode = RecoveryManifest {
            last_device_mode: RecoveryManifestDeviceMode::Unknown,
            ..base.clone()
        }
        .to_value();
        let compensated = RecoveryManifest::decode(&document("compensation"))
            .unwrap()
            .to_value();
        let base = base.to_value();
        type Edit = fn(&mut Value);
        let edits: [(&str, &Value, Edit); 10] = [
            ("extra-member", &base, |v| v["extra"] = true.into()),
            ("missing-member", &base, |v| {
                v.as_object_mut().unwrap().remove("recoveryOfJobId");
            }),
            ("hazard-extra-member", &base, |v| {
                v["deviceHazards"][0]["extra"] = true.into();
            }),
            ("hazard-missing-member", &base, |v| {
                v["deviceHazards"][0]
                    .as_object_mut()
                    .unwrap()
                    .remove("summary");
            }),
            ("mode-unknown-extra-member", &unknown_mode, |v| {
                v["lastDeviceMode"]["value"] = "loader".into();
            }),
            ("mode-known-extra-member", &base, |v| {
                v["lastDeviceMode"]["extra"] = true.into();
            }),
            ("guide-extra-member", &base, |v| {
                v["recoveryGuide"]["extra"] = true.into();
            }),
            ("confirmation-extra-member", &base, |v| {
                v["userConfirmation"]["extra"] = true.into();
            }),
            ("confirmation-missing-member", &base, |v| {
                v["userConfirmation"]
                    .as_object_mut()
                    .unwrap()
                    .remove("actor");
            }),
            ("compensation-extra-member", &compensated, |v| {
                v["unexecutedCompensations"][0]["extra"] = true.into();
            }),
        ];
        for (name, start, edit) in edits {
            let mut value = start.clone();
            edit(&mut value);
            let written = session_json::encode(&value).unwrap();
            assert_eq!(written, document(name), "{name}");
            let refusal = RecoveryManifest::decode(&written).unwrap_err();
            assert_eq!(refusal.outcome(), case(name)["outcome"], "{name}");
        }
    }

    /// A Session manifest Swift sealed (`failed`, with steps), with a recovery
    /// member set: the Session reader reads it through this codec and then
    /// checks the member's relations to the Session's steps.
    #[test]
    fn the_session_reader_reads_the_member_through_the_codec() {
        let mut found = Vec::new();
        let mut pending = vec![fixtures()];
        while let Some(directory) = pending.pop() {
            for entry in std::fs::read_dir(&directory).unwrap() {
                let path = entry.unwrap().path();
                if path.is_dir() {
                    pending.push(path);
                } else if path.file_name().is_some_and(|name| name == "manifest.json") {
                    found.push(path);
                }
            }
        }
        found.sort();
        let (session, step) = found
            .iter()
            .find_map(|path| {
                let session: Value = serde_json::from_slice(&std::fs::read(path).ok()?).ok()?;
                let step = session["steps"][0]["id"].as_str()?.to_owned();
                (session["status"] == "failed" && session["recovery"].is_null())
                    .then_some((session, step))
            })
            .expect("an oracle holds a failed Session with steps");
        let read = |recovery: Value| {
            let mut manifest = session.clone();
            manifest["recovery"] = recovery;
            crate::session_manifest::decode_manifest(&session_json::encode(&manifest).unwrap())
        };
        let member = |name: &str| {
            let mut member: Value = serde_json::from_slice(&document(name)).unwrap();
            member["lastConfirmedStepId"] = step.as_str().into();
            member
        };
        assert!(read(Value::Null).is_ok());
        assert!(read(member("base")).is_ok());
        assert!(read(member("minimal")).is_ok());
        // `step-probe` is no step of this Session.
        let base: Value = serde_json::from_slice(&document("base")).unwrap();
        assert!(read(base).is_err());
        for refused in [
            "extra-member",
            "hazard-certainty-mixed",
            "mode-known-empty-evidence",
            "confirmation-actor-agent",
            "audit-without-confirmation",
        ] {
            assert!(read(member(refused)).is_err(), "{refused}");
        }
    }
}
