//! Swift `RuntimeToolSelectionControlActionRecord` over
//! `RuntimeToolSelectionControlActionStore` (CHG-2026-074, TASK-XPA-012): the
//! durable half of `runtime.tool.select`. One control action per request
//! identity moves one exact HDC tool transition — the active registered tool
//! to a new one at the active selection's generation — through a preview of
//! the managed server's impact, an impact approval with its console challenge
//! and receipt, a prepared dispatch and its lifecycle audit, to the settled
//! selection. The store keeps the records in the owner's private
//! `tool-selection-control-actions/records` directory as Swift does
//! (`control_action_store.rs`), byte for byte.
//!
//! Each transition takes its instant and the random identities Swift draws
//! (`UUID()` for the action, preview, approval, challenge and receipt) from its
//! caller, so a Swift record's timeline can be played again exactly. The
//! owner that observes the impact, asks the registry and drives the lifecycle
//! is not here: it needs the HDC restart (C2).
use crate::control_action::{identifier, refused};
use crate::control_action_approval::{ImpactApproval, InteractionChallenge, InteractionReceipt};
use crate::control_action_store::{ActionStore, StoredAction};
use crate::control_action_value::{
    digest, exact_keys, generation, hash, one_of, optional_digest, optional_identifier,
    optional_text, owner, record_unreadable, time, timestamp,
};
use crate::hdc_control_action::Impact;
use arkdeck_contract::WireError;
use serde_json::{Map, Value, json};
use std::io;
use std::path::Path;

/// An action's life: `expiresAt` is `createdAt` plus 300 s.
const LIFETIME_MS: u64 = 300_000;
/// A challenge answers for at most 120 s, and never past its action.
const CHALLENGE_MS: u64 = 120_000;

/// Every state a tool-selection record may hold (it never `dispatching`).
const STATES: [&str; 11] = [
    "observing",
    "previewReady",
    "awaitingImpactApproval",
    "approvalRecorded",
    "dispatchPrepared",
    "outcomeUnknown",
    "succeeded",
    "failed",
    "blocked",
    "expired",
    "previewDrifted",
];

/// The audit rows a prepared or launched selection appends.
const AUDIT_KINDS: [&str; 7] = [
    "impactPreview",
    "confirmation",
    "intent",
    "actualCommand",
    "launchWindowEntered",
    "outcome",
    "reconciliation",
];

fn text<'a>(value: &'a Map<String, Value>, key: &str) -> Option<&'a str> {
    value.get(key).and_then(Value::as_str)
}

fn object(value: Value) -> Map<String, Value> {
    match value {
        Value::Object(fields) => fields,
        _ => unreachable!("an object literal"),
    }
}

/// `tool:sha256:` and 64 lowercase hex digits.
fn tool_reference(text: &str) -> bool {
    text.strip_prefix("tool:sha256:").is_some_and(digest)
}

// --- intent (`RuntimeToolSelectionIntent`) --------------------------------

/// One exact selection: the caller's request identity, the new tool and the
/// active selection generation the caller expects.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ToolSelectionIntent {
    request: String,
    tool: String,
    generation: u64,
}

impl ToolSelectionIntent {
    /// Swift `init(_:)`: exactly the three members, strings all.
    pub fn parse(fields: &Map<String, Value>) -> Result<Self, WireError> {
        let parsed = (|| {
            if !exact_keys(
                fields,
                &["actionRequestId", "tool", "expectedActiveGeneration"],
            ) {
                return None;
            }
            Some(Self {
                request: text(fields, "actionRequestId")
                    .filter(|request| identifier(request))?
                    .to_owned(),
                tool: text(fields, "tool")
                    .filter(|tool| tool_reference(tool))?
                    .to_owned(),
                generation: generation(text(fields, "expectedActiveGeneration")?)?,
            })
        })();
        parsed.ok_or_else(|| {
            refused(
                "invalidInput",
                "tool selection requires an exact tool, active generation and request identity",
            )
        })
    }

    /// The request identity.
    pub fn request(&self) -> &str {
        &self.request
    }

    fn request_value(&self) -> Value {
        json!({
            "actionRequestId": self.request, "tool": self.tool,
            "expectedActiveGeneration": self.generation.to_string(),
        })
    }

    /// The fingerprint covers the transition, never the request identity.
    fn fingerprint(&self) -> Result<String, WireError> {
        hash(&json!({
            "schemaVersion": "arkdeck.tool-selection-intent/1", "kind": "runtimeToolSelection",
            "newToolRef": self.tool, "expectedActiveGeneration": self.generation.to_string(),
        }))
    }
}

// --- tool facts (`RuntimeToolSelectionToolFacts`) -------------------------

/// The path-free, immutable facts of one registered HDC tool that enter the
/// preview digest.
#[derive(Clone, Debug, PartialEq)]
pub struct ToolFacts {
    value: Map<String, Value>,
    tool: String,
}

impl ToolFacts {
    /// Swift `init(value:)`.
    pub fn parse(value: Map<String, Value>) -> Result<Self, WireError> {
        let signature = value.get("signature").and_then(Value::as_object);
        let trust = value.get("trust").and_then(Value::as_object);
        let valid = exact_keys(
            &value,
            &[
                "toolRef",
                "recordGeneration",
                "contentSHA256",
                "executableSHA256",
                "signature",
                "version",
                "trust",
            ],
        ) && text(&value, "toolRef").is_some_and(tool_reference)
            && text(&value, "recordGeneration")
                .and_then(generation)
                .is_some()
            && text(&value, "contentSHA256").is_some_and(digest)
            && text(&value, "executableSHA256").is_some_and(digest)
            && optional_text(value.get("version"), 128)
            && signature.is_some_and(|signature| {
                exact_keys(
                    signature,
                    &[
                        "state",
                        "identifier",
                        "teamIdentifier",
                        "codeDirectoryIdentitySHA256",
                    ],
                ) && one_of(signature.get("state"), &["unsigned", "adHoc", "verified"])
                    && optional_text(signature.get("identifier"), 256)
                    && optional_text(signature.get("teamIdentifier"), 256)
                    && optional_digest(signature.get("codeDirectoryIdentitySHA256"))
            })
            && trust.is_some_and(|trust| {
                exact_keys(
                    trust,
                    &[
                        "policy",
                        "registeredIdentity",
                        "platformTrust",
                        "executionAssessment",
                        "profileReferences",
                    ],
                ) && trust.get("policy") == Some(&json!("arkdeck.host-tool-inspection/1"))
                    && trust.get("registeredIdentity") == Some(&json!(true))
                    && trust.get("platformTrust") == Some(&json!("unverified"))
                    && trust.get("executionAssessment") == Some(&json!("notPerformed"))
                    && trust
                        .get("profileReferences")
                        .and_then(Value::as_array)
                        .is_some_and(|profiles| {
                            profiles.len() <= 32
                                && profiles
                                    .iter()
                                    .all(|profile| profile.as_str().is_some_and(identifier))
                        })
            });
        if !valid {
            return Err(record_unreadable("tool selection facts are malformed"));
        }
        Ok(Self {
            tool: text(&value, "toolRef").unwrap_or_default().to_owned(),
            value,
        })
    }

    pub fn value(&self) -> &Map<String, Value> {
        &self.value
    }

    /// `toolRef`.
    pub fn tool(&self) -> &str {
        &self.tool
    }
}

// --- impact (`RuntimeToolSelectionImpact`) --------------------------------

/// The managed server's impact of one tool transition: the HDC impact, whose
/// running executable is the active tool's, and both tools' facts.
#[derive(Clone, Debug, PartialEq)]
pub struct SelectionImpact {
    hdc: Impact,
    old: ToolFacts,
    new: ToolFacts,
    generation: u64,
}

impl SelectionImpact {
    /// Swift `init(hdc:oldTool:newTool:activeGeneration:)`.
    pub fn new(
        hdc: Impact,
        old: ToolFacts,
        new: ToolFacts,
        generation: u64,
    ) -> Result<Self, WireError> {
        let running = hdc
            .value()
            .get("tool")
            .and_then(Value::as_object)
            .and_then(|tool| tool.get("sha256"));
        if generation == 0 || old.tool == new.tool || running != old.value.get("executableSHA256") {
            return Err(refused(
                "factsDrifted",
                "active selection does not match the managed HDC executable",
            ));
        }
        Ok(Self {
            hdc,
            old,
            new,
            generation,
        })
    }

    /// The HDC impact's members with both tools and the expected active
    /// generation.
    pub fn value(&self) -> Map<String, Value> {
        let mut fields = self.hdc.value().clone();
        fields.insert("oldTool".into(), Value::Object(self.old.value.clone()));
        fields.insert("newTool".into(), Value::Object(self.new.value.clone()));
        fields.insert(
            "expectedActiveGeneration".into(),
            json!(self.generation.to_string()),
        );
        fields
    }
}

// --- preview (`RuntimeToolSelectionPreview`) ------------------------------

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

/// The immutable preview of one selection: its impact, identity and
/// lifetime, and the SHA-256 of the canonical bytes of all of it.
#[derive(Clone, Debug, PartialEq)]
struct Preview {
    value: Map<String, Value>,
    impact: SelectionImpact,
}

impl Preview {
    /// Swift `init(actionID:previewID:createdAt:expiresAt:impact:)`.
    fn build(
        action: &str,
        preview: &str,
        created: &str,
        expires: &str,
        impact: &SelectionImpact,
    ) -> Result<Self, WireError> {
        let mut fields = impact.value();
        for (key, value) in [
            ("schemaVersion", json!("arkdeck.tool-selection-preview/1")),
            ("controlActionId", json!(action)),
            ("previewId", json!(preview)),
            ("kind", json!("runtimeToolSelection")),
            ("action", json!("select")),
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

    /// Swift `init(value:)`.
    fn parse(value: Map<String, Value>) -> Result<Self, WireError> {
        let invalid =
            || record_unreadable("tool-selection preview failed identity or digest validation");
        let id = text(&value, "controlActionId").filter(|id| identifier(id));
        let mut unsigned = value.clone();
        unsigned.remove("previewDigest");
        let tools = (
            value.get("oldTool").and_then(Value::as_object),
            value.get("newTool").and_then(Value::as_object),
        );
        let active = text(&value, "expectedActiveGeneration").and_then(generation);
        let valid = value.get("schemaVersion") == Some(&json!("arkdeck.tool-selection-preview/1"))
            && value.get("kind") == Some(&json!("runtimeToolSelection"))
            && value.get("action") == Some(&json!("select"))
            && value.get("confirmationRequired") == Some(&json!(true))
            && value.get("dispatchCount") == Some(&json!(0))
            && value.get("digestAlgorithm") == Some(&json!("sha256-jcs"))
            && id.is_some()
            && text(&value, "previewId").is_some_and(identifier)
            && matches!(
                (
                    text(&value, "createdAt").and_then(time),
                    text(&value, "expiresAt").and_then(time),
                ),
                (Some(start), Some(end)) if end > start
            )
            && value.get("owner") == id.map(owner).as_ref()
            && text(&value, "previewDigest").is_some_and(digest)
            && text(&value, "previewDigest").map(str::to_owned)
                == Some(hash(&Value::Object(unsigned))?);
        let (true, (Some(old), Some(new)), Some(active)) = (valid, tools, active) else {
            return Err(invalid());
        };
        let facts = |excluded: &[&str]| -> Map<String, Value> {
            value
                .iter()
                .filter(|(key, _)| {
                    !PREVIEW_METADATA.contains(&key.as_str()) && !excluded.contains(&key.as_str())
                })
                .map(|(key, value)| (key.clone(), value.clone()))
                .collect()
        };
        let hdc = Impact::new(facts(&["oldTool", "newTool", "expectedActiveGeneration"]))?;
        let impact = SelectionImpact::new(
            hdc,
            ToolFacts::parse(old.clone())?,
            ToolFacts::parse(new.clone())?,
            active,
        )?;
        if impact.value() != facts(&[]) {
            return Err(record_unreadable(
                "stored tool-selection impact is not canonical",
            ));
        }
        Ok(Self { value, impact })
    }
}

// --- record (`RuntimeToolSelectionControlActionRecord`) -------------------

const RECORD_KEYS: [&str; 20] = [
    "schemaVersion",
    "controlActionId",
    "actionRequestId",
    "requestFingerprint",
    "intent",
    "catalogDigest",
    "runtimeEpoch",
    "generation",
    "state",
    "createdAt",
    "expiresAt",
    "lastObservedAt",
    "preview",
    "observationRelations",
    "blockerReasonCode",
    "humanAction",
    "interactionChallenge",
    "interactionReceipt",
    "dispatchCount",
    "selectionAudit",
];

/// One durable tool-selection control action.
#[derive(Clone, Debug, PartialEq)]
pub struct ToolSelectionRecord {
    value: Map<String, Value>,
    intent: ToolSelectionIntent,
    preview: Option<Preview>,
    approval: Option<ImpactApproval>,
    challenge: Option<InteractionChallenge>,
    receipt: Option<InteractionReceipt>,
    generation: u64,
    id: String,
    state: String,
    epoch: String,
    created: String,
    expires: String,
    observed: String,
}

/// A nested record: null, or an object its type reads.
fn nested<T>(
    value: Option<&Value>,
    parse: impl FnOnce(Map<String, Value>) -> Result<T, WireError>,
) -> Result<Option<T>, WireError> {
    match value {
        Some(Value::Null) => Ok(None),
        Some(Value::Object(fields)) => parse(fields.clone()).map(Some),
        _ => Err(record_unreadable(
            "tool-selection nested record is malformed",
        )),
    }
}

impl ToolSelectionRecord {
    /// Swift `init(intent:catalogDigest:runtimeEpoch:now:)`: `observing`,
    /// generation 1, for 300 s; `action` is the random identity Swift draws
    /// for `control-action-`.
    pub fn new(
        intent: &ToolSelectionIntent,
        catalog: &str,
        epoch: &str,
        now: u64,
        action: &str,
    ) -> Result<Self, WireError> {
        let created = timestamp(now);
        let start = time(&created).ok_or_else(|| {
            record_unreadable("tool-selection action requires a representable creation time")
        })?;
        Self::parse(object(json!({
            "schemaVersion": "arkdeck.runtime-tool-selection-control-action/1",
            "controlActionId": format!("control-action-{action}"),
            "actionRequestId": intent.request, "requestFingerprint": intent.fingerprint()?,
            "intent": intent.request_value(), "catalogDigest": catalog,
            "runtimeEpoch": epoch, "generation": "1", "state": "observing",
            "createdAt": created, "expiresAt": timestamp(start + LIFETIME_MS),
            "lastObservedAt": created, "preview": null, "observationRelations": [],
            "blockerReasonCode": null, "humanAction": null,
            "interactionChallenge": null, "interactionReceipt": null,
            "dispatchCount": 0, "selectionAudit": [],
        })))
    }

    /// Swift `init(value:)`: the closed members, then the nested records,
    /// then the bindings between them and the state.
    pub fn parse(value: Map<String, Value>) -> Result<Self, WireError> {
        let malformed = || record_unreadable("tool-selection control action is malformed");
        let intent = value
            .get("intent")
            .and_then(Value::as_object)
            .and_then(|fields| ToolSelectionIntent::parse(fields).ok());
        let id = text(&value, "controlActionId").filter(|id| identifier(id));
        let epoch = text(&value, "runtimeEpoch").filter(|epoch| identifier(epoch));
        let record_generation = text(&value, "generation").and_then(generation);
        let state = text(&value, "state").filter(|state| STATES.contains(state));
        let created = text(&value, "createdAt");
        let start = created.and_then(time);
        let expires = text(&value, "expiresAt");
        let end = expires.and_then(time);
        let observed = text(&value, "lastObservedAt");
        let latest = observed.and_then(time);
        let dispatch = value.get("dispatchCount").and_then(Value::as_i64);
        let (
            true,
            Some(intent),
            Some(id),
            Some(epoch),
            Some(record_generation),
            Some(state),
            Some(created),
            Some(start),
            Some(expires),
            Some(end),
            Some(observed),
            Some(latest),
            Some(dispatch),
        ) = (
            exact_keys(&value, &RECORD_KEYS),
            intent,
            id,
            epoch,
            record_generation,
            state,
            created,
            start,
            expires,
            end,
            observed,
            latest,
            dispatch,
        )
        else {
            return Err(malformed());
        };
        let fingerprint = text(&value, "requestFingerprint").filter(|value| digest(value));
        let closed = value.get("schemaVersion")
            == Some(&json!("arkdeck.runtime-tool-selection-control-action/1"))
            && text(&value, "actionRequestId") == Some(intent.request.as_str())
            && fingerprint.is_some()
            && fingerprint.map(str::to_owned) == Some(intent.fingerprint()?)
            && text(&value, "catalogDigest").is_some_and(digest)
            && end.checked_sub(start) == Some(LIFETIME_MS)
            && latest >= start
            && optional_identifier(value.get("blockerReasonCode"))
            && value
                .get("observationRelations")
                .and_then(Value::as_array)
                .is_some_and(|relations| relations.len() <= 256)
            && (0..=1).contains(&dispatch)
            && value
                .get("selectionAudit")
                .and_then(Value::as_array)
                .is_some_and(|audit| audit.len() <= 16 && audit.iter().all(Value::is_object));
        if !closed {
            return Err(malformed());
        }
        let preview = nested(value.get("preview"), Preview::parse)?;
        let approval = nested(value.get("humanAction"), ImpactApproval::parse)?;
        let challenge = nested(
            value.get("interactionChallenge"),
            InteractionChallenge::parse,
        )?;
        let receipt = nested(value.get("interactionReceipt"), InteractionReceipt::parse)?;
        let owned = |fields: Option<&Map<String, Value>>| {
            fields.is_none_or(|fields| text(fields, "controlActionId") == Some(id))
        };
        let recorded = [
            "approvalRecorded",
            "dispatchPrepared",
            "outcomeUnknown",
            "succeeded",
            "failed",
        ];
        let bound = owned(preview.as_ref().map(|preview| &preview.value))
            && owned(approval.as_ref().map(ImpactApproval::value))
            && owned(challenge.as_ref().map(InteractionChallenge::value))
            && owned(receipt.as_ref().map(InteractionReceipt::value))
            && (state == "failed"
                || (dispatch == 1) == ["outcomeUnknown", "succeeded"].contains(&state))
            && (!["awaitingImpactApproval"]
                .iter()
                .chain(&recorded)
                .any(|s| *s == state)
                || approval.is_some())
            && (!["observing", "previewReady", "blocked"].contains(&state) || approval.is_none())
            && (receipt.is_some() == recorded.contains(&state));
        if !bound {
            return Err(record_unreadable(
                "tool-selection owner bindings contradict its state",
            ));
        }
        Ok(Self {
            intent,
            preview,
            approval,
            challenge,
            receipt,
            generation: record_generation,
            id: id.to_owned(),
            state: state.to_owned(),
            epoch: epoch.to_owned(),
            created: created.to_owned(),
            expires: expires.to_owned(),
            observed: observed.to_owned(),
            value,
        })
    }

    pub fn value(&self) -> &Map<String, Value> {
        &self.value
    }

    /// `controlActionId`.
    pub fn id(&self) -> &str {
        &self.id
    }

    pub fn intent(&self) -> &ToolSelectionIntent {
        &self.intent
    }

    pub fn state(&self) -> &str {
        &self.state
    }

    pub fn generation(&self) -> u64 {
        self.generation
    }

    fn audit(&self) -> &[Value] {
        self.value
            .get("selectionAudit")
            .and_then(Value::as_array)
            .map_or(&[], Vec::as_slice)
    }

    /// The next generation's fields, observed `now`.
    fn advanced(&self, now: u64) -> Result<Map<String, Value>, WireError> {
        if self.generation == u64::MAX || time(&self.observed).is_none_or(|last| now < last) {
            return Err(refused(
                "orchestrationClockUntrusted",
                "tool-selection clock moved backwards",
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

    /// The one preview, and with it `previewReady` or `blocked`; a record
    /// already past `observing` is itself. `preview` is the random identity
    /// Swift draws for `preview-`.
    pub fn publishing(
        &self,
        impact: &SelectionImpact,
        relations: &[Value],
        blocker: Option<&str>,
        now: u64,
        preview: &str,
    ) -> Result<Self, WireError> {
        if self.state != "observing" {
            return Ok(self.clone());
        }
        let mut fields = self.advanced(now)?;
        let preview = Preview::build(
            &self.id,
            &format!("preview-{preview}"),
            &timestamp(now),
            &self.expires,
            impact,
        )?;
        fields.insert("preview".into(), Value::Object(preview.value));
        fields.insert(
            "observationRelations".into(),
            Value::Array(relations.to_vec()),
        );
        fields.insert("blockerReasonCode".into(), json!(blocker));
        fields.insert(
            "state".into(),
            json!(if blocker.is_none() {
                "previewReady"
            } else {
                "blocked"
            }),
        );
        Self::parse(fields)
    }

    /// The impact approval of the ready preview; `action` and `resume` are the
    /// random identities Swift draws for the approval.
    pub fn requesting_impact_approval(
        &self,
        now: u64,
        action: &str,
        resume: &str,
    ) -> Result<Self, WireError> {
        let (true, Some(preview)) = (self.state == "previewReady", &self.preview) else {
            return Err(refused(
                "admissionDenied",
                "tool selection is not eligible for impact approval",
            ));
        };
        let mut fields = self.advanced(now)?;
        let approval = ImpactApproval::new(
            &self.id,
            &preview.value,
            self.generation + 1,
            &timestamp(now),
            &self.expires,
            action,
            resume,
        )?;
        fields.insert("state".into(), json!("awaitingImpactApproval"));
        fields.insert(
            "humanAction".into(),
            Value::Object(approval.value().clone()),
        );
        Self::parse(fields)
    }

    /// One console challenge for the waiting approval, answering until the
    /// earlier of 120 s and the action's expiry; `id` is its random identity.
    pub fn issuing_interactive_challenge(
        &self,
        challenge: &str,
        now: u64,
        id: &str,
    ) -> Result<Self, WireError> {
        let (true, Some(approval), None, None, Some(record_expiry)) = (
            self.state == "awaitingImpactApproval",
            &self.approval,
            &self.challenge,
            &self.receipt,
            time(&self.expires),
        ) else {
            return Err(refused(
                "humanActionExpired",
                "tool-selection approval is no longer waiting",
            ));
        };
        let mut fields = self.advanced(now)?;
        let expiry = record_expiry.min(now + CHALLENGE_MS);
        let challenge = InteractionChallenge::new(
            &self.id,
            approval,
            challenge,
            &timestamp(now),
            &timestamp(expiry),
            id,
        )?;
        fields.insert(
            "interactionChallenge".into(),
            Value::Object(challenge.value().clone()),
        );
        Self::parse(fields)
    }

    /// The approval resolved by the challenge's own text, before it expires;
    /// `id` is the receipt's random identity.
    pub fn recording_interactive_approval(
        &self,
        response: &str,
        now: u64,
        id: &str,
    ) -> Result<Self, WireError> {
        let expiry = self
            .challenge
            .as_ref()
            .and_then(|challenge| text(challenge.value(), "expiresAt"))
            .and_then(time);
        let (true, Some(approval), Some(challenge), Some(expiry)) = (
            self.state == "awaitingImpactApproval",
            &self.approval,
            &self.challenge,
            expiry,
        ) else {
            return Err(refused(
                "impactApprovalChallengeExpired",
                "tool-selection challenge expired",
            ));
        };
        if now >= expiry {
            return Err(refused(
                "impactApprovalChallengeExpired",
                "tool-selection challenge expired",
            ));
        }
        let mut fields = self.advanced(now)?;
        let resolved = approval.resolving()?;
        let receipt =
            InteractionReceipt::new(&self.id, approval, challenge, response, &timestamp(now), id)?;
        fields.insert("state".into(), json!("approvalRecorded"));
        fields.insert(
            "humanAction".into(),
            Value::Object(resolved.value().clone()),
        );
        fields.insert(
            "interactionReceipt".into(),
            Value::Object(receipt.value().clone()),
        );
        Self::parse(fields)
    }

    /// Dispatch prepared: the audit begins with the transition itself.
    pub fn prepared(&self, now: u64) -> Result<Self, WireError> {
        let (true, Some(preview)) = (self.state == "approvalRecorded", &self.preview) else {
            return Err(record_unreadable(
                "tool selection lacks an approved preview",
            ));
        };
        let mut fields = self.advanced(now)?;
        fields.insert("state".into(), json!("dispatchPrepared"));
        fields.insert(
            "selectionAudit".into(),
            json!([{
                "kind": "selectionPrepared", "recordedAt": timestamp(now),
                "oldToolRef": preview.impact.old.tool,
                "newToolRef": preview.impact.new.tool,
                "activeGeneration": preview.impact.generation.to_string(),
            }]),
        );
        Self::parse(fields)
    }

    /// One lifecycle audit row; `launchWindowEntered`, once and only while
    /// prepared, makes the outcome unknown with one dispatch. `audit` is the
    /// row's identity, a lowercase UUID.
    pub fn appending_lifecycle_audit(
        &self,
        kind: &str,
        audit: &str,
        payload: Map<String, Value>,
        now: u64,
    ) -> Result<Self, WireError> {
        let rows = self.audit();
        if !["dispatchPrepared", "outcomeUnknown"].contains(&self.state.as_str())
            || !AUDIT_KINDS.contains(&kind)
            || self
                .value
                .get("selectionAudit")
                .is_none_or(|rows| !rows.is_array())
            || rows.len() >= 16
        {
            return Err(record_unreadable(
                "invalid tool-selection lifecycle audit transition",
            ));
        }
        let launch = kind == "launchWindowEntered";
        if launch
            && (self.state != "dispatchPrepared"
                || rows
                    .iter()
                    .any(|row| row.get("kind") == Some(&json!("launchWindowEntered"))))
        {
            return Err(record_unreadable(
                "tool-selection launch window was already entered",
            ));
        }
        let mut fields = self.advanced(now)?;
        let mut rows = rows.to_vec();
        rows.push(json!({
            "kind": kind, "auditId": audit, "recordedAt": timestamp(now), "payload": payload,
        }));
        fields.insert("selectionAudit".into(), Value::Array(rows));
        if launch {
            fields.insert("state".into(), json!("outcomeUnknown"));
            fields.insert("dispatchCount".into(), json!(1));
        }
        Self::parse(fields)
    }

    /// A failure before any lifecycle effect: `failed`, dispatch zero.
    pub fn failed_before_launch(&self, reason: &str, now: u64) -> Result<Self, WireError> {
        if !["approvalRecorded", "dispatchPrepared"].contains(&self.state.as_str())
            || !identifier(reason)
            || self
                .value
                .get("selectionAudit")
                .is_none_or(|rows| !rows.is_array())
        {
            return Err(record_unreadable(
                "invalid pre-launch tool-selection failure",
            ));
        }
        let mut fields = self.advanced(now)?;
        let mut rows = self.audit().to_vec();
        rows.push(json!({
            "kind": "selectionOutcome", "recordedAt": timestamp(now),
            "result": "failed", "reasonCode": reason,
        }));
        fields.insert("selectionAudit".into(), Value::Array(rows));
        fields.insert("state".into(), json!("failed"));
        fields.insert("blockerReasonCode".into(), json!(reason));
        fields.insert("dispatchCount".into(), json!(0));
        Self::parse(fields)
    }

    /// The registry's durable outcome of an unknown one: `succeeded` or
    /// `failed` with the active tool and generation it left.
    pub fn settled(
        &self,
        result: &str,
        active_tool: &str,
        active_generation: u64,
        reason: Option<&str>,
        now: u64,
    ) -> Result<Self, WireError> {
        if self.state != "outcomeUnknown"
            || !["succeeded", "failed"].contains(&result)
            || !tool_reference(active_tool)
            || active_generation == 0
            || !reason.is_none_or(identifier)
            || self
                .value
                .get("selectionAudit")
                .is_none_or(|rows| !rows.is_array())
        {
            return Err(record_unreadable("invalid tool-selection settlement"));
        }
        let mut fields = self.advanced(now)?;
        let mut rows = self.audit().to_vec();
        rows.push(json!({
            "kind": "selectionOutcome", "recordedAt": timestamp(now), "result": result,
            "activeToolRef": active_tool, "activeGeneration": active_generation.to_string(),
            "reasonCode": reason,
        }));
        fields.insert("selectionAudit".into(), Value::Array(rows));
        fields.insert("state".into(), json!(result));
        fields.insert("blockerReasonCode".into(), json!(reason));
        Self::parse(fields)
    }

    /// `expired` or `previewDrifted` for `reason`: a waiting approval expires
    /// and an issued challenge is withdrawn.
    pub fn invalidated(&self, reason: &str, expired: bool, now: u64) -> Result<Self, WireError> {
        let mut fields = self.advanced(now)?;
        fields.insert(
            "state".into(),
            json!(if expired { "expired" } else { "previewDrifted" }),
        );
        fields.insert("blockerReasonCode".into(), json!(reason));
        if let Some(approval) = &self.approval {
            fields.insert(
                "humanAction".into(),
                Value::Object(approval.expiring()?.value().clone()),
            );
        }
        fields.insert("interactionChallenge".into(), Value::Null);
        Self::parse(fields)
    }

    /// What `control-action.show`, `.list` and `.reconcile` answer.
    pub fn projection(&self) -> Value {
        let id = self.id.as_str();
        let field = |key: &str| self.value.get(key).cloned().unwrap_or(Value::Null);
        let blocker = field("blockerReasonCode");
        let waiting = self.state == "awaitingImpactApproval";
        let kind = if waiting {
            "humanAction"
        } else if ["succeeded", "failed"].contains(&self.state.as_str()) {
            "none"
        } else {
            "reconcile"
        };
        let resource = match (&self.approval, waiting) {
            (Some(approval), true) => json!({"kind": "humanAction", "id": approval.action_id()}),
            _ => owner(id),
        };
        let reason = match self.state.as_str() {
            "awaitingImpactApproval" => json!("policy.impactApprovalRequired"),
            "succeeded" => json!("controlAction.completed"),
            "failed" => blocker.clone(),
            "outcomeUnknown" => json!("tool.selectionRecomposePending"),
            _ if blocker.is_null() => json!("controlAction.previewAvailable"),
            _ => blocker.clone(),
        };
        json!({
            "schemaVersion": "arkdeck.control-action/1", "controlActionId": id,
            "actionRequestId": self.intent.request,
            "requestFingerprint": field("requestFingerprint"),
            "fingerprintAlgorithm": "sha256-jcs", "kind": "runtimeToolSelection",
            "action": "select", "owner": owner(id),
            "generation": self.generation.to_string(), "state": self.state,
            "catalogDigest": field("catalogDigest"), "createdAt": self.created,
            "expiresAt": self.expires, "lastObservedAt": self.observed,
            "preview": self.preview.as_ref().map(|preview| Value::Object(preview.value.clone())),
            "blockerReasonCode": blocker,
            "humanAction": self.approval.as_ref().map(ImpactApproval::projection),
            "dispatchCount": field("dispatchCount"),
            "nextAction": {"kind": kind, "owner": owner(id), "resource": resource, "reasonCode": reason},
        })
    }
}

// --- store (`RuntimeToolSelectionControlActionStore`) ---------------------

impl StoredAction for ToolSelectionRecord {
    fn parse(value: Map<String, Value>) -> Result<Self, WireError> {
        ToolSelectionRecord::parse(value)
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

    /// Swift `replace`: never the intent, lifetime, epoch, catalog, published
    /// preview or relations; the approval changes only its status, a receipt
    /// only answers the challenge it was issued, the audit only grows by one
    /// row, the clock never runs back, over a permitted transition.
    fn replaces(previous: &Self, next: &Self) -> bool {
        fn challenge(record: &ToolSelectionRecord) -> Option<&Map<String, Value>> {
            record.challenge.as_ref().map(InteractionChallenge::value)
        }
        fn receipt(record: &ToolSelectionRecord) -> Option<&Map<String, Value>> {
            record.receipt.as_ref().map(InteractionReceipt::value)
        }
        previous.intent == next.intent
            && previous.created == next.created
            && previous.expires == next.expires
            && previous.epoch == next.epoch
            && previous.value.get("catalogDigest") == next.value.get("catalogDigest")
            && (previous.preview.is_none() || previous.preview == next.preview)
            && (previous.preview.is_none()
                || previous.value.get("observationRelations")
                    == next.value.get("observationRelations"))
            && previous.approval.as_ref().is_none_or(|approval| {
                next.approval
                    .as_ref()
                    .is_some_and(|next| approval.continues(next))
            })
            && (next.receipt.is_none() || challenge(previous) == challenge(next))
            && (previous.receipt.is_none() || receipt(previous) == receipt(next))
            && next.audit().starts_with(previous.audit())
            && next.audit().len() <= previous.audit().len() + 1
            && time(&previous.observed)
                .zip(time(&next.observed))
                .is_some_and(|(old, new)| new >= old)
            && permits(&previous.state, &next.state)
    }
}

/// `RuntimeToolSelectionControlActionStore.permitsTransition`.
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
        "dispatchPrepared" => &["dispatchPrepared", "outcomeUnknown", "failed"],
        "outcomeUnknown" => &["outcomeUnknown", "succeeded", "failed"],
        "blocked" => &["expired", "previewDrifted"],
        _ => &[],
    };
    allowed.contains(&to)
}

/// The tool-selection owner's records, one document per request identity,
/// changed only under the transaction lock beside them.
pub struct ToolSelectionRecords(ActionStore<ToolSelectionRecord>);

impl ToolSelectionRecords {
    /// The owner's existing private records directory.
    pub fn open(path: &Path) -> io::Result<Self> {
        Ok(Self(ActionStore::open(path)?))
    }

    /// The record of the intent's request identity, or a new `observing` one;
    /// `action` is the random identity Swift draws for a new record.
    pub fn begin(
        &self,
        intent: &ToolSelectionIntent,
        catalog: &str,
        epoch: &str,
        now: u64,
        action: &str,
    ) -> Result<ToolSelectionRecord, WireError> {
        self.0.begin(
            &intent.request,
            |existing| existing.intent == *intent,
            || ToolSelectionRecord::new(intent, catalog, epoch, now, action),
        )
    }

    pub fn load(&self, id: &str) -> Result<Option<ToolSelectionRecord>, WireError> {
        self.0.load(id)
    }

    pub fn load_request(&self, request: &str) -> Result<Option<ToolSelectionRecord>, WireError> {
        self.0.load_request(request)
    }

    /// Creation time, then identity in byte order.
    pub fn list(&self) -> Result<Vec<ToolSelectionRecord>, WireError> {
        self.0.list()
    }

    /// The exact next generation of the same action, on Swift's conditions.
    pub fn replace(&self, record: &ToolSelectionRecord, expected: u64) -> Result<(), WireError> {
        self.0.replace(record, expected)
    }
}

#[cfg(test)]
#[path = "tool_selection_tests.rs"]
mod tests;
