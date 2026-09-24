//! Swift `performDebugHAPFailureFinalization` for a debug HAP whose required
//! step failed, and the cleanup debt a failed cleanup owes. The failure is
//! durable before the Job enters `finalizing`. Then every compensation its
//! succeeded source steps declared runs, the latest source first
//! (`RuntimeDebugHAPFailureFinalization.derive`, `CompensationPlanner`). A
//! cleanup whose catalog step already ran, as a step or as this compensation,
//! is never sent again, and owes a debt if that attempt failed. Before its
//! intent each compensation proves the Target and its binding again against
//! the plan and its source's intent, resolves the Job's packages again, is
//! checked against its declaration (`validateCompensationAction`) and
//! continues under the capability use the Job consumed (`validateContinuation`,
//! `mutation_execution.rs`); it is journaled as a `compensationIntent` and a
//! `compensationOutcome` under its declared identity. A confirmed failed
//! cleanup is owed in the Artifact root's ledger with the exact action that
//! failed, and the Job counts its outstanding residue; a process left running
//! is named on the timeline alone. The Job then fails with its original
//! failure. A lane that cannot conclude parks the Job for recovery; what
//! Swift throws past the lane is this run's refusal, and the Job stays
//! `finalizing`. The same lane concludes a Job a reconcile confirmed not
//! executed and one a restart left `finalizing` for its explicit continuation
//! (`job.run` or `job.reconcile`); an attempt already made is never made
//! again.
use super::{HAP, Journaled, Stop, inputs_of};
use crate::artifact_read_owner::swift_string;
use crate::cleanup_debt;
use crate::device_facts::{self, HdcComposition};
use crate::device_steps::{self, StepAction, StepContext, StepInputs};
use crate::job_record::JobRecord;
use crate::job_run::{JobRunner, Run, RunRefusal, uncertain};
use crate::mutation_execution::MutationConsumption;
use crate::operation_catalog::{CatalogOperation, CatalogStep};
use crate::session_json;
use arkdeck_contract::sha256_hex;
use arkdeck_provider_hdc::HapAction;
use serde_json::{Value, json};
use std::collections::BTreeSet;

/// The reason a failed debug HAP keeps once its compensations concluded.
const CONCLUDED: &str = "original failure retained; declared compensations have confirmed outcomes";

/// Swift `PlannedCompensation`: the source step that declared it and what it
/// declared, with that source's intent.
struct Planned {
    source: String,
    descriptor: Value,
    intent: Value,
}

fn kind(event: &Value) -> &str {
    event["kind"].as_str().unwrap_or_default()
}

fn step_of(event: &Value) -> &str {
    event["stepId"].as_str().unwrap_or_default()
}

fn correlates(outcome: &Value, intent: &Value) -> bool {
    outcome["payload"]["correlatesToIntentEventId"] == intent["eventId"]
}

/// The confirmed outcome correlated with `intent`, a step's or a
/// compensation's.
fn confirmed<'a>(events: &'a [Value], intent: &Value) -> Option<&'a Value> {
    events.iter().rev().find(|event| {
        matches!(kind(event), "stepOutcome" | "compensationOutcome")
            && correlates(event, intent)
            && event["payload"]["outcomeCertainty"] == "confirmed"
    })
}

fn succeeded(outcome: &Value) -> bool {
    outcome["payload"]["result"] == "succeeded"
}

/// Whether nothing in the journal keeps a lane from concluding: no torn
/// tail, no outstanding intent and no unknown outcome.
fn concludable(run: &Run) -> bool {
    let facts = run.journal.facts();
    !facts.has_torn_tail
        && facts.outstanding_intents.is_empty()
        && facts.unknown_outcomes.is_empty()
}

/// Swift `RuntimeDebugHAPFailureFinalization.derive`, then
/// `CompensationPlanner.plan` on the failure path: the compensations every
/// source step whose outcome is confirmed succeeded declared, the latest
/// source first. `None` when no source declared any (a record from before
/// declarations), which never acquires one.
fn derive(events: &[Value]) -> Option<Vec<Planned>> {
    let mut declared = false;
    let mut completed = Vec::new();
    for intent in events.iter().filter(|event| {
        kind(event) == "stepIntent" && device_steps::hap_compensation_step(step_of(event)).is_some()
    }) {
        let descriptors = intent["payload"]["step"]["compensationDescriptors"]
            .as_array()
            .cloned()
            .unwrap_or_default();
        declared = declared || !descriptors.is_empty();
        let outcome = events
            .iter()
            .find(|event| kind(event) == "stepOutcome" && correlates(event, intent));
        if !outcome.is_some_and(|outcome| {
            succeeded(outcome) && outcome["payload"]["outcomeCertainty"] == "confirmed"
        }) {
            continue;
        }
        completed.push((step_of(intent).to_owned(), descriptors, intent.clone()));
    }
    if !declared {
        return None;
    }
    let mut planned = Vec::new();
    for (source, descriptors, intent) in completed.into_iter().rev() {
        for descriptor in descriptors.into_iter().rev() {
            if matches!(
                descriptor["trigger"].as_str(),
                Some("onFailure" | "onAnyTerminal")
            ) {
                planned.push(Planned {
                    source: source.clone(),
                    descriptor,
                    intent: intent.clone(),
                });
            }
        }
    }
    Some(planned)
}

/// Swift `validateCompensationAction`: the action a compensation runs, or a
/// debt records, must be its catalog step's own over this Job's staging, of
/// the step's effect, and must derive exactly the descriptor its source
/// declared.
pub(super) fn declares(
    source: &str,
    declared: &Value,
    step: &CatalogStep,
    action: &StepAction,
    record: &JobRecord,
) -> bool {
    let own = match (step.step_id.as_str(), action) {
        ("stop-ability", StepAction::Hap(HapAction::StopAbility(_)))
        | ("cleanup-uninstall", StepAction::Hap(HapAction::UninstallPackage(_))) => true,
        ("cleanup-remote-staging", StepAction::Hap(HapAction::CleanupOwnedRemotePath { path })) => {
            path.job_id == record.job_id && path.step_id == "send-hap"
        }
        ("cleanup-remote-staging", StepAction::Hap(HapAction::CleanupStagedPackageSet(set))) => {
            set.directory.job_id == record.job_id && set.directory.step_id == "send-hap"
        }
        _ => false,
    };
    let inputs = record.request["inputs"]
        .as_object()
        .cloned()
        .unwrap_or_default();
    let context = StepContext {
        job_id: &record.job_id,
        resolved: &[],
        library: None,
        helper: None,
    };
    let expected =
        device_steps::declared_descriptor(step, record.operation(), &inputs, action, &context);
    record.operation() == HAP
        && own
        && action.effect() == step.effect
        && expected.as_ref() == Some(declared)
        && device_steps::hap_compensation_step(source) == Some(step.step_id.as_str())
}

impl JobRunner<'_> {
    /// Swift `runOwned`'s failure lanes for a debug HAP, then
    /// `performDebugHAPFailureFinalization`. The failure the run recorded is
    /// made durable, and the Job enters `finalizing` with its reason. Each
    /// owed compensation then concludes, and the Job fails with its original
    /// failure.
    pub(super) fn finalize_hap_failure(
        &self,
        run: &mut Run,
        hdc: &HdcComposition<'_>,
        descriptor: &CatalogOperation,
        reason: &str,
    ) -> Result<(), RunRefusal> {
        run.persist(self.jobs)?;
        run.transition("running", "finalizing", reason)?;
        self.perform_hap_failure_finalization(run, hdc, descriptor)
    }

    /// Swift `performDebugHAPFailureFinalization` for a debug HAP already
    /// `finalizing`: its run's failure lane, a reconcile that confirmed its
    /// parked intent not executed, or a finalization a restart left for its
    /// explicit continuation. The original failure — the record's, or the one
    /// its journal proves — is made durable with the Job open again, then
    /// every owed compensation concludes and the Job fails with it.
    pub(crate) fn perform_hap_failure_finalization(
        &self,
        run: &mut Run,
        hdc: &HdcComposition<'_>,
        descriptor: &CatalogOperation,
    ) -> Result<(), RunRefusal> {
        if run.record.state != "finalizing" || descriptor.reference() != HAP {
            return Err(uncertain());
        }
        let failure =
            crate::job_recovery::hap_original_failure(&run.record, &self.journal_events(run)?)
                .ok_or_else(uncertain)?;
        run.record.set_operation_failure(Some(failure.clone()));
        run.record.clear_finished();
        run.persist(self.jobs)?;
        if !concludable(run) {
            return self.park_hap(run, "unresolved durable intent");
        }
        let target_id = run.record.request["target"]["targetId"]
            .as_str()
            .unwrap_or_default()
            .to_owned();
        let revision = run.record.request["target"]["expectedBindingRevision"].as_i64();
        let reference = descriptor.reference();
        for planned in derive(&self.journal_events(run)?).unwrap_or_default() {
            let step = planned.descriptor["id"]
                .as_str()
                .and_then(device_steps::compensation_catalog_step)
                .and_then(|id| descriptor.steps.iter().find(|step| step.step_id == id))
                .ok_or_else(uncertain)?;
            let events = self.journal_events(run)?;
            // A cleanup already attempted, as a step or as this compensation,
            // is final: it is never sent a second time.
            if let Some(attempted) = events.iter().rev().find(|event| {
                (kind(event) == "compensationIntent" && event["stepId"] == planned.descriptor["id"])
                    || (kind(event) == "stepIntent" && step_of(event) == step.step_id)
            }) {
                let Some(outcome) = confirmed(&events, attempted) else {
                    return self.park_hap(run, "compensation already has an outstanding intent");
                };
                if !succeeded(outcome) {
                    self.hap_debt(run, descriptor, &planned, step, attempted, outcome)?;
                }
                continue;
            }
            run.record.set_recovery(None, None, None);
            run.persist(self.jobs)?;
            let unavailable =
                |error: String| format!("fresh compensation identity unavailable: {error}");
            let facts = match hdc.facts(&target_id) {
                Ok(facts) => facts,
                Err(error) => return self.park_hap(run, &unavailable(error)),
            };
            if let Err(reason) = device_facts::validate(&facts, &target_id, revision) {
                return self.park_hap(
                    run,
                    &unavailable(format!("failed({})", swift_string(reason))),
                );
            }
            // The identity the plan bound, and the one the source's intent did.
            let source = &planned.intent;
            if run.record.materialized_identity() != Some(facts.identity.as_str())
                || run.record.materialized_binding() != Some(facts.binding_revision)
                || source["bindingRevision"].as_i64() != Some(facts.binding_revision)
                || source["payload"]["target"]["identitySnapshotHash"] != facts.identity.as_str()
                || source["payload"]["target"]["targetId"] != target_id.as_str()
            {
                return self.park_hap(
                    run,
                    &unavailable("outcomeUnknown(\"compensation source identity drifted\")".into()),
                );
            }
            let resolved = self
                .resolve_inputs(run, StepInputs::All, &step.step_id)
                .map_err(|_| uncertain())?;
            let job_id = run.record.job_id.clone();
            let context = StepContext {
                job_id: &job_id,
                resolved: &resolved,
                library: None,
                helper: None,
            };
            let now = (hdc.now)().ok_or_else(uncertain)?;
            let action = device_steps::action_in(step, &reference, &inputs_of(run), &now, &context)
                .map_err(|_| uncertain())?;
            if !declares(
                &planned.source,
                &planned.descriptor,
                step,
                &action,
                &run.record,
            ) {
                return Err(uncertain());
            }
            let plan = action
                .plan(&step.step_id, Some(&facts.connect_key), &context)
                .map_err(|_| uncertain())?;
            // Under the use the Job consumed; a refusal is thrown past the
            // lane as Swift throws it.
            match self.consume_mutation_authority(run, descriptor, &facts) {
                Ok(MutationConsumption::Held) => {}
                _ => return Err(uncertain()),
            }
            let dispatched = self.dispatch_step(
                run,
                hdc,
                descriptor,
                step,
                &action,
                &plan,
                Some(&facts),
                &target_id,
                revision,
                &resolved,
                Journaled::Compensation {
                    source: &planned.source,
                    descriptor: &planned.descriptor,
                },
            );
            match dispatched {
                // A confirmed failure is the debt the lane records next.
                Ok(()) | Err(Stop::Failed(_)) => {}
                Err(Stop::Unknown(reason)) => {
                    return self.park_hap(
                        run,
                        &format!(
                            "compensation outcome unknown: outcomeUnknown({})",
                            swift_string(&reason)
                        ),
                    );
                }
                Err(Stop::Refused(refusal)) => return Err(refusal),
                Err(_) => return Err(uncertain()),
            }
            let events = self.journal_events(run)?;
            let intent = events
                .iter()
                .rev()
                .find(|event| {
                    kind(event) == "compensationIntent"
                        && event["stepId"] == planned.descriptor["id"]
                })
                .ok_or_else(uncertain)?;
            let outcome = events
                .iter()
                .rev()
                .find(|event| {
                    kind(event) == "compensationOutcome"
                        && correlates(event, intent)
                        && event["payload"]["outcomeCertainty"] == "confirmed"
                })
                .ok_or_else(uncertain)?;
            if !succeeded(outcome) {
                self.hap_debt(run, descriptor, &planned, step, intent, outcome)?;
            }
        }
        if !concludable(run) {
            return Err(uncertain());
        }
        self.refresh_residues(run)?;
        run.record.set_operation_failure(Some(failure));
        run.record.set_recovery(None, None, None);
        run.persist(self.jobs)?;
        run.transition("finalizing", "failed", CONCLUDED)?;
        run.finish()?;
        run.persist(self.jobs)
    }

    /// Swift `persistDebugHAPCompensationDebt`: a confirmed failed cleanup is
    /// owed under the intent that attempted it, with the exact action that
    /// failed, and the Job's outstanding residue is counted again. A process
    /// left running is named on the timeline alone.
    fn hap_debt(
        &self,
        run: &mut Run,
        descriptor: &CatalogOperation,
        planned: &Planned,
        step: &CatalogStep,
        intent: &Value,
        outcome: &Value,
    ) -> Result<(), RunRefusal> {
        let reason = outcome["payload"]["summary"].as_str().map_or_else(
            || format!("confirmed compensation failure: {}", step.step_id),
            str::to_owned,
        );
        if step.step_id == "stop-ability" {
            run.record
                .timeline
                .push(format!("compensation needsAttention: {reason}"));
            return Ok(());
        }
        let job_id = run.record.job_id.clone();
        let owed = intent["stepId"]
            .as_str()
            .unwrap_or(&step.step_id)
            .to_owned();
        let existing =
            cleanup_debt::record(self.artifacts, &job_id, &owed).map_err(|_| uncertain())?;
        // The exact action the attempt kept, or the one its debt recorded.
        let persisted = if run.record.recovery_intent() == intent["eventId"].as_str() {
            run.record.recovery_action().cloned()
        } else {
            existing.map(|record| record["persistedAction"].clone())
        };
        let Some(persisted) = persisted.filter(|action| !action.is_null()) else {
            return Err(uncertain());
        };
        // Swift materializes the persisted action. It is built again here as
        // it was built for that attempt, and must persist as exactly it and
        // derive its source's declaration.
        let action =
            self.attempted_action(run, descriptor, step, kind(intent) == "compensationIntent")?;
        let (action_kind, arguments) = action.persisted();
        if persisted != json!({"kind": action_kind, "arguments": arguments})
            || !declares(
                &planned.source,
                &planned.descriptor,
                step,
                &action,
                &run.record,
            )
        {
            return Err(uncertain());
        }
        let residue = device_steps::cleanup_residue(&action).ok_or_else(uncertain)?;
        let now = run.clock()?;
        cleanup_debt::record_compensation_debt(
            self.artifacts,
            &job_id,
            &owed,
            &residue,
            &reason,
            &persisted,
            &now,
        )
        .map_err(|_| uncertain())?;
        self.refresh_residues(run)?;
        run.record
            .timeline
            .push(format!("compensation needsAttention: {reason}"));
        Ok(())
    }

    /// The typed action a cleanup was dispatched with, built again as it was
    /// then: under this Job, and given the packages a compensation is given
    /// or a step of its kind is.
    fn attempted_action(
        &self,
        run: &Run,
        descriptor: &CatalogOperation,
        step: &CatalogStep,
        compensation: bool,
    ) -> Result<StepAction, RunRefusal> {
        let reference = descriptor.reference();
        let given = if compensation {
            StepInputs::All
        } else {
            device_steps::step_inputs(&reference, &step.kind)
        };
        let resolved = self
            .resolve_inputs(run, given, &step.step_id)
            .map_err(|_| uncertain())?;
        let now = run.clock()?;
        let context = StepContext {
            job_id: &run.record.job_id,
            resolved: &resolved,
            library: None,
            helper: None,
        };
        device_steps::action_in(step, &reference, &inputs_of(run), &now, &context)
            .map_err(|_| uncertain())
    }

    /// Swift `resumeConfirmedOptionalDebugHAPCleanupDebt` on the normal path:
    /// an optional debug HAP cleanup whose failure is journaled and confirmed
    /// owes its debt under the compensation its succeeded source declared, and
    /// is then skipped. It must have attempted exactly that declaration.
    pub(super) fn owe_optional_hap_cleanup(
        &self,
        run: &mut Run,
        descriptor: &CatalogOperation,
        step: &CatalogStep,
        skipped: &mut BTreeSet<String>,
    ) -> Result<(), Stop> {
        let refused = || Stop::Refused(uncertain());
        let Some(source) = device_steps::hap_source_of(&step.step_id)
            .filter(|_| step.optional && step.step_id != "stop-ability")
        else {
            return Err(refused());
        };
        let events = self.journal_events(run)?;
        let Some(intent) = events
            .iter()
            .rev()
            .find(|event| kind(event) == "stepIntent" && step_of(event) == step.step_id)
        else {
            return Err(refused());
        };
        let Some(outcome) = events.iter().rev().find(|event| {
            kind(event) == "stepOutcome"
                && correlates(event, intent)
                && event["payload"]["outcomeCertainty"] == "confirmed"
                && event["payload"]["result"] == "failed"
        }) else {
            return Err(refused());
        };
        let Some(source_intent) = events
            .iter()
            .rev()
            .find(|event| kind(event) == "stepIntent" && step_of(event) == source)
            .filter(|source| {
                concludable(run)
                    && events.iter().any(|event| {
                        kind(event) == "stepOutcome"
                            && correlates(event, source)
                            && event["payload"]["outcomeCertainty"] == "confirmed"
                            && succeeded(event)
                    })
                    && source["bindingRevision"] == intent["bindingRevision"]
                    && source["payload"]["target"] == intent["payload"]["target"]
            })
        else {
            return Err(refused());
        };
        // What the cleanup attempted must be what its source declared.
        let attempted = &intent["payload"]["step"];
        let hash = session_json::encode(&attempted["arguments"])
            .ok()
            .map(|bytes| sha256_hex(&bytes));
        let id = device_steps::compensation_id(&step.step_id);
        let Some(declared) = source_intent["payload"]["step"]["compensationDescriptors"]
            .as_array()
            .into_iter()
            .flatten()
            .find(|declared| declared["id"] == id.as_str())
            .filter(|declared| {
                [
                    "kind",
                    "effect",
                    "arguments",
                    "bindingRequirement",
                    "cancellation",
                ]
                .iter()
                .all(|key| attempted[*key] == declared[*key])
                    && hash
                        .as_deref()
                        .is_some_and(|hash| declared["argumentsHash"] == hash)
            })
        else {
            return Err(refused());
        };
        let planned = Planned {
            source: source.to_owned(),
            descriptor: declared.clone(),
            intent: source_intent.clone(),
        };
        self.hap_debt(run, descriptor, &planned, step, intent, outcome)?;
        self.skip(
            run,
            descriptor,
            step,
            "journal-confirmed cleanup failure; debt retained",
            skipped,
        );
        if run.record.recovery_intent() == intent["eventId"].as_str() {
            run.record.set_recovery(None, None, None);
        }
        run.persist(self.jobs)?;
        Ok(())
    }

    /// Swift `hasCompleteMutationNonExecutionProof` over a failed debug HAP's
    /// terminal journal: every mutation it intended, a step's or a
    /// compensation's, confirmed failed as not executed. Only then is its use
    /// `safeToReflash`; this Runtime's HDC dispatcher never reports a
    /// confirmed non-execution, so a Job it ran settles `confirmed`.
    pub(super) fn hap_non_execution_proven(&self, run: &Run) -> Result<bool, RunRefusal> {
        if run.record.operation() != HAP || run.record.state != "failed" || !concludable(run) {
            return Ok(false);
        }
        let events = self.journal_events(run)?;
        let intents: Vec<&Value> = events
            .iter()
            .filter(|event| matches!(kind(event), "stepIntent" | "compensationIntent"))
            .collect();
        let effect = |intent: &Value| {
            let key = if kind(intent) == "stepIntent" {
                "step"
            } else {
                "descriptor"
            };
            intent["payload"][key]["effect"].as_str().map(str::to_owned)
        };
        if intents.iter().any(|intent| effect(intent).is_none()) {
            return Ok(false);
        }
        let mutations: Vec<&&Value> = intents
            .iter()
            .filter(|intent| {
                matches!(
                    effect(intent).as_deref(),
                    Some("deviceMutation" | "destructive")
                )
            })
            .collect();
        Ok(!mutations.is_empty()
            && mutations.iter().all(|intent| {
                events
                    .iter()
                    .rev()
                    .find(|event| {
                        matches!(kind(event), "stepOutcome" | "compensationOutcome")
                            && correlates(event, intent)
                    })
                    .is_some_and(|outcome| {
                        outcome["payload"]["outcomeCertainty"] == "confirmed"
                            && outcome["payload"]["result"] == "failed"
                            && outcome["payload"]["semanticCode"] == "confirmedNotExecuted"
                    })
            }))
    }

    /// Swift `refreshDebugHAPResidueCount`: the Job's outstanding debts,
    /// counted and made durable.
    fn refresh_residues(&self, run: &mut Run) -> Result<(), RunRefusal> {
        let count = cleanup_debt::outstanding(self.artifacts, &run.record.job_id)
            .map_err(|_| uncertain())?;
        run.record
            .set_residues(i64::try_from(count).map_err(|_| uncertain())?);
        run.persist(self.jobs)
    }

    /// Swift `parkDebugHAPCompensation`: a lane that cannot conclude waits
    /// for recovery, keeping its original failure.
    fn park_hap(&self, run: &mut Run, reason: &str) -> Result<(), RunRefusal> {
        if run.record.state == "finalizing" {
            run.transition("finalizing", "waitingForRecovery", reason)?;
        }
        run.record.set_outcome_unknown();
        run.record
            .timeline
            .push(format!("compensation needsAttention: {reason}"));
        run.persist(self.jobs)
    }

    /// Swift `resumeConfirmedOptionalDebugHAPCleanupDebt`'s own question: is
    /// this optional debug HAP cleanup one whose last attempt the journal
    /// already confirms failed? Only a resumed run can find one.
    pub(super) fn hap_cleanup_failed(&self, run: &Run, step: &CatalogStep) -> Result<bool, Stop> {
        if device_steps::hap_source_of(&step.step_id).is_none() || step.step_id == "stop-ability" {
            return Ok(false);
        }
        let events = self.journal_events(run)?;
        let Some(intent) = events
            .iter()
            .rev()
            .find(|event| kind(event) == "stepIntent" && step_of(event) == step.step_id)
        else {
            return Ok(false);
        };
        Ok(events.iter().any(|event| {
            kind(event) == "stepOutcome"
                && correlates(event, intent)
                && event["payload"]["outcomeCertainty"] == "confirmed"
                && event["payload"]["result"] == "failed"
        }))
    }

    /// Swift `confirmedSucceededStepIDs`: every step whose confirmed outcome
    /// in the journal is a success.
    pub(super) fn confirmed_steps(&self, run: &Run) -> Result<BTreeSet<String>, Stop> {
        Ok(self
            .journal_events(run)?
            .iter()
            .filter(|event| {
                kind(event) == "stepOutcome"
                    && event["payload"]["outcomeCertainty"] == "confirmed"
                    && succeeded(event)
            })
            .map(|event| step_of(event).to_owned())
            .collect())
    }

    /// The Job's journal as it stands, every durable event in order (Swift
    /// `DurableJournalRecovery.inspect`), read without its writer.
    fn journal_events(&self, run: &Run) -> Result<Vec<Value>, RunRefusal> {
        let bytes = self
            .jobs
            .journal_bytes(&run.record.job_id)
            .map_err(|_| uncertain())?;
        let durable = bytes
            .iter()
            .rposition(|byte| *byte == b'\n')
            .map_or(0, |last| last + 1);
        bytes[..durable]
            .split(|byte| *byte == b'\n')
            .filter(|line| !line.is_empty())
            .map(|line| serde_json::from_slice(line).map_err(|_| uncertain()))
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Map;

    fn event(kind: &str, step: &str, payload: Value) -> Value {
        json!({"kind": kind, "stepId": step, "eventId": format!("intent-{step}"),
            "payload": payload})
    }

    #[test]
    fn compensations_run_latest_source_first_and_only_for_confirmed_successes() {
        let declared = |id: &str| json!({"id": id, "trigger": "onFailure"});
        let intent = |step: &str, compensation: &str| {
            event(
                "stepIntent",
                step,
                json!({"step": {"compensationDescriptors": [declared(compensation)]}}),
            )
        };
        let outcome = |step: &str, result: &str| {
            json!({"kind": "stepOutcome", "stepId": step,
                "payload": {"correlatesToIntentEventId": format!("intent-{step}"),
                    "result": result, "outcomeCertainty": "confirmed"}})
        };
        let events = [
            intent("send-hap", "compensation-cleanup-remote-staging"),
            outcome("send-hap", "succeeded"),
            intent("install-hap", "compensation-cleanup-uninstall"),
            outcome("install-hap", "succeeded"),
            intent("start-ability", "compensation-stop-ability"),
            outcome("start-ability", "failed"),
        ];
        let planned: Vec<(String, Value)> = derive(&events)
            .unwrap()
            .into_iter()
            .map(|planned| (planned.source, planned.descriptor["id"].clone()))
            .collect();
        assert_eq!(
            planned,
            [
                (
                    "install-hap".to_owned(),
                    json!("compensation-cleanup-uninstall")
                ),
                (
                    "send-hap".to_owned(),
                    json!("compensation-cleanup-remote-staging")
                ),
            ]
        );
        // A journal whose sources declared nothing never acquires a plan.
        let undeclared = [event(
            "stepIntent",
            "send-hap",
            json!({"step": {"compensationDescriptors": []}}),
        )];
        assert!(derive(&undeclared).is_none());
    }

    #[test]
    fn a_compensation_must_be_its_own_catalog_steps_declared_action() {
        let record = JobRecord::decode(include_bytes!(
            "../../../tests/fixtures/debug-hap/store/jobs/job-e79d1b4e261f4a13d0bfb58a97fbf163/job-record.json"
        ))
        .unwrap();
        let descriptor = CatalogOperation::lookup("debug.hap", Some(1)).unwrap();
        let step = descriptor
            .steps
            .iter()
            .find(|step| step.step_id == "cleanup-uninstall")
            .unwrap();
        let inputs: Map<String, Value> = record.request["inputs"].as_object().unwrap().clone();
        let bundle = arkdeck_provider_hdc::BundleReference::new("com.example.demo").unwrap();
        let action = StepAction::Hap(HapAction::UninstallPackage(bundle));
        let context = StepContext {
            job_id: &record.job_id,
            resolved: &[],
            library: None,
            helper: None,
        };
        let declared =
            device_steps::declared_descriptor(step, HAP, &inputs, &action, &context).unwrap();
        assert!(declares("install-hap", &declared, step, &action, &record));
        // Another source, another bundle or another declaration is refused.
        assert!(!declares("send-hap", &declared, step, &action, &record));
        let other = arkdeck_provider_hdc::BundleReference::new("com.example.other").unwrap();
        let wrong = StepAction::Hap(HapAction::UninstallPackage(other));
        assert!(!declares("install-hap", &declared, step, &wrong, &record));
        let mut changed = declared.clone();
        changed["trigger"] = json!("onSuccess");
        assert!(!declares("install-hap", &changed, step, &action, &record));
    }
}
