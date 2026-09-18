//! Strict current Job snapshots. Unknown durable fields are refused, never
//! dropped while projecting a successful result. This reader grants no authority.
use super::job_repository::{JobRow, identifier, order_key};
use arkdeck_contract::{WireError, strict_json};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};

pub(super) fn failure(code: &str, message: &str) -> WireError {
    WireError {
        code: code.into(),
        message: message.into(),
        details: None,
    }
}
pub(super) fn unreadable(_: impl std::fmt::Debug) -> WireError {
    failure(
        "recordUnreadable",
        "The Runtime Job snapshot is unreadable or unsupported",
    )
}
pub(super) const STATES: &[&str] = &[
    "queued",
    "preflight",
    "running",
    "waitingForDevice",
    "awaitingRebindConfirmation",
    "planning",
    "cancelRequested",
    "cancellingAtSafeBoundary",
    "waitingForRecovery",
    "reconciling",
    "recoveringByCompleteOverwrite",
    "resumeAtConfirmedSafeBoundary",
    "userAbandonRequested",
    "finalizing",
    "planned",
    "succeeded",
    "recovered",
    "failed",
    "cancelled",
    "interrupted",
];
pub(super) fn terminal(state: &str) -> bool {
    [
        "planned",
        "succeeded",
        "recovered",
        "failed",
        "cancelled",
        "interrupted",
    ]
    .contains(&state)
}
pub(super) fn digest(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c))
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct JobRecord {
    #[serde(rename = "jobID")]
    pub job_id: String,
    pub request: Value,
    #[serde(
        rename = "originalSubmissionRequest",
        skip_serializing_if = "Option::is_none"
    )]
    original_request: Option<Value>,
    #[serde(rename = "operationReference")]
    operation: String,
    #[serde(rename = "catalogDigest")]
    catalog: String,
    #[serde(rename = "providerID")]
    provider: String,
    #[serde(rename = "createdAtUTC")]
    created: String,
    #[serde(rename = "actualEffect", skip_serializing_if = "Option::is_none")]
    effect: Option<String>,
    #[serde(rename = "admissionEvidence", skip_serializing_if = "Option::is_none")]
    admission: Option<Value>,
    #[serde(
        rename = "materializedPlanDigest",
        skip_serializing_if = "Option::is_none"
    )]
    plan: Option<String>,
    #[serde(
        rename = "materializedStableTargetIdentitySHA256",
        skip_serializing_if = "Option::is_none"
    )]
    identity: Option<String>,
    #[serde(
        rename = "materializedBindingRevision",
        skip_serializing_if = "Option::is_none"
    )]
    binding: Option<i64>,
    pub state: String,
    #[serde(rename = "outcomeUnknown")]
    unknown: bool,
    #[serde(rename = "operationFailure", skip_serializing_if = "Option::is_none")]
    operation_failure: Option<Value>,
    #[serde(rename = "recoveryStepID", skip_serializing_if = "Option::is_none")]
    recovery_step: Option<String>,
    #[serde(rename = "recoveryAction", skip_serializing_if = "Option::is_none")]
    recovery_action: Option<Value>,
    #[serde(
        rename = "recoveryIntentEventID",
        skip_serializing_if = "Option::is_none"
    )]
    recovery_intent: Option<String>,
    #[serde(rename = "evidencePreflight", skip_serializing_if = "Option::is_none")]
    evidence_preflight: Option<Value>,
    #[serde(
        rename = "evidenceObservation",
        skip_serializing_if = "Option::is_none"
    )]
    evidence_observation: Option<Value>,
    #[serde(rename = "traceProbeBefore", skip_serializing_if = "Option::is_none")]
    trace_before: Option<Value>,
    #[serde(rename = "traceProbeAfter", skip_serializing_if = "Option::is_none")]
    trace_after: Option<Value>,
    #[serde(
        rename = "sessionPublicationRecord",
        skip_serializing_if = "Option::is_none"
    )]
    session_publication: Option<Value>,
    pub timeline: Vec<String>,
    #[serde(rename = "actualStepKinds", skip_serializing_if = "Option::is_none")]
    step_kinds: Option<Vec<String>>,
    #[serde(rename = "startedAtUTC", skip_serializing_if = "Option::is_none")]
    started: Option<String>,
    #[serde(
        rename = "firstEvidenceStepAtUTC",
        skip_serializing_if = "Option::is_none"
    )]
    first_evidence: Option<String>,
    #[serde(rename = "finishedAtUTC", skip_serializing_if = "Option::is_none")]
    finished: Option<String>,
    #[serde(rename = "ringCoverage", skip_serializing_if = "Option::is_none")]
    ring: Option<Value>,
    #[serde(rename = "screenSequence", skip_serializing_if = "Option::is_none")]
    screen: Option<Value>,
    #[serde(rename = "skipReasons")]
    skip_reasons: std::collections::BTreeMap<String, String>,
    #[serde(
        rename = "outstandingResidueCount",
        skip_serializing_if = "Option::is_none"
    )]
    residues: Option<i64>,
}

pub(super) fn closed<'a>(
    value: &'a Value,
    required: &[&str],
    optional: &[&str],
) -> Result<&'a Map<String, Value>, WireError> {
    let fields = value.as_object().ok_or_else(|| unreadable(()))?;
    if required.iter().any(|k| !fields.contains_key(*k))
        || fields
            .keys()
            .any(|k| !required.contains(&k.as_str()) && !optional.contains(&k.as_str()))
        || optional
            .iter()
            .any(|k| fields.get(*k) == Some(&Value::Null))
    {
        return Err(unreadable(()));
    }
    Ok(fields)
}
fn request(value: &Value) -> Result<(), WireError> {
    let fields = closed(
        value,
        &[
            "documentType",
            "schemaVersion",
            "requestId",
            "idempotencyKey",
            "target",
            "operation",
            "inputs",
            "requestedOutputs",
        ],
        &["authorization", "clientContext"],
    )?;
    let text = |k: &str| {
        fields[k]
            .as_str()
            .filter(|s| identifier(s))
            .ok_or_else(|| unreadable(()))
    };
    text("requestId")?;
    text("idempotencyKey")?;
    if value["documentType"] != "runtime-operation-request"
        || value["schemaVersion"] != "1.0.0"
        || !value["inputs"].is_object()
    {
        return Err(unreadable(()));
    }
    let target = closed(
        &value["target"],
        &["targetId"],
        &["expectedBindingRevision"],
    )?;
    if !target["targetId"].as_str().is_some_and(identifier)
        || target
            .get("expectedBindingRevision")
            .is_some_and(|v| v.as_i64().is_none_or(|n| n <= 0))
    {
        return Err(unreadable(()));
    }
    let operation = closed(&value["operation"], &["id"], &["version"])?;
    if !operation["id"].as_str().is_some_and(identifier)
        || operation
            .get("version")
            .is_some_and(|v| v.as_i64().is_none_or(|n| n <= 0))
    {
        return Err(unreadable(()));
    }
    let outputs = value["requestedOutputs"]
        .as_array()
        .ok_or_else(|| unreadable(()))?;
    if outputs.iter().any(|v| {
        ![
            "derivedArtifacts",
            "rawArtifacts",
            "analysisReport",
            "hardwareEvidence",
        ]
        .iter()
        .any(|s| v == s)
    }) {
        return Err(unreadable(()));
    }
    if let Some(context) = value.get("clientContext") {
        let context = closed(context, &[], &["clientName", "provenance"])?;
        if context
            .get("clientName")
            .is_some_and(|v| v.as_str().is_none_or(|s| s.is_empty() || s.len() > 128))
        {
            return Err(unreadable(()));
        }
        if let Some(provenance) = context.get("provenance")
            && provenance
                .as_object()
                .is_none_or(|m| m.values().any(|v| !v.is_string()))
        {
            return Err(unreadable(()));
        }
    }
    if let Some(authorization) = value.get("authorization") {
        closed(authorization, &["capabilityId"], &[])?;
        if !authorization["capabilityId"].as_str().is_some_and(|s| {
            let count = crate::session_graphemes::graphemes(s).take(129).count();
            s.starts_with("CAP-RT-") && (8..=128).contains(&count)
        }) {
            return Err(unreadable(()));
        }
    }
    Ok(())
}

impl JobRecord {
    pub(super) fn requires_session_retention(&self) -> bool {
        self.unknown || !terminal(&self.state)
    }
    pub(super) fn from_row(row: &JobRow) -> Result<Self, WireError> {
        let record = Self::decode(&row.record)?;
        if record.job_id != row.id
            || record.state != row.state
            || record.created != row.created
            || record.request["idempotencyKey"] != row.idempotency_key
            || row.version < 1
            || !digest(&row.request_hash)
            || order_key(&row.updated).is_err()
        {
            return Err(unreadable(()));
        }
        Ok(record)
    }

    /// Decode an existing snapshot without opening a store, claiming ownership,
    /// authorizing an action, or changing any bytes. SQLite callers additionally
    /// check the index correlation in `from_row`.
    pub fn decode(bytes: &[u8]) -> Result<Self, WireError> {
        let value = strict_json(bytes).map_err(unreadable)?;
        let record: Self = serde_json::from_value(value.clone()).map_err(unreadable)?;
        if serde_json::to_value(&record).map_err(unreadable)? != value
            || !identifier(&record.job_id)
            || order_key(&record.created).is_err()
            || !STATES.contains(&record.state.as_str())
            || !digest(&record.catalog)
            || !identifier(&record.provider)
            || record.effect.as_ref().is_some_and(|s| {
                !["hostOnly", "readOnly", "deviceMutation", "destructive"].contains(&s.as_str())
            })
            || record.plan.as_ref().is_some_and(|s| !digest(s))
            || record.identity.as_ref().is_some_and(|s| !digest(s))
            || record.binding.is_some_and(|v| v <= 0)
            || record.residues.is_some_and(|v| v < 0)
        {
            return Err(unreadable(()));
        }
        request(&record.request)?;
        if let Some(original) = &record.original_request {
            request(original)?;
        }
        let operation = &record.request["operation"];
        let expected = format!(
            "{}@{}",
            operation["id"].as_str().unwrap_or(""),
            operation["version"].as_i64().unwrap_or(1)
        );
        if expected != record.operation {
            return Err(unreadable(()));
        }
        for date in [&record.started, &record.finished, &record.first_evidence]
            .into_iter()
            .flatten()
        {
            order_key(date).map_err(unreadable)?;
        }
        record.validate_historical_admission()?;
        for (value, validate) in [
            (
                &record.recovery_action,
                super::job_record_fields::persisted_action as fn(&Value) -> Result<(), WireError>,
            ),
            (
                &record.evidence_preflight,
                super::job_record_fields::preflight,
            ),
            (
                &record.evidence_observation,
                super::job_record_fields::observation,
            ),
            (&record.trace_before, super::job_record_fields::trace_probe),
            (&record.trace_after, super::job_record_fields::trace_probe),
            (
                &record.session_publication,
                super::job_record_fields::publication,
            ),
        ] {
            if let Some(value) = value {
                validate(value)?;
            }
        }
        if let Some(failure) = &record.operation_failure {
            super::job_record_fields::operation_failure(failure)?;
        }
        if let Some(ring) = &record.ring {
            closed(ring, &["anchor", "ringHeldAnchor"], &[])?;
            if !ring["anchor"].is_string() || !ring["ringHeldAnchor"].is_boolean() {
                return Err(unreadable(()));
            }
        }
        if let Some(screen) = &record.screen {
            closed(
                screen,
                &[
                    "requestedFrameCount",
                    "capturedFrameCount",
                    "frameDurationsSeconds",
                ],
                &[],
            )?;
            if screen["requestedFrameCount"].as_i64().is_none()
                || screen["capturedFrameCount"].as_i64().is_none()
                || screen["frameDurationsSeconds"]
                    .as_array()
                    .is_none_or(|v| v.iter().any(|n| !n.is_number()))
            {
                return Err(unreadable(()));
            }
        }
        Ok(record)
    }

    fn validate_historical_admission(&self) -> Result<(), WireError> {
        // RuntimeJobRecord's strict decoder checks this durable correlation.
        // It is historical provenance, not a currently usable capability.
        if self.request.get("authorization").is_some() && self.original_request.is_none() {
            return Err(unreadable(()));
        }
        let Some(evidence) = &self.admission else {
            return Ok(());
        };
        super::job_record_fields::admission(evidence)?;
        let capability = evidence["kind"] == "runtimeCapability";
        if capability != evidence.get("runtimeCapabilityCorrelation").is_some()
            || capability != evidence.get("consumptionFingerprintSHA256").is_some()
            || (capability
                && (evidence.get("validUntilUTC").is_none() || self.original_request.is_none()))
        {
            return Err(unreadable(()));
        }
        if let Some(correlation) = evidence.get("runtimeCapabilityCorrelation") {
            let binding = arkdeck_contract::sha256_hex(
                format!(
                    "{}\n{}",
                    self.identity.as_deref().unwrap_or("-"),
                    self.binding.map_or_else(|| "-".into(), |n| n.to_string())
                )
                .as_bytes(),
            );
            if evidence["reference"] != self.request["authorization"]["capabilityId"]
                || correlation["reservationID"] != self.request["idempotencyKey"]
                || correlation["useOrdinal"].as_i64().is_none_or(|n| n <= 0)
                || correlation["planDigestSHA256"].as_str() != self.plan.as_deref()
                || !correlation["planDigestSHA256"].as_str().is_some_and(digest)
                || !correlation["stepSetDigestSHA256"]
                    .as_str()
                    .is_some_and(digest)
                || correlation["targetBindingDigestSHA256"] != binding
                || correlation
                    .get("artifactSHA256")
                    .is_some_and(|v| !v.as_str().is_some_and(digest))
                || !evidence["consumptionFingerprintSHA256"]
                    .as_str()
                    .is_some_and(digest)
            {
                return Err(unreadable(()));
            }
        }
        Ok(())
    }

    pub fn value(&self) -> Result<Value, WireError> {
        serde_json::to_value(self).map_err(unreadable)
    }
    /// The `job-record.json` and `initial_record_json` bytes Swift
    /// `RuntimeJobRecord.durableData()` writes for this record. They must
    /// decode to this same record, so no writer stores what a strict reader
    /// would refuse.
    pub fn durable_bytes(&self) -> Result<Vec<u8>, WireError> {
        let value = self.value()?;
        let bytes = crate::session_json::encode_pretty(&value).map_err(unreadable)?;
        if Self::decode(&bytes)?.value()? != value {
            return Err(unreadable(()));
        }
        Ok(bytes)
    }
    pub(super) fn created(&self) -> &str {
        &self.created
    }
    pub(super) fn idempotency_key(&self) -> Option<&str> {
        self.request["idempotencyKey"].as_str()
    }
    pub(super) fn catalog_digest(&self) -> &str {
        &self.catalog
    }
    pub(super) fn plan_digest(&self) -> Option<&str> {
        self.plan.as_deref()
    }
    pub(super) fn operation(&self) -> &str {
        &self.operation
    }
    pub(super) fn materialized_identity(&self) -> Option<&str> {
        self.identity.as_deref()
    }
    pub(super) fn materialized_binding(&self) -> Option<i64> {
        self.binding
    }
    /// Swift `materializedStableTargetIdentitySHA256` and
    /// `materializedBindingRevision`: what a device-bound plan was bound to.
    pub(super) fn set_materialized(&mut self, identity: Option<String>, binding: Option<i64>) {
        self.identity = identity;
        self.binding = binding;
    }
    pub(super) fn evidence_preflight(&self) -> Option<&Value> {
        self.evidence_preflight.as_ref()
    }
    /// The admission evidence Swift records as the Job's authority.
    pub(super) fn admission(&self) -> Option<&Value> {
        self.admission.as_ref()
    }
    /// Whether the record carries a Trace probe, which this Runtime does not
    /// project yet.
    pub(super) fn carries_trace_probe(&self) -> bool {
        self.trace_before.is_some() || self.trace_after.is_some()
    }
    pub(super) fn set_evidence_preflight(&mut self, preflight: Value) {
        self.evidence_preflight = Some(preflight);
    }
    pub(super) fn set_evidence_observation(&mut self, observation: Value) {
        self.evidence_observation = Some(observation);
    }
    /// Swift sets `firstEvidenceStepAtUTC` once.
    pub(super) fn set_first_evidence(&mut self, at: &str) {
        if self.first_evidence.is_none() {
            self.first_evidence = Some(at.into());
        }
    }
    /// Swift `skipReasons`: why an optional step did not run.
    pub(super) fn set_skip_reason(&mut self, step: &str, reason: &str) {
        self.skip_reasons.insert(step.into(), reason.into());
    }
    pub(super) fn skip_reason(&self, step: &str) -> Option<&str> {
        self.skip_reasons.get(step).map(String::as_str)
    }
    /// Swift sets `startedAtUTC` once, when a run first starts.
    pub(super) fn start(&mut self, now: &str) {
        if self.started.is_none() {
            self.started = Some(now.into());
        }
    }
    pub(super) fn finish(&mut self, now: &str) {
        self.finished = Some(now.into());
    }
    pub(super) fn set_operation_failure(&mut self, failure: Option<Value>) {
        self.operation_failure = failure;
    }
    /// The step, write-ahead intent and exact typed action recovery would
    /// need, persisted before that intent can become dispatchable.
    pub(super) fn set_recovery(
        &mut self,
        step: Option<&str>,
        intent: Option<&str>,
        action: Option<Value>,
    ) {
        self.recovery_step = step.map(str::to_owned);
        self.recovery_intent = intent.map(str::to_owned);
        self.recovery_action = action;
    }
    pub(super) fn add_step_kind(&mut self, kind: &str) {
        let kinds = self.step_kinds.get_or_insert_with(Vec::new);
        if !kinds.iter().any(|known| known == kind) {
            kinds.push(kind.into());
        }
    }
    pub(super) fn set_outcome_unknown(&mut self) {
        self.unknown = true;
    }
    pub(super) fn provider(&self) -> &str {
        &self.provider
    }
    pub(super) fn outcome_unknown(&self) -> bool {
        self.unknown
    }
    pub(super) fn finished_at(&self) -> Option<&str> {
        self.finished.as_deref()
    }
    pub(super) fn operation_failure(&self) -> Option<&Value> {
        self.operation_failure.as_ref()
    }
    pub(super) fn evidence_observation(&self) -> Option<&Value> {
        self.evidence_observation.as_ref()
    }
    /// The ownership marker of this Job's Session publication, if any.
    pub(super) fn session_publication(&self) -> Option<&Value> {
        self.session_publication.as_ref()
    }
    pub(super) fn set_session_publication(&mut self, marker: Value) {
        self.session_publication = Some(marker);
    }
    /// Swift `encodeEvidence`'s observation: the Job's evidence observation
    /// with its absent members as nulls, or null.
    fn observation_fields(&self) -> Value {
        let Some(observation) = &self.evidence_observation else {
            return Value::Null;
        };
        let member = |key: &str| observation.get(key).cloned().unwrap_or(Value::Null);
        let steps: Vec<Value> = observation["preflightSteps"]
            .as_array()
            .map(|steps| {
                steps
                    .iter()
                    .map(|step| {
                        json!({"stepId": step["stepID"], "stepKind": step["stepKind"],
                            "outcomeAtUtc": step["outcomeAtUTC"]})
                    })
                    .collect()
            })
            .unwrap_or_default();
        json!({
            "targetId": member("targetID"),
            "bindingRevision": member("bindingRevision"),
            "stableIdentitySha256": member("stableIdentitySHA256"),
            "model": member("model"),
            "firmware": member("firmware"),
            "transport": member("transport"),
            "providerId": member("providerID"),
            "toolVersion": member("toolVersion"),
            "toolSha256": member("toolSHA256"),
            "confirmedAtUtc": member("confirmedAtUTC"),
            "confirmationMethod": member("confirmationMethod"),
            "preflightSteps": steps,
        })
    }
    /// Swift `RuntimeControlPlaneHandler.encodeEvidence` over the facts
    /// `RuntimeJobEngine.evidenceSnapshot` reads from a record with no device
    /// observation, Trace probe or recovery epoch (the caller checks), before
    /// artifacts and blockers are added: the admission evidence as the
    /// authority, the request's inputs as the parameters, and the typed steps
    /// that ran (none recorded reads as none ran).
    pub(super) fn evidence_fields(&self) -> Map<String, Value> {
        let authority = self.admission.as_ref().map_or(Value::Null, |admission| {
            let optional = |key: &str| admission.get(key).cloned().unwrap_or(Value::Null);
            let mut fields = Map::from_iter([
                ("kind".into(), optional("kind")),
                ("reference".into(), optional("reference")),
                ("admittedAtUtc".into(), optional("admittedAtUTC")),
                ("validUntilUtc".into(), optional("validUntilUTC")),
                (
                    "consumptionFingerprintSha256".into(),
                    optional("consumptionFingerprintSHA256"),
                ),
                ("recoveryEpoch".into(), Value::Null),
            ]);
            if let Some(runtime) = admission.get("runtimeCapabilityCorrelation") {
                let value = |key: &str| runtime.get(key).cloned().unwrap_or(Value::Null);
                for (name, key) in [
                    ("reservationId", "reservationID"),
                    ("useOrdinal", "useOrdinal"),
                    ("planDigest", "planDigestSHA256"),
                    ("stepSetDigest", "stepSetDigestSHA256"),
                    ("targetBindingDigest", "targetBindingDigestSHA256"),
                    ("artifactDigest", "artifactSHA256"),
                ] {
                    fields.insert(name.into(), value(key));
                }
            }
            Value::Object(fields)
        });
        let effect = self.effect.as_deref().filter(|effect| {
            ["hostOnly", "readOnly", "deviceMutation", "destructive"].contains(effect)
        });
        Map::from_iter([
            ("jobId".into(), json!(self.job_id)),
            ("operationReference".into(), json!(self.operation)),
            ("catalogDigest".into(), json!(self.catalog)),
            (
                "targetId".into(),
                self.request["target"]["targetId"].clone(),
            ),
            (
                "bindingRevision".into(),
                self.request["target"]
                    .get("expectedBindingRevision")
                    .cloned()
                    .unwrap_or(Value::Null),
            ),
            ("providerId".into(), json!(self.provider)),
            ("actualEffect".into(), json!(effect)),
            ("authority".into(), authority),
            ("observation".into(), self.observation_fields()),
            (
                "actualStepKinds".into(),
                json!(self.step_kinds.clone().unwrap_or_default()),
            ),
            ("executionMode".into(), json!("execute")),
            (
                "terminalState".into(),
                json!(if self.unknown {
                    "outcomeUnknown"
                } else {
                    &self.state
                }),
            ),
            ("outcomeUnknown".into(), json!(self.unknown)),
            ("startedAtUtc".into(), json!(self.started)),
            ("firstEvidenceStepAtUtc".into(), json!(self.first_evidence)),
            ("finishedAtUtc".into(), json!(self.finished)),
            ("recoveryEpoch".into(), Value::Null),
            ("traceProbeBefore".into(), Value::Null),
            ("traceProbeAfter".into(), Value::Null),
            ("parameters".into(), self.request["inputs"].clone()),
        ])
    }
    /// The record Swift `submitOwned` builds for an admitted Job: the request
    /// it executes, which names the Runtime capability a device mutation was
    /// authorized with; the caller's original submission; the admission
    /// evidence, which is a default read-only policy's and absent for a
    /// mutation until a use is consumed; the materialized plan; and the Job
    /// gone from `queued` to `preflight`.
    #[allow(clippy::too_many_arguments)]
    pub(super) fn admitted(
        job_id: &str,
        request: Value,
        original: Value,
        operation: &str,
        catalog: &str,
        provider: &str,
        created: &str,
        effect: &str,
        admission: Option<Value>,
        plan: &str,
    ) -> Self {
        Self {
            job_id: job_id.into(),
            original_request: Some(original),
            request,
            operation: operation.into(),
            catalog: catalog.into(),
            provider: provider.into(),
            created: created.into(),
            effect: Some(effect.into()),
            admission,
            plan: Some(plan.into()),
            identity: None,
            binding: None,
            state: "preflight".into(),
            unknown: false,
            operation_failure: None,
            recovery_step: None,
            recovery_action: None,
            recovery_intent: None,
            evidence_preflight: None,
            evidence_observation: None,
            trace_before: None,
            trace_after: None,
            session_publication: None,
            timeline: vec!["jobCreated".into(), "queued->preflight".into()],
            step_kinds: None,
            started: None,
            first_evidence: None,
            finished: None,
            ring: None,
            screen: None,
            skip_reasons: Default::default(),
            residues: None,
        }
    }
    /// Swift `RuntimeJobRecord.outstandingResidueCount`: none until a cleanup
    /// path has counted the Job's residue.
    pub(super) fn residues(&self) -> Option<i64> {
        self.residues
    }
    pub(super) fn status(&self) -> Value {
        let uncertain =
            self.unknown || ["waitingForRecovery", "reconciling"].contains(&self.state.as_str());
        let finalizing = self.state == "finalizing"
            && self.operation == "debug.hap@1"
            && self.operation_failure.is_some();
        let mut next = json!({"kind":if uncertain || finalizing { "reconcile" } else if terminal(&self.state) { "readResult" } else { "wait" }, "owner":{"kind":"job", "id":self.job_id}, "resource":{"kind":"job", "id":self.job_id}, "reasonCode":if uncertain {"recovery.outcomeUnknown"} else if finalizing {"job.finalizationPending"} else if terminal(&self.state) {"job.resultAvailable"} else {"job.running"}});
        if !uncertain && !finalizing && !terminal(&self.state) {
            next["retryAfter"] = json!("250ms");
        }
        json!({
            "schemaVersion":"arkdeck.job-status/1", "jobId":self.job_id, "operation":self.operation,
            "targetId":self.request["target"]["targetId"], "state":self.state,
            "outcome":if self.unknown {"outcomeUnknown"} else {&self.state}, "waitingForHuman":false,
            "outcomeUnknown":self.unknown, "outstandingResidueCount":self.residues.unwrap_or(0),
            "executionMode":"execute", "sessionId":format!("session-{}",self.job_id),
            "threadId":self.request["clientContext"]["provenance"]["arkdeck.threadId"],
            "workspaceKind":self.workspace(), "actualEffect":self.effect,
            "createdAtUtc":self.created, "startedAtUtc":self.started, "finishedAtUtc":self.finished,
            "supersededByRecoveryEpochId":null, "recoveryEpochId":null, "resolvedByTargetAliasResolutionId":null,
            "sessionPublication":super::job_record_fields::publication_fact(self.session_publication.as_ref()),
            "failure":self.failure_projection(), "processProgress":null, "nextAction":next
        })
    }
    fn failure_projection(&self) -> Value {
        if let Some(failure) = &self.operation_failure {
            return failure.clone();
        }
        let (code, category, retry, recovery) =
            if self.unknown || self.state == "waitingForRecovery" {
                (
                    "outcomeUnknown",
                    "unknownOutcome",
                    "runtimeDecisionRequired",
                    "awaitRuntimeReconciliation",
                )
            } else {
                match self.state.as_str() {
                    "failed" => (
                        "legacyFailure",
                        "runtime",
                        "runtimeDecisionRequired",
                        "inspectJob",
                    ),
                    "cancelled" => ("cancelled", "cancelled", "notAutomatic", "none"),
                    "interrupted" => (
                        "interrupted",
                        "runtime",
                        "runtimeDecisionRequired",
                        "inspectJob",
                    ),
                    _ => return Value::Null,
                }
            };
        json!({"schemaVersion":"1.0.0", "code":code, "category":category, "retryability":retry, "recovery":recovery})
    }
    fn workspace(&self) -> Option<&str> {
        match self.operation.split('@').next().unwrap_or("") {
            "flash.full-restore" | "flash.board-provision" => Some("flash"),
            "debug.hap"
            | "debug.template"
            | "deploy.native-library.app-owned"
            | "port-forward.create"
            | "port-forward.remove" => Some("debug"),
            "input.tap" | "input.long-press" | "input.swipe" | "capture.screen-sequence" => {
                Some("toolkit")
            }
            "observe.device" | "observe.devices" => Some("viewer"),
            "analyzer.analyze-trace" | "analyzer.summarize-trace" => Some("trace"),
            "analyzer.extract-crash-signature" | "analyzer.summarize-hilog" => Some("diagnostics"),
            "capture.diagnostics" => {
                let inputs = &self.request["inputs"];
                let yes = |k: &str| inputs[k] == true;
                let many = |k: &str| inputs[k].as_array().is_some_and(|a| !a.is_empty());
                if yes("uiComponentTree") || yes("uiDump") || yes("advancedDump") {
                    Some("viewer")
                } else if many("traceCategories") {
                    Some("trace")
                } else if yes("uiScreenshot")
                    && !yes("captureHilog")
                    && !yes("crashLogs")
                    && !many("hilogFilters")
                {
                    Some("toolkit")
                } else {
                    Some("diagnostics")
                }
            }
            _ => None,
        }
    }
    pub(super) fn history(&self, timeline: bool) -> Value {
        let mut value = self.status();
        value["schemaVersion"] = json!("arkdeck.job-summary/1");
        value["current"] =
            json!(!terminal(&self.state) || self.unknown || self.residues.unwrap_or(0) > 0);
        value["timeline"] = if timeline {
            self.timeline_projection()
        } else {
            Value::Null
        };
        value
    }
    fn timeline_projection(&self) -> Value {
        if serde_json::to_vec(&self.timeline).map_or(usize::MAX, |v| v.len()) <= 256 * 1024 {
            json!({"kind":"inline", "entries":self.timeline})
        } else {
            json!({"kind":"snapshotPages", "jobId":self.job_id, "method":"job.timeline"})
        }
    }
    pub(super) fn show(&self) -> Value {
        json!({"schemaVersion":"arkdeck.job/1", "job":self.status(), "request":self.request,
            "catalogDigest":self.catalog, "providerId":self.provider, "materializedPlanDigest":self.plan,
            "materializedBindingRevision":self.binding, "materializedStableIdentitySha256":self.identity,
            "actualStepKinds":self.step_kinds, "timeline":self.timeline_projection(),
            "events":{"method":"job.events", "jobId":self.job_id}, "evidence":{"method":"job.evidence", "jobId":self.job_id},
            "ringCoverage":self.ring, "screenSequence":self.screen})
    }
    pub(super) fn timeline_rows(&self) -> Vec<Value> {
        let mut rows = Vec::new();
        for (index, entry) in self.timeline.iter().enumerate() {
            let mut start = 0;
            let mut part = 0;
            while entry.len() - start > 64 * 1024 {
                let mut end = start + 64 * 1024;
                while !entry.is_char_boundary(end) {
                    end -= 1;
                }
                rows.push(json!({"entryIndex":index.to_string(), "partIndex":part.to_string(), "text":&entry[start..end], "lastPart":false}));
                start = end;
                part += 1;
            }
            rows.push(json!({"entryIndex":index.to_string(), "partIndex":part.to_string(), "text":&entry[start..], "lastPart":true}));
        }
        rows
    }
}
