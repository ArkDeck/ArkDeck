//! Journal records for the kinds the Swift engine writes, spelled as Swift's
//! `JournalEvent` factories and `jsonObject` spell them: intent and outcome
//! envelope keys are always present (null when absent), optional outcome text
//! is omitted when absent, and every record carries schema 1.0.0. Building a
//! record grants nothing; the writer validates it before any byte is written.
use arkdeck_contract::sha256_hex;
use serde_json::{Map, Value, json};

#[derive(Clone, Debug)]
pub struct Envelope {
    pub event_id: String,
    pub sequence: i64,
    pub session_id: String,
    pub job_id: String,
    pub timestamp: String,
}

#[derive(Clone, Debug)]
pub struct Target {
    pub scope: String,
    pub target_id: String,
    pub connect_key: Option<String>,
    pub identity_snapshot_hash: Option<String>,
}
impl Target {
    fn value(&self) -> Value {
        json!({"scope":self.scope, "targetId":self.target_id, "connectKey":self.connect_key,
            "identitySnapshotHash":self.identity_snapshot_hash})
    }
}

fn record(envelope: &Envelope, kind: &str, payload: Value) -> Map<String, Value> {
    Map::from_iter([
        ("schemaVersion".into(), json!("1.0.0")),
        ("eventId".into(), json!(envelope.event_id)),
        ("sequence".into(), json!(envelope.sequence)),
        ("sessionId".into(), json!(envelope.session_id)),
        ("jobId".into(), json!(envelope.job_id)),
        ("timestamp".into(), json!(envelope.timestamp)),
        ("kind".into(), json!(kind)),
        ("payload".into(), payload),
    ])
}
fn outcome_text(payload: &mut Value, semantic_code: Option<&str>, summary: Option<&str>) {
    if let Some(code) = semantic_code {
        payload["semanticCode"] = json!(code);
    }
    if let Some(summary) = summary {
        payload["summary"] = json!(summary);
    }
}

pub fn job_created(
    envelope: &Envelope,
    execution_mode: &str,
    execution_authority: &str,
    core_baseline: &str,
) -> Value {
    Value::Object(record(
        envelope,
        "jobCreated",
        json!({"executionMode":execution_mode, "executionAuthority":execution_authority,
            "initialState":"queued", "coreBaseline":core_baseline}),
    ))
}

pub fn state_transition(
    envelope: &Envelope,
    from: &str,
    to: &str,
    reason: &str,
    trigger_event_id: Option<&str>,
) -> Value {
    Value::Object(record(
        envelope,
        "stateTransition",
        json!({"from":from, "to":to, "reason":reason, "triggerEventId":trigger_event_id}),
    ))
}

/// `step` is the encoded WorkflowStep; its argument hash is derived here.
pub fn step_intent(
    envelope: &Envelope,
    step: &Value,
    target: &Target,
    attempt: i64,
    binding_revision: Option<i64>,
) -> Result<Value, &'static str> {
    let arguments = crate::session_json::encode(&step["arguments"])
        .map_err(|_| "step arguments are not canonical JSON")?;
    let step_id = step["id"].as_str().ok_or("step has no identity")?;
    let mut object = record(
        envelope,
        "stepIntent",
        json!({"step":step, "target":target.value()}),
    );
    object.insert("stepId".into(), json!(step_id));
    object.insert("attempt".into(), json!(attempt));
    object.insert("bindingRevision".into(), json!(binding_revision));
    object.insert("argumentsHash".into(), json!(sha256_hex(&arguments)));
    Ok(Value::Object(object))
}

#[allow(clippy::too_many_arguments)]
pub fn step_outcome(
    envelope: &Envelope,
    step_id: &str,
    attempt: i64,
    correlates_to_intent_event_id: &str,
    result: &str,
    outcome_certainty: &str,
    semantic_code: Option<&str>,
    summary: Option<&str>,
) -> Value {
    let mut payload = json!({"correlatesToIntentEventId":correlates_to_intent_event_id,
        "result":result, "outcomeCertainty":outcome_certainty});
    outcome_text(&mut payload, semantic_code, summary);
    let mut object = record(envelope, "stepOutcome", payload);
    object.insert("stepId".into(), json!(step_id));
    object.insert("attempt".into(), json!(attempt));
    Value::Object(object)
}

/// `descriptor` is the encoded CompensationDescriptor its source declared.
pub fn compensation_intent(
    envelope: &Envelope,
    compensation_of_step_id: &str,
    descriptor: &Value,
    target: &Target,
    attempt: i64,
    binding_revision: Option<i64>,
) -> Result<Value, &'static str> {
    let descriptor_id = descriptor["id"]
        .as_str()
        .ok_or("compensation has no identity")?;
    let hash = descriptor["argumentsHash"]
        .as_str()
        .ok_or("compensation has no argument hash")?
        .to_ascii_lowercase();
    let mut object = record(
        envelope,
        "compensationIntent",
        json!({"compensationOfStepId":compensation_of_step_id, "descriptor":descriptor,
            "target":target.value()}),
    );
    object.insert("stepId".into(), json!(descriptor_id));
    object.insert("attempt".into(), json!(attempt));
    object.insert("bindingRevision".into(), json!(binding_revision));
    object.insert("argumentsHash".into(), json!(hash));
    Ok(Value::Object(object))
}

#[allow(clippy::too_many_arguments)]
pub fn compensation_outcome(
    envelope: &Envelope,
    compensation_of_step_id: &str,
    descriptor_id: &str,
    attempt: i64,
    correlates_to_intent_event_id: &str,
    result: &str,
    outcome_certainty: &str,
    semantic_code: Option<&str>,
    summary: Option<&str>,
) -> Value {
    let mut payload = json!({"compensationOfStepId":compensation_of_step_id,
        "descriptorId":descriptor_id, "correlatesToIntentEventId":correlates_to_intent_event_id,
        "result":result, "outcomeCertainty":outcome_certainty});
    outcome_text(&mut payload, semantic_code, summary);
    let mut object = record(envelope, "compensationOutcome", payload);
    object.insert("stepId".into(), json!(descriptor_id));
    object.insert("attempt".into(), json!(attempt));
    Value::Object(object)
}

pub fn reconcile_started(
    envelope: &Envelope,
    recovery_attempt_id: &str,
    source_state: &str,
    last_durable_sequence: i64,
    trigger: &str,
) -> Value {
    Value::Object(record(
        envelope,
        "reconcileStarted",
        json!({"recoveryAttemptId":recovery_attempt_id, "sourceState":source_state,
            "lastDurableSequence":last_durable_sequence, "trigger":trigger}),
    ))
}

#[allow(clippy::too_many_arguments)]
pub fn reconcile_outcome(
    envelope: &Envelope,
    binding_revision: Option<i64>,
    recovery_attempt_id: &str,
    result: &str,
    next_state: &str,
    outcome_certainty: &str,
    safe_boundary_confirmed: bool,
    evidence: &[&str],
) -> Value {
    let mut object = record(
        envelope,
        "reconcileOutcome",
        json!({"recoveryAttemptId":recovery_attempt_id, "result":result,
            "nextState":next_state, "outcomeCertainty":outcome_certainty,
            "safeBoundaryConfirmed":safe_boundary_confirmed, "evidence":evidence}),
    );
    object.insert("bindingRevision".into(), json!(binding_revision));
    Value::Object(object)
}

pub fn finalized(
    envelope: &Envelope,
    terminal_status: &str,
    manifest_sha256: &str,
    outcome_certainty: &str,
) -> Value {
    Value::Object(record(
        envelope,
        "finalized",
        json!({"terminalStatus":terminal_status, "manifestSha256":manifest_sha256,
            "outcomeCertainty":outcome_certainty}),
    ))
}
