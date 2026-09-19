//! Swift `RuntimeHDCControlActionCoordinator` over
//! `RuntimeHDCControlActionStore` (CHG-2026-074, TASK-XPA-014): the Runtime's
//! HDC control-action owner, which the daemon composes once its HDC server
//! host has started, in its private `hdc-control-actions` directory. It
//! answers `runtime.hdc.impact-preview` — a durable action for one exact
//! restart intent, observed once into an immutable preview — and the records
//! `control-action.list`, `.show` and `.reconcile` read through the union
//! owner (`control_action.rs`).
//!
//! What is here is what an action holds before anyone asks to restart:
//! the intent and its fingerprint (`HDCControlActionIntent`), the impact and
//! its preview with their canonical collections and digest
//! (`HDCControlImpact`, `HDCControlActionPreview`), the record in the states
//! `observing`, `previewReady`, `blocked`, `expired` and `previewDrifted`
//! (`HDCControlActionRecord`), the store's transaction lock and CAS
//! transitions, and the coordinator's preview, reconcile and age refresh.
//! Restart, the impact approval human action, its console challenge, the
//! lifecycle audit and the recovery of an interrupted lifecycle are not: a
//! record carrying an approval, a challenge, a receipt or an audit is refused
//! as unreadable, and this owner never writes one.
//!
//! The owner serves one request at a time. Swift's actor lets another
//! request run while a preview awaits its observation and joins the
//! observation in flight; here that request waits instead.
use crate::control_action::{identifier, refused, unreadable};
use crate::control_action_store::{ActionStore, StoredAction};
use crate::control_action_value::{
    digest, exact_keys, generation, hash, one_of, optional_digest, optional_generation,
    optional_identifier, optional_text, owner, record_unreadable, time, timestamp,
};
use arkdeck_contract::{CATALOG_DIGEST, WireError, canonical_json, sha256_hex};
use arkdeck_platform::HostDirectory;
use serde_json::{Map, Value, json};
use std::collections::{BTreeMap, BTreeSet};
use std::io;
use std::path::Path;

/// An action's and its preview's life: `expiresAt` is `createdAt` plus 300 s.
const LIFETIME_MS: u64 = 300_000;
/// `HDCControlImpact`'s canonical bound.
const MAX_IMPACT: usize = 512 * 1024;
/// `HDCControlValue.ids` and `.rows`.
const MAX_COLLECTION: usize = 4096;

/// Every state a record may hold.
pub(crate) const STATES: [&str; 12] = [
    "observing",
    "previewReady",
    "awaitingImpactApproval",
    "approvalRecorded",
    "dispatchPrepared",
    "dispatching",
    "succeeded",
    "failed",
    "outcomeUnknown",
    "blocked",
    "expired",
    "previewDrifted",
];
/// The states a record needs its preview in.
const READY: [&str; 8] = [
    "previewReady",
    "awaitingImpactApproval",
    "approvalRecorded",
    "dispatchPrepared",
    "dispatching",
    "succeeded",
    "failed",
    "outcomeUnknown",
];
/// The states `invalidated` and the age refresh move.
const OPEN: [&str; 5] = [
    "observing",
    "previewReady",
    "awaitingImpactApproval",
    "approvalRecorded",
    "blocked",
];

// --- intent (`HDCControlActionIntent`) ------------------------------------

/// One exact restart intent: the caller's request identity, the endpoint
/// reference and the server generation the caller expects.
#[derive(Clone, Debug, PartialEq, Eq)]
struct Intent {
    request: String,
    endpoint: String,
    generation: u64,
}

impl Intent {
    fn parse(fields: &Map<String, Value>) -> Result<Self, WireError> {
        let text = |key: &str| fields.get(key).and_then(Value::as_str);
        let parsed = (|| {
            if !exact_keys(
                fields,
                &[
                    "action",
                    "actionRequestId",
                    "expectedServerGeneration",
                    "serverEndpointRef",
                ],
            ) || text("action") != Some("restart")
            {
                return None;
            }
            let request = text("actionRequestId").filter(|request| identifier(request))?;
            let endpoint = text("serverEndpointRef")
                .filter(|endpoint| endpoint.strip_prefix("hdc-endpoint:").is_some_and(digest))?;
            Some(Self {
                request: request.to_owned(),
                endpoint: endpoint.to_owned(),
                generation: generation(text("expectedServerGeneration")?)?,
            })
        })();
        parsed.ok_or_else(|| {
            refused(
                "invalidInput",
                "an exact restart intent and request identity are required",
            )
        })
    }

    fn request_value(&self) -> Value {
        json!({
            "actionRequestId": self.request, "action": "restart",
            "serverEndpointRef": self.endpoint,
            "expectedServerGeneration": self.generation.to_string(),
        })
    }

    /// The fingerprint covers the intent, never the request identity.
    fn fingerprint(&self) -> Result<String, WireError> {
        hash(&json!({
            "schemaVersion": "arkdeck.hdc-control-intent/1", "kind": "hdcLifecycle",
            "action": "restart", "serverEndpointRef": self.endpoint,
            "expectedServerGeneration": self.generation.to_string(),
        }))
    }
}

// --- impact (`HDCControlImpact`) ------------------------------------------

/// The impact of restarting the server at one endpoint, as only the Runtime
/// constructs it: closed members, canonical collections, bounded bytes.
#[derive(Clone, Debug, PartialEq)]
pub struct Impact {
    value: Map<String, Value>,
}

const IMPACT_KEYS: [&str; 15] = [
    "serverEndpointRef",
    "endpoint",
    "serverOwnership",
    "serverGeneration",
    "tool",
    "serverHealth",
    "serverVersion",
    "affectedTargetIds",
    "affectedJobIds",
    "detectedOtherClientIds",
    "otherClientsMayExist",
    "affectedDeviceObservations",
    "criticalJobGate",
    "interruption",
    "recovery",
];

fn drifted(message: &str) -> WireError {
    refused("factsDrifted", message)
}

/// Sorted distinct identities.
fn ids(value: Option<&Value>) -> Result<Value, WireError> {
    let Some(Value::Array(rows)) = value.filter(|value| {
        value
            .as_array()
            .is_some_and(|rows| rows.len() <= MAX_COLLECTION)
    }) else {
        return Err(drifted("impact ID collection is unavailable or too large"));
    };
    let mut values = BTreeSet::new();
    for row in rows {
        match row.as_str().filter(|id| identifier(id)) {
            Some(id) => {
                values.insert(id.to_owned());
            }
            None => return Err(drifted("impact collection has an invalid identity")),
        }
    }
    Ok(json!(values.into_iter().collect::<Vec<_>>()))
}

/// Rows distinct by their identity, equal rows collapsed, sorted by identity.
fn rows(
    value: Option<&Value>,
    key: impl Fn(&Map<String, Value>) -> Result<Vec<String>, WireError>,
) -> Result<Value, WireError> {
    let Some(Value::Array(rows)) = value.filter(|value| {
        value
            .as_array()
            .is_some_and(|rows| rows.len() <= MAX_COLLECTION)
    }) else {
        return Err(drifted("impact row collection is unavailable or too large"));
    };
    let mut unique: BTreeMap<Vec<String>, Value> = BTreeMap::new();
    for row in rows {
        let Value::Object(fields) = row else {
            return Err(drifted("impact row is not an object"));
        };
        let identity = key(fields)?;
        if unique.get(&identity).is_some_and(|old| old != row) {
            return Err(drifted(
                "the same impact identity carries conflicting facts",
            ));
        }
        unique.insert(identity, row.clone());
    }
    // A `Vec<String>` orders component by component in byte order, then
    // by length: Swift's comparator.
    Ok(Value::Array(unique.into_values().collect()))
}

fn device_key(row: &Map<String, Value>) -> Result<Vec<String>, WireError> {
    let id = row.get("observationId").and_then(Value::as_str);
    if exact_keys(
        row,
        &["observationId", "generation", "authorization", "health"],
    ) && id.is_some_and(identifier)
        && row
            .get("generation")
            .and_then(Value::as_str)
            .and_then(generation)
            .is_some()
        && one_of(
            row.get("authorization"),
            &["authorized", "unauthorized", "unknown"],
        )
        && one_of(row.get("health"), &["connected", "offline", "unknown"])
    {
        return Ok(vec![id.unwrap_or_default().to_owned()]);
    }
    Err(drifted(
        "device observation has no exact lifecycle identity",
    ))
}

fn blocker_key(row: &Map<String, Value>) -> Result<Vec<String>, WireError> {
    let job = row.get("jobId").and_then(Value::as_str);
    if exact_keys(
        row,
        &["jobId", "stepId", "state", "safeBoundary", "recovery"],
    ) && job.is_some_and(identifier)
        && optional_identifier(row.get("stepId"))
        && row
            .get("state")
            .and_then(Value::as_str)
            .is_some_and(identifier)
        && one_of(row.get("safeBoundary"), &["blocked", "unknown"])
        && one_of(
            row.get("recovery"),
            &[
                "waitForJob",
                "reconcileJob",
                "continueCleanup",
                "inspectJob",
            ],
        )
    {
        let step = row.get("stepId").and_then(Value::as_str).unwrap_or("");
        return Ok(vec![job.unwrap_or_default().to_owned(), step.to_owned()]);
    }
    Err(drifted("critical Job blocker is incomplete"))
}

fn validate_tool(value: Option<&Value>) -> Result<(), WireError> {
    let Some(Value::Object(tool)) = value else {
        return Err(drifted("selected tool facts are incomplete"));
    };
    if !(exact_keys(
        tool,
        &[
            "reference",
            "executablePath",
            "source",
            "sha256",
            "signature",
            "version",
            "trust",
        ],
    ) && optional_text(tool.get("reference"), 256)
        && optional_text(tool.get("executablePath"), 4096)
        && one_of(
            tool.get("source"),
            &["runtimeConfiguration", "bootstrapRegistry", "unknown"],
        )
        && optional_digest(tool.get("sha256"))
        && optional_text(tool.get("version"), 128)
        && one_of(tool.get("trust"), &["unverified", "verified", "unknown"]))
    {
        return Err(drifted("selected tool facts are incomplete"));
    }
    match tool.get("signature") {
        Some(Value::Null) => Ok(()),
        Some(Value::Object(signature))
            if exact_keys(
                signature,
                &[
                    "state",
                    "identifier",
                    "teamIdentifier",
                    "platformTrust",
                    "executionAssessment",
                ],
            ) && one_of(signature.get("state"), &["unsigned", "adHoc", "verified"])
                && optional_text(signature.get("identifier"), 256)
                && optional_text(signature.get("teamIdentifier"), 256)
                && signature.get("platformTrust") == Some(&json!("unverified"))
                && signature.get("executionAssessment") == Some(&json!("notPerformed")) =>
        {
            Ok(())
        }
        _ => Err(drifted("selected signature facts are incomplete")),
    }
}

impl Impact {
    /// Swift `HDCControlImpact.init`: the closed members, the tool and its
    /// signature, the canonical collections, the critical Job gate against its
    /// blockers and inventory, then the byte bound.
    pub fn new(source: Map<String, Value>) -> Result<Self, WireError> {
        let text = |key: &str| source.get(key).and_then(Value::as_str);
        let reference = text("serverEndpointRef");
        let endpoint = text("endpoint");
        let closed = exact_keys(&source, &IMPACT_KEYS)
            && reference.is_some_and(|reference| {
                reference.strip_prefix("hdc-endpoint:").is_some_and(digest)
            })
            && endpoint.is_some_and(|endpoint| {
                (1..=128).contains(&endpoint.len())
                    && endpoint.bytes().all(|byte| (33..=126).contains(&byte))
            })
            && reference.map(str::to_owned)
                == endpoint
                    .map(|endpoint| format!("hdc-endpoint:{}", sha256_hex(endpoint.as_bytes())))
            && one_of(
                source.get("serverOwnership"),
                &["arkDeckManaged", "external", "unknown"],
            )
            && optional_generation(source.get("serverGeneration"))
            && one_of(
                source.get("serverHealth"),
                &["healthy", "unavailable", "unknown"],
            )
            && optional_text(source.get("serverVersion"), 128)
            && source.get("otherClientsMayExist") == Some(&json!(true))
            && source.get("interruption")
                == Some(&json!({"kind": "hdcEndpointUnavailable", "affectsAllParticipants": true}))
            && source.get("recovery")
                == Some(&json!({"kind": "statusThenReconcile", "replayAllowed": false}));
        if !closed {
            return Err(drifted(
                "impact facts do not match the closed lifecycle schema",
            ));
        }
        validate_tool(source.get("tool"))?;
        let mut fields = source;
        for key in [
            "affectedTargetIds",
            "affectedJobIds",
            "detectedOtherClientIds",
        ] {
            let value = ids(fields.get(key))?;
            fields.insert(key.into(), value);
        }
        let observations = rows(fields.get("affectedDeviceObservations"), device_key)?;
        fields.insert("affectedDeviceObservations".into(), observations);
        let mut gate = match fields.get("criticalJobGate") {
            Some(Value::Object(gate))
                if exact_keys(gate, &["state", "blocking", "reasonCode"])
                    && one_of(gate.get("state"), &["clear", "blocked", "unknown"])
                    && optional_identifier(gate.get("reasonCode")) =>
            {
                gate.clone()
            }
            _ => return Err(drifted("critical Job gate is incomplete")),
        };
        let blocking = rows(gate.get("blocking"), blocker_key)?;
        gate.insert("blocking".into(), blocking.clone());
        let blockers = blocking.as_array().cloned().unwrap_or_default();
        let state = gate.get("state").and_then(Value::as_str);
        let reason_null = gate.get("reasonCode") == Some(&Value::Null);
        let Some(jobs) = fields.get("affectedJobIds").and_then(Value::as_array) else {
            return Err(drifted("critical Job gate contradicts its blockers"));
        };
        if !((state != Some("clear") || (blockers.is_empty() && reason_null))
            && (state == Some("clear") || !reason_null)
            && (state != Some("blocked") || !blockers.is_empty()))
        {
            return Err(drifted("critical Job gate contradicts its blockers"));
        }
        let jobs: BTreeSet<&str> = jobs.iter().filter_map(Value::as_str).collect();
        if !blockers.iter().all(|row| {
            row.get("jobId")
                .and_then(Value::as_str)
                .is_some_and(|job| jobs.contains(job))
        }) {
            return Err(drifted(
                "a critical Job is absent from the impact inventory",
            ));
        }
        fields.insert("criticalJobGate".into(), Value::Object(gate));
        let bytes = canonical_json(&Value::Object(fields.clone())).map_err(|_| unreadable())?;
        if bytes.len() > MAX_IMPACT {
            return Err(refused(
                "inputTooLarge",
                "lifecycle impact exceeds its bounded record",
            ));
        }
        Ok(Self { value: fields })
    }

    /// The members, canonical.
    pub fn value(&self) -> &Map<String, Value> {
        &self.value
    }

    fn critical_gate_is_clear(&self) -> bool {
        self.value
            .get("criticalJobGate")
            .and_then(|gate| gate.get("state"))
            == Some(&json!("clear"))
    }
}

// --- preview (`HDCControlActionPreview`) ----------------------------------

const PREVIEW_METADATA: [&str; 12] = [
    "schemaVersion",
    "controlActionId",
    "previewId",
    "kind",
    "action",
    "createdAt",
    "expiresAt",
    "owner",
    "confirmationRequired",
    "dispatchCount",
    "digestAlgorithm",
    "previewDigest",
];

/// The immutable preview: the impact with its identity and lifetime, and the
/// SHA-256 of the canonical bytes of all of it (`previewDigest`).
#[derive(Clone, Debug, PartialEq)]
struct Preview {
    value: Map<String, Value>,
    impact: Impact,
}

impl Preview {
    fn build(
        action: &str,
        preview: &str,
        created: &str,
        expires: &str,
        impact: &Impact,
    ) -> Result<Self, WireError> {
        let mut fields = impact.value.clone();
        for (key, value) in [
            ("schemaVersion", json!("arkdeck.hdc-control-preview/1")),
            ("controlActionId", json!(action)),
            ("previewId", json!(preview)),
            ("kind", json!("hdcLifecycle")),
            ("action", json!("restart")),
            ("createdAt", json!(created)),
            ("expiresAt", json!(expires)),
            ("owner", owner(action)),
            ("confirmationRequired", json!(true)),
            ("dispatchCount", json!(0)),
            ("digestAlgorithm", json!("sha256-jcs")),
        ] {
            fields.insert(key.into(), value);
        }
        let digest = hash(&Value::Object(fields.clone()))?;
        fields.insert("previewDigest".into(), json!(digest));
        Self::parse(fields)
    }

    fn parse(value: Map<String, Value>) -> Result<Self, WireError> {
        let text = |key: &str| value.get(key).and_then(Value::as_str);
        let id = text("controlActionId").filter(|id| identifier(id));
        let start = text("createdAt").and_then(time);
        let end = text("expiresAt").and_then(time);
        let mut unsigned = value.clone();
        unsigned.remove("previewDigest");
        let valid = value.get("schemaVersion") == Some(&json!("arkdeck.hdc-control-preview/1"))
            && value.get("kind") == Some(&json!("hdcLifecycle"))
            && value.get("action") == Some(&json!("restart"))
            && value.get("confirmationRequired") == Some(&json!(true))
            && value.get("dispatchCount") == Some(&json!(0))
            && value.get("digestAlgorithm") == Some(&json!("sha256-jcs"))
            && id.is_some()
            && text("previewId").is_some_and(identifier)
            && value.get("owner") == id.map(owner).as_ref()
            && matches!((start, end), (Some(start), Some(end)) if end > start && end - start <= LIFETIME_MS)
            && text("previewDigest").map(str::to_owned) == Some(hash(&Value::Object(unsigned))?);
        if !valid {
            return Err(refused(
                "recordUnreadable",
                "control-action preview failed identity or digest validation",
            ));
        }
        let facts: Map<String, Value> = value
            .iter()
            .filter(|(key, _)| !PREVIEW_METADATA.contains(&key.as_str()))
            .map(|(key, value)| (key.clone(), value.clone()))
            .collect();
        let impact = Impact::new(facts.clone())?;
        if impact.value != facts {
            return Err(refused(
                "recordUnreadable",
                "stored impact collections are not canonical",
            ));
        }
        Ok(Self { value, impact })
    }
}

// --- record (`HDCControlActionRecord`) ------------------------------------

const RECORD_KEYS: [&str; 20] = [
    "schemaVersion",
    "controlActionId",
    "actionRequestId",
    "request",
    "requestFingerprint",
    "fingerprintAlgorithm",
    "catalogDigest",
    "runtimeEpoch",
    "generation",
    "state",
    "createdAt",
    "expiresAt",
    "lastObservedAt",
    "preview",
    "blockerReasonCode",
    "observationRelations",
    "humanAction",
    "interactionChallenge",
    "interactionReceipt",
    "lifecycleAudit",
];

/// One durable control action.
#[derive(Clone, Debug, PartialEq)]
pub struct Record {
    value: Map<String, Value>,
    intent: Intent,
    preview: Option<Preview>,
    id: String,
    generation: u64,
    state: String,
    created: String,
    expires: String,
    observed: String,
    epoch: String,
}

/// Swift's continuity binding, private to the record: one proved USB relation
/// of an observation the preview names.
fn relation_id(relation: &Value) -> Option<(String, String)> {
    let fields = relation.as_object()?;
    let text = |key: &str| fields.get(key).and_then(Value::as_str);
    let canonical = |text: &str| text.parse::<u64>().ok().filter(|n| n.to_string() == text);
    let id = text("observationId").filter(|id| identifier(id))?;
    let revision = text("generation").filter(|text| generation(text).is_some())?;
    let port = |key: &str| {
        fields
            .get(key)
            .and_then(Value::as_i64)
            .is_some_and(|value| (1..=65535).contains(&value))
    };
    (exact_keys(
        fields,
        &[
            "observationId",
            "generation",
            "serial",
            "location",
            "attachmentId",
            "vendorId",
            "productId",
        ],
    ) && optional_text(fields.get("serial"), 1024)
        && fields.get("serial") != Some(&Value::Null)
        && text("location").and_then(canonical).is_some()
        && text("attachmentId")
            .and_then(canonical)
            .is_some_and(|attachment| attachment > 0)
        && port("vendorId")
        && port("productId"))
    .then(|| (id.to_owned(), revision.to_owned()))
}

impl Record {
    fn new(
        intent: &Intent,
        catalog: &str,
        epoch: &str,
        now: u64,
        action_id: &str,
    ) -> Result<Self, WireError> {
        let created = timestamp(now);
        let start = time(&created).ok_or_else(|| {
            record_unreadable("control action requires a representable creation time")
        })?;
        let Value::Object(value) = json!({
            "schemaVersion": "arkdeck.runtime-hdc-control-action/1",
            "controlActionId": format!("control-action-{action_id}"),
            "actionRequestId": intent.request, "request": intent.request_value(),
            "requestFingerprint": intent.fingerprint()?, "fingerprintAlgorithm": "sha256-jcs",
            "catalogDigest": catalog, "runtimeEpoch": epoch,
            "generation": "1", "state": "observing", "createdAt": created,
            "expiresAt": timestamp(start + LIFETIME_MS), "lastObservedAt": created,
            "preview": null, "blockerReasonCode": null, "observationRelations": [],
            "humanAction": null, "interactionChallenge": null,
            "interactionReceipt": null, "lifecycleAudit": [],
        }) else {
            unreachable!("an object literal")
        };
        Self::parse(value)
    }

    /// Swift `HDCControlActionRecord.init(value:)`, for the records this
    /// owner writes: an approval, a challenge, a receipt or a lifecycle audit
    /// is not read here.
    fn parse(value: Map<String, Value>) -> Result<Self, WireError> {
        let text = |key: &str| value.get(key).and_then(Value::as_str);
        let invalid = || record_unreadable("control-action record has invalid identity or state");
        let id = text("controlActionId")
            .filter(|id| identifier(id))
            .ok_or_else(invalid)?;
        let request = value
            .get("request")
            .and_then(Value::as_object)
            .ok_or_else(invalid)?;
        let epoch = text("runtimeEpoch")
            .filter(|epoch| identifier(epoch))
            .ok_or_else(invalid)?;
        let generation = text("generation")
            .and_then(generation)
            .ok_or_else(invalid)?;
        let state = text("state")
            .filter(|state| STATES.contains(state))
            .ok_or_else(invalid)?;
        let created = text("createdAt").ok_or_else(invalid)?;
        let start = time(created).ok_or_else(invalid)?;
        let expires = text("expiresAt").ok_or_else(invalid)?;
        let end = time(expires).ok_or_else(invalid)?;
        let observed = text("lastObservedAt").ok_or_else(invalid)?;
        let latest = time(observed).ok_or_else(invalid)?;
        let relations = value
            .get("observationRelations")
            .and_then(Value::as_array)
            .ok_or_else(invalid)?;
        if !exact_keys(&value, &RECORD_KEYS)
            || text("schemaVersion") != Some("arkdeck.runtime-hdc-control-action/1")
            || text("fingerprintAlgorithm") != Some("sha256-jcs")
            || !text("catalogDigest").is_some_and(digest)
            || end.checked_sub(start) != Some(LIFETIME_MS)
            || latest < start
            || !optional_identifier(value.get("blockerReasonCode"))
            || relations.len() > 1000
        {
            return Err(invalid());
        }
        let intent = Intent::parse(request)?;
        if text("actionRequestId") != Some(intent.request.as_str())
            || text("requestFingerprint") != Some(intent.fingerprint()?.as_str())
        {
            return Err(record_unreadable(
                "control-action intent fingerprint is invalid",
            ));
        }
        let preview = match value.get("preview") {
            Some(Value::Null) => None,
            Some(Value::Object(fields)) => Some(Preview::parse(fields.clone())?),
            _ => {
                return Err(record_unreadable("control-action preview is malformed"));
            }
        };
        // What only an impact approval and its lifecycle hold.
        if value.get("humanAction") != Some(&Value::Null)
            || value.get("interactionChallenge") != Some(&Value::Null)
            || value.get("interactionReceipt") != Some(&Value::Null)
            || value.get("lifecycleAudit") != Some(&json!([]))
        {
            return Err(unreadable());
        }
        let blocker = value.get("blockerReasonCode");
        if let Some(preview) = &preview {
            if preview.value.get("controlActionId") != Some(&json!(id))
                || preview.value.get("createdAt") != Some(&json!(created))
                || preview.value.get("expiresAt") != Some(&json!(expires))
                || preview.impact.value.get("serverEndpointRef") != Some(&json!(intent.endpoint))
                || state == "observing"
            {
                return Err(record_unreadable(
                    "control-action preview belongs to another owner or intent",
                ));
            }
        } else if READY.contains(&state) {
            return Err(record_unreadable("ready control action has no preview"));
        }
        if READY.contains(&state) {
            let live = [
                "previewReady",
                "awaitingImpactApproval",
                "approvalRecorded",
                "dispatchPrepared",
            ]
            .contains(&state);
            let expected = match state {
                "failed" => json!("hdc.lifecycleFailedBeforeLaunch"),
                "outcomeUnknown" => json!("hdc.lifecycleOutcomeUnknown"),
                _ => Value::Null,
            };
            let complete = preview.as_ref().is_some_and(|preview| {
                preview.impact.critical_gate_is_clear()
                    && preview.impact.value.get("serverGeneration")
                        == Some(&json!(intent.generation.to_string()))
                    && preview.impact.value.get("serverHealth") == Some(&json!("healthy"))
            }) && blocker == Some(&expected)
                && (!live || latest < end);
            if !complete {
                return Err(record_unreadable("ready preview lacks its complete gate"));
            }
        } else if state == "observing" {
            if blocker != Some(&Value::Null) || !relations.is_empty() {
                return Err(record_unreadable("unobserved action has resolved facts"));
            }
        } else if blocker == Some(&Value::Null)
            && !["succeeded", "failed", "outcomeUnknown"].contains(&state)
        {
            return Err(record_unreadable("blocked control action has no reason"));
        }
        if state == "awaitingImpactApproval" {
            return Err(record_unreadable(
                "impact approval is not bound to its exact preview generation",
            ));
        }
        if [
            "approvalRecorded",
            "dispatchPrepared",
            "dispatching",
            "succeeded",
            "failed",
            "outcomeUnknown",
        ]
        .contains(&state)
        {
            return Err(record_unreadable(
                "advanced control action lacks interactive approval proof",
            ));
        }
        let mut bound = BTreeSet::new();
        for relation in relations {
            let Some((observation, revision)) =
                relation_id(relation).filter(|(observation, _)| !bound.contains(observation))
            else {
                return Err(record_unreadable(
                    "observation continuity binding is malformed",
                ));
            };
            let named = preview.as_ref().is_some_and(|preview| {
                preview
                    .impact
                    .value
                    .get("affectedDeviceObservations")
                    .and_then(Value::as_array)
                    .is_some_and(|rows| {
                        rows.iter().any(|row| {
                            row.get("observationId") == Some(&json!(observation))
                                && row.get("generation") == Some(&json!(revision))
                        })
                    })
            });
            if !named {
                return Err(record_unreadable(
                    "continuity binding is absent from its preview",
                ));
            }
            bound.insert(observation);
        }
        if READY.contains(&state)
            && let Some(rows) = preview.as_ref().and_then(|preview| {
                preview
                    .impact
                    .value
                    .get("affectedDeviceObservations")
                    .and_then(Value::as_array)
            })
        {
            let observed: BTreeSet<String> = rows
                .iter()
                .filter_map(|row| row.get("observationId").and_then(Value::as_str))
                .map(str::to_owned)
                .collect();
            if observed != bound {
                return Err(record_unreadable(
                    "ready preview lacks durable observation relations",
                ));
            }
        }
        Ok(Self {
            id: id.to_owned(),
            epoch: epoch.to_owned(),
            generation,
            state: state.to_owned(),
            created: created.to_owned(),
            expires: expires.to_owned(),
            observed: observed.to_owned(),
            intent,
            preview,
            value,
        })
    }

    /// The next generation's fields, observed `now`.
    fn advanced(&self, now: u64) -> Result<Map<String, Value>, WireError> {
        if self.generation >= i64::MAX as u64 || time(&self.observed).is_none_or(|last| now < last)
        {
            return Err(refused(
                "orchestrationClockUntrusted",
                "control-action time moved behind its durable observation",
            ));
        }
        let mut fields = self.value.clone();
        fields.insert(
            "generation".into(),
            json!((self.generation + 1).to_string()),
        );
        fields.insert("lastObservedAt".into(), json!(timestamp(now)));
        Ok(fields)
    }

    /// The first and only preview, and with it `previewReady` or `blocked`.
    fn publishing(
        &self,
        reading: &ImpactReading,
        blocker: Option<&str>,
        now: u64,
        preview_id: &str,
    ) -> Result<Self, WireError> {
        if self.state != "observing" || self.preview.is_some() {
            return Err(refused(
                "resourceConflict",
                "the immutable preview has already been published",
            ));
        }
        let preview = Preview::build(
            &self.id,
            &format!("preview-{preview_id}"),
            &self.created,
            &self.expires,
            &reading.impact,
        )?;
        let mut fields = self.advanced(now)?;
        fields.insert("preview".into(), Value::Object(preview.value));
        fields.insert(
            "observationRelations".into(),
            Value::Array(reading.relations.clone()),
        );
        fields.insert(
            "state".into(),
            json!(if blocker.is_none() {
                "previewReady"
            } else {
                "blocked"
            }),
        );
        fields.insert("blockerReasonCode".into(), json!(blocker));
        Self::parse(fields)
    }

    /// `expired` or `previewDrifted` for `reason`; a record past these states
    /// is itself.
    fn invalidated(&self, reason: &str, expired: bool, now: u64) -> Result<Self, WireError> {
        if !OPEN.contains(&self.state.as_str()) {
            return Ok(self.clone());
        }
        let mut fields = self.advanced(now)?;
        fields.insert(
            "state".into(),
            json!(if expired { "expired" } else { "previewDrifted" }),
        );
        fields.insert("blockerReasonCode".into(), json!(reason));
        Self::parse(fields)
    }

    /// What `control-action.show`, `.list` and `.reconcile` answer.
    pub fn projection(&self) -> Value {
        let id = self.id.as_str();
        let blocker = self
            .value
            .get("blockerReasonCode")
            .cloned()
            .unwrap_or(Value::Null);
        let kind = match self.state.as_str() {
            "awaitingImpactApproval" => "humanAction",
            "previewReady" => "inspectControlAction",
            "succeeded" | "failed" => "none",
            _ => "reconcile",
        };
        let reason = match self.state.as_str() {
            "awaitingImpactApproval" => json!("policy.impactApprovalRequired"),
            "succeeded" => json!("controlAction.completed"),
            "failed" => json!("hdc.lifecycleFailedBeforeLaunch"),
            "outcomeUnknown" => json!("hdc.lifecycleOutcomeUnknown"),
            _ if blocker.is_null() => json!("controlAction.previewAvailable"),
            _ => blocker.clone(),
        };
        json!({
            "schemaVersion": "arkdeck.control-action/1", "controlActionId": id,
            "actionRequestId": self.intent.request,
            "requestFingerprint": self.value.get("requestFingerprint"),
            "fingerprintAlgorithm": "sha256-jcs", "kind": "hdcLifecycle", "action": "restart",
            "owner": owner(id), "generation": self.generation.to_string(), "state": self.state,
            "catalogDigest": self.value.get("catalogDigest"), "createdAt": self.created,
            "expiresAt": self.expires, "lastObservedAt": self.observed,
            "preview": self.preview.as_ref().map(|preview| Value::Object(preview.value.clone())),
            "blockerReasonCode": blocker, "humanAction": null, "dispatchCount": 0,
            "nextAction": {"kind": kind, "owner": owner(id), "resource": owner(id), "reasonCode": reason},
        })
    }

    /// The action's identity.
    pub fn id(&self) -> &str {
        &self.id
    }
}

// --- store (`RuntimeHDCControlActionStore`) -------------------------------

impl StoredAction for Record {
    fn parse(value: Map<String, Value>) -> Result<Self, WireError> {
        Record::parse(value)
    }

    fn value(&self) -> &Map<String, Value> {
        &self.value
    }

    fn id(&self) -> &str {
        &self.id
    }

    fn request(&self) -> &str {
        &self.intent.request
    }

    fn generation(&self) -> u64 {
        self.generation
    }

    fn created(&self) -> &str {
        &self.created
    }

    /// Never its intent, lifetime, epoch, catalog or published preview, and
    /// only over a permitted transition.
    fn replaces(previous: &Self, next: &Self) -> bool {
        previous.intent == next.intent
            && previous.created == next.created
            && previous.expires == next.expires
            && previous.epoch == next.epoch
            && previous.value.get("catalogDigest") == next.value.get("catalogDigest")
            && (previous.preview.is_none() || previous.preview == next.preview)
            && (previous.preview.is_none()
                || previous.value.get("observationRelations")
                    == next.value.get("observationRelations"))
            && time(&previous.observed)
                .zip(time(&next.observed))
                .is_some_and(|(old, new)| new >= old)
            && permits(&previous.state, &next.state)
    }
}

/// The owner's records, one document per request identity, changed only
/// under the transaction lock beside them.
struct Store(ActionStore<Record>);

impl Store {
    fn open(path: &Path) -> io::Result<Self> {
        Ok(Self(ActionStore::open(path)?))
    }

    fn begin(
        &self,
        intent: &Intent,
        catalog: &str,
        epoch: &str,
        now: u64,
        action_id: &str,
    ) -> Result<Record, WireError> {
        self.0.begin(
            &intent.request,
            |existing| existing.intent == *intent,
            || Record::new(intent, catalog, epoch, now, action_id),
        )
    }

    fn load(&self, id: &str) -> Result<Option<Record>, WireError> {
        self.0.load(id)
    }

    fn load_request(&self, request: &str) -> Result<Option<Record>, WireError> {
        self.0.load_request(request)
    }

    /// Creation time, then identity in byte order.
    fn list(&self) -> Result<Vec<Record>, WireError> {
        self.0.list()
    }

    /// The exact next generation of the same action, over a permitted
    /// transition, never replacing its identity, intent, lifetime, epoch,
    /// catalog or published preview.
    fn replace(&self, record: &Record, expected: u64) -> Result<(), WireError> {
        self.0.replace(record, expected)
    }
}

/// `RuntimeHDCControlActionStore.permitsTransition`.
fn permits(from: &str, to: &str) -> bool {
    let allowed: &[&str] = match from {
        "observing" => &["previewReady", "blocked", "expired", "previewDrifted"],
        "previewReady" => &["awaitingImpactApproval", "expired", "previewDrifted"],
        "awaitingImpactApproval" => &[
            "awaitingImpactApproval",
            "approvalRecorded",
            "expired",
            "previewDrifted",
        ],
        "approvalRecorded" => &[
            "approvalRecorded",
            "dispatchPrepared",
            "expired",
            "previewDrifted",
        ],
        "dispatchPrepared" => &["dispatchPrepared", "dispatching", "failed"],
        "dispatching" => &["dispatching", "succeeded", "outcomeUnknown"],
        "blocked" => &["expired", "previewDrifted"],
        _ => &[],
    };
    allowed.contains(&to)
}

// --- coordinator (`RuntimeHDCControlActionCoordinator`) -------------------

/// One reading of the impact source: the impact, the private continuity
/// relations of its observations, and the source's own reason, if any, that
/// the preview cannot be approved.
#[derive(Clone, Debug)]
pub struct ImpactReading {
    pub impact: Impact,
    pub relations: Vec<Value>,
    pub blocker: Option<String>,
}

/// Swift `HDCControlImpactObserving`: the Runtime's own observation of what a
/// restart of its server would affect. It takes no caller fact.
pub trait ImpactSource {
    /// The endpoint the source observes, as a reference.
    fn endpoint_reference(&self) -> String;
    /// A fresh reading. Any failure — the reason is diagnostic only — leaves
    /// the impact unavailable.
    fn read_impact(&self) -> Result<ImpactReading, String>;
}

/// What an owner reads besides its records: the epoch of this Runtime start,
/// the catalog digest its actions bind, its clock (milliseconds since the
/// Unix epoch) and where fresh identities come from.
pub struct OwnerContext {
    pub epoch: String,
    pub catalog: String,
    pub clock: Box<dyn Fn() -> Option<u64> + Send + Sync>,
    pub uuid: Box<dyn Fn() -> Result<String, WireError> + Send + Sync>,
}

impl OwnerContext {
    /// As the daemon composes it: a fresh epoch, the operation catalog's
    /// digest, the system clock and random version-4 identities.
    pub fn production() -> Result<Self, WireError> {
        Ok(Self {
            epoch: crate::snapshot_pager::uuid()?,
            catalog: CATALOG_DIGEST.into(),
            clock: Box::new(|| {
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .ok()
                    .and_then(|elapsed| u64::try_from(elapsed.as_millis()).ok())
            }),
            uuid: Box::new(crate::snapshot_pager::uuid),
        })
    }
}

/// The HDC control-action owner over its private directory.
pub struct HdcControlActions {
    store: Store,
    context: OwnerContext,
}

fn not_found() -> WireError {
    refused("resourceNotFound", "control action does not exist")
}

impl HdcControlActions {
    /// Swift's coordinator over `directory`: its `records` beside the
    /// `snapshots` its own listing would page (the union owner pages
    /// instead), each made owner-only when absent.
    pub fn open(directory: &Path, context: OwnerContext) -> io::Result<Self> {
        let root = HostDirectory::open(directory)?;
        root.private_child("records")?;
        root.private_child("snapshots")?;
        Ok(Self {
            store: Store::open(&directory.join("records"))?,
            context,
        })
    }

    fn clock(&self) -> Result<u64, WireError> {
        (self.context.clock)().ok_or_else(|| {
            refused(
                "orchestrationClockUntrusted",
                "control-action time is unavailable",
            )
        })
    }

    fn required(&self, id: &str) -> Result<Record, WireError> {
        self.store.load(id)?.ok_or_else(not_found)
    }

    /// Swift `preview`: an existing action of the request identity wins over
    /// the current endpoint; otherwise the endpoint must be the source's, a
    /// new action is durably `observing`, then observed once.
    pub fn preview(
        &self,
        fields: &Map<String, Value>,
        source: &dyn ImpactSource,
    ) -> Result<Value, WireError> {
        let intent = Intent::parse(fields)?;
        if let Some(existing) = self.store.load_request(&intent.request)? {
            if existing.intent != intent {
                return Err(refused(
                    "idempotencyConflict",
                    "the request identity belongs to a different lifecycle intent",
                ));
            }
            let record = self.refresh_age(existing)?;
            if record.state == "observing" {
                return Ok(self.finish_observation(&record, source)?.projection());
            }
            return Ok(record.projection());
        }
        if intent.endpoint != source.endpoint_reference() {
            return Err(refused(
                "resourceNotFound",
                "the exact HDC endpoint reference is not configured",
            ));
        }
        let action_id = (self.context.uuid)()?;
        let record = self.store.begin(
            &intent,
            &self.context.catalog,
            &self.context.epoch,
            self.clock()?,
            &action_id,
        )?;
        Ok(self.finish_observation(&record, source)?.projection())
    }

    /// Swift `show`.
    pub fn show(&self, id: &str) -> Result<Value, WireError> {
        Ok(self.refresh_age(self.required(id)?)?.projection())
    }

    /// Swift `listRecords`: every action, its age refreshed.
    pub fn list_records(&self) -> Result<Vec<Record>, WireError> {
        self.store
            .list()?
            .into_iter()
            .map(|record| self.refresh_age(record))
            .collect()
    }

    /// Swift `reconcile`: an unobserved action is observed; a preview not yet
    /// approved is compared with a fresh reading and invalidated when the
    /// reading is unavailable or differs; any other action is read.
    pub fn reconcile(&self, id: &str, source: &dyn ImpactSource) -> Result<Value, WireError> {
        let record = self.refresh_age(self.required(id)?)?;
        if record.state == "observing" {
            return Ok(self.finish_observation(&record, source)?.projection());
        }
        let Some(preview) = record.preview.as_ref().filter(|_| {
            ["previewReady", "awaitingImpactApproval", "blocked"].contains(&record.state.as_str())
        }) else {
            return Ok(record.projection());
        };
        let Ok(reading) = source.read_impact() else {
            return Ok(self
                .invalidate_latest(&record, "hdc.impactObservationUnavailable")?
                .projection());
        };
        let latest = self.refresh_age(self.required(id)?)?;
        if latest.generation != record.generation {
            return Ok(latest.projection());
        }
        if preview.impact != reading.impact
            || record.value.get("observationRelations")
                != Some(&Value::Array(reading.relations.clone()))
            || record.value.get("blockerReasonCode")
                != Some(&json!(blocker(&reading, &record.intent)))
        {
            return Ok(self
                .invalidate_latest(&record, "hdc.previewDrifted")?
                .projection());
        }
        Ok(latest.projection())
    }

    fn finish_observation(
        &self,
        initial: &Record,
        source: &dyn ImpactSource,
    ) -> Result<Record, WireError> {
        let record = self.refresh_age(self.required(&initial.id)?)?;
        if record.state != "observing" {
            return Ok(record);
        }
        let Ok(reading) = source.read_impact() else {
            return self.invalidate_latest(&record, "hdc.impactObservationUnavailable");
        };
        let latest = self.refresh_age(self.required(&record.id)?)?;
        if latest.state != "observing" || latest.generation != record.generation {
            return Ok(latest);
        }
        let blocker = blocker(&reading, &record.intent);
        let preview_id = (self.context.uuid)()?;
        let published =
            latest.publishing(&reading, blocker.as_deref(), self.clock()?, &preview_id)?;
        self.store.replace(&published, latest.generation)?;
        Ok(published)
    }

    /// Swift `refreshAge`: an action still awaiting anything expires 300 s
    /// after its creation, and is invalidated once this Runtime is another
    /// start or binds another catalog — when read.
    fn refresh_age(&self, record: Record) -> Result<Record, WireError> {
        if record.epoch != self.context.epoch
            && ["approvalRecorded", "dispatchPrepared", "dispatching"]
                .contains(&record.state.as_str())
        {
            // An interrupted lifecycle is recovered by its audit, which this
            // owner never holds (such a record does not parse here).
            return Err(unreadable());
        }
        if !OPEN.contains(&record.state.as_str()) {
            return Ok(record);
        }
        let current = self.clock()?;
        let (Some(last), Some(expires)) = (time(&record.observed), time(&record.expires)) else {
            return Err(clock_backwards());
        };
        if current < last {
            return Err(clock_backwards());
        }
        let expired = current >= expires;
        let reason = if expired {
            "controlAction.expired"
        } else if record.epoch != self.context.epoch {
            "controlAction.runtimeRestarted"
        } else if record.value.get("catalogDigest") != Some(&json!(self.context.catalog)) {
            "controlAction.catalogChanged"
        } else {
            return Ok(record);
        };
        let next = record.invalidated(reason, expired, current)?;
        self.store.replace(&next, record.generation)?;
        Ok(next)
    }

    fn invalidate_latest(&self, before: &Record, reason: &str) -> Result<Record, WireError> {
        let latest = self.refresh_age(self.required(&before.id)?)?;
        if latest.generation != before.generation {
            return Ok(latest);
        }
        let next = latest.invalidated(reason, false, self.clock()?)?;
        if next != latest {
            self.store.replace(&next, latest.generation)?;
        }
        Ok(next)
    }
}

fn clock_backwards() -> WireError {
    refused(
        "orchestrationClockUntrusted",
        "control-action clock moved backwards",
    )
}

/// Swift `blocker(for:intent:)`, in its order: no proved server identity,
/// another server or generation than the intent's, unresolved critical Jobs,
/// unproved health, then the source's own reason.
fn blocker(reading: &ImpactReading, intent: &Intent) -> Option<String> {
    let impact = &reading.impact.value;
    let generation = impact.get("serverGeneration");
    if generation == Some(&Value::Null) {
        return Some("hdc.serverIdentityUnproven".into());
    }
    if impact.get("serverEndpointRef") != Some(&json!(intent.endpoint))
        || generation != Some(&json!(intent.generation.to_string()))
    {
        return Some("hdc.serverGenerationChanged".into());
    }
    if !reading.impact.critical_gate_is_clear() {
        return Some("hdc.criticalJobsUnresolved".into());
    }
    if impact.get("serverHealth") != Some(&json!("healthy")) {
        return Some("hdc.serverHealthUnproven".into());
    }
    reading.blocker.clone()
}

#[cfg(test)]
#[path = "hdc_control_action_tests.rs"]
mod tests;
