//! The Swift journal's replay and append discipline (TASK-XPA-014):
//! `JournalReplay.validate` and `JournalAppendValidationState` as one state
//! machine, so a cold replay and every record the Rust writer appends pass the
//! same checks. Outstanding intents and unknown outcomes are reported as
//! recorded facts; nothing here recovers, reconciles or replays an effect.
use crate::job_journal::JournalEvent;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::{BTreeMap, BTreeSet};

pub type Violation = &'static str;

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
enum Effect {
    HostOnly,
    ReadOnly,
    DeviceMutation,
    Destructive,
}
impl Effect {
    fn parse(value: &Value) -> Option<Self> {
        match value.as_str()? {
            "hostOnly" => Some(Self::HostOnly),
            "readOnly" => Some(Self::ReadOnly),
            "deviceMutation" => Some(Self::DeviceMutation),
            "destructive" => Some(Self::Destructive),
            _ => None,
        }
    }
    fn name(self) -> &'static str {
        match self {
            Self::HostOnly => "hostOnly",
            Self::ReadOnly => "readOnly",
            Self::DeviceMutation => "deviceMutation",
            Self::Destructive => "destructive",
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Mode {
    Execute,
    PlanOnly,
}
/// Swift `stateMachineMode(for:)`: a simulated journal follows execute rules.
fn mode(execution_mode: Option<&str>) -> Option<Mode> {
    match execution_mode? {
        "execute" | "simulated" => Some(Mode::Execute),
        "planOnly" => Some(Mode::PlanOnly),
        _ => None,
    }
}
/// Swift `JobStateMachine.allowedDestinations(from:mode:)`.
fn allowed(mode: Mode, from: &str, to: &str) -> bool {
    use Mode::{Execute, PlanOnly};
    let destinations: &[&str] = match (mode, from) {
        (_, "queued") => &["preflight", "cancelRequested", "finalizing"],
        (Execute, "preflight") => &[
            "running",
            "cancelRequested",
            "finalizing",
            "waitingForRecovery",
        ],
        (PlanOnly, "preflight") => &["planning", "cancelRequested", "finalizing"],
        (Execute, "running") => &[
            "waitingForDevice",
            "cancelRequested",
            "finalizing",
            "waitingForRecovery",
            "recoveringByCompleteOverwrite",
        ],
        (Execute, "waitingForDevice") => &[
            "running",
            "awaitingRebindConfirmation",
            "cancelRequested",
            "finalizing",
            "waitingForRecovery",
        ],
        (Execute, "awaitingRebindConfirmation") => &[
            "waitingForDevice",
            "cancelRequested",
            "finalizing",
            "waitingForRecovery",
        ],
        (PlanOnly, "planning") => &["cancelRequested", "finalizing"],
        (Execute, "cancelRequested") => &[
            "cancellingAtSafeBoundary",
            "finalizing",
            "waitingForRecovery",
        ],
        (PlanOnly, "cancelRequested") => &["cancellingAtSafeBoundary"],
        (Execute, "cancellingAtSafeBoundary") => &["cancelled", "finalizing", "waitingForRecovery"],
        (PlanOnly, "cancellingAtSafeBoundary") => &["cancelled"],
        (Execute, "waitingForRecovery") => &[
            "reconciling",
            "recoveringByCompleteOverwrite",
            "userAbandonRequested",
        ],
        (PlanOnly, "waitingForRecovery") => &["reconciling", "userAbandonRequested"],
        (Execute, "reconciling") => &[
            "resumeAtConfirmedSafeBoundary",
            "recoveringByCompleteOverwrite",
            "finalizing",
            "waitingForRecovery",
        ],
        (PlanOnly, "reconciling") => &[
            "resumeAtConfirmedSafeBoundary",
            "finalizing",
            "waitingForRecovery",
        ],
        (Execute, "recoveringByCompleteOverwrite") => {
            &["cancelRequested", "finalizing", "waitingForRecovery"]
        }
        (Execute, "resumeAtConfirmedSafeBoundary") => {
            &["running", "finalizing", "waitingForRecovery"]
        }
        (PlanOnly, "resumeAtConfirmedSafeBoundary") => {
            &["planning", "finalizing", "waitingForRecovery"]
        }
        (_, "userAbandonRequested") => &["interrupted", "waitingForRecovery"],
        (Execute, "finalizing") => &["succeeded", "recovered", "failed", "waitingForRecovery"],
        (PlanOnly, "finalizing") => &["planned", "failed"],
        _ => &[],
    };
    destinations.contains(&to)
}
fn terminal(state: &str) -> bool {
    matches!(
        state,
        "planned" | "succeeded" | "recovered" | "failed" | "cancelled" | "interrupted"
    )
}
/// Swift `JobState.permitsJournalIntent`.
fn permits_intent(state: &str) -> bool {
    !terminal(state)
        && !matches!(
            state,
            "queued"
                | "waitingForRecovery"
                | "reconciling"
                | "resumeAtConfirmedSafeBoundary"
                | "userAbandonRequested"
        )
}
fn strings(value: &Value) -> Option<Vec<&str>> {
    value.as_array()?.iter().map(Value::as_str).collect()
}

#[derive(Clone, Debug)]
struct Intent {
    event_id: String,
    step_id: String,
    attempt: i64,
    effect: Effect,
    binding_revision: Option<i64>,
}
#[derive(Clone, Debug)]
struct Unknown {
    event_id: String,
    correlated: String,
    step_id: String,
    attempt: i64,
    effect: Effect,
    compensation: bool,
}
fn hazard(effect: Effect, step_id: &str, event_id: &str) -> String {
    format!("unresolved-{}-intent:{step_id}:{event_id}", effect.name())
}

/// Swift `JournalCompensationValidationState`: a compensation is executable
/// only because its successful source declared these exact bytes first.
#[derive(Clone, Default)]
struct Compensation {
    sources: BTreeMap<String, Value>,
    descriptor_sources: BTreeMap<String, String>,
    intents: BTreeMap<String, Value>,
    succeeded_sources: BTreeSet<String>,
    attempted: BTreeSet<String>,
}
impl Compensation {
    fn validate(
        &self,
        e: &Value,
        kind: &str,
        state: Option<&str>,
        execution_mode: Option<&str>,
        outstanding: bool,
    ) -> Result<(), Violation> {
        let payload = &e["payload"];
        match kind {
            "stepIntent" => {
                let step = &payload["step"];
                if state == Some("finalizing") && step["kind"] != "finalizeSession" {
                    return Err(
                        "finalizing rejects ordinary Workflow dispatch other than finalizeSession",
                    );
                }
                let step_id = step["id"].as_str().unwrap_or_default();
                let mut declared = BTreeSet::new();
                for descriptor in step["compensationDescriptors"]
                    .as_array()
                    .into_iter()
                    .flatten()
                {
                    let id = descriptor["id"].as_str().unwrap_or_default();
                    if !declared.insert(id)
                        || self
                            .descriptor_sources
                            .get(id)
                            .is_some_and(|source| source != step_id)
                    {
                        return Err("ambiguous compensation source declaration");
                    }
                }
            }
            "compensationIntent" => {
                let linked = (|| {
                    let source = self
                        .sources
                        .get(payload["compensationOfStepId"].as_str()?)?;
                    let descriptor_id = e["stepId"].as_str()?;
                    let declarations =
                        source["payload"]["step"]["compensationDescriptors"].as_array()?;
                    Some(
                        self.succeeded_sources.contains(source["eventId"].as_str()?)
                            && e["attempt"] == 1
                            && !self.attempted.contains(descriptor_id)
                            && source["bindingRevision"] == e["bindingRevision"]
                            && source["payload"]["target"] == payload["target"]
                            && declarations.contains(&payload["descriptor"]),
                    )
                })()
                .unwrap_or(false);
                if execution_mode == Some("planOnly") || outstanding || !linked {
                    return Err(
                        "compensation requires its confirmed source, exact declaration/target/binding and one unused attempt",
                    );
                }
                if state == Some("finalizing") && mode(execution_mode) != Some(Mode::Execute) {
                    return Err("finalizing compensation dispatch is unavailable");
                }
            }
            "stepOutcome" | "compensationOutcome" => {
                let Some(intent) = payload["correlatesToIntentEventId"]
                    .as_str()
                    .and_then(|id| self.intents.get(id))
                else {
                    return Ok(());
                };
                let compensating = intent["kind"] == "compensationIntent";
                if compensating != (kind == "compensationOutcome") {
                    return Err("outcome event kind differs from its intent");
                }
                if compensating
                    && (payload["compensationOfStepId"]
                        != intent["payload"]["compensationOfStepId"]
                        || payload["descriptorId"].as_str() != intent["stepId"].as_str())
                {
                    return Err("compensation outcome source differs from its intent");
                }
            }
            _ => {}
        }
        Ok(())
    }

    fn accept(&mut self, e: &Value, kind: &str) {
        let event_id = e["eventId"].as_str().unwrap_or_default().to_owned();
        match kind {
            "stepIntent" => {
                self.intents.insert(event_id, e.clone());
                if let Some(step_id) = e["stepId"].as_str() {
                    self.sources.insert(step_id.into(), e.clone());
                    for descriptor in e["payload"]["step"]["compensationDescriptors"]
                        .as_array()
                        .into_iter()
                        .flatten()
                    {
                        if let Some(id) = descriptor["id"].as_str() {
                            self.descriptor_sources.insert(id.into(), step_id.into());
                        }
                    }
                }
            }
            "compensationIntent" => {
                self.intents.insert(event_id, e.clone());
                if let Some(id) = e["stepId"].as_str() {
                    self.attempted.insert(id.into());
                }
            }
            "stepOutcome" => {
                let payload = &e["payload"];
                if payload["result"] == "succeeded"
                    && payload["outcomeCertainty"] == "confirmed"
                    && let Some(correlation) = payload["correlatesToIntentEventId"].as_str()
                {
                    self.succeeded_sources.insert(correlation.into());
                }
            }
            _ => {}
        }
    }
}

/// The replay facts Swift `DurableJournalRecovery.inspect` derives, in the
/// shape the shared parity fixtures record them.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct IntentFact {
    pub event_id: String,
    pub step_id: String,
    pub attempt: i64,
    pub effect: String,
    pub binding_revision: Option<i64>,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct UnknownFact {
    pub event_id: String,
    pub correlated_intent_event_id: String,
    pub step_id: String,
    pub attempt: i64,
    pub effect: String,
    pub is_compensation: bool,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct AbandonmentFact {
    pub intent_event_id: String,
    pub phase: String,
    pub outcome_event_id: Option<String>,
    pub release_authorized: Option<bool>,
    pub device_hazards: Vec<String>,
    pub outcome_certainty: String,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ReplayFacts {
    pub has_torn_tail: bool,
    pub event_count: usize,
    pub schema_version: Option<String>,
    pub execution_mode: Option<String>,
    pub execution_authority: Option<String>,
    pub current_state: Option<String>,
    pub last_durable_sequence: Option<i64>,
    pub outstanding_intents: Vec<IntentFact>,
    pub unknown_outcomes: Vec<UnknownFact>,
    pub required_abandonment_hazards: Vec<String>,
    pub latest_binding_revision: Option<i64>,
    pub last_confirmed_step_id: Option<String>,
    pub last_reconcile_outcome_certainty: Option<String>,
    pub resource_release_authorized: bool,
    pub requires_unknown_finalized_outcome: bool,
    pub pending_abandonment: Option<AbandonmentFact>,
    pub finalized: bool,
    pub requires_recovery: bool,
}

#[derive(Clone, Default)]
pub struct ReplayState {
    events: usize,
    last_sequence: Option<i64>,
    session_id: Option<String>,
    job_id: Option<String>,
    schema_version: Option<String>,
    event_ids: BTreeSet<String>,
    execution_mode: Option<String>,
    execution_authority: Option<String>,
    /// The durable state; while a reconcile outcome awaits its transition this
    /// stays `reconciling` and `pending_reconcile` names the next state.
    state: Option<String>,
    finalized: bool,
    intents: BTreeMap<String, Intent>,
    completed: BTreeSet<String>,
    unknown: Vec<Unknown>,
    latest_binding_revision: Option<i64>,
    last_confirmed_step_id: Option<String>,
    recovery_attempts: BTreeSet<String>,
    completed_recovery_attempts: BTreeSet<String>,
    pending_reconcile: Option<(String, String)>,
    last_reconcile_certainty: Option<String>,
    abandon_intents: BTreeSet<String>,
    completed_abandon_intents: BTreeSet<String>,
    active_abandon: Option<(String, Vec<String>, String)>,
    pending_abandon: Option<(String, String)>,
    resource_release_authorized: bool,
    requires_unknown_finalized_outcome: bool,
    compensation: Compensation,
}

/// One snapshot's replay: complete records validated in order, and whether
/// bytes after the last LF (a torn tail) remain.
pub struct Replay {
    pub state: ReplayState,
    pub torn: bool,
    pub durable_length: usize,
}

impl ReplayState {
    /// Swift `DurableJournalRecovery.inspect(data:)`: every LF-terminated
    /// record must decode and follow the replay rules; bytes after the last LF
    /// are a torn tail, reported but never interpreted.
    pub fn replay(bytes: &[u8]) -> Result<Replay, Violation> {
        let durable_length = bytes.iter().rposition(|b| *b == b'\n').map_or(0, |p| p + 1);
        let mut state = Self::default();
        if durable_length > 0 {
            for line in bytes[..durable_length - 1].split(|b| *b == b'\n') {
                if line.is_empty() {
                    return Err("malformed completed journal record");
                }
                let event =
                    JournalEvent::decode(line).map_err(|_| "malformed completed journal record")?;
                state.validate(&event)?;
                state.accept(&event);
            }
        }
        Ok(Replay {
            state,
            torn: durable_length != bytes.len(),
            durable_length,
        })
    }

    pub fn event_count(&self) -> usize {
        self.events
    }

    fn outstanding(&self) -> impl Iterator<Item = &Intent> {
        self.intents
            .values()
            .filter(|intent| !self.completed.contains(&intent.event_id))
    }

    fn required_hazards(&self) -> Vec<String> {
        let mut hazards: BTreeSet<String> = self
            .outstanding()
            .filter(|intent| intent.effect >= Effect::DeviceMutation)
            .map(|intent| hazard(intent.effect, &intent.step_id, &intent.event_id))
            .collect();
        hazards.extend(
            self.unknown
                .iter()
                .filter(|unknown| unknown.effect >= Effect::DeviceMutation)
                .map(|unknown| hazard(unknown.effect, &unknown.step_id, &unknown.correlated)),
        );
        hazards.into_iter().collect()
    }

    fn authorizes_interrupted(&self, to: Option<&str>, trigger: Option<&str>) -> bool {
        to == Some("interrupted")
            && self
                .pending_abandon
                .as_ref()
                .is_some_and(|(outcome, next)| next == "interrupted" && trigger == Some(outcome))
    }

    /// Checks one decoded record against everything recorded before it.
    pub fn validate(&self, event: &JournalEvent) -> Result<(), Violation> {
        let e = event.value();
        let kind = event.kind();
        let payload = &e["payload"];
        let sequence = e["sequence"].as_i64().ok_or("invalid journal sequence")?;
        match self.last_sequence {
            Some(last) => {
                if last.checked_add(1) != Some(sequence) {
                    return Err("append sequence is not contiguous");
                }
                if self.session_id.as_deref() != Some(event.session_id())
                    || self.job_id.as_deref() != Some(event.job_id())
                {
                    return Err("append identity changed");
                }
                if self.schema_version.as_deref() != e["schemaVersion"].as_str() {
                    return Err("mixed journal schemaVersion");
                }
            }
            None if sequence != 0 || kind != "jobCreated" => {
                return Err("first durable event must be sequence 0 jobCreated");
            }
            None => {}
        }
        if self.event_ids.contains(event.event_id()) {
            return Err("duplicate eventId");
        }
        if self.finalized {
            return Err("event follows finalized record");
        }
        let state = self.state.as_deref();
        if state.is_some_and(terminal) && kind != "finalized" {
            return Err("non-final event follows terminal state");
        }
        if self.pending_reconcile.is_some() && kind != "stateTransition" {
            return Err("reconcile outcome must be followed by its state transition");
        }
        if self.pending_abandon.is_some() && kind != "stateTransition" {
            return Err("abandon outcome must be followed by its state transition");
        }
        let (from, to) = (payload["from"].as_str(), payload["to"].as_str());
        let trigger = payload["triggerEventId"].as_str();
        let outstanding = self.outstanding().next().is_some();
        if !self.unknown.is_empty() {
            if matches!(kind, "stepIntent" | "compensationIntent") {
                return Err("outcomeUnknown blocks subsequent external-effect intent");
            }
            let authorized_abandon = kind == "stateTransition"
                && state == Some("userAbandonRequested")
                && self.authorizes_interrupted(to, trigger);
            if state != Some("waitingForRecovery")
                && state != Some("reconciling")
                && kind == "stateTransition"
                && to != Some("waitingForRecovery")
                && !authorized_abandon
            {
                return Err("outcomeUnknown requires transition to waitingForRecovery");
            }
        }
        self.compensation
            .validate(e, kind, state, self.execution_mode.as_deref(), outstanding)?;
        match kind {
            "jobCreated" => {
                if self.last_sequence.is_some() || self.execution_mode.is_some() || state.is_some()
                {
                    return Err("jobCreated must be first");
                }
            }
            "stateTransition" => {
                let (Some(from), Some(to), Some(current)) = (from, to, state) else {
                    return Err("transition precedes jobCreated");
                };
                let mode = mode(self.execution_mode.as_deref()).ok_or("unknown execution mode")?;
                if from != current || !allowed(mode, from, to) {
                    return Err(
                        "transition is inconsistent with the current state or execution mode",
                    );
                }
                if let Some((outcome, next)) = &self.pending_reconcile
                    && (from != "reconciling" || to != next || trigger != Some(outcome.as_str()))
                {
                    return Err("state transition does not persist reconcile outcome");
                }
                if let Some((outcome, next)) = &self.pending_abandon {
                    if from != "userAbandonRequested"
                        || to != next
                        || trigger != Some(outcome.as_str())
                    {
                        return Err("state transition does not persist abandon outcome");
                    }
                } else if from == "userAbandonRequested" {
                    return Err("abandon transition has no durable correlated outcome");
                }
                if to == "userAbandonRequested" {
                    if from != "waitingForRecovery"
                        || trigger != self.active_abandon.as_ref().map(|a| a.0.as_str())
                    {
                        return Err("userAbandonRequested transition has no active abandon intent");
                    }
                } else if self.active_abandon.is_some() && from == "waitingForRecovery" {
                    return Err("durable abandon intent must transition to userAbandonRequested");
                }
                if outstanding
                    && (to == "finalizing" || terminal(to))
                    && !self.authorizes_interrupted(Some(to), trigger)
                {
                    return Err("unresolved intent cannot enter finalization or terminal state");
                }
            }
            "stepIntent" => {
                if !state.is_some_and(permits_intent) {
                    return Err("current Job state does not permit external-effect intent");
                }
                let effect =
                    Effect::parse(&payload["step"]["effect"]).ok_or("invalid step effect")?;
                if self.execution_mode.as_deref() == Some("planOnly")
                    && effect >= Effect::DeviceMutation
                {
                    return Err("planOnly journal cannot contain device-mutating intent");
                }
            }
            "compensationIntent" => {
                if !state.is_some_and(permits_intent)
                    || self.execution_mode.as_deref() == Some("planOnly")
                    || Effect::parse(&payload["descriptor"]["effect"]).is_none()
                {
                    return Err(
                        "compensation intent is inconsistent with the current state or execution mode",
                    );
                }
            }
            "stepOutcome" | "compensationOutcome" => {
                let intent = payload["correlatesToIntentEventId"]
                    .as_str()
                    .filter(|id| !self.completed.contains(*id))
                    .and_then(|id| self.intents.get(id));
                if !intent.is_some_and(|intent| {
                    e["stepId"].as_str() == Some(intent.step_id.as_str())
                        && e["attempt"].as_i64() == Some(intent.attempt)
                }) {
                    return Err("outcome does not match outstanding intent");
                }
            }
            "bindingConfirmed" => {
                let revision = e["bindingRevision"]
                    .as_i64()
                    .ok_or("binding revision did not increase")?;
                if self
                    .latest_binding_revision
                    .is_some_and(|latest| revision <= latest)
                {
                    return Err("binding revision did not increase");
                }
            }
            "reconcileStarted" => {
                if payload["recoveryAttemptId"]
                    .as_str()
                    .is_none_or(|attempt| self.recovery_attempts.contains(attempt))
                    || state != Some("reconciling")
                    || payload["sourceState"] != "waitingForRecovery"
                {
                    return Err("reconcile start must follow waitingForRecovery to reconciling");
                }
            }
            "reconcileOutcome" => {
                let mode = if self.execution_mode.as_deref() == Some("planOnly") {
                    Mode::PlanOnly
                } else {
                    Mode::Execute
                };
                let next = payload["nextState"].as_str().unwrap_or_default();
                if payload["recoveryAttemptId"].as_str().is_none_or(|attempt| {
                    !self.recovery_attempts.contains(attempt)
                        || self.completed_recovery_attempts.contains(attempt)
                }) || state != Some("reconciling")
                    || !allowed(mode, "reconciling", next)
                {
                    return Err("reconcile outcome has no durable start");
                }
            }
            "abandonIntent" => {
                let requires_unknown = outstanding
                    || !self.unknown.is_empty()
                    || self.last_reconcile_certainty.as_deref() == Some("outcomeUnknown");
                let hazards = strings(&payload["deviceHazards"]);
                let preserved = hazards.is_some_and(|hazards| {
                    self.required_hazards()
                        .iter()
                        .all(|required| hazards.contains(&required.as_str()))
                });
                if state != Some("waitingForRecovery")
                    || self.active_abandon.is_some()
                    || !preserved
                    || (requires_unknown && payload["outcomeCertainty"] != "outcomeUnknown")
                {
                    return Err(
                        "abandon intent must start from waitingForRecovery and preserve device hazards",
                    );
                }
            }
            "abandonOutcome" => {
                let correlation = payload["correlatesToAbandonIntentEventId"].as_str();
                let unresolved = strings(&payload["unresolvedHazards"]);
                let linked = match (correlation, &self.active_abandon, unresolved) {
                    (Some(correlation), Some((active, hazards, _)), Some(unresolved)) => {
                        self.abandon_intents.contains(correlation)
                            && !self.completed_abandon_intents.contains(correlation)
                            && correlation == active
                            && hazards
                                .iter()
                                .all(|hazard| unresolved.contains(&hazard.as_str()))
                    }
                    _ => false,
                };
                if !linked || state != Some("userAbandonRequested") {
                    return Err("abandon outcome has no durable intent");
                }
            }
            "finalized" => {
                let Some(current) = state.filter(|state| terminal(state)) else {
                    return Err("finalized requires a terminal Job state");
                };
                if payload["terminalStatus"].as_str() != Some(current) {
                    return Err("finalized status does not match Job state");
                }
                if outstanding && !(current == "interrupted" && self.resource_release_authorized) {
                    return Err("finalized cannot hide an unresolved external-effect intent");
                }
                if (outstanding
                    || !self.unknown.is_empty()
                    || self.requires_unknown_finalized_outcome)
                    && (current != "interrupted" || payload["outcomeCertainty"] == "confirmed")
                {
                    return Err(
                        "finalized certainty cannot confirm an unresolved intent or unknown outcome",
                    );
                }
            }
            _ => {}
        }
        Ok(())
    }

    /// Records a validated event. Call only after `validate` returned `Ok`.
    pub fn accept(&mut self, event: &JournalEvent) {
        let e = event.value();
        let kind = event.kind();
        let payload = &e["payload"];
        let text = |value: &Value| value.as_str().map(str::to_owned);
        self.compensation.accept(e, kind);
        self.events += 1;
        self.last_sequence = e["sequence"].as_i64();
        self.session_id = Some(event.session_id().into());
        self.job_id = Some(event.job_id().into());
        self.schema_version = text(&e["schemaVersion"]);
        self.event_ids.insert(event.event_id().into());
        match kind {
            "jobCreated" => {
                self.execution_mode = text(&payload["executionMode"]);
                self.execution_authority = text(&payload["executionAuthority"]);
                self.state = Some("queued".into());
            }
            "stateTransition" => {
                let to = payload["to"].as_str();
                if self.authorizes_interrupted(to, payload["triggerEventId"].as_str()) {
                    self.resource_release_authorized = true;
                    if self
                        .active_abandon
                        .as_ref()
                        .is_some_and(|abandon| abandon.2 == "outcomeUnknown")
                    {
                        self.requires_unknown_finalized_outcome = true;
                    }
                }
                if payload["from"] == "userAbandonRequested" {
                    self.active_abandon = None;
                }
                self.state = to.map(str::to_owned);
                self.pending_reconcile = None;
                self.pending_abandon = None;
            }
            "stepIntent" | "compensationIntent" => {
                let source = if kind == "stepIntent" {
                    &payload["step"]["effect"]
                } else {
                    &payload["descriptor"]["effect"]
                };
                if let (Some(step_id), Some(attempt), Some(effect)) = (
                    e["stepId"].as_str(),
                    e["attempt"].as_i64(),
                    Effect::parse(source),
                ) {
                    self.intents.insert(
                        event.event_id().into(),
                        Intent {
                            event_id: event.event_id().into(),
                            step_id: step_id.into(),
                            attempt,
                            effect,
                            binding_revision: e["bindingRevision"].as_i64(),
                        },
                    );
                }
            }
            "stepOutcome" | "compensationOutcome" => {
                if let Some(correlation) = payload["correlatesToIntentEventId"].as_str() {
                    self.completed.insert(correlation.into());
                    if payload["outcomeCertainty"] == "confirmed" {
                        self.last_confirmed_step_id = text(&e["stepId"]);
                    } else if let Some(intent) = self.intents.get(correlation) {
                        self.unknown.push(Unknown {
                            event_id: event.event_id().into(),
                            correlated: correlation.into(),
                            step_id: intent.step_id.clone(),
                            attempt: intent.attempt,
                            effect: intent.effect,
                            compensation: kind == "compensationOutcome",
                        });
                    }
                }
            }
            "bindingConfirmed" => self.latest_binding_revision = e["bindingRevision"].as_i64(),
            "reconcileStarted" => {
                if let Some(attempt) = payload["recoveryAttemptId"].as_str() {
                    self.recovery_attempts.insert(attempt.into());
                }
            }
            "reconcileOutcome" => {
                if let (Some(attempt), Some(next)) = (
                    payload["recoveryAttemptId"].as_str(),
                    payload["nextState"].as_str(),
                ) {
                    self.completed_recovery_attempts.insert(attempt.into());
                    self.pending_reconcile = Some((event.event_id().into(), next.into()));
                }
                self.last_reconcile_certainty = text(&payload["outcomeCertainty"]);
                if let Some(revision) = e["bindingRevision"].as_i64() {
                    self.latest_binding_revision =
                        Some(self.latest_binding_revision.unwrap_or(0).max(revision));
                }
            }
            "abandonIntent" => {
                self.abandon_intents.insert(event.event_id().into());
                self.active_abandon = Some((
                    event.event_id().into(),
                    strings(&payload["deviceHazards"])
                        .unwrap_or_default()
                        .into_iter()
                        .map(str::to_owned)
                        .collect(),
                    payload["outcomeCertainty"]
                        .as_str()
                        .unwrap_or("outcomeUnknown")
                        .into(),
                ));
            }
            "abandonOutcome" => {
                if let Some(correlation) = payload["correlatesToAbandonIntentEventId"].as_str() {
                    self.completed_abandon_intents.insert(correlation.into());
                }
                let next = if payload["releaseAuthorized"] == true {
                    "interrupted"
                } else {
                    "waitingForRecovery"
                };
                self.pending_abandon = Some((event.event_id().into(), next.into()));
            }
            "finalized" => self.finalized = true,
            _ => {}
        }
    }

    pub fn facts(&self, torn: bool) -> ReplayFacts {
        let current_state = self
            .pending_reconcile
            .as_ref()
            .map(|(_, next)| next.clone())
            .or_else(|| self.state.clone());
        let mut outstanding: Vec<_> = self
            .outstanding()
            .map(|intent| IntentFact {
                event_id: intent.event_id.clone(),
                step_id: intent.step_id.clone(),
                attempt: intent.attempt,
                effect: intent.effect.name().into(),
                binding_revision: intent.binding_revision,
            })
            .collect();
        outstanding.sort_by(|a, b| a.event_id.cmp(&b.event_id));
        let mut unknown: Vec<_> = self
            .unknown
            .iter()
            .map(|unknown| UnknownFact {
                event_id: unknown.event_id.clone(),
                correlated_intent_event_id: unknown.correlated.clone(),
                step_id: unknown.step_id.clone(),
                attempt: unknown.attempt,
                effect: unknown.effect.name().into(),
                is_compensation: unknown.compensation,
            })
            .collect();
        unknown.sort_by(|a, b| a.event_id.cmp(&b.event_id));
        let pending_abandonment =
            self.active_abandon
                .as_ref()
                .map(|(intent, hazards, certainty)| match &self.pending_abandon {
                    Some((outcome, next)) => AbandonmentFact {
                        intent_event_id: intent.clone(),
                        phase: "outcomeDurable".into(),
                        outcome_event_id: Some(outcome.clone()),
                        release_authorized: Some(next == "interrupted"),
                        device_hazards: hazards.clone(),
                        outcome_certainty: certainty.clone(),
                    },
                    None => AbandonmentFact {
                        intent_event_id: intent.clone(),
                        phase: if self.state.as_deref() == Some("userAbandonRequested") {
                            "requested"
                        } else {
                            "intentDurable"
                        }
                        .into(),
                        outcome_event_id: None,
                        release_authorized: None,
                        device_hazards: hazards.clone(),
                        outcome_certainty: certainty.clone(),
                    },
                });
        let requires_recovery = torn
            || !outstanding.is_empty()
            || !unknown.is_empty()
            || self.last_reconcile_certainty.as_deref() == Some("outcomeUnknown")
            || matches!(
                current_state.as_deref(),
                Some("waitingForRecovery" | "reconciling" | "userAbandonRequested")
            )
            || self.pending_reconcile.is_some();
        ReplayFacts {
            has_torn_tail: torn,
            event_count: self.events,
            schema_version: self.schema_version.clone(),
            execution_mode: self.execution_mode.clone(),
            execution_authority: self.execution_authority.clone(),
            current_state,
            last_durable_sequence: self.last_sequence,
            outstanding_intents: outstanding,
            unknown_outcomes: unknown,
            required_abandonment_hazards: self.required_hazards(),
            latest_binding_revision: self.latest_binding_revision,
            last_confirmed_step_id: self.last_confirmed_step_id.clone(),
            last_reconcile_outcome_certainty: self.last_reconcile_certainty.clone(),
            resource_release_authorized: self.resource_release_authorized,
            requires_unknown_finalized_outcome: self.requires_unknown_finalized_outcome,
            pending_abandonment,
            finalized: self.finalized,
            requires_recovery,
        }
    }
}
