//! Swift `reconcileOwned` for an ArkForge Flash Job whose outcome is unknown:
//! its one delegated intent is correlated to one daemon job, and only that
//! daemon job's canonical completed-plan receipt can settle it
//! (`reconcileLaneAgainstDaemonTerminal`). The lane is only observed: nothing
//! is admitted, no control receipt is submitted and no job is created.
//!
//! - A completed plan whose receipt validates is recorded first, then the
//!   intent is confirmed completed with that receipt's summary, and the Job
//!   waits at its confirmed safe boundary for `job.run` to project the plan.
//! - A daemon job cancelled safely confirms the intent not executed: the Job
//!   fails, its use safe to reflash.
//! - Anything else — no terminal yet, an unknown or failed terminal, an
//!   unreachable daemon, a receipt that does not validate, or no correlation
//!   at all — cannot prove every destructive effect: the attempt is closed
//!   `waitingForRecovery` (`recordUnprovenLaneRecovery`) and the uncertainty
//!   kept. A model or build readback is never taken for that proof.
use super::*;
use crate::job_owner::arkforge_job_state::ArkForgeJobState;
use arkdeck_provider_arkforge::{Execution, FlashLane, Terminal, validate_completion};

/// Swift `ArkForgeFlashOperation.containsDurableRecordReference`.
pub(super) const ARKFORGE: [&str; 3] = ["flash.full-restore@1", "flash.dayu200", "flash.dayu200@1"];
/// Swift `arkForgePlanCompletionSemanticCode`.
const PLAN_COMPLETION_CODE: &str = "arkForgePlanCompletion";
/// Swift `recordUnprovenLaneRecovery`'s reason.
const PROOF_MISSING: &str = "flash.recoveryProofMissing: no correlated complete-plan receipt; a \
                             model/build readback cannot prove all destructive effects";

/// `job.reconcile` over the Flash composition: a Flash Job is reconciled
/// against its correlated daemon job through `lane`, every other Job by the
/// reconciler as before.
pub struct FlashReconciler<'a> {
    pub reconciler: JobReconciler<'a>,
    /// The ArkForge lane the correlated daemon job is observed through; none
    /// when the daemon composed none.
    pub lane: Option<&'a dyn FlashLane>,
}

impl FlashReconciler<'_> {
    pub fn handle(&self, params: &Map<String, Value>) -> Result<Value, WireError> {
        let reconciler = &self.reconciler;
        let Some(id) = params.get("jobId").and_then(Value::as_str) else {
            return reconciler.handle(params);
        };
        let Ok(record) = reconciler.read(id) else {
            return reconciler.handle(params);
        };
        if !ARKFORGE.contains(&record.operation()) {
            return reconciler.handle(params);
        }
        if terminal(&record.state) {
            return reconciler.released(record);
        }
        if record.outcome_unknown()
            && lineage::runtime_capability(&record)
            && reconciler.capabilities.is_none()
        {
            return Err(refused(
                "rejected",
                format!(
                    "job {} settles a runtime capability use, and this owner holds no \
                     capability store; nothing was dispatched or written",
                    record.job_id
                ),
            ));
        }
        reconciler.resident(record, self.lane)
    }
}

/// Swift `arkForgePlanCompletionSummary`.
fn completion_summary(receipt: &arkdeck_provider_arkforge::ActionReceipt) -> String {
    let evidence: String = receipt
        .evidence_sha256
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect();
    format!(
        "arkforge-plan={}; daemon-job={}; terminal-step={}; evidence-sha256={evidence}",
        receipt.plan_id, receipt.job_id, receipt.step_id
    )
}

impl JobReconciler<'_> {
    /// Swift's delegated-plan branch of `reconcileOwned`: the correlated
    /// daemon job when there is one and a lane to observe it through, and
    /// otherwise, or when it proves nothing, the unproven recovery.
    pub(super) fn reconcile_lane(
        &self,
        held: &mut Held,
        lane: Option<&dyn FlashLane>,
    ) -> Result<Option<Value>, WireError> {
        let job_id = held.run.record.job_id.clone();
        let mut state = self
            .jobs
            .arkforge_state(&job_id)
            .map_err(|error| other(format!("the Job's ArkForge state is unreadable: {error}")))?;
        if let (Some(execution), Some(lane)) = (state.execution.clone(), lane)
            && let Some(settled) = self.lane_terminal(held, &mut state, &execution, lane)?
        {
            return Ok(settled);
        }
        self.unproven_lane(held)
    }

    /// Swift `reconcileLaneAgainstDaemonTerminal`: `Some` with the reconcile's
    /// answer once the exact daemon job's terminal settles the intent, `None`
    /// when it does not.
    fn lane_terminal(
        &self,
        held: &mut Held,
        state: &mut ArkForgeJobState,
        execution: &Execution,
        lane: &dyn FlashLane,
    ) -> Result<Option<Option<Value>>, WireError> {
        let job_id = held.run.record.job_id.clone();
        let (Some(step), Some(intent)) = (
            held.run.record.recovery_step().map(str::to_owned),
            held.run.record.recovery_intent().map(str::to_owned),
        ) else {
            return Ok(None);
        };
        let facts = held.run.journal.facts();
        if !facts.unknown_outcomes.is_empty()
            || !facts
                .outstanding_intents
                .iter()
                .any(|outstanding| outstanding.event_id == intent && outstanding.step_id == step)
        {
            return Ok(None);
        }
        let daemon = execution.daemon_job_id.clone();
        let mut receipt = state.completion.clone();
        let mut cancelled = false;
        if receipt.is_none() {
            let note = match lane.observe_terminal(execution) {
                Ok(Some(Terminal::Completed(receipts))) => {
                    receipt = receipts.last().cloned();
                    None
                }
                Ok(Some(Terminal::CancelledSafe)) => {
                    cancelled = true;
                    None
                }
                Ok(Some(Terminal::ConfirmedFailed(reason))) => Some(format!(
                    "correlated arkforged terminal is confirmedFailed without complete-plan \
                     proof: {reason}"
                )),
                Ok(Some(Terminal::OutcomeUnknown(reason))) => Some(format!(
                    "correlated arkforged terminal remains unknown: {reason}"
                )),
                Ok(None) => Some(format!(
                    "correlated arkforged job {daemon} has no terminal yet"
                )),
                Err(error) => Some(format!(
                    "could not observe correlated arkforged job {daemon}: {error}"
                )),
            };
            if let Some(note) = note {
                held.run.record.timeline.push(note);
                held.store();
            }
        }
        if let Some(receipt) = &receipt {
            if !validate_completion(receipt, Some(execution)) {
                held.run.record.timeline.push(
                    "correlated arkforged completion receipt is non-canonical; uncertainty \
                     retained"
                        .into(),
                );
                held.persist(self.jobs)?;
                return Ok(None);
            }
            // The receipt is durable before the outcome, as a live drive
            // makes it; a crash re-entering here reuses it.
            state.completion = Some(receipt.clone());
            self.jobs
                .persist_arkforge_state(&job_id, state)
                .map_err(|error| other(format!("{error:?}")))?;
        } else if !cancelled {
            held.persist(self.jobs)?;
            return Ok(None);
        }
        let mut facts = held.run.journal.facts();
        if facts.current_state.as_deref() == Some("waitingForRecovery") {
            held.transition(
                "waitingForRecovery",
                "reconciling",
                "begin passive correlated ArkForge reconciliation",
                None,
            )?;
            facts = held.run.journal.facts();
        }
        if facts.current_state.as_deref() != Some("reconciling") {
            return Ok(None);
        }
        let mut events = held.events(self.jobs)?;
        let attempt = match unfinished_attempt(&events) {
            Some(attempt) => attempt,
            None => {
                let sequence = held.run.sequence;
                let attempt = format!("arkforge-terminal-recovery-{job_id}-{sequence}");
                let envelope = held
                    .run
                    .envelope(format!("reconcile-start-{sequence}"))
                    .map_err(from_run)?;
                held.append(events::reconcile_started(
                    &envelope,
                    &attempt,
                    "waitingForRecovery",
                    facts.last_durable_sequence.unwrap_or(0),
                    "manual",
                ))?;
                held.run
                    .record
                    .timeline
                    .push(format!("reconcile observed exact daemon job {daemon}"));
                held.store();
                events = held.events(self.jobs)?;
                attempt
            }
        };
        let revision = held.run.record.materialized_binding();
        if cancelled {
            return self
                .finish(
                    held,
                    &events,
                    &intent,
                    &step,
                    &attempt,
                    Decision::NotExecuted,
                    revision,
                )
                .map(Some);
        }
        let Some(receipt) = state.completion.clone() else {
            return Ok(None);
        };
        let summary = completion_summary(&receipt);
        self.finish_annotated(
            held,
            &events,
            &intent,
            &step,
            &attempt,
            Decision::Completed(vec!["daemonJobID".into(), "planID".into(), "source".into()]),
            revision,
            Some((PLAN_COMPLETION_CODE, &summary)),
        )
        .map(Some)
    }

    /// Swift `recordUnprovenLaneRecovery`: the attempt closed without
    /// resolving the original destructive intent, which stays unknown until
    /// the exact daemon job's receipt or a complete-overwrite recovery proves
    /// what happened.
    fn unproven_lane(&self, held: &mut Held) -> Result<Option<Value>, WireError> {
        let job_id = held.run.record.job_id.clone();
        let mut facts = held.run.journal.facts();
        match facts.current_state.as_deref() {
            Some("waitingForRecovery") => {
                held.transition(
                    "waitingForRecovery",
                    "reconciling",
                    "record missing delegated-plan recovery proof",
                    None,
                )?;
                facts = held.run.journal.facts();
            }
            Some("reconciling") => {}
            state => {
                return Err(engine(
                    "internalFailure",
                    &format!(
                        "unknown outcome journal is {}, not at a recovery boundary",
                        state.unwrap_or("missing")
                    ),
                ));
            }
        }
        let events = held.events(self.jobs)?;
        let attempt = match unfinished_attempt(&events) {
            Some(attempt) => attempt,
            None => {
                let sequence = held.run.sequence;
                let attempt = format!("lane-recovery-{job_id}-{sequence}");
                let envelope = held
                    .run
                    .envelope(format!("reconcile-start-{sequence}"))
                    .map_err(from_run)?;
                held.append(events::reconcile_started(
                    &envelope,
                    &attempt,
                    "waitingForRecovery",
                    facts.last_durable_sequence.unwrap_or(0),
                    "manual",
                ))?;
                held.run
                    .record
                    .timeline
                    .push("reconcile requires a correlated complete-plan receipt".into());
                held.store();
                attempt
            }
        };
        let decided = format!("reconcile-outcome-{}", held.run.sequence);
        let envelope = held.run.envelope(decided.clone()).map_err(from_run)?;
        held.append(events::reconcile_outcome(
            &envelope,
            None,
            &attempt,
            "waitingForRecovery",
            "waitingForRecovery",
            "outcomeUnknown",
            false,
            &[PROOF_MISSING],
        ))?;
        held.transition(
            "reconciling",
            "waitingForRecovery",
            &format!("persist delegated-plan recovery refusal: {PROOF_MISSING}"),
            Some(&decided),
        )?;
        held.run.record.set_outcome_unknown();
        held.run
            .record
            .timeline
            .push(format!("reconcile inconclusive: {PROOF_MISSING}"));
        held.persist(self.jobs)?;
        lineage::record_capability_outcome(
            &held.run.record,
            self.capabilities,
            UseOutcome::OutcomeUnknown,
            "waitingForRecovery",
            self.now,
        )
        .map_err(from_repair)?;
        Ok(Some(held.run.record.status()))
    }
}
