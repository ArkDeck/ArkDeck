//! A control action's impact approval (CHG-2026-074): Swift's
//! `HDCControlHumanAction` (the approval a preview requests of a person),
//! `HDCControlInteractionChallenge` (the one-time console challenge issued for
//! it; only its SHA-256 is kept) and `HDCControlInteractionReceipt` (the
//! durable proof that a person typed it). Both Swift control-action owners'
//! records hold them; the tool-selection record reads and writes them
//! (TASK-XPA-012), the HDC lifecycle record once its restart is here.
use crate::control_action::{identifier, refused};
use crate::control_action_value::{digest, exact_keys, generation, owner, record_unreadable, time};
use arkdeck_contract::{WireError, sha256_hex};
use serde_json::{Map, Value, json};

/// A challenge answers for at most this long after it is issued.
const CHALLENGE_LIFETIME_MS: u64 = 120_000;

fn text<'a>(value: &'a Map<String, Value>, key: &str) -> Option<&'a str> {
    value.get(key).and_then(Value::as_str)
}

/// The impact approval a control action requests: Swift
/// `HDCControlHumanAction`.
#[derive(Clone, Debug, PartialEq)]
pub struct ImpactApproval {
    value: Map<String, Value>,
    action_id: String,
    status: String,
}

const APPROVAL_KEYS: [&str; 9] = [
    "actionId",
    "resumeReference",
    "controlActionId",
    "previewId",
    "previewDigest",
    "controlActionGeneration",
    "createdAt",
    "expiresAt",
    "status",
];

impl ImpactApproval {
    /// Swift `init(controlActionID:preview:generation:createdAt:expiresAt:)`:
    /// a waiting approval bound to the preview's identity and digest and to
    /// the generation that records it; `action` and `resume` are the random
    /// identities Swift draws for `har-` and `resume-`.
    pub fn new(
        control_action: &str,
        preview: &Map<String, Value>,
        generation: u64,
        created: &str,
        expires: &str,
        action: &str,
        resume: &str,
    ) -> Result<Self, WireError> {
        let (Some(preview_id), Some(preview_digest)) = (
            text(preview, "previewId").filter(|id| identifier(id)),
            text(preview, "previewDigest").filter(|value| digest(value)),
        ) else {
            return Err(record_unreadable(
                "control-action preview binding is malformed",
            ));
        };
        let Value::Object(value) = json!({
            "actionId": format!("har-{action}"),
            "resumeReference": format!("resume-{resume}"),
            "controlActionId": control_action, "previewId": preview_id,
            "previewDigest": preview_digest,
            "controlActionGeneration": generation.to_string(),
            "createdAt": created, "expiresAt": expires, "status": "waiting",
        }) else {
            unreachable!("an object literal")
        };
        Self::parse(value)
    }

    /// Swift `init(value:)`.
    pub fn parse(value: Map<String, Value>) -> Result<Self, WireError> {
        let valid = exact_keys(&value, &APPROVAL_KEYS)
            && [
                "actionId",
                "resumeReference",
                "controlActionId",
                "previewId",
            ]
            .iter()
            .all(|key| text(&value, key).is_some_and(identifier))
            && text(&value, "previewDigest").is_some_and(digest)
            && text(&value, "controlActionGeneration")
                .and_then(generation)
                .is_some()
            && matches!(
                (
                    text(&value, "createdAt").and_then(time),
                    text(&value, "expiresAt").and_then(time),
                ),
                (Some(start), Some(end)) if end > start
            )
            && text(&value, "status")
                .is_some_and(|status| ["waiting", "expired", "resolved"].contains(&status));
        if !valid {
            return Err(record_unreadable(
                "control-action human action is malformed",
            ));
        }
        Ok(Self {
            action_id: text(&value, "actionId").unwrap_or_default().to_owned(),
            status: text(&value, "status").unwrap_or_default().to_owned(),
            value,
        })
    }

    pub fn value(&self) -> &Map<String, Value> {
        &self.value
    }

    /// `actionId`, `har-<uuid>`.
    pub fn action_id(&self) -> &str {
        &self.action_id
    }

    pub fn status(&self) -> &str {
        &self.status
    }

    fn with_status(&self, status: &str) -> Result<Self, WireError> {
        let mut value = self.value.clone();
        value.insert("status".into(), json!(status));
        Self::parse(value)
    }

    /// A waiting approval expires; any other stays as it is.
    pub fn expiring(&self) -> Result<Self, WireError> {
        if self.status != "waiting" {
            return Ok(self.clone());
        }
        self.with_status("expired")
    }

    /// Only a waiting approval resolves.
    pub fn resolving(&self) -> Result<Self, WireError> {
        if self.status != "waiting" {
            return Err(refused(
                "humanActionExpired",
                "impact approval is no longer waiting",
            ));
        }
        self.with_status("resolved")
    }

    /// Swift `sameHumanAction`: everything but its status, and a status that
    /// stays or leaves `waiting` for `expired` or `resolved`.
    pub fn continues(&self, next: &Self) -> bool {
        let without = |value: &Map<String, Value>| {
            let mut fields = value.clone();
            fields.remove("status");
            fields
        };
        without(&self.value) == without(&next.value)
            && (self.status == next.status
                || (self.status == "waiting"
                    && ["expired", "resolved"].contains(&next.status.as_str())))
    }

    /// What `human-action.list`, `.show` and a control action's projection
    /// answer: `arkdeck.human-action/1` owned by the control action.
    pub fn projection(&self) -> Value {
        let field = |key: &str| self.value.get(key).cloned().unwrap_or(Value::Null);
        json!({
            "schemaVersion": "arkdeck.human-action/1", "actionId": field("actionId"),
            "owner": owner(text(&self.value, "controlActionId").unwrap_or_default()),
            "resumeReference": field("resumeReference"), "category": "impactApproval",
            "reasonCode": "policy.impactApprovalRequired",
            "minimumAction": "human.reviewImpact", "prohibitedAutomation": ["selfApproval"],
            "createdAt": field("createdAt"), "expiresAt": field("expiresAt"),
            "status": field("status"), "newDispatchCount": 0,
            "selectionSchema": null, "choices": [],
            "binding": {
                "controlActionId": field("controlActionId"), "previewId": field("previewId"),
                "previewDigest": field("previewDigest"),
                "generation": field("controlActionGeneration"),
            },
        })
    }
}

/// The one-time console challenge issued for a waiting approval: Swift
/// `HDCControlInteractionChallenge`. Only the challenge's SHA-256 is kept.
#[derive(Clone, Debug, PartialEq)]
pub struct InteractionChallenge {
    value: Map<String, Value>,
}

const CHALLENGE_KEYS: [&str; 9] = [
    "challengeId",
    "challengeSha256",
    "controlActionId",
    "humanActionId",
    "previewId",
    "previewDigest",
    "controlActionGeneration",
    "issuedAt",
    "expiresAt",
];

impl InteractionChallenge {
    /// Swift `init(controlActionID:humanAction:challenge:issuedAt:expiresAt:)`;
    /// `id` is the random identity Swift draws for `challenge-`.
    pub fn new(
        control_action: &str,
        human: &ImpactApproval,
        challenge: &str,
        issued: &str,
        expires: &str,
        id: &str,
    ) -> Result<Self, WireError> {
        let field = |key: &str| human.value.get(key).cloned().unwrap_or(Value::Null);
        let Value::Object(value) = json!({
            "challengeId": format!("challenge-{id}"),
            "challengeSha256": sha256_hex(challenge.as_bytes()),
            "controlActionId": control_action, "humanActionId": human.action_id,
            "previewId": field("previewId"), "previewDigest": field("previewDigest"),
            "controlActionGeneration": field("controlActionGeneration"),
            "issuedAt": issued, "expiresAt": expires,
        }) else {
            unreachable!("an object literal")
        };
        Self::parse(value)
    }

    /// Swift `init(value:)`: issued before it expires, at most 120 s before.
    pub fn parse(value: Map<String, Value>) -> Result<Self, WireError> {
        let valid = exact_keys(&value, &CHALLENGE_KEYS)
            && [
                "challengeId",
                "controlActionId",
                "humanActionId",
                "previewId",
            ]
            .iter()
            .all(|key| text(&value, key).is_some_and(identifier))
            && ["challengeSha256", "previewDigest"]
                .iter()
                .all(|key| text(&value, key).is_some_and(digest))
            && text(&value, "controlActionGeneration")
                .and_then(generation)
                .is_some()
            && matches!(
                (
                    text(&value, "issuedAt").and_then(time),
                    text(&value, "expiresAt").and_then(time),
                ),
                (Some(start), Some(end)) if end > start && end - start <= CHALLENGE_LIFETIME_MS
            );
        if !valid {
            return Err(record_unreadable("interactive challenge is malformed"));
        }
        Ok(Self { value })
    }

    pub fn value(&self) -> &Map<String, Value> {
        &self.value
    }
}

/// The durable proof that a person typed the challenge in the same console:
/// Swift `HDCControlInteractionReceipt`. The plaintext is never kept.
#[derive(Clone, Debug, PartialEq)]
pub struct InteractionReceipt {
    value: Map<String, Value>,
}

const RECEIPT_KEYS: [&str; 10] = [
    "receiptId",
    "interactionOrigin",
    "controlActionId",
    "humanActionId",
    "challengeId",
    "challengeSha256",
    "previewId",
    "previewDigest",
    "controlActionGeneration",
    "confirmedAt",
];

impl InteractionReceipt {
    /// Swift `init(controlActionID:humanAction:challenge:response:confirmedAt:)`:
    /// only the issued challenge's own text confirms it; `id` is the random
    /// identity Swift draws for `interaction-`.
    pub fn new(
        control_action: &str,
        human: &ImpactApproval,
        challenge: &InteractionChallenge,
        response: &str,
        confirmed: &str,
        id: &str,
    ) -> Result<Self, WireError> {
        let Some(hash) = text(&challenge.value, "challengeSha256")
            .filter(|hash| *hash == sha256_hex(response.as_bytes()))
        else {
            return Err(refused(
                "impactApprovalChallengeMismatch",
                "the one-time impact challenge did not match",
            ));
        };
        let field = |key: &str| human.value.get(key).cloned().unwrap_or(Value::Null);
        let Value::Object(value) = json!({
            "receiptId": format!("interaction-{id}"),
            "interactionOrigin": "interactiveConsole",
            "controlActionId": control_action, "humanActionId": human.action_id,
            "challengeId": challenge.value.get("challengeId"), "challengeSha256": hash,
            "previewId": field("previewId"), "previewDigest": field("previewDigest"),
            "controlActionGeneration": field("controlActionGeneration"),
            "confirmedAt": confirmed,
        }) else {
            unreachable!("an object literal")
        };
        Self::parse(value)
    }

    /// Swift `init(value:)`.
    pub fn parse(value: Map<String, Value>) -> Result<Self, WireError> {
        let valid = exact_keys(&value, &RECEIPT_KEYS)
            && text(&value, "receiptId").is_some_and(identifier)
            && text(&value, "interactionOrigin") == Some("interactiveConsole")
            && [
                "controlActionId",
                "humanActionId",
                "challengeId",
                "previewId",
            ]
            .iter()
            .all(|key| text(&value, key).is_some_and(identifier))
            && ["challengeSha256", "previewDigest"]
                .iter()
                .all(|key| text(&value, key).is_some_and(digest))
            && text(&value, "controlActionGeneration")
                .and_then(generation)
                .is_some()
            && text(&value, "confirmedAt").and_then(time).is_some();
        if !valid {
            return Err(record_unreadable(
                "control-action interaction receipt is malformed",
            ));
        }
        Ok(Self { value })
    }

    pub fn value(&self) -> &Map<String, Value> {
        &self.value
    }
}
