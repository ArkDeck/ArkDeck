//! Swift `RuntimeAgentExecutionCoordinator` and `RuntimeAgentExecutionStore`
//! for typed executions (CHG-2026-074, TASK-XPA-014): the
//! intent a caller declares, the record the owner keeps for it under
//! `agent-executions`, the orchestration that resolves the target, prepares
//! the exact Job request, submits it and owns the Job, and the answer the
//! daemon projects over the owned Job. The Job's run is the caller's, started
//! once the execution owns it and reported back when it ends. The owner also
//! lists its executions through the snapshot pager it keeps beside them, and
//! abandons one that owns no Job, which never cancels a Job. An execution
//! that waits for a person is read, listed, run again and abandoned as
//! Swift's owner does: its physical-assistance actions typed and checked as
//! Swift checks them, the waiting one projected with its resume reference,
//! and expired once the execution is abandoned or its budget runs out. An
//! execution without a target observes the devices through the Target
//! observation owner and, when a person must act, raises the action Swift's
//! owner raises; the combined human-action owner lists and shows those
//! actions. Physical resume follows fresh exact observations and guarded
//! adoption, preserving the original intent, deadline and unique Job identity.

use crate::format_time::{precise_utc_millis, utc_precise_from_millis};
use crate::job_record::terminal;
use crate::operation_catalog::{CatalogOperation, InputRefusal};
use crate::session_json;
use crate::snapshot_pager::{SnapshotPager, uuid};
use crate::target_observation::{
    Observation, ObservationError, Snapshot, Sources, TargetObservations,
};
use crate::{
    AdmissionRefusal, AdmissionVerdict, JobAdmitter, JobResultReader, JobStore, OperationRequest,
    TargetStore,
};
use arkdeck_contract::{CATALOG_DIGEST, WireError, canonical_json, sha256_hex, strict_json};
use arkdeck_platform::HostDirectory;
use serde_json::{Map, Value, json};
use std::collections::{BTreeSet, HashMap};
use std::io;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{Duration, Instant};
use unicode_segmentation::UnicodeSegmentation;

const RECORD_SCHEMA: &str = "arkdeck.runtime-agent-execution/1";
const INTENT_SCHEMA: &str = "arkdeck.agent-execution-request/1";
const PROJECTION_SCHEMA: &str = "arkdeck.agent-execution/1";
const MAX_RECORD: usize = 16 * 1024 * 1024;
const MAX_RECORDS: usize = 4096;
const MAX_STORE: u64 = 64 * 1024 * 1024;
const MAX_INTENT: usize = 3_145_728;
const MAX_BUDGET: i64 = 86_400_000;
const OUTPUTS: [&str; 4] = [
    "rawArtifacts",
    "derivedArtifacts",
    "analysisReport",
    "hardwareEvidence",
];
const INTENT_KEYS: [&str; 12] = [
    "schemaVersion",
    "executionId",
    "operation",
    "inputs",
    "target",
    "capabilityReference",
    "maximumWaitMilliseconds",
    "reviewedPlanDigest",
    "requestId",
    "idempotencyKey",
    "requestedOutputs",
    "clientContext",
];
const RECORD_KEYS: [&str; 16] = [
    "schemaVersion",
    "intent",
    "intentFingerprintSHA256",
    "catalogDigest",
    "createdAt",
    "deadline",
    "lastObservedAt",
    "generation",
    "state",
    "target",
    "submissionRequest",
    "jobID",
    "jobState",
    "outcomeUnknown",
    "failureCode",
    "actions",
];
const STATES: [&str; 9] = [
    "orchestrating",
    "waitingForHuman",
    "creatingJob",
    "jobOwned",
    "completed",
    "failed",
    "abandoned",
    "budgetExpired",
    "clockUntrusted",
];
const TERMINAL: [&str; 5] = [
    "completed",
    "failed",
    "abandoned",
    "budgetExpired",
    "clockUntrusted",
];
/// The owner refusals Swift's daemon answers with the zero-dispatch proof.
const PROVEN: [&str; 13] = [
    "invalidInput",
    "inputTooLarge",
    "invalidCursor",
    "idempotencyConflict",
    "reviewedPlanMismatch",
    "resourceConflict",
    "resourceNotFound",
    "operationUnavailable",
    "humanActionExpired",
    "orchestrationBudgetExpired",
    "orchestrationClockUntrusted",
    "bindingRevisionStale",
    "admissionDenied",
];
const ADVANCE: &str = "execution could not be advanced; inspect the exact owner";
pub(crate) const UNREADABLE: &str =
    "execution resource could not be read or advanced; inspect the exact owner";

/// Swift `AgentExecutionControlFailure` as the daemon answers it: a named
/// owner refusal carries the zero-dispatch proof, any other its own details.
fn failure_with(
    code: &str,
    message: impl Into<String>,
    mut details: Map<String, Value>,
) -> WireError {
    if PROVEN.contains(&code) {
        details.insert("phase".into(), json!("preAdmission"));
        details.insert("newDispatchCount".into(), json!(0));
    }
    WireError {
        code: code.into(),
        message: message.into(),
        details: Some(details),
    }
}

pub(crate) fn failure(code: &str, message: impl Into<String>) -> WireError {
    failure_with(code, message, Map::new())
}

/// A failure the daemon reports without any owner proof.
pub(crate) fn internal(message: &str) -> WireError {
    WireError {
        code: "internalError".into(),
        message: message.into(),
        details: None,
    }
}

/// Swift `agentExecutionRequest`'s answer to an observation that failed:
/// the reading's own reason or, for the observation owner's refusal, that
/// the execution could not be advanced.
fn observation_failure(error: ObservationError) -> WireError {
    match error {
        ObservationError::Refused { .. } => internal(UNREADABLE),
        ObservationError::Failed(reason) => internal(&reason),
    }
}

/// Swift `AgentObservedCandidate`: one observation of a snapshot, exactly.
fn observed(row: &Observation, snapshot: &Snapshot) -> Observed {
    Observed {
        candidate: row.candidate.connect_key.clone(),
        id: row.observation_id.clone(),
        generation: snapshot.generation,
    }
}

/// A fresh identity of `kind` (`har`, `resume` or `candidate`): the kind
/// and a lowercase version-4 UUID, as Swift mints one.
fn minted(kind: &str) -> Result<String, WireError> {
    uuid()
        .map(|uuid| format!("{kind}-{uuid}"))
        .map_err(|_| internal(UNREADABLE))
}

fn execution_detail(id: &str) -> Map<String, Value> {
    Map::from_iter([("executionId".into(), json!(id))])
}

/// Swift `agentExecutionRequest`'s `exact`: the request names exactly these
/// fields.
fn exact(params: &Map<String, Value>, keys: &[&str]) -> Result<(), WireError> {
    if params.len() != keys.len() || !keys.iter().all(|key| params.contains_key(*key)) {
        return Err(failure(
            "invalidInput",
            "request fields do not match the closed method contract",
        ));
    }
    Ok(())
}

/// Swift `agentExecutionRequest`'s `string`: a field that is a bounded
/// resource identity.
fn identity<'a>(params: &'a Map<String, Value>, key: &str) -> Result<&'a str, WireError> {
    params
        .get(key)
        .and_then(Value::as_str)
        .filter(|value| valid_identifier(value))
        .ok_or_else(|| {
            failure(
                "invalidInput",
                format!("{key} must be a bounded resource identity"),
            )
        })
}

/// Swift `AgentExecutionIntent.validIdentifier`.
pub(crate) fn valid_identifier(value: &str) -> bool {
    (1..=128).contains(&value.len())
        && value.as_bytes()[0].is_ascii_alphanumeric()
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || b"-._".contains(&byte))
}

fn digest(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

fn thread_identity(value: &str) -> bool {
    (1..=64).contains(&value.len())
        && value.as_bytes()[0].is_ascii_alphanumeric()
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || b"._-".contains(&byte))
}

/// The exact Catalog entry a reference names: `id@version`, or an
/// unversioned id.
fn descriptor(reference: &str) -> Option<&'static CatalogOperation> {
    match reference.rsplit_once('@') {
        Some((id, version)) => {
            let version = version
                .parse::<i64>()
                .ok()
                .filter(|number| number.to_string() == version)?;
            CatalogOperation::lookup(id, Some(version))
        }
        None => CatalogOperation::lookup(reference, None),
    }
}

const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

/// Foundation's default `Data` encoding: standard base64 with padding.
fn base64(bytes: &[u8]) -> String {
    let mut text = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let word = (u32::from(chunk[0]) << 16)
            | (u32::from(*chunk.get(1).unwrap_or(&0)) << 8)
            | u32::from(*chunk.get(2).unwrap_or(&0));
        for index in 0..4 {
            if index <= chunk.len() {
                text.push(ALPHABET[(word >> (18 - 6 * index)) as usize & 63] as char);
            } else {
                text.push('=');
            }
        }
    }
    text
}

fn unbase64(text: &str) -> Option<Vec<u8>> {
    let bytes = text.as_bytes();
    if !bytes.len().is_multiple_of(4) {
        return None;
    }
    let mut out = Vec::with_capacity(bytes.len() / 4 * 3);
    for (position, chunk) in bytes.chunks(4).enumerate() {
        let last = position + 1 == bytes.len() / 4;
        let padding = chunk.iter().rev().take_while(|byte| **byte == b'=').count();
        if padding > 2 || (padding > 0 && !last) {
            return None;
        }
        let mut word = 0u32;
        for (index, byte) in chunk.iter().enumerate() {
            let value = if index >= 4 - padding {
                0
            } else {
                ALPHABET.iter().position(|symbol| symbol == byte)? as u32
            };
            word = (word << 6) | value;
        }
        let decoded = [(word >> 16) as u8, (word >> 8) as u8, word as u8];
        out.extend_from_slice(&decoded[..3 - padding]);
    }
    Some(out)
}

/// Swift `AgentExecutionIntent`: the original caller intent, which a
/// resolved target, fresh facts or a Job never change.
#[derive(Clone, Debug)]
struct Intent {
    /// The intent as Swift encodes it.
    fields: Map<String, Value>,
    execution: String,
    operation: String,
    inputs: Map<String, Value>,
    target: Option<String>,
    expected_revision: Option<i64>,
    capability: Option<String>,
    budget: i64,
    reviewed: Option<String>,
    request_id: Option<String>,
    idempotency_key: Option<String>,
    outputs: Option<Vec<String>>,
    context: Option<Value>,
}

impl Intent {
    /// Swift's initializer, in its order and with its refusals; a stored
    /// record's intent need not name an operation the Catalog still publishes.
    fn parse(fields: &Map<String, Value>, published: bool) -> Result<Self, WireError> {
        let invalid = |message: &str| failure("invalidInput", message);
        let text = |key: &str| fields.get(key).and_then(Value::as_str);
        let budget = text("maximumWaitMilliseconds").and_then(|budget| {
            budget
                .parse::<i64>()
                .ok()
                .filter(|number| number.to_string() == budget && (1..=MAX_BUDGET).contains(number))
        });
        let (Some(execution), Some(operation), Some(inputs), Some(budget)) = (
            text("executionId").filter(|id| valid_identifier(id)),
            text("operation").filter(|operation| (1..=128).contains(&operation.len())),
            fields.get("inputs").and_then(Value::as_object),
            budget,
        ) else {
            return Err(invalid(
                "an exact published operation, executionId, inputs and bounded orchestration budget are required",
            ));
        };
        if !fields.keys().all(|key| INTENT_KEYS.contains(&key.as_str()))
            || fields.get("schemaVersion") != Some(&json!(INTENT_SCHEMA))
        {
            return Err(invalid(
                "an exact published operation, executionId, inputs and bounded orchestration budget are required",
            ));
        }
        let catalog = descriptor(operation);
        if published && catalog.is_none_or(|entry| entry.reference() != operation) {
            return Err(invalid(
                "operation must be an exact token published by the current Catalog",
            ));
        }
        let identity = |key: &str| match fields.get(key) {
            None => Ok(None),
            Some(Value::String(value)) if valid_identifier(value) => Ok(Some(value.clone())),
            Some(_) => Err(invalid(&format!("{key} must be a bounded identity"))),
        };
        let request_id = identity("requestId")?;
        let idempotency_key = identity("idempotencyKey")?;
        if idempotency_key
            .as_ref()
            .is_some_and(|key| key.chars().count() < 8)
        {
            return Err(invalid("idempotencyKey must contain at least 8 characters"));
        }
        let outputs = match fields.get("requestedOutputs") {
            None => None,
            Some(Value::Array(values)) if values.len() <= 4 => {
                let mut outputs = Vec::new();
                for value in values {
                    match value.as_str() {
                        Some(output) if OUTPUTS.contains(&output) => {
                            outputs.push(output.to_owned())
                        }
                        _ => return Err(invalid("requestedOutputs contains an unpublished value")),
                    }
                }
                if outputs.iter().collect::<BTreeSet<_>>().len() != values.len() {
                    return Err(invalid("requestedOutputs must be unique"));
                }
                Some(outputs)
            }
            Some(_) => return Err(invalid("requestedOutputs must be a bounded typed list")),
        };
        let context = match fields.get("clientContext") {
            None => None,
            Some(Value::Object(context))
                if context
                    .keys()
                    .all(|key| key == "clientName" || key == "provenance") =>
            {
                if let Some(name) = context.get("clientName")
                    && !name
                        .as_str()
                        .is_some_and(|name| (1..=128).contains(&name.graphemes(true).count()))
                {
                    return Err(invalid("invalid clientName"));
                }
                if let Some(annotations) = context.get("provenance") {
                    let Some(pairs) = annotations.as_object().filter(|pairs| {
                        pairs.len() <= 16
                            && pairs.iter().all(|(key, value)| {
                                (1..=64).contains(&key.graphemes(true).count())
                                    && value
                                        .as_str()
                                        .is_some_and(|text| text.graphemes(true).count() <= 400)
                            })
                    }) else {
                        return Err(invalid("invalid provenance annotations"));
                    };
                    if let Some(Value::String(thread)) = pairs.get("arkdeck.threadId")
                        && !thread_identity(thread)
                    {
                        return Err(invalid("invalid thread provenance identity"));
                    }
                }
                Some(Value::Object(context.clone()))
            }
            Some(_) => {
                return Err(invalid(
                    "clientContext must contain only display/audit annotations",
                ));
            }
        };
        let (target, expected_revision) = match fields.get("target") {
            None => (None, None),
            Some(Value::Object(object))
                if object
                    .keys()
                    .all(|key| key == "targetId" || key == "expectedBindingRevision")
                    && object
                        .get("targetId")
                        .and_then(Value::as_str)
                        .is_some_and(valid_identifier) =>
            {
                let revision = match object.get("expectedBindingRevision") {
                    None => None,
                    Some(value) => match value.as_i64() {
                        Some(revision)
                            if revision > 0
                                && catalog.is_none_or(|entry| entry.binding() != "none") =>
                        {
                            Some(revision)
                        }
                        _ => {
                            return Err(invalid(
                                "expectedBindingRevision must be positive and device-bound",
                            ));
                        }
                    },
                };
                (object["targetId"].as_str().map(str::to_owned), revision)
            }
            Some(_) => return Err(invalid("target must be an exact durable target reference")),
        };
        let capability = match fields.get("capabilityReference") {
            None => None,
            Some(Value::String(reference)) if valid_identifier(reference) => {
                Some(reference.clone())
            }
            Some(_) => {
                return Err(invalid(
                    "capability must be a reference, never an authority document",
                ));
            }
        };
        let reviewed = match fields.get("reviewedPlanDigest") {
            None => None,
            Some(Value::String(value)) if digest(value) => Some(value.clone()),
            Some(_) => {
                return Err(invalid(
                    "reviewedPlanDigest must be an exact lowercase SHA-256",
                ));
            }
        };
        let canonical = canonical_json(&Value::Object(fields.clone()))
            .map_err(|_| invalid("execution intent must be representable as canonical I-JSON"))?;
        if canonical.len() > MAX_INTENT {
            return Err(failure(
                "inputTooLarge",
                "execution intent exceeds its document bound",
            ));
        }
        let mut normalized = Map::new();
        normalized.insert("schemaVersion".into(), json!(INTENT_SCHEMA));
        normalized.insert("executionId".into(), json!(execution));
        normalized.insert("operation".into(), json!(operation));
        normalized.insert("inputs".into(), Value::Object(inputs.clone()));
        normalized.insert("maximumWaitMilliseconds".into(), json!(budget.to_string()));
        if let Some(target) = &target {
            let mut object = Map::from_iter([("targetId".into(), json!(target))]);
            if let Some(revision) = expected_revision {
                object.insert("expectedBindingRevision".into(), json!(revision));
            }
            normalized.insert("target".into(), Value::Object(object));
        }
        if let Some(capability) = &capability {
            normalized.insert("capabilityReference".into(), json!(capability));
        }
        if let Some(reviewed) = &reviewed {
            normalized.insert("reviewedPlanDigest".into(), json!(reviewed));
        }
        if let Some(request_id) = &request_id {
            normalized.insert("requestId".into(), json!(request_id));
        }
        if let Some(key) = &idempotency_key {
            normalized.insert("idempotencyKey".into(), json!(key));
        }
        if let Some(outputs) = &outputs {
            normalized.insert("requestedOutputs".into(), json!(outputs));
        }
        if let Some(context) = &context {
            normalized.insert("clientContext".into(), context.clone());
        }
        Ok(Self {
            fields: normalized,
            execution: execution.to_owned(),
            operation: operation.to_owned(),
            inputs: inputs.clone(),
            target,
            expected_revision,
            capability,
            budget,
            reviewed,
            request_id,
            idempotency_key,
            outputs,
            context,
        })
    }

    /// Swift `canonicalIntent`'s digest: the intent without its identity or
    /// reviewed-plan precondition, in the portable canonical form.
    fn fingerprint(&self) -> Result<String, WireError> {
        let mut intent = self.fields.clone();
        intent.remove("executionId");
        intent.remove("reviewedPlanDigest");
        canonical_json(&Value::Object(intent))
            .map(|bytes| sha256_hex(&bytes))
            .map_err(|_| {
                failure(
                    "invalidInput",
                    "execution intent must be representable as canonical I-JSON",
                )
            })
    }

    fn descriptor(&self) -> Option<&'static CatalogOperation> {
        descriptor(&self.operation)
    }
}

const ACTION_KINDS: [&str; 3] = ["connectDevice", "trustDevice", "selectDevice"];
const ACTION_STATUSES: [&str; 3] = ["waiting", "resolvedByFreshProbe", "expired"];

/// Swift `AgentObservedCandidate`: the exact observation an action names.
#[derive(Clone, Debug, PartialEq)]
struct Observed {
    candidate: String,
    id: String,
    generation: u64,
}

impl Observed {
    fn decode(value: &Value) -> Option<Self> {
        let object = value.as_object()?;
        Some(Self {
            candidate: object.get("candidate")?.as_str()?.to_owned(),
            id: object.get("observationID")?.as_str()?.to_owned(),
            generation: object.get("generation")?.as_u64()?,
        })
    }

    fn value(&self) -> Value {
        json!({"candidate": self.candidate, "generation": self.generation,
            "observationID": self.id})
    }
}

/// Swift `AgentCandidateSelection`: one choice a device selection offers.
#[derive(Clone, Debug, PartialEq)]
struct Selection {
    reference: String,
    observed: Observed,
}

/// Swift `RuntimeAgentHumanAction`: the physical assistance an execution
/// asked a person for, the reference that resumes it and, for a device
/// selection, the choices it offers.
#[derive(Clone, Debug)]
struct HumanAction {
    id: String,
    execution: String,
    resume: String,
    kind: String,
    created: String,
    expires: String,
    status: String,
    resolved: Option<String>,
    observation: Option<Observed>,
    selections: Vec<Selection>,
}

impl HumanAction {
    /// Swift's decoder: its typed members, a member it does not know
    /// dropped as `Codable` drops it.
    fn decode(value: &Value) -> Option<Self> {
        let object = value.as_object()?;
        let text = |key: &str| object.get(key).and_then(Value::as_str).map(str::to_owned);
        let kind = text("kind").filter(|kind| ACTION_KINDS.contains(&kind.as_str()))?;
        let resolved = match object.get("resolvedSelection") {
            None | Some(Value::Null) => None,
            Some(Value::String(selection)) => Some(selection.clone()),
            Some(_) => return None,
        };
        let observation = match object.get("observation") {
            None | Some(Value::Null) => None,
            Some(value) => Some(Observed::decode(value)?),
        };
        let selections = object
            .get("selections")?
            .as_array()?
            .iter()
            .map(|selection| {
                Some(Selection {
                    reference: selection.get("reference")?.as_str()?.to_owned(),
                    observed: Observed::decode(selection.get("observation")?)?,
                })
            })
            .collect::<Option<Vec<_>>>()?;
        Some(Self {
            id: text("actionID")?,
            execution: text("executionID")?,
            resume: text("resumeReference")?,
            kind,
            created: text("createdAt")?,
            expires: text("expiresAt")?,
            status: text("status")?,
            resolved,
            observation,
            selections,
        })
    }

    /// The action as Swift's canonical encoder writes it: nil members
    /// omitted.
    fn value(&self) -> Value {
        let mut object = Map::new();
        object.insert("actionID".into(), json!(self.id));
        object.insert("createdAt".into(), json!(self.created));
        object.insert("executionID".into(), json!(self.execution));
        object.insert("expiresAt".into(), json!(self.expires));
        object.insert("kind".into(), json!(self.kind));
        if let Some(observation) = &self.observation {
            object.insert("observation".into(), observation.value());
        }
        if let Some(selection) = &self.resolved {
            object.insert("resolvedSelection".into(), json!(selection));
        }
        object.insert("resumeReference".into(), json!(self.resume));
        object.insert(
            "selections".into(),
            self.selections
                .iter()
                .map(|selection| {
                    json!({"observation": selection.observed.value(),
                        "reference": selection.reference})
                })
                .collect(),
        );
        object.insert("status".into(), json!(self.status));
        Value::Object(object)
    }

    /// Swift `AgentPhysicalActionKind`: the category, the reason and the
    /// least a person must do.
    fn contract(&self) -> (&'static str, &'static str, &'static str) {
        match self.kind.as_str() {
            "connectDevice" => (
                "physicalConnection",
                "device.notObserved",
                "human.connectOrPowerDevice",
            ),
            "trustDevice" => (
                "deviceTrustPrompt",
                "device.trustPending",
                "human.acceptDeviceTrustPrompt",
            ),
            _ => (
                "ambiguousIdentity",
                "device.identityAmbiguous",
                "human.confirmDeviceIdentity",
            ),
        }
    }

    /// Swift `RuntimeAgentHumanAction.projection`.
    fn projection(&self) -> Value {
        let (category, reason, minimum) = self.contract();
        let schema = if self.selections.is_empty() {
            Value::Null
        } else {
            json!({"type": "string", "enum": self.selections.iter()
                .map(|selection| &selection.reference).collect::<Vec<_>>()})
        };
        json!({
            "schemaVersion": "arkdeck.human-action/1", "actionId": self.id,
            "owner": {"kind": "agentExecution", "id": self.execution},
            "resumeReference": self.resume, "category": category, "reasonCode": reason,
            "minimumAction": minimum, "createdAt": self.created, "expiresAt": self.expires,
            "status": self.status, "newDispatchCount": 0, "selectionSchema": schema,
            "choices": self.selections.iter().map(|selection| json!({
                "value": selection.reference, "candidateKey": selection.observed.candidate,
            })).collect::<Vec<_>>(),
        })
    }

    /// Swift `RuntimeAgentHumanAction.nextAction`.
    fn next_action(&self) -> Value {
        let (_, reason, _) = self.contract();
        json!({"kind": "humanAction", "owner": {"kind": "agentExecution", "id": self.execution},
            "resource": {"kind": "humanAction", "id": self.id}, "reasonCode": reason,
            "resumeReference": self.resume, "expiresAt": self.expires})
    }
}

/// Swift `RuntimeAgentExecutionRecord`.
#[derive(Clone, Debug)]
struct Record {
    intent: Intent,
    fingerprint: String,
    catalog: String,
    created: String,
    deadline: String,
    observed: String,
    generation: i64,
    state: String,
    target: Option<(String, Option<i64>)>,
    submission: Option<Vec<u8>>,
    job: Option<String>,
    job_state: Option<String>,
    unknown: bool,
    failure_code: Option<String>,
    actions: Vec<HumanAction>,
}

impl Record {
    /// The record as Swift's canonical encoder writes it: nil fields
    /// omitted, the prepared request as base64.
    fn value(&self) -> Value {
        let mut object = Map::new();
        object.insert(
            "actions".into(),
            self.actions.iter().map(HumanAction::value).collect(),
        );
        object.insert("catalogDigest".into(), json!(self.catalog));
        object.insert("createdAt".into(), json!(self.created));
        object.insert("deadline".into(), json!(self.deadline));
        if let Some(code) = &self.failure_code {
            object.insert("failureCode".into(), json!(code));
        }
        object.insert("generation".into(), json!(self.generation));
        object.insert("intent".into(), Value::Object(self.intent.fields.clone()));
        object.insert("intentFingerprintSHA256".into(), json!(self.fingerprint));
        if let Some(job) = &self.job {
            object.insert("jobID".into(), json!(job));
        }
        if let Some(state) = &self.job_state {
            object.insert("jobState".into(), json!(state));
        }
        object.insert("lastObservedAt".into(), json!(self.observed));
        object.insert("outcomeUnknown".into(), json!(self.unknown));
        object.insert("schemaVersion".into(), json!(RECORD_SCHEMA));
        object.insert("state".into(), json!(self.state));
        if let Some(bytes) = &self.submission {
            object.insert("submissionRequest".into(), json!(base64(bytes)));
        }
        if let Some((target, revision)) = &self.target {
            let mut object_target = Map::new();
            if let Some(revision) = revision {
                object_target.insert("bindingRevision".into(), json!(revision));
            }
            object_target.insert("targetID".into(), json!(target));
            object.insert("target".into(), Value::Object(object_target));
        }
        Value::Object(object)
    }

    /// Swift's reader: the closed key set, the typed fields and every
    /// invariant `validate` holds.
    fn decode(bytes: &[u8]) -> Option<Self> {
        let value = strict_json(bytes).ok()?;
        let object = value.as_object()?;
        if !object.keys().all(|key| RECORD_KEYS.contains(&key.as_str()))
            || object.get("schemaVersion") != Some(&json!(RECORD_SCHEMA))
        {
            return None;
        }
        let text = |key: &str| object.get(key).and_then(Value::as_str).map(str::to_owned);
        let optional = |key: &str| match object.get(key) {
            None | Some(Value::Null) => Some(None),
            Some(Value::String(value)) => Some(Some(value.clone())),
            Some(_) => None,
        };
        let target = match object.get("target") {
            None | Some(Value::Null) => None,
            Some(Value::Object(target)) => {
                let id = target.get("targetID")?.as_str()?.to_owned();
                let revision = match target.get("bindingRevision") {
                    None | Some(Value::Null) => None,
                    Some(value) => Some(value.as_i64()?),
                };
                Some((id, revision))
            }
            Some(_) => return None,
        };
        let submission = match object.get("submissionRequest") {
            None | Some(Value::Null) => None,
            Some(Value::String(text)) => Some(unbase64(text)?),
            Some(_) => return None,
        };
        let record = Self {
            intent: Intent::parse(object.get("intent")?.as_object()?, false).ok()?,
            fingerprint: text("intentFingerprintSHA256")?,
            catalog: text("catalogDigest")?,
            created: text("createdAt")?,
            deadline: text("deadline")?,
            observed: text("lastObservedAt")?,
            generation: object.get("generation")?.as_i64()?,
            state: text("state")?,
            target,
            submission,
            job: optional("jobID")?,
            job_state: optional("jobState")?,
            unknown: object.get("outcomeUnknown")?.as_bool()?,
            failure_code: optional("failureCode")?,
            actions: object
                .get("actions")?
                .as_array()?
                .iter()
                .map(HumanAction::decode)
                .collect::<Option<Vec<_>>>()?,
        };
        record.valid().then_some(record)
    }

    /// Swift `waitingAction`: the last action, while it waits.
    fn waiting(&self) -> Option<&HumanAction> {
        self.actions
            .last()
            .filter(|action| action.status == "waiting")
    }

    /// Swift `expireWaitingActions`.
    fn expire_waiting(&mut self) {
        for action in &mut self.actions {
            if action.status == "waiting" {
                action.status = "expired".into();
            }
        }
    }

    /// Swift `validate`'s actions: at most 128, owned by this execution, at
    /// most one waiting and waiting exactly while the execution does, unique
    /// identities and resume references, each inside the execution's life and
    /// deadline, and choices only for a device selection, which names no
    /// single observation.
    fn actions_valid(&self, created: u64, observed: u64) -> bool {
        let identities: BTreeSet<&str> = self
            .actions
            .iter()
            .map(|action| action.id.as_str())
            .collect();
        let references: BTreeSet<&str> = self
            .actions
            .iter()
            .map(|action| action.resume.as_str())
            .collect();
        self.actions.len() <= 128
            && self.actions.iter().all(|action| {
                action.execution == self.intent.execution
                    && ACTION_STATUSES.contains(&action.status.as_str())
            })
            && self
                .actions
                .iter()
                .filter(|action| action.status == "waiting")
                .count()
                <= 1
            && (self.state == "waitingForHuman") == self.waiting().is_some()
            && identities.len() == self.actions.len()
            && references.len() == self.actions.len()
            && self.actions.iter().all(|action| {
                let choices: BTreeSet<&str> = action
                    .selections
                    .iter()
                    .map(|selection| selection.reference.as_str())
                    .collect();
                let kind_holds = if action.kind == "selectDevice" {
                    action.observation.is_none() && !action.selections.is_empty()
                } else {
                    action.selections.is_empty() && action.resolved.is_none()
                };
                valid_identifier(&action.id)
                    && valid_identifier(&action.resume)
                    && precise_utc_millis(&action.created)
                        .is_some_and(|at| at >= created && at <= observed)
                    && action.expires == self.deadline
                    && action.selections.len() <= 1000
                    && choices.len() == action.selections.len()
                    && kind_holds
                    && action
                        .resolved
                        .as_deref()
                        .is_none_or(|selection| choices.contains(selection))
                    && choices.iter().all(|reference| valid_identifier(reference))
            })
    }

    fn valid(&self) -> bool {
        let (Some(created), Some(deadline), Some(observed)) = (
            precise_utc_millis(&self.created),
            precise_utc_millis(&self.deadline),
            precise_utc_millis(&self.observed),
        ) else {
            return false;
        };
        self.generation > 0
            && self.intent.fingerprint().ok().as_deref() == Some(self.fingerprint.as_str())
            && observed >= created
            && deadline.checked_sub(created) == u64::try_from(self.intent.budget).ok()
            && STATES.contains(&self.state.as_str())
            && self.actions_valid(created, observed)
            && (self.state != "creatingJob" || self.submission.is_some())
            && (self.state != "abandoned" || self.job.is_none())
            && (self.job.is_none() || self.submission.is_some())
            && self.job.as_deref().is_none_or(valid_identifier)
            && self.target.as_ref().is_none_or(|(target, revision)| {
                valid_identifier(target) && revision.is_none_or(|revision| revision > 0)
            })
            && self
                .submission
                .as_ref()
                .is_none_or(|bytes| self.prepared(bytes))
    }

    /// Swift's check that the prepared Job request is exactly the one this
    /// intent and resolved target make.
    fn prepared(&self, bytes: &[u8]) -> bool {
        let (Ok(request), Ok(document), Some((target, revision))) = (
            OperationRequest::decode(bytes),
            strict_json(bytes),
            self.target.as_ref(),
        ) else {
            return false;
        };
        let seed = sha256_hex(self.intent.execution.as_bytes());
        let inputs =
            |inputs: &Map<String, Value>| canonical_json(&Value::Object(inputs.clone())).ok();
        request.request_id
            == self
                .intent
                .request_id
                .clone()
                .unwrap_or_else(|| format!("agent-request-{seed}"))
            && request.idempotency_key
                == self
                    .intent
                    .idempotency_key
                    .clone()
                    .unwrap_or_else(|| format!("agent-execution-{seed}"))
            && request.reference() == self.intent.operation
            && request.target_id == *target
            && request.expected_binding_revision == *revision
            && request.capability_id == self.intent.capability
            && request.requested_outputs
                == self
                    .intent
                    .outputs
                    .clone()
                    .unwrap_or_else(|| vec!["derivedArtifacts".into()])
            && document.get("reviewedPlanDigest").and_then(Value::as_str)
                == self.intent.reviewed.as_deref()
            && document.get("clientContext") == self.intent.context.as_ref()
            && inputs(&request.inputs) == inputs(&self.intent.inputs)
    }

    /// Swift `RuntimeAgentExecutionRecord.projection`.
    fn projection(&self) -> Value {
        let id = &self.intent.execution;
        let completed = self.state == "completed";
        let waiting = self.waiting();
        let next = if let Some(action) = waiting.filter(|_| self.state == "waitingForHuman") {
            action.next_action()
        } else if let Some(job) = &self.job {
            let kind = if self.unknown {
                "reconcile"
            } else if completed {
                "readResult"
            } else {
                "wait"
            };
            let mut action = json!({"kind": kind, "owner": {"kind": "job", "id": job},
                "resource": {"kind": "job", "id": job},
                "reasonCode": if self.unknown { "recovery.outcomeUnknown" }
                    else if completed { "job.resultAvailable" } else { "job.running" }});
            if kind == "wait" {
                action["retryAfter"] = json!("250ms");
            }
            action
        } else if !TERMINAL.contains(&self.state.as_str()) {
            json!({"kind": "wait", "owner": {"kind": "agentExecution", "id": id},
                "resource": {"kind": "agentExecution", "id": id},
                "reasonCode": "agent.orchestrationPending", "retryAfter": "250ms"})
        } else {
            Value::Null
        };
        json!({
            "schemaVersion": PROJECTION_SCHEMA, "executionId": id,
            "generation": self.generation.to_string(), "operation": self.intent.operation,
            "catalogDigest": self.catalog, "createdAt": self.created, "deadline": self.deadline,
            "lastObservedAt": self.observed, "state": self.state,
            "targetId": self.target.as_ref().map(|(target, _)| target),
            "bindingRevision": self.target.as_ref().and_then(|(_, revision)| *revision),
            "jobId": self.job, "jobState": self.job_state, "outcomeUnknown": self.unknown,
            "failureCode": self.failure_code,
            "humanAction": waiting.map(HumanAction::projection), "nextAction": next,
        })
    }
}

/// What an execution reaches: the Target owner, the Job owner and the
/// admitter the daemon admits with, the Runtime's precise clock and, for an
/// execution that names no target, the Runtime's own device observation.
pub struct AgentEngine<'a> {
    pub targets: &'a TargetStore,
    pub jobs: &'a JobStore,
    pub admitter: &'a JobAdmitter<'a>,
    pub now: fn() -> Option<String>,
    pub observations: Option<Observing<'a>>,
}

/// The Target observation owner and what it reads through.
pub struct Observing<'a> {
    pub owner: &'a TargetObservations,
    pub sources: Sources<'a>,
}

/// One physical-assistance action as the human-action owner lists it.
pub(crate) struct ActionRow {
    pub(crate) created: String,
    pub(crate) id: String,
    pub(crate) value: Value,
}

/// The Job an execution has just come to own, which the caller runs.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AgentStart {
    pub execution: String,
    pub job: String,
}

/// An answer before the daemon projects the owned Job over it, and the Job
/// to start, when this request made the execution own it.
pub struct AgentAnswer {
    pub value: Value,
    pub start: Option<AgentStart>,
}

/// The agent execution owner over its private directory.
pub struct AgentExecutionStore {
    root: HostDirectory,
    path: PathBuf,
    /// Swift's `RuntimeSnapshotPager` over `snapshots`, which the list pages
    /// through.
    pages: SnapshotPager,
    /// Swift's owner is an actor: one request advances the store at a time.
    gate: Mutex<()>,
    /// Swift `continuousDeadlines`: the monotonic end of each budget this
    /// process has observed.
    deadlines: Mutex<HashMap<String, Instant>>,
}

impl AgentExecutionStore {
    /// `path` is the owner's private directory, which the composition
    /// makes; the pager directory Swift's owner keeps beside the records
    /// (`snapshots`) is made here.
    pub fn open(path: &Path) -> io::Result<Self> {
        let root = HostDirectory::open(path)?;
        root.private_child("snapshots")?;
        Ok(Self {
            root,
            path: path.into(),
            // The gate serializes every list, as Swift's actor does.
            pages: SnapshotPager::open_serialized(&path.join("snapshots"))?,
            gate: Mutex::new(()),
            deadlines: Mutex::new(HashMap::new()),
        })
    }

    fn file(id: &str) -> String {
        format!("execution-{}.json", sha256_hex(id.as_bytes()))
    }

    fn validate_directory(&self) -> Result<(), WireError> {
        self.root.validate_path(&self.path).map_err(|_| {
            failure(
                "recordUnreadable",
                "execution store is not a private Runtime directory",
            )
        })
    }

    fn load(&self, id: &str) -> Result<Option<Record>, WireError> {
        self.validate_directory()?;
        let Some(record) = self.read(&Self::file(id))? else {
            return Ok(None);
        };
        if record.intent.execution != id {
            return Err(failure(
                "recordUnreadable",
                "execution identity does not match its record",
            ));
        }
        Ok(Some(record))
    }

    /// Swift `read`: the record a file holds, if the file exists.
    fn read(&self, name: &str) -> Result<Option<Record>, WireError> {
        match self.root.read(name, MAX_RECORD) {
            Ok(bytes) => Record::decode(&bytes)
                .map(Some)
                .ok_or_else(|| failure("recordUnreadable", "execution record cannot be validated")),
            Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(None),
            Err(_) => Err(failure(
                "recordUnreadable",
                "execution record failed identity or size checks",
            )),
        }
    }

    /// Swift `forEachRecord`: every record, one at a time in file-name
    /// order, each under the name its own identity gives.
    fn each_record(&self, mut visit: impl FnMut(&Record)) -> Result<(), WireError> {
        self.validate_directory()?;
        let mut files = self.files()?;
        files.sort();
        for file in files {
            let record = self
                .read(&file)?
                .filter(|record| Self::file(&record.intent.execution) == file)
                .ok_or_else(|| {
                    failure(
                        "recordUnreadable",
                        "execution record was removed or renamed",
                    )
                })?;
            visit(&record);
        }
        Ok(())
    }

    fn files(&self) -> Result<Vec<String>, WireError> {
        let exceeded = || {
            failure(
                "recordUnreadable",
                "execution directory exceeds its record bound",
            )
        };
        let files: Vec<String> = self
            .root
            .names(MAX_RECORDS + 64)
            .map_err(|_| exceeded())?
            .into_iter()
            .filter(|name| name.starts_with("execution-") && name.ends_with(".json"))
            .collect();
        if files.len() > MAX_RECORDS {
            return Err(exceeded());
        }
        Ok(files)
    }

    /// Every execution's identity, state and Job as the cutover preflight
    /// reads them: each record validated under the name its identity gives,
    /// read without the owner (whose open makes its pager directory) and
    /// without writing anything. Records are published whole, so a read beside
    /// a running owner sees each one before or after a change. An absent store
    /// holds no execution.
    pub(crate) fn cutover_executions(
        path: &Path,
    ) -> Result<Vec<(String, String, Option<String>)>, String> {
        let root = match HostDirectory::open(path) {
            Ok(root) => root,
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(Vec::new()),
            Err(error) => return Err(format!("the execution store is unreadable: {error}")),
        };
        let mut files: Vec<String> = root
            .names(MAX_RECORDS + 64)
            .map_err(|error| format!("the execution store is unreadable: {error}"))?
            .into_iter()
            .filter(|name| name.starts_with("execution-") && name.ends_with(".json"))
            .collect();
        if files.len() > MAX_RECORDS {
            return Err("the execution store exceeds its record bound".into());
        }
        files.sort();
        let mut rows = Vec::with_capacity(files.len());
        for file in files {
            let bytes = root
                .read(&file, MAX_RECORD)
                .map_err(|error| format!("execution record {file} is unreadable: {error}"))?;
            let record = Record::decode(&bytes)
                .filter(|record| Self::file(&record.intent.execution) == file)
                .ok_or_else(|| format!("execution record {file} cannot be validated"))?;
            rows.push((record.intent.execution, record.state, record.job));
        }
        Ok(rows)
    }

    /// Swift `save`: a complete record, generation by generation, whose
    /// identity never changes.
    fn save(&self, record: &Record, expected: Option<i64>) -> Result<(), WireError> {
        if !record.valid() {
            return Err(failure(
                "recordUnreadable",
                "execution record invariants failed",
            ));
        }
        let existing = self.load(&record.intent.execution)?;
        if existing.as_ref().map(|existing| existing.generation) != expected
            || expected.unwrap_or(0) == i64::MAX
            || record.generation != expected.unwrap_or(0) + 1
        {
            return Err(failure("resourceConflict", "execution generation changed"));
        }
        if let Some(existing) = &existing
            && (existing.fingerprint != record.fingerprint
                || existing.intent.reviewed != record.intent.reviewed
                || existing.catalog != record.catalog
                || existing.created != record.created
                || existing.deadline != record.deadline
                || existing
                    .target
                    .as_ref()
                    .is_some_and(|target| Some(target) != record.target.as_ref())
                || existing
                    .submission
                    .as_ref()
                    .is_some_and(|bytes| Some(bytes) != record.submission.as_ref())
                || existing
                    .job
                    .as_ref()
                    .is_some_and(|job| Some(job) != record.job.as_ref()))
        {
            return Err(failure(
                "resourceConflict",
                "immutable execution identity changed",
            ));
        }
        let files = self.files()?;
        if existing.is_none() && files.len() >= MAX_RECORDS {
            return Err(failure(
                "operationUnavailable",
                "execution store reached its resource bound",
            ));
        }
        let bytes = session_json::encode(&record.value()).map_err(|_| internal(UNREADABLE))?;
        if bytes.len() > MAX_RECORD {
            return Err(failure(
                "inputTooLarge",
                "execution record exceeds its storage bound",
            ));
        }
        let name = Self::file(&record.intent.execution);
        let mut total = bytes.len() as u64;
        for file in files.iter().filter(|file| **file != name) {
            let (_, size) = self.root.owned_kind_and_size(file).map_err(|_| {
                failure(
                    "recordUnreadable",
                    "execution store contains an unsafe record",
                )
            })?;
            total += size;
            if total > MAX_STORE {
                return Err(failure(
                    "operationUnavailable",
                    "execution store reached its byte bound",
                ));
            }
        }
        self.root
            .publish_document(&name, &bytes, MAX_RECORD)
            .map_err(|_| internal(UNREADABLE))
    }

    fn commit(&self, record: &mut Record) -> Result<(), WireError> {
        if record.generation == i64::MAX {
            return Err(failure(
                "recordUnreadable",
                "execution generation exhausted",
            ));
        }
        let previous = record.generation;
        record.generation += 1;
        self.save(record, Some(previous))
    }

    /// Swift `guardFor` and `check`: the time now, if it is neither behind
    /// the record's high-water mark nor past its durable or monotonic
    /// deadline.
    fn check_budget(&self, record: &Record, now: fn() -> Option<String>) -> Result<u64, WireError> {
        let id = &record.intent.execution;
        let (Some(observed), Some(deadline), Some(current)) = (
            precise_utc_millis(&record.observed),
            precise_utc_millis(&record.deadline),
            now().and_then(|text| precise_utc_millis(&text)),
        ) else {
            return Err(failure(
                "orchestrationClockUntrusted",
                "no trusted orchestration time is available",
            ));
        };
        let continuous = {
            let mut deadlines = self.deadlines.lock().map_err(|_| internal(UNREADABLE))?;
            *deadlines.entry(id.clone()).or_insert_with(|| {
                let remaining = u64::try_from(record.intent.budget)
                    .unwrap_or(0)
                    .min(deadline.saturating_sub(current));
                Instant::now() + Duration::from_millis(remaining)
            })
        };
        if current < observed {
            return Err(failure_with(
                "orchestrationClockUntrusted",
                "the orchestration clock moved behind its durable high-water mark",
                execution_detail(id),
            ));
        }
        if current >= deadline || Instant::now() >= continuous {
            return Err(failure_with(
                "orchestrationBudgetExpired",
                "the durable orchestration deadline has expired",
                execution_detail(id),
            ));
        }
        Ok(current)
    }

    /// Swift `observeBudget`: the high-water mark advanced, or the execution
    /// stopped at its original budget.
    fn observe_budget(
        &self,
        record: &mut Record,
        now: fn() -> Option<String>,
    ) -> Result<(), WireError> {
        match self.check_budget(record, now) {
            Ok(current) => {
                record.observed = utc_precise_from_millis(current);
                self.commit(record)
            }
            Err(error)
                if matches!(
                    error.code.as_str(),
                    "orchestrationBudgetExpired" | "orchestrationClockUntrusted"
                ) =>
            {
                record.state = if error.code == "orchestrationBudgetExpired" {
                    "budgetExpired"
                } else {
                    "clockUntrusted"
                }
                .into();
                record.failure_code = Some(error.code.clone());
                record.expire_waiting();
                self.commit(record)?;
                Err(error)
            }
            Err(error) => Err(error),
        }
    }

    /// The daemon's `agent.run`, `agent.status`, `agent.list` and
    /// `agent.abandon`, as `agentExecutionRequest` takes them, before the
    /// owned Job is projected over a run's or a status read's answer.
    pub fn advance(
        &self,
        method: &str,
        params: &Map<String, Value>,
        engine: &AgentEngine<'_>,
    ) -> Result<AgentAnswer, WireError> {
        let _gate = self.gate.lock().map_err(|_| internal(UNREADABLE))?;
        let value = match method {
            "agent.run" => return self.run(params, engine),
            "agent.resume" | "human-action.resume" => return self.resume(method, params, engine),
            "agent.status" => {
                exact(params, &["executionId"])?;
                self.status(identity(params, "executionId")?, engine)?
            }
            "agent.list" => self.list(params)?,
            "agent.abandon" => {
                exact(params, &["executionId", "expectedGeneration"])?;
                let text = identity(params, "expectedGeneration")?;
                let generation = text
                    .parse::<i64>()
                    .ok()
                    .filter(|generation| *generation > 0 && generation.to_string() == text)
                    .ok_or_else(|| {
                        failure(
                            "invalidInput",
                            "expectedGeneration must be a positive canonical decimal string",
                        )
                    })?;
                self.abandon(identity(params, "executionId")?, generation, engine)?
            }
            _ => return Err(internal("unknown execution method")),
        };
        Ok(AgentAnswer { value, start: None })
    }

    /// Swift `resumeOwned`: only fresh Runtime observations resolve physical assistance.
    fn resume(
        &self,
        method: &str,
        params: &Map<String, Value>,
        engine: &AgentEngine<'_>,
    ) -> Result<AgentAnswer, WireError> {
        let required = if method == "agent.resume" {
            vec!["resumeReference"]
        } else {
            vec!["resumeReference", "humanAction"]
        };
        // The combined HAR wire also carries an impact challenge. Like Swift,
        // the physical-action owner ignores it; only its own exact action can
        // resolve here, and no challenge contributes admission authority.
        if required.iter().any(|key| !params.contains_key(*key))
            || params.keys().any(|key| {
                !required.contains(&key.as_str())
                    && key != "selection"
                    && !(method == "human-action.resume" && key == "challengeResponse")
            })
        {
            return Err(failure(
                "invalidInput",
                "resume fields do not match the closed physical-action contract",
            ));
        }
        let reference = identity(params, "resumeReference")?;
        let action_id = if method == "human-action.resume" {
            Some(identity(params, "humanAction")?)
        } else {
            None
        };
        let mut found = Vec::new();
        self.each_record(|record| {
            for (index, action) in record.actions.iter().enumerate() {
                if action.resume == reference && action_id.is_none_or(|id| action.id == id) {
                    found.push((record.clone(), index));
                }
            }
        })?;
        if found.len() > 1 {
            return Err(failure(
                "recordUnreadable",
                "resume reference has multiple owners",
            ));
        }
        let (mut record, index) = found
            .pop()
            .ok_or_else(|| failure("resourceNotFound", "human action does not exist"))?;
        let action = record.actions[index].clone();
        if action.status == "expired" {
            return Err(failure(
                "humanActionExpired",
                "the exact human action expired",
            ));
        }
        let choice = if action.kind == "selectDevice" {
            let value = params.get("selection").and_then(Value::as_str);
            Some(
                action
                    .selections
                    .iter()
                    .find(|choice| Some(choice.reference.as_str()) == value)
                    .ok_or_else(|| {
                        failure(
                            "invalidInput",
                            "selection must be an opaque value from this action's schema",
                        )
                    })?
                    .clone(),
            )
        } else {
            if params.contains_key("selection") {
                return Err(failure(
                    "invalidInput",
                    "this physical action accepts no selection",
                ));
            }
            None
        };
        if action.status == "resolvedByFreshProbe" {
            if action.resolved != choice.as_ref().map(|choice| choice.reference.clone()) {
                return Err(failure(
                    "idempotencyConflict",
                    "resolved human action selection changed",
                ));
            }
            return Ok(AgentAnswer {
                value: self.status(&record.intent.execution, engine)?,
                start: None,
            });
        }
        if record.state != "waitingForHuman"
            || record
                .waiting()
                .is_none_or(|waiting| waiting.id != action.id)
        {
            return Err(failure(
                "humanActionExpired",
                "this action is no longer the execution's waiting action",
            ));
        }
        if record.catalog != CATALOG_DIGEST {
            return Err(failure(
                "resourceConflict",
                "the Catalog changed during physical assistance",
            ));
        }
        self.observe_budget(&mut record, engine.now)
            .map_err(|mut error| {
                if error.code == "orchestrationBudgetExpired" {
                    error.code = "humanActionExpired".into();
                }
                error
            })?;
        let selected = if action.kind == "connectDevice" {
            None
        } else {
            choice
                .as_ref()
                .map(|choice| &choice.observed)
                .or(action.observation.as_ref())
        };
        let reference = selected.map(|selected| crate::target_owner::ObservationReference {
            candidate: selected.candidate.clone(),
            observation_id: selected.id.clone(),
            generation: selected.generation,
        });
        let observing = engine
            .observations
            .as_ref()
            .ok_or_else(|| internal(ADVANCE))?;
        let snapshot = observing
            .owner
            .snapshot(&observing.sources, reference.as_ref())
            .map_err(|error| match error {
                ObservationError::Refused { ref code, .. } if code == "resourceConflict" => {
                    failure("resourceConflict", "candidate observation changed")
                }
                error => observation_failure(error),
            })
            .and_then(|snapshot| {
                if action.kind == "selectDevice"
                    && selected.is_some_and(|selected| selected.generation != snapshot.generation)
                {
                    Err(failure(
                        "resourceConflict",
                        "candidate selection generation changed",
                    ))
                } else {
                    Ok(snapshot)
                }
            });
        let snapshot = match snapshot {
            Ok(snapshot) => snapshot,
            Err(error) if error.code == "resourceConflict" => {
                let fresh = observing
                    .owner
                    .snapshot(&observing.sources, None)
                    .map_err(observation_failure)?;
                self.guard_budget(&mut record, engine.now)?;
                self.raise_action(
                    if fresh.observations.is_empty() {
                        "connectDevice"
                    } else {
                        "selectDevice"
                    },
                    &mut record,
                    &fresh,
                    None,
                )?;
                return Ok(AgentAnswer {
                    value: record.projection(),
                    start: None,
                });
            }
            Err(error) => return Err(error),
        };
        self.guard_budget(&mut record, engine.now)?;
        let Some(target) = self.resolve_snapshot(&snapshot, &mut record, engine, selected)? else {
            return Ok(AgentAnswer {
                value: record.projection(),
                start: None,
            });
        };
        record.actions[index].status = "resolvedByFreshProbe".into();
        record.actions[index].resolved = choice.map(|choice| choice.reference);
        record.target = Some(target);
        record.state = "orchestrating".into();
        self.commit(&mut record)?;
        self.drive(record, engine)
    }

    /// Swift `run`: the execution created, or found under the same intent,
    /// then advanced until it owns its Job.
    fn run(
        &self,
        params: &Map<String, Value>,
        engine: &AgentEngine<'_>,
    ) -> Result<AgentAnswer, WireError> {
        let intent = Intent::parse(params, true)?;
        let fingerprint = intent.fingerprint()?;
        let record = match self.load(&intent.execution)? {
            Some(existing) => {
                if existing.fingerprint != fingerprint
                    || existing.intent.reviewed != intent.reviewed
                {
                    return Err(failure_with(
                        "idempotencyConflict",
                        "execution identity already belongs to a different intent or reviewed-plan precondition",
                        execution_detail(&intent.execution),
                    ));
                }
                existing
            }
            None => {
                Self::validate_intent(&intent)?;
                let Some(current) = (engine.now)().and_then(|text| precise_utc_millis(&text))
                else {
                    return Err(failure(
                        "orchestrationClockUntrusted",
                        "cannot create execution without trusted time",
                    ));
                };
                let created = utc_precise_from_millis(current);
                let deadline = utc_precise_from_millis(
                    current + u64::try_from(intent.budget).map_err(|_| internal(ADVANCE))?,
                );
                let record = Record {
                    intent,
                    fingerprint,
                    catalog: CATALOG_DIGEST.into(),
                    created: created.clone(),
                    deadline,
                    observed: created,
                    generation: 1,
                    state: "orchestrating".into(),
                    target: None,
                    submission: None,
                    job: None,
                    job_state: None,
                    unknown: false,
                    failure_code: None,
                    actions: Vec::new(),
                };
                self.save(&record, None)?;
                record
            }
        };
        let id = record.intent.execution.clone();
        if matches!(record.state.as_str(), "budgetExpired" | "clockUntrusted") {
            return Err(failure_with(
                record.failure_code.as_deref().unwrap_or("recordUnreadable"),
                "execution stopped at its original orchestration budget",
                execution_detail(&id),
            ));
        }
        if TERMINAL.contains(&record.state.as_str()) || record.state == "jobOwned" {
            return Ok(AgentAnswer {
                value: self.status(&id, engine)?,
                start: None,
            });
        }
        if record.state == "waitingForHuman" {
            // Running it again is not a resume: the budget is read, and the
            // execution answers as it waits.
            let mut record = record;
            self.observe_budget(&mut record, engine.now)?;
            return Ok(AgentAnswer {
                value: record.projection(),
                start: None,
            });
        }
        self.drive(record, engine)
    }

    /// Swift `engine.validateAgentIntent`, for a new execution only.
    fn validate_intent(intent: &Intent) -> Result<(), WireError> {
        let catalog = intent.descriptor().ok_or_else(|| internal(ADVANCE))?;
        catalog
            .validate_inputs(&intent.inputs)
            .map_err(|refusal| match refusal {
                InputRefusal::Invalid(_) => {
                    failure("invalidInput", "typed operation inputs were rejected")
                }
                InputRefusal::Unsupported(_) => internal(ADVANCE),
            })
    }

    /// Swift `drive`: an accepted Job recovered, or the target resolved,
    /// the exact request prepared and submitted, and the Job owned.
    fn drive(
        &self,
        mut record: Record,
        engine: &AgentEngine<'_>,
    ) -> Result<AgentAnswer, WireError> {
        let id = record.intent.execution.clone();
        if let Some(submission) = record.submission.clone()
            && let Some(job) = Self::accepted(engine.jobs, &submission)?
        {
            record.job = Some(job.clone());
            record.state = "jobOwned".into();
            self.commit(&mut record)?;
            return Ok(AgentAnswer {
                value: record.projection(),
                start: Some(AgentStart { execution: id, job }),
            });
        }
        self.observe_budget(&mut record, engine.now)?;
        if record.catalog != CATALOG_DIGEST {
            return Err(failure(
                "resourceConflict",
                "the Catalog changed during orchestration",
            ));
        }
        if record.target.is_none() {
            let Some(target) = self.resolve_target(&mut record, engine)? else {
                // A person must act first: the execution answers as it waits.
                return Ok(AgentAnswer {
                    value: record.projection(),
                    start: None,
                });
            };
            record.target = Some(target);
            self.commit(&mut record)?;
        }
        self.observe_budget(&mut record, engine.now)?;
        if record.submission.is_none() {
            record.submission = Some(Self::submission(&record)?);
            record.state = "creatingJob".into();
            self.commit(&mut record)?;
        }
        let request = record.submission.clone().ok_or_else(|| {
            failure(
                "recordUnreadable",
                "execution has no exact submission request",
            )
        })?;
        // Swift checks the budget once more as the engine is about to admit.
        // The Job starts at once, so an operation this Runtime admits but
        // does not execute yet is refused before admission.
        self.check_budget(&record, engine.now)?;
        match engine.admitter.submit_for_agent(&request) {
            Ok(accepted) => {
                let job = accepted["jobId"]
                    .as_str()
                    .ok_or_else(|| internal(ADVANCE))?
                    .to_owned();
                record.job = Some(job.clone());
                record.state = "jobOwned".into();
                // No dispatch before the Job identity is durable here.
                self.commit(&mut record)?;
                Ok(AgentAnswer {
                    value: record.projection(),
                    start: Some(AgentStart { execution: id, job }),
                })
            }
            Err(refusal) => self.refused(record, &request, refusal, engine),
        }
    }

    /// Swift `drive`'s handling of a refused submission: a typed refusal
    /// before admission ends the execution, unless the Job was accepted.
    fn refused(
        &self,
        mut record: Record,
        request: &[u8],
        refusal: AdmissionRefusal,
        engine: &AgentEngine<'_>,
    ) -> Result<AgentAnswer, WireError> {
        let id = record.intent.execution.clone();
        match refusal.code {
            "reviewedPlanMismatch" => {
                record.state = "failed".into();
                record.failure_code = Some("reviewedPlanMismatch".into());
                self.commit(&mut record)?;
                Err(failure("reviewedPlanMismatch", refusal.message))
            }
            "idempotencyConflict" => {
                record.state = "failed".into();
                record.failure_code = Some("idempotencyConflict".into());
                self.commit(&mut record)?;
                Err(failure_with(
                    "idempotencyConflict",
                    refusal.message,
                    execution_detail(&id),
                ))
            }
            code if refusal.proven && code != "internalError" => {
                if Self::accepted(engine.jobs, request)?.is_some() {
                    return Err(internal(ADVANCE));
                }
                record.state = "failed".into();
                record.failure_code = Some("admissionDenied".into());
                self.commit(&mut record)?;
                Err(failure_with(
                    "admissionDenied",
                    refusal.message,
                    execution_detail(&id),
                ))
            }
            _ => Err(internal(ADVANCE)),
        }
    }

    /// Swift `acceptedJobForAgent`: the Job this exact request was already
    /// admitted as, found by its idempotency key and fingerprint only.
    fn accepted(jobs: &JobStore, request: &[u8]) -> Result<Option<String>, WireError> {
        let request = OperationRequest::decode(request).map_err(|_| internal(ADVANCE))?;
        match jobs
            .lookup(&request.idempotency_key, &request.fingerprint())
            .map_err(|_| internal(ADVANCE))?
        {
            AdmissionVerdict::Duplicate(job) => Ok(Some(job)),
            AdmissionVerdict::Conflict => Err(internal(ADVANCE)),
            AdmissionVerdict::Admitted => Ok(None),
        }
    }

    /// Swift `resolveTarget`: the exact durable Target the intent names, at
    /// its current binding revision; a registered project, for an operation
    /// that binds no device; or else the device the Runtime observes. `None`
    /// is an execution that now waits for a person.
    fn resolve_target(
        &self,
        record: &mut Record,
        engine: &AgentEngine<'_>,
    ) -> Result<Option<(String, Option<i64>)>, WireError> {
        let catalog = record.intent.descriptor().ok_or_else(|| {
            failure(
                "operationUnavailable",
                "the declared operation is not published",
            )
        })?;
        if let Some(target) = &record.intent.target {
            if catalog.binding() == "none" {
                return Ok(Some((target.clone(), None)));
            }
            let route = engine
                .targets
                .hdc_route(target)
                .map_err(|_| internal(UNREADABLE))?
                .ok_or_else(|| {
                    failure(
                        "resourceNotFound",
                        "the explicitly requested target is not registered",
                    )
                })?;
            let current =
                i64::try_from(route.binding_revision).map_err(|_| internal(UNREADABLE))?;
            if record
                .intent
                .expected_revision
                .is_some_and(|expected| expected != current)
            {
                return Err(failure(
                    "bindingRevisionStale",
                    "the requested binding revision is no longer current",
                ));
            }
            return Ok(Some((target.clone(), Some(current))));
        }
        if catalog.binding() == "none"
            && let Some(Value::String(project)) = record.intent.inputs.get("projectRef")
            && valid_identifier(project)
        {
            // A registered host workspace is an existing typed scope.
            return Ok(Some((project.clone(), None)));
        }
        let Some(observing) = &engine.observations else {
            return Err(failure(
                "operationUnavailable",
                "an execution without a target is not served by the Rust Runtime yet",
            ));
        };
        let snapshot = observing
            .owner
            .snapshot(&observing.sources, None)
            .map_err(observation_failure)?;
        self.guard_budget(record, engine.now)?;
        self.resolve_snapshot(&snapshot, record, engine, None)
    }

    /// Swift `budget.check()` inside `drive`, whose expiry `serialize`
    /// records: unless the execution has ended or owns a Job, it stops at
    /// its original budget with its waiting action expired.
    fn guard_budget(
        &self,
        record: &mut Record,
        now: fn() -> Option<String>,
    ) -> Result<(), WireError> {
        let Err(error) = self.check_budget(record, now) else {
            return Ok(());
        };
        if matches!(
            error.code.as_str(),
            "orchestrationBudgetExpired" | "orchestrationClockUntrusted"
        ) && !TERMINAL.contains(&record.state.as_str())
            && record.job.is_none()
        {
            record.state = if error.code == "orchestrationBudgetExpired" {
                "budgetExpired"
            } else {
                "clockUntrusted"
            }
            .into();
            record.failure_code = Some(error.code.clone());
            record.expire_waiting();
            self.commit(record)?;
        }
        Err(error)
    }

    /// Swift `resolveSnapshot` for a run: no device observed, several, one
    /// that is not authorized and connected, or one whose physical identity
    /// is unproved. A person must act on the first three, so each raises its
    /// action; the last is refused. A single proved connected device is
    /// adopted through the observation owner before creating the typed Job.
    fn resolve_snapshot(
        &self,
        snapshot: &Snapshot,
        record: &mut Record,
        engine: &AgentEngine<'_>,
        selected: Option<&Observed>,
    ) -> Result<Option<(String, Option<i64>)>, WireError> {
        let row = if let Some(selected) = selected {
            let Some(row) = snapshot.observations.iter().find(|row| {
                row.observation_id == selected.id
                    && row.candidate.connect_key == selected.candidate
                    && row.relation.is_some()
            }) else {
                self.raise_action(
                    if snapshot.observations.is_empty() {
                        "connectDevice"
                    } else {
                        "selectDevice"
                    },
                    record,
                    snapshot,
                    None,
                )?;
                return Ok(None);
            };
            row
        } else if let [row] = snapshot.observations.as_slice() {
            row
        } else {
            let kind = if snapshot.observations.is_empty() {
                "connectDevice"
            } else {
                "selectDevice"
            };
            self.raise_action(kind, record, snapshot, None)?;
            return Ok(None);
        };
        if row.candidate.state != "Connected" {
            let kind = if row.candidate.state == "Unauthorized" {
                "trustDevice"
            } else {
                "connectDevice"
            };
            self.raise_action(kind, record, snapshot, Some(observed(row, snapshot)))?;
            return Ok(None);
        }
        if row.relation.is_none() {
            return Err(failure(
                "admissionDenied",
                "the Runtime cannot prove the candidate's physical identity",
            ));
        }
        let observing = engine
            .observations
            .as_ref()
            .ok_or_else(|| internal(ADVANCE))?;
        let reference = crate::target_owner::ObservationReference {
            candidate: row.candidate.connect_key.clone(),
            observation_id: row.observation_id.clone(),
            generation: snapshot.generation,
        };
        // Preserve the agent owner's exact budget refusal (including execution
        // identity), rather than reclassifying it as an observation failure.
        let mut budget_error = None;
        let adopted = observing
            .owner
            .adopt_guarded(&observing.sources, &reference, || {
                self.guard_budget(record, engine.now).map_err(|error| {
                    let reason = error.message.clone();
                    budget_error = Some(error);
                    ObservationError::Failed(reason)
                })
            })
            .map_err(|error| budget_error.unwrap_or_else(|| observation_failure(error)))?;
        self.guard_budget(record, engine.now)?;
        if record
            .target
            .as_ref()
            .is_some_and(|(target, _)| target != &adopted.target_id)
        {
            return Err(failure(
                "factsDrifted",
                "physical assistance cannot select a different resolved target",
            ));
        }
        let binding = record
            .intent
            .descriptor()
            .ok_or_else(|| internal(ADVANCE))?;
        let revision = if binding.binding() == "none" {
            None
        } else {
            Some(i64::try_from(adopted.binding_revision).map_err(|_| internal(UNREADABLE))?)
        };
        Ok(Some((adopted.target_id, revision)))
    }

    /// Swift `raiseAction`: the one action the execution now waits on, with
    /// the observation it names or, for a device selection, one choice per
    /// observed device. An observation that asks for exactly what the
    /// waiting action asks raises nothing new.
    fn raise_action(
        &self,
        kind: &str,
        record: &mut Record,
        snapshot: &Snapshot,
        observation: Option<Observed>,
    ) -> Result<(), WireError> {
        let choices: Vec<Observed> = if kind == "selectDevice" {
            snapshot
                .observations
                .iter()
                .map(|row| observed(row, snapshot))
                .collect()
        } else {
            Vec::new()
        };
        if let Some(current) = record.waiting()
            && current.kind == kind
            && current.observation == observation
            && current
                .selections
                .iter()
                .map(|selection| &selection.observed)
                .eq(choices.iter())
        {
            return Ok(());
        }
        if record.actions.len() >= 128 {
            return Err(failure(
                "operationUnavailable",
                "the bounded physical-assistance history is exhausted",
            ));
        }
        record.expire_waiting();
        let id = minted("har")?;
        let resume = minted("resume")?;
        let selections = choices
            .into_iter()
            .map(|observed| {
                Ok(Selection {
                    reference: minted("candidate")?,
                    observed,
                })
            })
            .collect::<Result<Vec<_>, WireError>>()?;
        record.actions.push(HumanAction {
            id,
            execution: record.intent.execution.clone(),
            resume,
            kind: kind.into(),
            created: record.observed.clone(),
            expires: record.deadline.clone(),
            status: "waiting".into(),
            resolved: None,
            observation,
            selections,
        });
        record.state = "waitingForHuman".into();
        self.commit(record)
    }

    /// Swift `submission(for:)`: the exact typed Job request the execution
    /// submits, as `RuntimeOperationCodec.encodeRequest` encodes it.
    fn submission(record: &Record) -> Result<Vec<u8>, WireError> {
        let unavailable = || {
            failure(
                "recordUnreadable",
                "execution target or operation is unavailable",
            )
        };
        let (Some((target, revision)), Some(_)) = (&record.target, record.intent.descriptor())
        else {
            return Err(unavailable());
        };
        let (id, version) = match record.intent.operation.rsplit_once('@') {
            Some((id, version)) => (id, Some(version.parse::<i64>().map_err(|_| unavailable())?)),
            None => (record.intent.operation.as_str(), None),
        };
        let seed = sha256_hex(record.intent.execution.as_bytes());
        let mut object_target = Map::from_iter([("targetId".into(), json!(target))]);
        if let Some(revision) = revision {
            object_target.insert("expectedBindingRevision".into(), json!(revision));
        }
        let mut operation = Map::from_iter([("id".into(), json!(id))]);
        if let Some(version) = version {
            operation.insert("version".into(), json!(version));
        }
        let mut object = Map::new();
        object.insert("documentType".into(), json!("runtime-operation-request"));
        object.insert("schemaVersion".into(), json!("1.0.0"));
        object.insert(
            "requestId".into(),
            json!(
                record
                    .intent
                    .request_id
                    .clone()
                    .unwrap_or_else(|| format!("agent-request-{seed}"))
            ),
        );
        object.insert(
            "idempotencyKey".into(),
            json!(
                record
                    .intent
                    .idempotency_key
                    .clone()
                    .unwrap_or_else(|| format!("agent-execution-{seed}"))
            ),
        );
        object.insert("target".into(), Value::Object(object_target));
        object.insert("operation".into(), Value::Object(operation));
        object.insert("inputs".into(), Value::Object(record.intent.inputs.clone()));
        object.insert(
            "requestedOutputs".into(),
            json!(
                record
                    .intent
                    .outputs
                    .clone()
                    .unwrap_or_else(|| vec!["derivedArtifacts".into()])
            ),
        );
        if let Some(capability) = &record.intent.capability {
            object.insert("authorization".into(), json!({"capabilityId": capability}));
        }
        if let Some(context) = &record.intent.context {
            object.insert("clientContext".into(), context.clone());
        }
        if let Some(reviewed) = &record.intent.reviewed {
            object.insert("reviewedPlanDigest".into(), json!(reviewed));
        }
        let bytes = session_json::encode(&Value::Object(object)).map_err(|_| unavailable())?;
        // The prepared request is one the Job owner reads as the typed request.
        OperationRequest::decode(&bytes).map_err(|_| unavailable())?;
        Ok(bytes)
    }

    /// Swift `status`: the record with its owned Job's state, read without a
    /// write; an accepted Job whose receipt was lost is found by its request.
    fn status(&self, id: &str, engine: &AgentEngine<'_>) -> Result<Value, WireError> {
        let mut record = self
            .load(id)?
            .ok_or_else(|| failure("resourceNotFound", "execution does not exist"))?;
        if !TERMINAL.contains(&record.state.as_str())
            && record.job.is_none()
            && let Some(submission) = record.submission.clone()
            && let Some(job) = Self::accepted(engine.jobs, &submission)?
        {
            record.job = Some(job);
            record.state = "jobOwned".into();
        }
        if let Some(job) = record.job.clone() {
            let owned = engine
                .jobs
                .read_snapshot(&job)
                .map_err(|_| internal(UNREADABLE))?;
            record.state = if terminal(&owned.state) {
                "completed"
            } else {
                "jobOwned"
            }
            .into();
            record.unknown = owned.outcome_unknown();
            record.job_state = Some(owned.state);
        }
        Ok(record.projection())
    }

    /// The daemon's `agent.list` and Swift `list`: the closed request, then
    /// every execution the filters select as its stored projection without a
    /// physical action, newest first, paged through a stored snapshot a
    /// cursor names. A filtered target is the resolved one.
    fn list(&self, params: &Map<String, Value>) -> Result<Value, WireError> {
        const FILTERS: [&str; 3] = ["state", "operation", "target"];
        if !params
            .keys()
            .all(|key| FILTERS.contains(&key.as_str()) || key == "pageSize" || key == "cursor")
        {
            return Err(failure(
                "invalidInput",
                "request fields do not match the closed method contract",
            ));
        }
        let size = match params.get("pageSize") {
            None => 100,
            Some(value) => value
                .as_i64()
                .filter(|size| (1..=1000).contains(size))
                .and_then(|size| usize::try_from(size).ok())
                .ok_or_else(|| failure("invalidInput", "pageSize must be between 1 and 1000"))?,
        };
        let cursor = match params.get("cursor") {
            None => None,
            Some(Value::String(cursor)) if cursor.len() <= 256 => Some(cursor.as_str()),
            Some(_) => {
                return Err(failure(
                    "invalidCursor",
                    "cursor must be a bounded opaque string",
                ));
            }
        };
        let filters: Map<String, Value> = params
            .iter()
            .filter(|(key, _)| FILTERS.contains(&key.as_str()))
            .map(|(key, value)| (key.clone(), value.clone()))
            .collect();
        if !filters.iter().all(|(key, value)| {
            value.as_str().is_some_and(|text| match key.as_str() {
                "state" => STATES.contains(&text),
                "target" => valid_identifier(text),
                _ => (1..=128).contains(&text.len()),
            })
        }) {
            return Err(failure("invalidInput", "invalid execution list filter"));
        }
        let filter = |key: &str| filters.get(key).and_then(Value::as_str);
        self.pages
            .page_filtered(
                "agent.list",
                &Value::Object(filters.clone()),
                "createdAtDescExecutionIdAsc",
                size,
                cursor,
                || {
                    let mut rows = Vec::new();
                    self.each_record(|record| {
                        if filter("state").is_some_and(|state| state != record.state)
                            || filter("operation")
                                .is_some_and(|operation| operation != record.intent.operation)
                            || filter("target").is_some_and(|target| {
                                record.target.as_ref().is_none_or(|(id, _)| id != target)
                            })
                        {
                            return;
                        }
                        let mut value = record.projection();
                        if let Some(fields) = value.as_object_mut() {
                            // Selection and inputs are never list metadata.
                            fields.remove("humanAction");
                        }
                        rows.push((
                            record.created.clone(),
                            record.intent.execution.clone(),
                            value,
                        ));
                    })?;
                    rows.sort_by(|a, b| b.0.cmp(&a.0).then_with(|| a.1.cmp(&b.1)));
                    Ok(rows.into_iter().map(|(_, _, value)| value).collect())
                },
            )
            .map_err(|error| {
                // The pager's refusals are the owner's own in Swift, with
                // the owner's zero-dispatch proof.
                let message = if error.code == "invalidCursor" {
                    "cursor is invalid, belongs to another query or its snapshot was reclaimed"
                        .to_owned()
                } else {
                    error.message
                };
                failure(&error.code, message)
            })
    }

    /// Swift `humanActionResourceRows`: every physical-assistance action of
    /// every execution, or of one, as the combined human-action owner lists
    /// them.
    pub(crate) fn human_action_rows(
        &self,
        owner: Option<&str>,
    ) -> Result<Vec<ActionRow>, WireError> {
        let _gate = self.gate.lock().map_err(|_| internal(UNREADABLE))?;
        let mut rows = Vec::new();
        self.each_record(|record| {
            if owner.is_some_and(|owner| owner != record.intent.execution) {
                return;
            }
            rows.extend(record.actions.iter().map(|action| ActionRow {
                created: action.created.clone(),
                id: action.id.clone(),
                value: action.projection(),
            }));
        })?;
        Ok(rows)
    }

    /// Swift `abandon`: an execution that owns no Job, at the generation the
    /// caller last read, stops orchestrating. This never cancels a Job, and
    /// a terminal execution is answered as it is, without a write.
    fn abandon(
        &self,
        id: &str,
        expected: i64,
        engine: &AgentEngine<'_>,
    ) -> Result<Value, WireError> {
        let mut record = self
            .load(id)?
            .ok_or_else(|| failure("resourceNotFound", "execution does not exist"))?;
        let owned = |job: &str| Map::from_iter([("jobId".into(), json!(job))]);
        if let Some(submission) = &record.submission
            && let Some(job) = Self::accepted(engine.jobs, submission)?
        {
            return Err(failure_with(
                "resourceConflict",
                "execution already owns a Job; use explicit job cancel",
                owned(&job),
            ));
        }
        if let Some(job) = &record.job {
            return Err(failure_with(
                "resourceConflict",
                "execution already owns a Job",
                owned(job),
            ));
        }
        if record.generation != expected {
            return Err(failure("resourceConflict", "execution generation changed"));
        }
        if !TERMINAL.contains(&record.state.as_str()) {
            record.state = "abandoned".into();
            record.expire_waiting();
            self.commit(&mut record)?;
        }
        Ok(record.projection())
    }

    /// Swift `finishJob`: once the owned Job's run returns, the execution
    /// records the state it reached. A lost publication is recovered by a
    /// later status read, so a failure here changes nothing.
    pub fn finish(&self, start: &AgentStart, jobs: &JobStore) {
        let Ok(_gate) = self.gate.lock() else {
            return;
        };
        let (Ok(owned), Ok(Some(mut record))) =
            (jobs.read_snapshot(&start.job), self.load(&start.execution))
        else {
            return;
        };
        if record.job.as_deref() != Some(start.job.as_str()) {
            return;
        }
        record.state = if terminal(&owned.state) {
            "completed"
        } else {
            "jobOwned"
        }
        .into();
        record.unknown = owned.outcome_unknown();
        record.job_state = Some(owned.state);
        let _ = self.commit(&mut record);
    }

    /// Swift `executionResultProjection`: the owned Job's state and next
    /// action over the execution's answer and, once the Job is terminal, its
    /// evidence and verified Artifacts.
    pub fn project(
        answer: Value,
        jobs: &JobStore,
        reader: &JobResultReader<'_>,
    ) -> Result<Value, WireError> {
        let Value::Object(mut fields) = answer else {
            return Ok(answer);
        };
        let Some(job) = fields
            .get("jobId")
            .and_then(Value::as_str)
            .map(str::to_owned)
        else {
            return Ok(Value::Object(fields));
        };
        let record = jobs.read_snapshot(&job).map_err(|_| internal(UNREADABLE))?;
        let status = record.status();
        let is_terminal = terminal(&record.state);
        fields.insert("jobState".into(), json!(record.state));
        fields.insert("outcomeUnknown".into(), json!(record.outcome_unknown()));
        fields.insert(
            "state".into(),
            json!(if is_terminal { "completed" } else { "jobOwned" }),
        );
        fields.insert("nextAction".into(), status["nextAction"].clone());
        fields.insert(
            "job".into(),
            json!({"jobId": job, "state": record.state, "outcome": status["outcome"],
                "outcomeUnknown": record.outcome_unknown(), "waitingForHuman": false,
                "outstandingResidueCount": record.residues(),
                "sessionPublication": status["sessionPublication"]}),
        );
        if is_terminal {
            let evidence = reader.agent_evidence(&record);
            fields.insert("artifacts".into(), evidence["artifacts"].clone());
            fields.insert("evidence".into(), evidence);
        }
        Ok(Value::Object(fields))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn base64_round_trips_foundation_padding() {
        for (bytes, text) in [
            (&b""[..], ""),
            (b"f", "Zg=="),
            (b"fo", "Zm8="),
            (b"foo", "Zm9v"),
            (b"foob", "Zm9vYg=="),
        ] {
            assert_eq!(base64(bytes), text);
            assert_eq!(unbase64(text).unwrap(), bytes);
        }
        for text in ["Zg=", "Z===", "Zg==Zg==", "Zm9v!"] {
            assert!(unbase64(text).is_none(), "{text}");
        }
    }

    #[test]
    fn intents_are_refused_with_swift_codes() {
        let intent = |fields: Value| Intent::parse(fields.as_object().unwrap(), true);
        let base = json!({"schemaVersion": INTENT_SCHEMA, "executionId": "gj1-observe",
            "operation": "observe.device@1", "inputs": {}, "maximumWaitMilliseconds": "300000",
            "target": {"targetId": "TGT-3ba3f5f43b92"}});
        let parsed = intent(base.clone()).unwrap();
        assert_eq!(
            parsed.fingerprint().unwrap(),
            "31e369bb6a862bd7e28c00f868ba8247d784cf1090c7a75e7d2c2ecde78d8560"
        );
        for (change, code) in [
            (json!({"maximumWaitMilliseconds": "0"}), "invalidInput"),
            (
                json!({"maximumWaitMilliseconds": "0300000"}),
                "invalidInput",
            ),
            (json!({"operation": "observe.device@2"}), "invalidInput"),
            (json!({"executionId": "-bad"}), "invalidInput"),
            (
                json!({"requestedOutputs": ["derivedArtifacts", "derivedArtifacts"]}),
                "invalidInput",
            ),
            (
                json!({"target": {"targetId": "TGT-3ba3f5f43b92", "expectedBindingRevision": 0}}),
                "invalidInput",
            ),
            (json!({"idempotencyKey": "short"}), "invalidInput"),
        ] {
            let mut fields = base.clone();
            for (key, value) in change.as_object().unwrap() {
                fields[key] = value.clone();
            }
            assert_eq!(intent(fields).unwrap_err().code, code);
        }
    }

    /// The Swift physical-assistance oracle's execution records
    /// (`rust/tests/fixtures/agent-human-action`).
    const CONNECT: &str = include_str!(
        "../../../tests/fixtures/agent-human-action/agent-executions/execution-a5413dfa3f543ece541da5ac39e28bd399708adaa4524a3f3e74d44129373b27.json"
    );
    const TRUST: &str = include_str!(
        "../../../tests/fixtures/agent-human-action/agent-executions/execution-9be87d0b82afa6b6f432df5cd89bb755326fea7489acf981de9d32401698e564.json"
    );
    const AMBIGUOUS: &str = include_str!(
        "../../../tests/fixtures/agent-human-action/agent-executions/execution-f2c43a6fa56aac7e64e76e036fd10bb45bb28d77d51013efca02783d6f3d8526.json"
    );
    const UNPROVEN: &str = include_str!(
        "../../../tests/fixtures/agent-human-action/agent-executions/execution-458317a2eb34654f014beb0284270b42c104c4182c7079c4f6b6f30ec4487fc9.json"
    );

    /// The oracle's text with each identity it labelled (`<har-2>`) read as
    /// a valid one of its kind (`har-00000000-0000-4000-8000-000000000002`).
    fn unlabelled(text: &str) -> String {
        let mut out = String::new();
        let mut rest = text;
        while let Some(at) = rest.find('<') {
            out.push_str(&rest[..at]);
            let tail = &rest[at + 1..];
            let label = ["har", "resume", "candidate", "obs"]
                .iter()
                .find_map(|kind| {
                    let digits = tail.strip_prefix(kind)?.strip_prefix('-')?;
                    let end = digits.find('>')?;
                    let number: u64 = digits[..end].parse().ok()?;
                    Some((
                        format!("{kind}-00000000-0000-4000-8000-{number:012}"),
                        kind.len() + end + 2,
                    ))
                });
            match label {
                Some((identity, used)) => {
                    out.push_str(&identity);
                    rest = &tail[used..];
                }
                None => {
                    out.push('<');
                    rest = tail;
                }
            }
        }
        out + rest
    }

    fn record(text: &str) -> Record {
        Record::decode(unlabelled(text).as_bytes()).expect("Swift's record reads")
    }

    #[test]
    fn swift_physical_assistance_records_round_trip_byte_for_byte() {
        for text in [CONNECT, TRUST, AMBIGUOUS, UNPROVEN] {
            let bytes = session_json::encode(&record(text).value()).unwrap();
            assert_eq!(String::from_utf8(bytes).unwrap(), unlabelled(text));
        }
    }

    #[test]
    fn waiting_and_abandoned_executions_project_as_swift_answered() {
        let cases: Value = serde_json::from_str(&unlabelled(include_str!(
            "../../../tests/fixtures/agent-human-action/cases.json"
        )))
        .unwrap();
        let answer = |name: &str| {
            cases["exchanges"]
                .as_array()
                .unwrap()
                .iter()
                .find(|exchange| exchange["name"] == name)
                .unwrap()["answer"]["result"]
                .clone()
        };
        assert_eq!(record(AMBIGUOUS).projection(), answer("ambiguous.run"));
        assert_eq!(record(TRUST).projection(), answer("trust.abandon"));
        // A resolved action is no longer projected; the Job is read next.
        let connect = record(CONNECT).projection();
        assert_eq!(connect["humanAction"], Value::Null);
        assert_eq!(connect["nextAction"]["kind"], "readResult");
    }

    #[test]
    fn actions_swift_would_not_read_are_refused() {
        let waiting: Value = serde_json::from_str(&unlabelled(AMBIGUOUS)).unwrap();
        let refused = |change: &dyn Fn(&mut Value)| {
            let mut value = waiting.clone();
            change(&mut value);
            Record::decode(&serde_json::to_vec(&value).unwrap()).is_none()
        };
        assert!(!refused(&|_| ()));
        // A waiting action while the execution does not wait.
        assert!(refused(&|value| value["state"] = json!("orchestrating")));
        // An action past the execution's deadline.
        assert!(refused(&|value| {
            value["actions"][0]["expiresAt"] = json!("2026-09-14T00:06:00.000Z")
        }));
        // A device selection that names one observation.
        assert!(refused(&|value| {
            value["actions"][0]["observation"] =
                value["actions"][0]["selections"][0]["observation"].clone()
        }));
        // Two waiting actions.
        assert!(refused(&|value| {
            let action = value["actions"][0].clone();
            value["actions"].as_array_mut().unwrap().push(action);
        }));
        // A kind Swift does not publish.
        assert!(refused(
            &|value| value["actions"][0]["kind"] = json!("rebootDevice")
        ));
        // A resolution the action never offered.
        assert!(refused(&|value| {
            value["actions"][0]["status"] = json!("resolvedByFreshProbe");
            value["actions"][0]["resolvedSelection"] = json!("candidate-unknown");
            value["state"] = json!("orchestrating");
        }));
    }
}
