//! Durable console approval and the accepted HDC lifecycle boundaries.
//! No method in this module launches a process or accepts caller audit facts.
use super::*;
use crate::control_action_approval::{InteractionChallenge, InteractionReceipt};

pub(super) const ADVANCED: [&str; 6] = [
    "approvalRecorded",
    "dispatchPrepared",
    "dispatching",
    "succeeded",
    "failed",
    "outcomeUnknown",
];
const ORDER: [&str; 7] = [
    "impactPreview",
    "confirmation",
    "intent",
    "actualCommand",
    "launchWindowEntered",
    "outcome",
    "reconciliation",
];
fn invalid() -> WireError {
    record_unreadable("HDC lifecycle record is malformed or not bound to its approval")
}
fn fields(value: &Value) -> Result<&Map<String, Value>, WireError> {
    value.as_object().ok_or_else(invalid)
}
fn text<'a>(value: &'a Value, key: &str) -> Option<&'a str> {
    value.get(key)?.as_str()
}
fn uuid(value: &str) -> bool {
    crate::session_cleanup_records::uuid(value)
}
fn bounded(value: &Value, limit: usize) -> bool {
    value.as_str().is_some_and(|s| {
        !s.is_empty() && s.len() <= limit && s.bytes().all(|c| c >= 32 && c != 127)
    })
}
fn positive(value: &Value) -> bool {
    value.as_i64().is_some_and(|v| v > 0)
}
fn canonical_unsigned(value: &Value, max: u64) -> bool {
    value.as_str().is_some_and(|s| {
        s.parse::<u64>()
            .is_ok_and(|n| n <= max && n.to_string() == s)
    })
}
fn strings(value: &Value) -> bool {
    value.as_array().is_some_and(|rows| {
        rows.len() <= MAX_COLLECTION
            && rows.iter().all(|v| bounded(v, 1024))
            && rows.windows(2).all(|p| p[0].as_str() < p[1].as_str())
    })
}
fn outcome(value: &Value) -> bool {
    let Some(f) = value.as_object() else {
        return false;
    };
    exact_keys(f, &["result", "resultingGeneration", "reason"])
        && match text(value, "result") {
            Some("succeeded") => {
                positive(&value["resultingGeneration"]) && value["reason"].is_null()
            }
            Some("stopped") => value["resultingGeneration"].is_null() && value["reason"].is_null(),
            Some("failed" | "outcomeUnknown") => {
                value["resultingGeneration"].is_null()
                    && value["reason"]
                        .as_str()
                        .is_some_and(|s| !s.is_empty() && s.len() <= 4096)
            }
            _ => false,
        }
}
fn valid_payload(kind: &str, p: &Value) -> bool {
    let Some(f) = p.as_object() else {
        return false;
    };
    let ids = |keys: &[&str]| keys.iter().all(|k| text(p, k).is_some_and(uuid));
    let hash = |key| text(p, key).is_some_and(digest);
    let ownership = |key| {
        matches!(
            text(p, key),
            Some("arkDeckManaged" | "external" | "unknown")
        )
    };
    let command = || {
        ids(&["stepId"])
            && text(p, "executable").is_some_and(|s| s.starts_with('/'))
            && text(p, "endpoint").is_some_and(|s| !s.is_empty())
            && p["argv"] == json!(["-s", p["endpoint"], "kill", "-r"])
    };
    match kind {
        "impactPreview" => {
            exact_keys(
                f,
                &[
                    "previewId",
                    "action",
                    "endpoint",
                    "generation",
                    "ownership",
                    "scopeHash",
                    "affectedDeviceCoordinators",
                    "affectedJobs",
                    "otherClientDetection",
                    "expectedInterruption",
                    "recoveryPath",
                ],
            ) && ids(&["previewId"])
                && p["action"] == "restartConfirmedGeneration"
                && bounded(&p["endpoint"], 256)
                && positive(&p["generation"])
                && ownership("ownership")
                && hash("scopeHash")
                && strings(&p["affectedDeviceCoordinators"])
                && strings(&p["affectedJobs"])
                && p["otherClientDetection"]
                    .as_object()
                    .is_some_and(|c| exact_keys(c, &["kind", "clients"]))
                && matches!(
                    text(&p["otherClientDetection"], "kind"),
                    Some(
                        "detected"
                            | "noneDetectedExternalClientsMayStillExist"
                            | "unavailableExternalClientsMayStillExist"
                    )
                )
                && p["otherClientDetection"]["clients"]
                    .as_array()
                    .is_some_and(|clients| {
                        clients.len() <= MAX_COLLECTION
                            && clients.iter().all(|v| {
                                v.as_str().is_some_and(|s| !s.is_empty() && s.len() <= 1024)
                            })
                            && (p["otherClientDetection"]["kind"] == "detected")
                                != clients.is_empty()
                    })
                && bounded(&p["expectedInterruption"], 4096)
                && bounded(&p["recoveryPath"], 4096)
        }
        "confirmation" => {
            exact_keys(
                f,
                &[
                    "confirmationId",
                    "previewId",
                    "action",
                    "endpoint",
                    "generation",
                    "ownership",
                    "scopeHash",
                ],
            ) && ids(&["confirmationId", "previewId"])
                && p["action"] == "restartConfirmedGeneration"
                && bounded(&p["endpoint"], 256)
                && positive(&p["generation"])
                && ownership("ownership")
                && hash("scopeHash")
        }
        "intent" => {
            exact_keys(
                f,
                &[
                    "stepId",
                    "confirmationId",
                    "action",
                    "endpoint",
                    "expectedGeneration",
                    "expectedOwnership",
                    "impactSnapshotHash",
                ],
            ) && ids(&["stepId", "confirmationId"])
                && p["action"] == "restartConfirmedGeneration"
                && bounded(&p["endpoint"], 256)
                && positive(&p["expectedGeneration"])
                && ownership("expectedOwnership")
                && hash("impactSnapshotHash")
        }
        "actualCommand" => {
            exact_keys(f, &["stepId", "executable", "argv", "endpoint"])
                && command()
                && p["executable"].as_str().is_some_and(|s| s.len() <= 4096)
        }
        "launchWindowEntered" => {
            exact_keys(
                f,
                &[
                    "stepId",
                    "executable",
                    "argv",
                    "endpoint",
                    "authorizedExecutable",
                    "inodeLaunchPath",
                    "executableDevice",
                    "executableInode",
                    "executableFileSize",
                    "executableMode",
                    "executableSha256",
                ],
            ) && command()
                && p["authorizedExecutable"] == p["executable"]
                && text(p, "inodeLaunchPath").is_some_and(|s| s.starts_with("/.vol/"))
                && canonical_unsigned(&p["executableDevice"], u64::MAX)
                && canonical_unsigned(&p["executableInode"], u64::MAX)
                && p["executableFileSize"].as_i64().is_some_and(|n| n >= 0)
                && canonical_unsigned(&p["executableMode"], u32::MAX.into())
                && hash("executableSha256")
        }
        "outcome" => {
            exact_keys(f, &["stepId", "outcome"]) && ids(&["stepId"]) && outcome(&p["outcome"])
        }
        "reconciliation" => {
            let observation = &p["postDispatchObservation"];
            let scope = &p["observedScope"];
            exact_keys(
                f,
                &[
                    "reconciliationId",
                    "stepId",
                    "expectedScopeHash",
                    "historicalOutcome",
                    "outwardOutcome",
                    "postDispatchObservation",
                    "requiresReconcile",
                    "reason",
                    "observedScope",
                ],
            ) && ids(&["reconciliationId", "stepId"])
                && hash("expectedScopeHash")
                && outcome(&p["historicalOutcome"])
                && outcome(&p["outwardOutcome"])
                && p["requiresReconcile"].is_boolean()
                && bounded(&p["reason"], 4096)
                && observation
                    .as_object()
                    .is_some_and(|f| exact_keys(f, &["kind", "generation"]))
                && match text(observation, "kind") {
                    Some("generation") => positive(&observation["generation"]),
                    Some("unavailable" | "missing") => observation["generation"].is_null(),
                    _ => false,
                }
                && scope.as_object().is_some_and(|f| {
                    exact_keys(
                        f,
                        &[
                            "action",
                            "endpoint",
                            "health",
                            "version",
                            "generation",
                            "generationEvidence",
                            "ownership",
                            "affectedDeviceCoordinators",
                            "affectedJobs",
                            "otherClientDetection",
                            "criticalJobs",
                            "impactReliable",
                            "scopeHash",
                        ],
                    )
                })
                && scope["action"] == "restartConfirmedGeneration"
                && text(scope, "endpoint").is_some_and(|s| !s.is_empty())
                && scope["affectedDeviceCoordinators"].is_array()
                && scope["affectedJobs"].is_array()
                && scope["otherClientDetection"].is_object()
                && scope["criticalJobs"].is_array()
                && scope["impactReliable"].is_boolean()
        }
        _ => false,
    }
}
fn state_after(event: &Value) -> &'static str {
    match text(event, "kind") {
        Some("impactPreview" | "confirmation") => "approvalRecorded",
        Some("intent" | "actualCommand") => "dispatchPrepared",
        Some("launchWindowEntered") => "dispatching",
        Some("outcome") if event["payload"]["outcome"]["result"] == "failed" => "failed",
        Some("outcome") => "dispatching",
        Some("reconciliation")
            if matches!(
                text(&event["payload"]["outwardOutcome"], "result"),
                Some("succeeded" | "stopped")
            ) =>
        {
            "succeeded"
        }
        _ => "outcomeUnknown",
    }
}

pub(super) fn validate(
    value: &Map<String, Value>,
    id: &str,
    state: &str,
    expiry: u64,
    approval: Option<&ImpactApproval>,
    preview: Option<&Preview>,
    intent: &Intent,
) -> Result<(), WireError> {
    let challenge = match value.get("interactionChallenge") {
        Some(Value::Null) => None,
        Some(Value::Object(f)) => Some(InteractionChallenge::parse(f.clone())?),
        _ => return Err(invalid()),
    };
    let receipt = match value.get("interactionReceipt") {
        Some(Value::Null) => None,
        Some(Value::Object(f)) => Some(InteractionReceipt::parse(f.clone())?),
        _ => return Err(invalid()),
    };
    if let Some(challenge) = &challenge {
        let human = approval.ok_or_else(invalid)?;
        let c = challenge.value();
        if !(state == "awaitingImpactApproval"
            || ADVANCED.contains(&state)
            || ["expired", "previewDrifted"].contains(&state))
            || c["controlActionId"] != id
            || c["humanActionId"] != human.action_id()
            || ["previewId", "previewDigest", "controlActionGeneration"]
                .iter()
                .any(|k| c.get(*k) != human.value().get(*k))
            || c.get("expiresAt")
                .and_then(Value::as_str)
                .and_then(time)
                .is_none_or(|end| end > expiry)
        {
            return Err(invalid());
        }
    }
    if let Some(receipt) = &receipt {
        let human = approval.ok_or_else(invalid)?;
        let c = challenge.as_ref().ok_or_else(invalid)?.value();
        let r = receipt.value();
        let at = |f: &Map<String, Value>, k: &str| f.get(k).and_then(Value::as_str).and_then(time);
        if human.status() != "resolved"
            || r["controlActionId"] != id
            || r["humanActionId"] != human.action_id()
            || ["challengeId", "challengeSha256"]
                .iter()
                .any(|k| r.get(*k) != c.get(*k))
            || ["previewId", "previewDigest", "controlActionGeneration"]
                .iter()
                .any(|k| r.get(*k) != human.value().get(*k))
            || !matches!((at(r,"confirmedAt"),at(c,"issuedAt"),at(c,"expiresAt")),(Some(t),Some(start),Some(end)) if t >= start && t < end)
        {
            return Err(invalid());
        }
    } else if ADVANCED.contains(&state) {
        return Err(invalid());
    }
    let events = value
        .get("lifecycleAudit")
        .and_then(Value::as_array)
        .filter(|v| v.len() <= 16)
        .ok_or_else(invalid)?;
    for (i, event) in events.iter().enumerate() {
        let f = fields(event)?;
        if !exact_keys(
            f,
            &[
                "eventId",
                "sequence",
                "kind",
                "auditId",
                "recordedAt",
                "payload",
            ],
        ) || !text(event, "eventId").is_some_and(identifier)
            || event["sequence"].as_u64() != Some((i + 1) as u64)
            || !text(event, "auditId").is_some_and(uuid)
            || !text(event, "recordedAt").is_some_and(|s| time(s).is_some())
            || !text(event, "kind").is_some_and(|kind| valid_payload(kind, &event["payload"]))
        {
            return Err(invalid());
        }
    }
    if events.is_empty() {
        return if ADVANCED[1..].contains(&state) {
            Err(invalid())
        } else {
            Ok(())
        };
    }
    let preview = preview.ok_or_else(invalid)?;
    if receipt.is_none() || events.iter().any(|e| e["auditId"] != events[0]["auditId"]) {
        return Err(invalid());
    }
    let kinds: Vec<_> = events.iter().filter_map(|e| text(e, "kind")).collect();
    let prefix = kinds.len() <= ORDER.len() && kinds == ORDER[..kinds.len()];
    let failed_before = (kinds == ["impactPreview", "confirmation", "intent", "outcome"]
        || kinds
            == [
                "impactPreview",
                "confirmation",
                "intent",
                "actualCommand",
                "outcome",
            ])
        && events
            .last()
            .is_some_and(|e| e["payload"]["outcome"]["result"] == "failed");
    if !prefix && !failed_before {
        return Err(invalid());
    }
    let first = &events[0]["payload"];
    if first["action"] != "restartConfirmedGeneration"
        || first["generation"].as_u64() != Some(intent.generation)
        || first["endpoint"] != preview.impact.value["endpoint"]
        || first["ownership"] != preview.impact.value["serverOwnership"]
        || first["affectedDeviceCoordinators"] != preview.impact.value["affectedTargetIds"]
        || first["affectedJobs"] != preview.impact.value["affectedJobIds"]
    {
        return Err(invalid());
    }
    if let Some(event) = events.get(1)
        && [
            "previewId",
            "action",
            "endpoint",
            "generation",
            "ownership",
            "scopeHash",
        ]
        .iter()
        .any(|k| event["payload"][*k] != first[*k])
    {
        return Err(invalid());
    }
    if let Some(event) = events.get(2) {
        let confirmation = &events[1]["payload"];
        let p = &event["payload"];
        if [
            ("confirmationId", "confirmationId"),
            ("action", "action"),
            ("endpoint", "endpoint"),
            ("expectedGeneration", "generation"),
            ("expectedOwnership", "ownership"),
            ("impactSnapshotHash", "scopeHash"),
        ]
        .iter()
        .any(|(a, b)| p[*a] != confirmation[*b])
            || events
                .iter()
                .skip(3)
                .any(|e| e["payload"]["stepId"] != p["stepId"])
        {
            return Err(invalid());
        }
    }
    if ["expired", "previewDrifted"].contains(&state) && !kinds.contains(&"intent") {
        return Ok(());
    }
    if state != state_after(events.last().ok_or_else(invalid)?) {
        return Err(invalid());
    }
    Ok(())
}

pub(super) fn continues(old: &Record, next: &Record) -> bool {
    let receipt = old.value.get("interactionReceipt");
    (receipt == Some(&Value::Null) || receipt == next.value.get("interactionReceipt"))
        && (next.value.get("interactionReceipt") == Some(&Value::Null)
            || old.value.get("interactionChallenge") == next.value.get("interactionChallenge"))
        && next.audit().starts_with(old.audit())
        && next.audit().len() <= old.audit().len() + 1
}

impl Record {
    pub(super) fn audit(&self) -> &[Value] {
        self.value["lifecycleAudit"]
            .as_array()
            .map(Vec::as_slice)
            .unwrap_or(&[])
    }
    fn issuing_challenge(&self, plaintext: &str, now: u64, id: &str) -> Result<Self, WireError> {
        let human = self
            .approval
            .as_ref()
            .filter(|a| a.status() == "waiting")
            .filter(|_| self.state == "awaitingImpactApproval")
            .ok_or_else(|| {
                refused(
                    "admissionDenied",
                    "impact approval is not awaiting an interactive challenge",
                )
            })?;
        if plaintext.len() != 17
            || !plaintext.starts_with("ARKDECK-")
            || !plaintext[8..]
                .bytes()
                .all(|c| c.is_ascii_uppercase() || c.is_ascii_digit())
        {
            return Err(invalid());
        }
        let expiry = time(&self.expires)
            .filter(|end| now < *end)
            .ok_or_else(|| refused("humanActionExpired", "impact approval expired"))?;
        let challenge = InteractionChallenge::new(
            &self.id,
            human,
            plaintext,
            &timestamp(now),
            &timestamp(expiry.min(now.saturating_add(120_000))),
            id,
        )?;
        let mut value = self.advanced(now)?;
        value.insert(
            "interactionChallenge".into(),
            Value::Object(challenge.value().clone()),
        );
        Self::parse(value)
    }
    fn recording_approval(&self, response: &str, now: u64, id: &str) -> Result<Self, WireError> {
        let human = self
            .approval
            .as_ref()
            .filter(|_| {
                self.state == "awaitingImpactApproval" && self.value["interactionReceipt"].is_null()
            })
            .ok_or_else(|| {
                refused(
                    "impactApprovalChallengeExpired",
                    "the one-time impact challenge is absent or expired",
                )
            })?;
        let challenge =
            InteractionChallenge::parse(fields(&self.value["interactionChallenge"])?.clone())?;
        if challenge
            .value()
            .get("expiresAt")
            .and_then(Value::as_str)
            .and_then(time)
            .is_none_or(|end| now >= end)
        {
            return Err(refused(
                "impactApprovalChallengeExpired",
                "the one-time impact challenge is absent or expired",
            ));
        }
        let receipt =
            InteractionReceipt::new(&self.id, human, &challenge, response, &timestamp(now), id)?;
        let mut value = self.advanced(now)?;
        value.insert(
            "interactionReceipt".into(),
            Value::Object(receipt.value().clone()),
        );
        value.insert(
            "humanAction".into(),
            Value::Object(human.resolving()?.value().clone()),
        );
        value.insert("state".into(), json!("approvalRecorded"));
        Self::parse(value)
    }
    fn append_audit(
        &self,
        kind: &str,
        audit: &str,
        payload: Value,
        now: u64,
        event: &str,
    ) -> Result<Self, WireError> {
        if self.value["interactionReceipt"].is_null()
            || !["approvalRecorded", "dispatchPrepared", "dispatching"]
                .contains(&self.state.as_str())
            || self.audit().len() >= 16
        {
            return Err(refused(
                "admissionDenied",
                "control action cannot append another HDC lifecycle event",
            ));
        }
        let event = json!({"eventId":format!("lifecycle-event-{event}"),"sequence":self.audit().len()+1,"kind":kind,"auditId":audit,"recordedAt":timestamp(now),"payload":payload});
        let state = state_after(&event);
        let mut events = self.audit().to_vec();
        events.push(event);
        let mut value = self.advanced(now)?;
        value.insert("lifecycleAudit".into(), json!(events));
        value.insert("state".into(), json!(state));
        value.insert(
            "blockerReasonCode".into(),
            match state {
                "failed" => json!("hdc.lifecycleFailedBeforeLaunch"),
                "outcomeUnknown" => json!("hdc.lifecycleOutcomeUnknown"),
                _ => Value::Null,
            },
        );
        Self::parse(value)
    }
}

impl HdcControlActions {
    pub(super) fn append_lifecycle(
        &self,
        id: &str,
        kind: &str,
        audit: &str,
        payload: Value,
    ) -> Result<Record, WireError> {
        let old = self.required(id)?;
        let next =
            old.append_audit(kind, audit, payload, self.clock()?, &(self.context.uuid)()?)?;
        self.store.replace(&next, old.generation)?;
        Ok(next)
    }
    pub(super) fn recover_interrupted(&self, id: &str) -> Result<Record, WireError> {
        let mut record = self.required(id)?;
        if record.state == "approvalRecorded" {
            let now = self.clock()?;
            let expired = time(&record.expires).is_none_or(|end| now >= end);
            let next = record.invalidated(
                if expired {
                    "controlAction.expired"
                } else {
                    "hdc.lifecycleInterruptedBeforeIntent"
                },
                expired,
                now,
            )?;
            self.store.replace(&next, record.generation)?;
            return Ok(next);
        }
        if !["dispatchPrepared", "dispatching"].contains(&record.state.as_str()) {
            return Ok(record);
        }
        let audit = text(&record.audit()[0], "auditId")
            .ok_or_else(invalid)?
            .to_owned();
        let intent = record
            .audit()
            .iter()
            .find(|e| e["kind"] == "intent")
            .ok_or_else(invalid)?["payload"]
            .clone();
        if record.state == "dispatchPrepared" {
            return self.append_lifecycle(id,"outcome",&audit,json!({"stepId":intent["stepId"],"outcome":{"result":"failed","resultingGeneration":null,"reason":"Runtime restarted before the durable HDC launch-window entry"}}));
        }
        if record
            .audit()
            .last()
            .is_some_and(|e| e["kind"] == "launchWindowEntered")
        {
            record = self.append_lifecycle(id,"outcome",&audit,json!({"stepId":intent["stepId"],"outcome":{"result":"outcomeUnknown","resultingGeneration":null,"reason":"Runtime restarted after the durable HDC launch-window entry"}}))?;
        }
        let historical = &record
            .audit()
            .last()
            .filter(|e| e["kind"] == "outcome")
            .ok_or_else(invalid)?["payload"]["outcome"];
        self.append_lifecycle(id,"reconciliation",&audit,json!({
            "reconciliationId":(self.context.uuid)()?,"stepId":intent["stepId"],"expectedScopeHash":intent["impactSnapshotHash"],"historicalOutcome":historical,
            "outwardOutcome":{"result":"outcomeUnknown","resultingGeneration":null,"reason":"Runtime restarted before terminal HDC lifecycle reconciliation"},
            "postDispatchObservation":{"kind":"missing","generation":null},"requiresReconcile":true,
            "reason":"Runtime restarted before terminal lifecycle reconciliation; the external outcome remains unknown and is never replayed",
            "observedScope":{"action":"restartConfirmedGeneration","endpoint":intent["endpoint"],"health":null,"version":null,"generation":null,"generationEvidence":null,"ownership":null,"affectedDeviceCoordinators":[],"affectedJobs":[],"otherClientDetection":{"kind":"unavailableExternalClientsMayStillExist","clients":[]},"criticalJobs":[],"impactReliable":false,"scopeHash":null}
        }))
    }
}

/// The Runtime's lifecycle driver. A caller cannot supply a driver or audit
/// event through the control protocol. The owner holds final Job admission
/// frozen while this driver runs and while interruption recovery is persisted.
pub trait HdcLifecycleDriver {
    fn restart(
        &self,
        reading: &ImpactReading,
        audit: &HdcLifecycleAudit<'_>,
    ) -> Result<(), WireError>;
}

/// One Runtime-owned durable audit, bound to the approved action and impact.
/// The driver cannot switch its action, preview, approval, or append order.
pub struct HdcLifecycleAudit<'a> {
    owner: &'a HdcControlActions,
    id: &'a str,
    source: &'a dyn ImpactSource,
    approved: &'a ImpactReading,
}
impl HdcLifecycleAudit<'_> {
    pub fn record(&self) -> Result<Record, WireError> {
        self.owner.required(self.id)
    }
    /// The closed Swift event vocabulary and payloads are validated before
    /// the CAS publication; launch is permitted only after its marker returns.
    pub fn append(&self, kind: &str, audit_id: &str, payload: Value) -> Result<Record, WireError> {
        if kind == "actualCommand" {
            if !self.impact_is_current()? {
                return Err(refused(
                    "factsDrifted",
                    "HDC impact changed before durable dispatch authorization",
                ));
            }
            let record = self.record()?;
            let intent = record
                .audit()
                .last()
                .filter(|e| e["kind"] == "intent")
                .ok_or_else(invalid)?;
            if intent["auditId"] != audit_id
                || intent["payload"]["stepId"] != payload["stepId"]
                || intent["payload"]["endpoint"] != payload["endpoint"]
            {
                return Err(invalid());
            }
        }
        if kind == "launchWindowEntered" {
            let record = self.record()?;
            let prior = record
                .audit()
                .last()
                .filter(|e| e["kind"] == "actualCommand")
                .ok_or_else(invalid)?;
            if prior["auditId"] != audit_id
                || ["stepId", "executable", "argv", "endpoint"]
                    .iter()
                    .any(|key| prior["payload"][*key] != payload[*key])
                || payload["inodeLaunchPath"]
                    != json!(format!(
                        "/.vol/{}/{}",
                        payload["executableDevice"].as_str().unwrap_or_default(),
                        payload["executableInode"].as_str().unwrap_or_default()
                    ))
            {
                return Err(invalid());
            }
        }
        self.owner
            .append_lifecycle(self.id, kind, audit_id, payload)
    }
    /// Re-read trusted impact at the executor's authorization boundary.
    pub fn impact_is_current(&self) -> Result<bool, WireError> {
        let current = self
            .source
            .read_impact()
            .map_err(|_| drifted("HDC impact observation is unavailable"))?;
        Ok(current.impact == self.approved.impact
            && current.relations == self.approved.relations
            && current.blocker.is_none()
            && current.impact.critical_gate_is_clear())
    }
}

impl HdcControlActions {
    /// Issue the foreground console's one-time challenge. The transport,
    /// not a request parameter, decides whether this method can be reached.
    pub fn issue_interactive_challenge(
        &self,
        action: &str,
        reference: &str,
    ) -> Result<Value, WireError> {
        let matching: Vec<_> = self
            .store
            .list()?
            .into_iter()
            .filter(|r| {
                r.approval.as_ref().is_some_and(|a| {
                    a.action_id() == action && a.value()["resumeReference"] == reference
                })
            })
            .collect();
        if matching.len() != 1 {
            return Err(refused("resourceNotFound", "human action does not exist"));
        }
        let current = self.refresh_age(matching.into_iter().next().ok_or_else(invalid)?)?;
        let human = current
            .approval
            .as_ref()
            .filter(|a| current.state == "awaitingImpactApproval" && a.status() == "waiting")
            .ok_or_else(|| refused("humanActionExpired", "impact approval is no longer waiting"))?;
        let random = (self.context.uuid)()?.replace('-', "").to_ascii_uppercase();
        let suffix = random.get(..9).ok_or_else(invalid)?;
        let plaintext = format!("ARKDECK-{suffix}");
        let next = current.issuing_challenge(&plaintext, self.clock()?, &(self.context.uuid)()?)?;
        self.store.replace(&next, current.generation)?;
        let issued = &next.value["interactionChallenge"];
        Ok(
            json!({"schemaVersion":"arkdeck.impact-approval-challenge/1","interactionOrigin":"interactiveConsole","challenge":plaintext,"challengeId":issued["challengeId"],"expiresAt":issued["expiresAt"],"humanAction":human.projection(),"controlAction":next.projection(),"binding":{"controlActionId":issued["controlActionId"],"humanActionId":issued["humanActionId"],"previewId":issued["previewId"],"previewDigest":issued["previewDigest"],"generation":issued["controlActionGeneration"]},"newDispatchCount":0}),
        )
    }

    /// Consume the challenge after acquiring the final Job interlock and
    /// reproducing the entire approved impact. Only a configured Runtime
    /// lifecycle driver can advance a receipt to dispatch.
    pub fn consume_interactive_challenge(
        &self,
        id: &str,
        reference: &str,
        response: &str,
        jobs: &crate::JobStore,
        source: &dyn ImpactSource,
        driver: &dyn HdcLifecycleDriver,
    ) -> Result<Value, WireError> {
        if response.len() != 17
            || !response.starts_with("ARKDECK-")
            || !response[8..]
                .bytes()
                .all(|c| c.is_ascii_digit() || c.is_ascii_uppercase())
        {
            return Err(refused(
                "admissionDenied",
                "interactive HDC lifecycle execution is unavailable",
            ));
        }
        let before = self.refresh_age(self.required(id)?)?;
        if before.state != "awaitingImpactApproval"
            || before
                .approval
                .as_ref()
                .is_none_or(|a| a.value()["resumeReference"] != reference)
            || before.value["interactionChallenge"].is_null()
        {
            return Err(refused(
                "humanActionExpired",
                "impact approval is no longer awaiting this challenge",
            ));
        }
        let _interlock = jobs.acquire_hdc_lifecycle_interlock()?;
        let run = || {
            let reading = source
                .read_impact()
                .map_err(|_| drifted("HDC impact observation is unavailable"))?;
            let latest = self.refresh_age(self.required(id)?)?;
            if latest.generation != before.generation
                || latest.approval != before.approval
                || latest.value["interactionChallenge"] != before.value["interactionChallenge"]
                || latest
                    .preview
                    .as_ref()
                    .is_none_or(|p| p.impact != reading.impact)
                || latest.value["observationRelations"] != json!(reading.relations)
                || blocker(&reading, &latest.intent).is_some()
            {
                let invalid = self.invalidate_latest(&latest, "hdc.previewDrifted")?;
                return Err(drifted_action(
                    "fresh HDC impact differs before interactive approval",
                    &invalid,
                ));
            }
            let approved =
                latest.recording_approval(response, self.clock()?, &(self.context.uuid)()?)?;
            self.store.replace(&approved, latest.generation)?;
            driver.restart(
                &reading,
                &HdcLifecycleAudit {
                    owner: self,
                    id,
                    source,
                    approved: &reading,
                },
            )?;
            let completed = self.required(id)?;
            if !["succeeded", "failed", "outcomeUnknown"].contains(&completed.state.as_str()) {
                return Err(record_unreadable(
                    "HDC lifecycle driver returned a nonterminal control action",
                ));
            }
            Ok(completed.projection())
        };
        let result = run();
        if result.is_err() {
            self.recover_interrupted(id)?;
        }
        result
    }
}
