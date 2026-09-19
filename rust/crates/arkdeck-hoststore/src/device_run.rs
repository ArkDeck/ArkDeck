//! Swift `RuntimeJobEngine.runOwned` over `executeSteps` and `dispatchWithWAL`
//! for an admitted device-bound HDC Job (`observe.device@1`, the default legs
//! of `capture.diagnostics@1`, the pointer gestures, the port rules,
//! `debug.hap@1` and `deploy.native-library.app-owned@1`), as the isolated
//! Rust owner runs it through its HDC composition: the running transition;
//! every catalog step in
//! order — the engine's own recorded, the host storage preflight among them;
//! an optional step the request did not select recorded as skipped, with the
//! products it owned recorded missing; the provider's dispatched, each with
//! its exact typed action persisted before its write-ahead intent is durable
//! and the executor started only after that intent, its receipt verified as
//! Swift's HDC provider verifies it and its correlated outcome appended — then
//! finalization, which publishes the run's own products, and the terminal
//! transitions. The evidence preflight is the first thing the device steps
//! prove, and every later device step waits for it. An optional step that
//! fails is skipped with its reason and the Job goes on; a step whose outcome
//! cannot be observed, optional or not, leaves its intent outstanding and
//! parks the Job. Nothing is dispatched twice and no Job is resumed. A
//! cancellation is honoured at the next step boundary, where Swift's step
//! loop honours it. A step at or above `deviceMutation` consumes the Job's
//! capability use before its intent can exist; a later one continues under
//! that use once every fresh check has passed again. A port rule's readback is
//! judged against the operation it serves, and a confirmed failure after the
//! rule changed restores it before the Job fails.
//!
//! A debug HAP's packages are resolved from their leases again before each
//! step given them, each still bound to the Target and the identity the plan
//! bound. Its install and its start succeed only as dispatches, believed by
//! the required readback after each. Each step a failure would undo declares
//! that compensation on its intent. A failure is compensated as Swift
//! compensates it (`device_hap_failure.rs`), and a failed cleanup owes a debt
//! in the Artifact root's ledger.
//!
//! A screen sequence's file legs lower within the composition's host receive
//! root. What its run of stills measured stays on the record, and its received
//! archive is published from the landed file, which then does not outlive the
//! publication (`device_screen_sequence.rs`).
//!
//! A native deployment's library is verified on the host, then resolved again
//! and read for each of its device steps, which run only against the Target
//! identity and binding its plan was materialized for. Its send is believed
//! only through the staging readback after it. A confirmed failure of a
//! required step is compensated inside the step loop before the Job fails
//! (`device_native.rs`), and an optional cleanup that fails owes a debt for
//! what it left behind.
use crate::artifact_publication::{ArtifactPublisher, Product};
use crate::artifact_read_owner::{LeasedArtifact, swift_string};
use crate::capture_documents;
use crate::cleanup_debt::{self, Residue};
use crate::device_facts::{self, DeviceFacts, HdcComposition};
use crate::device_steps::{
    self, ActionRefusal, LeasedLibrary, StepAction, StepContext, StepInputs,
};
use crate::job_cancel::RunCancellation;
use crate::job_journal_events::{self as events, Target};
use crate::job_record::JobRecord;
use crate::job_run::{JobRunner, Run, RunRefusal, failure, uncertain};
use crate::mutation_execution::MutationConsumption;
use crate::operation_catalog::{CatalogArtifact, CatalogOperation, CatalogStep};
use crate::session_json;
use arkdeck_provider_hdc::{
    DispatchFailure, Expected, FilePlan, FileReceipt, Outcome, PortAction, PortRule,
    ResolvedArtifact,
};
use serde_json::{Map, Value, json};
use std::collections::{BTreeMap, BTreeSet};

#[path = "device_hap_failure.rs"]
mod hap_failure;
#[path = "device_native.rs"]
mod native;
#[path = "device_screen_sequence.rs"]
mod screen_sequence;

const OBSERVE: &str = "observe.device@1";
const CAPTURE: &str = "capture.diagnostics@1";
const HAP: &str = "debug.hap@1";

/// Swift's evidence preflight, in the order its fragments must arrive.
const EVIDENCE_STEPS: [&str; 3] = [
    "confirm-evidence-target",
    "read-evidence-model",
    "read-evidence-firmware",
];

/// Swift's job byte budget for a capture's products when the request sets no
/// `totalArtifactByteBudget`.
const CAPTURE_BYTE_BUDGET: u64 = 128 * 1024 * 1024;

/// Whether a Job of this operation runs through the HDC composition.
pub(crate) fn runs(operation: &str) -> bool {
    device_steps::DEVICE_OPERATIONS.contains(&operation)
}

/// How a step ended the step loop, as Swift's `runOwned` tells its lanes
/// apart.
enum Stop {
    /// `RuntimeDispatchFailure.failed`: the Job fails with this reason.
    Failed(String),
    /// `.outcomeUnknown`: the Job parks with its intent outstanding.
    Unknown(String),
    /// `RuntimeArtifactPublicationFailure`, with its detail.
    Publication(String),
    /// A cancellation reached a step boundary and was made durable.
    Cancelled,
    /// The lifecycle itself could not be completed.
    Refused(RunRefusal),
}

impl From<RunRefusal> for Stop {
    fn from(refusal: RunRefusal) -> Self {
        Self::Refused(refusal)
    }
}

/// What a dispatch's intent journals: a catalog step, which declares the
/// compensations that would undo it, or the declared compensation a debug
/// HAP's failure lane runs under its source's declaration.
enum Journaled<'a> {
    Step,
    Compensation {
        source: &'a str,
        descriptor: &'a Value,
    },
}

/// The request's inputs, as the run reads them.
fn inputs_of(run: &Run) -> Map<String, Value> {
    run.record.request["inputs"]
        .as_object()
        .cloned()
        .unwrap_or_default()
}

/// Swift's timeline spelling of a verified summary's fact names.
fn fact_names(summary: &BTreeMap<String, String>) -> String {
    let names: Vec<String> = summary.keys().map(|key| format!("\"{key}\"")).collect();
    format!("[{}]", names.join(", "))
}

/// The catalog descriptor a Job record names.
fn descriptor(reference: &str) -> Option<&'static CatalogOperation> {
    let (id, version) = reference.rsplit_once('@')?;
    CatalogOperation::lookup(id, version.parse().ok())
}

/// Swift's capture budget: the request's `totalArtifactByteBudget`, else
/// 128 MiB.
fn byte_budget(record: &JobRecord) -> u64 {
    record.request["inputs"]["totalArtifactByteBudget"]
        .as_u64()
        .unwrap_or(CAPTURE_BYTE_BUDGET)
}

/// Swift `RuntimeEvidencePreflightAccumulator.isComplete`.
fn preflight_complete(accumulator: &Value) -> bool {
    ["transport", "confirmedAtUTC", "model", "firmware"]
        .iter()
        .all(|key| accumulator.get(*key).is_some())
        && accumulator["steps"].as_array().is_some_and(|steps| {
            steps
                .iter()
                .map(|step| step["stepID"].clone())
                .collect::<Vec<_>>()
                == EVIDENCE_STEPS.map(Value::from)
        })
}

/// A partly carried readback cannot renew the session cache's original age.
fn preflight_fresh(accumulator: &Value) -> bool {
    preflight_complete(accumulator)
        && accumulator["steps"].as_array().is_some_and(|steps| {
            steps
                .iter()
                .all(|step| step.get("carriedFromUTC").is_none())
        })
}

/// Swift `WorkflowEffect >= .deviceMutation` over a catalog step: the steps
/// that consume the Job's capability use before their intent. An effect this
/// Runtime cannot read counts as one.
fn mutates(step: &CatalogStep) -> bool {
    !matches!(step.effect.as_str(), "hostOnly" | "readOnly")
}

/// Swift's engine judges a port rule's readback against the operation it
/// serves: a create must find the rule, a remove must not. The provider only
/// reports what it read.
fn port_readback(descriptor: &CatalogOperation, step: &CatalogStep, outcome: Outcome) -> Outcome {
    let expected = descriptor.reference() == "port-forward.create@1";
    let readback = matches!(
        step.step_id.as_str(),
        "verify-port-rule" | "verify-port-rule-compensation"
    );
    let mismatch = readback
        && matches!(&outcome, Outcome::Verified(summary) if summary
            .get("present")
            .and_then(|present| present.parse::<bool>().ok())
            .is_some_and(|present| present != expected));
    if !mismatch {
        return outcome;
    }
    Outcome::Failed {
        code: "portForwardReadbackMismatch",
        detail: if expected {
            "the exact typed rule is absent after create"
        } else {
            "the exact typed rule remains after remove"
        }
        .into(),
    }
}

/// Swift's interpolation of the `RuntimeDispatchFailure` a dispatch ended
/// with, as the lanes after it name it; none for a stop that is not one.
fn dispatch_failure(stop: &Stop) -> Option<String> {
    match stop {
        Stop::Failed(reason) => Some(format!("failed({})", swift_string(reason))),
        Stop::Unknown(reason) => Some(format!("outcomeUnknown({})", swift_string(reason))),
        _ => None,
    }
}

/// Swift `validateMaterializedTargetFacts`: the Target's facts hold for the
/// request and still name the identity and binding revision the Job's plan
/// was materialized against.
fn materialized_facts(
    record: &JobRecord,
    facts: Option<&DeviceFacts>,
    target_id: &str,
    revision: Option<i64>,
) -> Result<(), Stop> {
    let facts = facts.ok_or_else(|| {
        Stop::Failed(
            "evidenceIncomplete: target/binding/routing/tool facts are absent or mismatched".into(),
        )
    })?;
    device_facts::validate(facts, target_id, revision)
        .map_err(|reason| Stop::Failed(reason.into()))?;
    if record.materialized_identity() != Some(facts.identity.as_str())
        || record.materialized_binding() != Some(facts.binding_revision)
    {
        return Err(Stop::Failed(
            "target identity or binding revision drifted after plan materialization".into(),
        ));
    }
    Ok(())
}

/// What every product one Job publishes shares: its owner, operation,
/// provider and binding snapshot as they stand now.
struct Owner {
    job_id: String,
    session_id: String,
    reference: String,
    provider: String,
    binding: Value,
}

impl Owner {
    fn of(record: &JobRecord, descriptor: &CatalogOperation) -> Self {
        Self {
            job_id: record.job_id.clone(),
            session_id: format!("session-{}", record.job_id),
            reference: descriptor.reference(),
            provider: descriptor.provider.clone(),
            binding: binding_snapshot(record),
        }
    }

    fn product<'a>(
        &'a self,
        step_id: &'a str,
        declaration: &'a CatalogArtifact,
        window: Option<(String, String)>,
    ) -> Product<'a> {
        Product {
            job_id: &self.job_id,
            session_id: &self.session_id,
            step_id,
            name: &declaration.name,
            media_type: &declaration.media_type,
            privacy: &declaration.privacy,
            retention_class: &declaration.retention_class,
            source_operation: &self.reference,
            provider_id: &self.provider,
            binding: self.binding.clone(),
            observation_window: window,
        }
    }
}

fn declaration<'a>(descriptor: &'a CatalogOperation, name: &str) -> Option<&'a CatalogArtifact> {
    descriptor
        .artifacts
        .iter()
        .find(|artifact| artifact.name == name)
}

impl JobRunner<'_> {
    pub(crate) fn execute_device(
        &self,
        run: &mut Run,
        hdc: &HdcComposition<'_>,
    ) -> Result<(), RunRefusal> {
        self.execute_device_inner(run, hdc)?;
        let outcome = if run.record.state == "waitingForRecovery" {
            crate::capability_store::UseOutcome::OutcomeUnknown
        } else if self.hap_non_execution_proven(run)? {
            crate::capability_store::UseOutcome::SafeToReflash
        } else {
            crate::capability_store::UseOutcome::Confirmed
        };
        self.settle_mutation(run, outcome)
    }

    /// Swift `runOwned` for a device-bound HDC operation.
    fn execute_device_inner(
        &self,
        run: &mut Run,
        hdc: &HdcComposition<'_>,
    ) -> Result<(), RunRefusal> {
        let started = run.clock()?;
        run.record.start(&started);
        run.transition("preflight", "running", "steps-start")?;
        let Some(descriptor) = descriptor(run.record.operation()) else {
            return Err(uncertain());
        };
        let hap = descriptor.reference() == HAP;
        match self.steps(run, hdc, descriptor) {
            Ok(()) => {}
            // A debug HAP first compensates what its succeeded steps did.
            Err(Stop::Failed(reason)) if hap => {
                run.record.set_operation_failure(Some(failure(
                    "executionFailed",
                    "execution",
                    "runtimeDecisionRequired",
                    "inspectJob",
                )));
                return self.finalize_hap_failure(run, hdc, descriptor, &reason);
            }
            Err(Stop::Failed(reason)) => return self.fail(run, &reason),
            Err(Stop::Unknown(reason)) => return self.park(run, &reason),
            Err(Stop::Publication(detail)) => {
                run.record.set_operation_failure(Some(failure(
                    "artifactPublicationFailed",
                    "storage",
                    "notAutomatic",
                    "inspectJob",
                )));
                let reason = format!("artifact publication failed: {detail}");
                if hap {
                    return self.finalize_hap_failure(run, hdc, descriptor, &reason);
                }
                return self.close(run, &reason);
            }
            // Swift's step loop stops at the boundary and `runOwned` drains.
            Err(Stop::Cancelled) => {
                run.transition(
                    "cancelRequested",
                    "cancellingAtSafeBoundary",
                    "safe-boundary",
                )?;
                run.transition("cancellingAtSafeBoundary", "cancelled", "steps-drained")?;
                run.record.set_operation_failure(Some(failure(
                    "cancelled",
                    "cancelled",
                    "notAutomatic",
                    "none",
                )));
                run.finish()?;
                return run.persist(self.jobs);
            }
            Err(Stop::Refused(refusal)) => return Err(refusal),
        }
        run.transition("running", "finalizing", "steps-complete")?;
        if let Err(detail) = self.finalize(run, descriptor) {
            run.record.set_operation_failure(Some(failure(
                "artifactFinalizationFailed",
                "storage",
                "notAutomatic",
                "inspectJob",
            )));
            run.transition(
                "finalizing",
                "failed",
                &format!("artifact finalization failed: {detail}"),
            )?;
            run.finish()?;
            return run.persist(self.jobs);
        }
        run.record.set_operation_failure(None);
        run.transition("finalizing", "succeeded", "finalized")?;
        run.finish()?;
        run.persist(self.jobs)
    }

    fn publisher(&self) -> ArtifactPublisher<'_> {
        ArtifactPublisher {
            store: self.artifacts,
            quota: self.quota,
            home: self.home,
            now: self.now,
        }
    }

    /// Swift `executeSteps` over every step the descriptor declares.
    fn steps(
        &self,
        run: &mut Run,
        hdc: &HdcComposition<'_>,
        descriptor: &CatalogOperation,
    ) -> Result<(), Stop> {
        let reference = descriptor.reference();
        let gated = device_steps::requires_evidence_preflight(&reference);
        let inputs = inputs_of(run);
        let target_id = run.record.request["target"]["targetId"]
            .as_str()
            .unwrap_or_default()
            .to_owned();
        let revision = run.record.request["target"]["expectedBindingRevision"].as_i64();
        let (mut skipped, mut completed) = (BTreeSet::new(), BTreeSet::new());
        for step in &descriptor.steps {
            // The safe boundary between steps; the canceller's intent becomes
            // durable here and the run then drains.
            if self.cancellation.is_some_and(RunCancellation::pending) {
                self.carry(run)?;
                return Err(Stop::Cancelled);
            }
            if device_steps::engine_step(&step.kind) {
                match step.kind.as_str() {
                    "preflightHostStorage" => self.preflight_host_storage(run, descriptor)?,
                    "postprocessArtifact" | "finalizeSession" => {}
                    // Swift `verifyHostInputArtifact` verifies a flash image or
                    // a native library; a debug HAP's packages are resolved
                    // again at each step given them.
                    "verifyArtifact" if reference == HAP => {}
                    "verifyArtifact" | "hashFile" if reference == device_steps::NATIVE => {
                        self.verify_native_library(run, step)?;
                    }
                    _ => return Err(Stop::Refused(uncertain())),
                }
                run.record
                    .timeline
                    .push(format!("host-step {}", step.step_id));
                continue;
            }
            // "Its upstream did not run" and "you did not ask for it" are
            // different facts, and the reason names the real one.
            let upstream = device_steps::upstream(&reference, &step.step_id);
            if upstream.is_some_and(|upstream| skipped.contains(upstream))
                || !descriptor.step_is_selected(step, &inputs)
            {
                let reason = match upstream
                    .and_then(|upstream| Some((upstream, run.record.skip_reason(upstream)?)))
                {
                    Some((upstream, cause)) => format!("upstream {upstream} did not run: {cause}"),
                    None => "step not selected by the request inputs".into(),
                };
                self.skip(run, descriptor, step, &reason, &mut skipped);
                continue;
            }
            // A step's input Artifacts are resolved from their leases again
            // before anything else of it (a debug HAP's packages for the steps
            // given them, a native deployment's library, read for the step,
            // for each of its device steps); the other operations take none.
            let (resolved, library) = self.step_artifacts(run, &reference, step)?;
            let evidence = device_steps::evidence_preflight_step(step);
            let facts = if step.binding == "confirmedDevice" {
                match hdc.facts(&target_id) {
                    Ok(facts) => Some(facts),
                    Err(error) if gated && evidence => {
                        return Err(Stop::Failed(format!(
                            "evidenceIncomplete: descriptor-bound target facts unavailable: {error}"
                        )));
                    }
                    Err(error) => {
                        run.record
                            .timeline
                            .push(format!("target facts unavailable: {error}"));
                        None
                    }
                }
            } else {
                None
            };
            if gated && evidence {
                let facts = facts.as_ref().ok_or_else(|| {
                    Stop::Failed(
                        "evidenceIncomplete: target/binding/routing/tool facts are absent or mismatched"
                            .into(),
                    )
                })?;
                device_facts::validate(facts, &target_id, revision)
                    .map_err(|reason| Stop::Failed(reason.into()))?;
            } else if gated && step.binding == "confirmedDevice" {
                // Swift `requireCompleteEvidencePreflight`.
                let complete = run
                    .record
                    .evidence_preflight()
                    .is_some_and(preflight_complete)
                    && run.record.evidence_observation().is_some();
                if !complete {
                    return Err(Stop::Failed(format!(
                        "evidenceIncomplete: three-step typed preflight is incomplete before {}",
                        step.step_id
                    )));
                }
            }
            if gated && evidence && self.carry_session_evidence(run, descriptor, step)? {
                continue;
            }
            // A native deployment's device step runs only against the Target
            // its plan was materialized for.
            if reference == device_steps::NATIVE && step.binding == "confirmedDevice" {
                materialized_facts(&run.record, facts.as_ref(), &target_id, revision)?;
            }
            let Some(now) = (hdc.now)() else {
                return Err(Stop::Refused(uncertain()));
            };
            let job_id = run.record.job_id.clone();
            let context = StepContext {
                job_id: &job_id,
                resolved: &resolved,
                library: library.as_ref(),
                helper: hdc.code_sign_helper,
            };
            let action = match device_steps::action_in(step, &reference, &inputs, &now, &context) {
                Ok(action) => action,
                // Swift's provider refusing an optional step skips it.
                Err(ActionRefusal::Invalid(_)) if step.optional => {
                    self.skip(
                        run,
                        descriptor,
                        step,
                        "provider has no action for this step",
                        &mut skipped,
                    );
                    continue;
                }
                Err(_) => return Err(Stop::Refused(uncertain())),
            };
            // Swift lowers the action before any use is consumed.
            let plan = match action.plan_in(
                &step.step_id,
                facts.as_ref().map(|facts| facts.connect_key.as_str()),
                &context,
                hdc.receive_root,
            ) {
                Ok(plan) => plan,
                Err(error) if gated && evidence => {
                    return Err(Stop::Failed(format!(
                        "evidenceIncomplete: typed preflight could not be lowered: {error}"
                    )));
                }
                Err(_) => return Err(Stop::Refused(uncertain())),
            };
            // A refused authority is the step's own failure, handled below as
            // a failed dispatch is (Swift catches both in one place).
            let authorized = if mutates(step) {
                self.authorize_step(run, descriptor, facts.as_ref())?
            } else {
                Ok(())
            };
            match authorized.and_then(|()| {
                self.dispatch_step(
                    run,
                    hdc,
                    descriptor,
                    step,
                    &action,
                    &plan,
                    facts.as_ref(),
                    &target_id,
                    revision,
                    &resolved,
                    Journaled::Step,
                )
            }) {
                Ok(()) => {
                    completed.insert(step.step_id.clone());
                }
                // A debug HAP's optional cleanup that failed owes its debt,
                // then is skipped.
                Err(Stop::Failed(_))
                    if step.optional
                        && reference == HAP
                        && device_steps::cleanup_residue(&action).is_some() =>
                {
                    self.owe_optional_hap_cleanup(run, descriptor, step, &mut skipped)?;
                }
                // Optional steps are the partial-success surface: one that
                // fails is skipped with its failure and the Job goes on. An
                // unknown outcome is never tolerated. A cleanup that ran and
                // failed also owes a record of what it left behind.
                Err(Stop::Failed(reason)) if step.optional => {
                    let reason = format!("failed({})", swift_string(&reason));
                    self.skip(run, descriptor, step, &reason, &mut skipped);
                    if let Some(residue) = device_steps::cleanup_residue(&action) {
                        self.owe_cleanup(run, &step.step_id, &residue, &reason, &action);
                    }
                }
                // A native deployment first undoes what it changed, and a port
                // rule that changed before the failure is restored.
                Err(Stop::Failed(reason)) => {
                    if let StepAction::Native(native) = &action {
                        self.compensate_native_library(
                            run,
                            hdc,
                            descriptor,
                            native.deployment(),
                            &completed,
                            &step.step_id,
                            &reason,
                            &target_id,
                            revision,
                        )?;
                    }
                    self.compensate_port_rule(
                        run, hdc, descriptor, &action, &completed, &target_id, revision,
                    )?;
                    return Err(Stop::Failed(reason));
                }
                Err(stop) => return Err(stop),
            }
        }
        Ok(())
    }

    /// Swift `consumeCapabilityBeforeMutation` at a mutation step: the Job's
    /// use consumed before its first mutation, or continued at a later one.
    /// The outer error ends the step loop (a consumption whose persistence is
    /// uncertain, a cancellation made durable); the inner one is the step's
    /// own failure.
    fn authorize_step(
        &self,
        run: &mut Run,
        descriptor: &CatalogOperation,
        facts: Option<&DeviceFacts>,
    ) -> Result<Result<(), Stop>, Stop> {
        let Some(facts) = facts else {
            return Ok(Err(Stop::Failed(
                "authorizationRequired: fresh device facts unavailable".into(),
            )));
        };
        let authority = self.consume_mutation_authority(run, descriptor, facts);
        if matches!(&authority, Ok(MutationConsumption::PersistenceUncertain)) {
            return Err(Stop::Refused(uncertain()));
        }
        // Cancellation is re-read after fresh materialization and after
        // durable consumption; neither boundary may enter the WAL.
        if self.cancellation.is_some_and(RunCancellation::pending)
            || matches!(&authority, Ok(MutationConsumption::Cancelled))
        {
            self.carry(run)?;
            return Err(Stop::Cancelled);
        }
        Ok(authority.map(|_| ()).map_err(Stop::Failed))
    }

    /// Swift `recordSkippedOptionalStep`: the reason on the timeline and in
    /// the record, and every product the step owned recorded missing with it.
    fn skip(
        &self,
        run: &mut Run,
        descriptor: &CatalogOperation,
        step: &CatalogStep,
        reason: &str,
        skipped: &mut BTreeSet<String>,
    ) {
        run.record
            .timeline
            .push(format!("skipped {}: {reason}", step.step_id));
        skipped.insert(step.step_id.clone());
        run.record.set_skip_reason(&step.step_id, reason);
        let owner = Owner::of(&run.record, descriptor);
        let publisher = self.publisher();
        for name in device_steps::products(&owner.reference, &step.step_id) {
            if let Some(declaration) = declaration(descriptor, name) {
                let _ = publisher
                    .record_missing(&owner.product(&step.step_id, declaration, None), reason);
            }
        }
    }

    /// Swift `recordCleanupDebt`, then `refreshResidueCount`, each a best
    /// effort as Swift makes them: what a failed cleanup left behind appended
    /// to the ledger with the exact action that failed, then the Job's
    /// outstanding residue counted again from the ledger and made durable.
    fn owe_cleanup(
        &self,
        run: &mut Run,
        step_id: &str,
        residue: &Residue,
        reason: &str,
        action: &StepAction,
    ) {
        let (kind, arguments) = action.persisted();
        if let Some(now) = (self.now)() {
            let _ = cleanup_debt::append(
                self.artifacts,
                &run.record.job_id,
                step_id,
                residue,
                reason,
                &json!({"kind": kind, "arguments": arguments}),
                &now,
            );
        }
        let owed = cleanup_debt::outstanding(self.artifacts, &run.record.job_id).unwrap_or(0);
        run.record
            .set_residues(i64::try_from(owed).unwrap_or(i64::MAX));
        let _ = run.persist(self.jobs);
    }

    /// Swift's `preflightHostStorage` step: the room the capture may take,
    /// asked of the Artifact store before any device is touched.
    fn preflight_host_storage(&self, run: &Run, descriptor: &CatalogOperation) -> Result<(), Stop> {
        let requested = run.record.request["inputs"]["totalArtifactByteBudget"]
            .as_i64()
            .unwrap_or(descriptor.output_byte_budget);
        self.publisher()
            .preflight_additional_bytes(requested)
            .map_err(|error| {
                Stop::Publication(format!(
                    "host storage preflight refused collection: {error}"
                ))
            })
    }

    /// Swift `resolvedInputArtifact`, then `resolvedAdditionalInputArtifacts`
    /// for a step given every package: a debug HAP's input Artifacts resolved
    /// from their leases again immediately before the step, an Import's
    /// through its owner. Each must still be bound to the request's target and
    /// binding revision and to the identity the plan was materialized against
    /// (Swift `validateArtifactBinding`). One that no longer resolves, or no
    /// longer binds, fails the Job with Swift's interpolated refusal.
    fn resolve_inputs(
        &self,
        run: &Run,
        given: StepInputs,
        step_id: &str,
    ) -> Result<Vec<ResolvedArtifact>, Stop> {
        self.leased_inputs(run, given, step_id)?
            .into_iter()
            .map(resolved_input)
            .collect()
    }

    /// A step's input Artifacts, resolved from their leases again immediately
    /// before it, and for a native deployment its library as its provider
    /// reads it for the step (Swift `nativeLibraryAction` reads it there). A
    /// library that cannot be read leaves the provider no action for the
    /// step.
    fn step_artifacts(
        &self,
        run: &Run,
        reference: &str,
        step: &CatalogStep,
    ) -> Result<(Vec<ResolvedArtifact>, Option<LeasedLibrary>), Stop> {
        let leased = self.leased_inputs(
            run,
            device_steps::step_inputs(reference, &step.kind),
            &step.step_id,
        )?;
        let library = leased
            .first()
            .filter(|_| reference == device_steps::NATIVE)
            .and_then(|library| {
                Some(LeasedLibrary {
                    bytes: crate::job_plan::read_library(&library.path).ok()?,
                    byte_count: library.row["byteCount"].as_i64()?,
                })
            });
        let resolved = leased
            .into_iter()
            .map(resolved_input)
            .collect::<Result<_, _>>()?;
        Ok((resolved, library))
    }

    /// The leases `given` names, the entry first (a debug HAP's entry
    /// package, or a native deployment's library), each resolved and bound.
    fn leased_inputs(
        &self,
        run: &Run,
        given: StepInputs,
        step_id: &str,
    ) -> Result<Vec<LeasedArtifact>, Stop> {
        if given == StepInputs::None {
            return Ok(Vec::new());
        }
        let request = &run.record.request;
        let rejected = |message: &str| {
            Stop::Failed(format!(
                "rejected(ArkDeckCore.RuntimeOperationErrorCode.invalidInput, {})",
                swift_string(message)
            ))
        };
        // Swift `resolvedInputArtifact`: the lease the operation's entry
        // input names.
        let entry = if run.record.operation() == device_steps::NATIVE {
            "libraryArtifactLease"
        } else {
            "hapArtifactLease"
        };
        let Some(entry) = request["inputs"][entry].as_str() else {
            return Err(Stop::Refused(uncertain()));
        };
        let mut leases = vec![entry];
        if given == StepInputs::All {
            for lease in request["inputs"]["additionalHapArtifactLeases"]
                .as_array()
                .into_iter()
                .flatten()
            {
                leases.push(lease.as_str().ok_or_else(|| {
                    rejected("additionalHapArtifactLeases must be artifact leases")
                })?);
            }
        }
        leases
            .into_iter()
            .map(|lease| {
                let leased = self.lease(lease).map_err(|error| {
                    Stop::Failed(format!(
                        "input Artifact lease became unreadable before {step_id}: {error}"
                    ))
                })?;
                if let Some(refusal) = unbound(&leased, &run.record) {
                    return Err(rejected(refusal));
                }
                Ok(leased)
            })
            .collect()
    }

    /// Swift `RuntimeArtifactStore.resolveLease`: an Import's lease through
    /// the Import owner, any other through the Artifact owner.
    fn lease(&self, lease: &str) -> Result<LeasedArtifact, String> {
        match crate::job_owner::import_references::ImportReference::parse(lease)
            .map_err(|error| error.message)?
        {
            Some(reference) => self
                .imports
                .ok_or_else(|| "Import owner is unavailable".to_owned())?
                .resolve_input(self.artifacts, &reference)
                .map_err(|error| error.message),
            None => self.artifacts.lease(lease),
        }
    }

    /// Swift `dispatchWithWAL` for one HDC step, or for the compensation a
    /// debug HAP's failure lane runs under the identity its source declared.
    #[allow(clippy::too_many_arguments)]
    fn dispatch_step(
        &self,
        run: &mut Run,
        hdc: &HdcComposition<'_>,
        descriptor: &CatalogOperation,
        step: &CatalogStep,
        action: &StepAction,
        plan: &FilePlan,
        facts: Option<&DeviceFacts>,
        target_id: &str,
        revision: Option<i64>,
        resolved: &[ResolvedArtifact],
        journaled: Journaled<'_>,
    ) -> Result<(), Stop> {
        let reference = descriptor.reference();
        let device = step.binding == "confirmedDevice";
        let inputs = inputs_of(run);
        let job_id = run.record.job_id.clone();
        let context = StepContext {
            job_id: &job_id,
            resolved,
            library: None,
            helper: None,
        };
        let compensation = match &journaled {
            Journaled::Compensation { source, descriptor } => Some((*source, *descriptor)),
            Journaled::Step => None,
        };
        // A compensation runs only inside its Job's failure finalization, as
        // the catalog step its source declared, with exactly that action.
        let journal_step = match compensation {
            Some((source, declared)) => {
                let owned = run.record.state == "finalizing"
                    && declared["id"]
                        .as_str()
                        .and_then(device_steps::compensation_catalog_step)
                        == Some(step.step_id.as_str());
                if !owned || !hap_failure::declares(source, declared, step, action, &run.record) {
                    return Err(Stop::Refused(uncertain()));
                }
                None
            }
            None => {
                // Swift `debugHAPCompensationDeclaration`, within the step's
                // own context.
                let declarations =
                    match device_steps::hap_compensation(descriptor, &inputs, &step.step_id) {
                        None => Vec::new(),
                        Some(_) => {
                            let now = (hdc.now)().ok_or_else(|| Stop::Refused(uncertain()))?;
                            device_steps::compensation_declarations(
                                step, descriptor, &inputs, &now, &context,
                            )
                            .ok_or_else(|| Stop::Refused(uncertain()))?
                        }
                    };
                let arguments =
                    device_steps::journal_arguments_in(step, &reference, &inputs, action, &context)
                        .ok_or_else(|| Stop::Refused(uncertain()))?;
                Some(json!({
                    "id": step.step_id, "kind": step.kind, "effect": step.effect,
                    "cancellation": step.cancellation, "bindingRequirement": step.binding,
                    "arguments": arguments, "compensationDescriptors": declarations,
                }))
            }
        };
        let journal_id = match compensation {
            Some((_, declared)) => declared["id"]
                .as_str()
                .ok_or_else(|| Stop::Refused(uncertain()))?
                .to_owned(),
            None => step.step_id.clone(),
        };
        let intent_id = format!("intent-{journal_id}");
        // The journal mirrors the descriptor-bound facts without the raw key.
        let identity = facts.map_or_else(|| "0".repeat(64), |facts| facts.identity.clone());
        let target = Target {
            scope: if device { "device" } else { "host" }.into(),
            target_id: target_id.into(),
            connect_key: device.then(|| format!("sha256:{identity}")),
            identity_snapshot_hash: device.then(|| identity.clone()),
        };
        let binding = device.then(|| revision.unwrap_or(1));
        let envelope = run.envelope(intent_id.clone())?;
        let intent = match (compensation, &journal_step) {
            (Some((source, declared)), _) => {
                events::compensation_intent(&envelope, source, declared, &target, 1, binding)
            }
            (None, Some(journal_step)) => {
                events::step_intent(&envelope, journal_step, &target, 1, binding)
            }
            (None, None) => return Err(Stop::Refused(uncertain())),
        }
        .map_err(|_| Stop::Refused(uncertain()))?;
        // A debug HAP's cleanup, like every compensation, keeps its exact
        // action after a confirmed failure: the debt it owes records it.
        let retains = compensation.is_some()
            || (reference == HAP && device_steps::cleanup_residue(action).is_some());
        // The exact typed action is durable before its intent can be.
        let (kind, persisted) = action.persisted();
        run.record.set_recovery(
            Some(&journal_id),
            Some(&intent_id),
            Some(json!({"kind": kind, "arguments": persisted})),
        );
        run.persist(self.jobs)?;
        if run.append(intent).is_err() {
            run.record.set_recovery(None, None, None);
            let _ = run.persist(self.jobs);
            return Err(Stop::Refused(uncertain()));
        }
        run.record.timeline.push(format!("intent {journal_id}"));
        run.record.add_step_kind(&step.kind);
        // A device step after the preflight is where a Job's evidence starts.
        if device && !device_steps::evidence_preflight_step(step) {
            let now = run.clock()?;
            run.record.set_first_evidence(&now);
        }
        // The outcome correlated with the intent, under the intent's own
        // identity; a compensation's dispatch failure is its summary.
        let outcome =
            |run: &mut Run, result: &str, at: &str, summary: Option<&str>| match compensation {
                Some((source, _)) => {
                    let envelope = run.envelope_at(format!("outcome-{journal_id}"), at.into());
                    run.append(events::compensation_outcome(
                        &envelope,
                        source,
                        &journal_id,
                        1,
                        &intent_id,
                        result,
                        "confirmed",
                        None,
                        summary,
                    ))
                }
                None => run.step_outcome_at(&step.step_id, &intent_id, result, None, at),
            };
        let dispatch_failure =
            |reason: &str| compensation.map(|_| format!("failed({})", swift_string(reason)));
        // Only now may the executor start.
        let Some(opened) = (self.precise_now)() else {
            let reason = "dispatch refused: the Runtime clock is unavailable";
            let at = run.clock()?;
            outcome(run, "failed", &at, dispatch_failure(reason).as_deref())?;
            run.record.timeline.push(format!("failed {}", step.step_id));
            if !retains {
                run.record.set_recovery(None, None, None);
            }
            return Err(Stop::Failed(reason.into()));
        };
        // A sequence runs its processes in order, as Swift's dispatcher does.
        let receipt = match arkdeck_provider_hdc::run(plan, hdc.dispatch) {
            Ok(receipt) => receipt,
            Err(DispatchFailure::Unobservable(reason)) => {
                run.record.timeline.push(format!(
                    "outcomeUnknown {}; durable intent left outstanding",
                    step.step_id
                ));
                return Err(Stop::Unknown(reason));
            }
            Err(DispatchFailure::Refused(reason)) => {
                let at = run.clock()?;
                outcome(run, "failed", &at, dispatch_failure(&reason).as_deref())?;
                run.record.timeline.push(format!("failed {}", step.step_id));
                if !retains {
                    run.record.set_recovery(None, None, None);
                }
                return Err(Stop::Failed(reason));
            }
        };
        let window = (self.precise_now)().map(|closed| (opened, closed));
        let expected = Expected {
            connect_key: facts.map(|facts| facts.connect_key.as_str()),
            identity_sha256: facts.map(|facts| facts.identity.as_str()),
            tool_version: facts.map(|facts| facts.tool_version.as_str()),
        };
        // A package readback binds its verdict to the entry package resolved
        // for it.
        let entry = resolved.first().map(|artifact| artifact.sha256.as_str());
        match port_readback(descriptor, step, action.verify(&receipt, expected, entry)) {
            Outcome::Verified(summary) => {
                let outcome_at = run.clock()?;
                outcome(run, "succeeded", &outcome_at, None)?;
                run.record.timeline.push(format!(
                    "verified {} {}",
                    step.step_id,
                    fact_names(&summary)
                ));
                // The timeline names the facts a step verified, not their
                // values; what a run of stills measured is kept on the record.
                if let Some(measured) = screen_sequence::measured(&summary) {
                    run.record.set_screen_sequence(measured);
                }
                // A compensation keeps its action until its lane concludes,
                // and publishes nothing.
                if compensation.is_some() {
                    return Ok(());
                }
                run.record.set_recovery(None, None, None);
                if device_steps::requires_evidence_preflight(run.record.operation())
                    && device_steps::evidence_preflight_step(step)
                {
                    self.capture_evidence(
                        run,
                        step,
                        &summary,
                        facts,
                        target_id,
                        revision,
                        &outcome_at,
                    )?;
                }
                self.publish(run, descriptor, step, &summary, window, &receipt)
            }
            Outcome::Failed { code, detail } => {
                let at = run.clock()?;
                outcome(run, "failed", &at, None)?;
                if !retains {
                    run.record.set_recovery(None, None, None);
                }
                run.record
                    .timeline
                    .push(format!("failed {}: {code}: {detail}", step.step_id));
                Err(Stop::Failed(format!("{code}: {detail}")))
            }
            // Swift's awaiting-readback lane: a mutation whose truth its
            // provider delegates to the required readback after it succeeds
            // as a dispatch, and that readback is what may believe it.
            Outcome::Unknown(_) | Outcome::Unsupported(_)
                if compensation.is_none()
                    && device_steps::awaits_readback(descriptor, &step.step_id) =>
            {
                let at = run.clock()?;
                outcome(run, "succeeded", &at, None)?;
                run.record
                    .timeline
                    .push(format!("dispatched {}; awaiting readback", step.step_id));
                run.record.set_recovery(None, None, None);
                Ok(())
            }
            Outcome::Unknown(reason) | Outcome::Unsupported(reason) => {
                // The intent stays outstanding: no outcome is invented, and
                // recovery alone may resolve it by readback.
                run.record.timeline.push(format!(
                    "outcomeUnknown {}; durable intent left outstanding",
                    step.step_id
                ));
                Err(Stop::Unknown(reason))
            }
        }
    }

    /// A session may carry model/firmware only after this Job re-proved identity.
    /// The original complete readback never has its lifetime renewed by carrying.
    fn carry_session_evidence(
        &self,
        run: &mut Run,
        descriptor: &CatalogOperation,
        step: &CatalogStep,
    ) -> Result<bool, Stop> {
        if !["read-evidence-model", "read-evidence-firmware"].contains(&step.step_id.as_str()) {
            return Ok(false);
        }
        let inputs = run.record.request["inputs"]
            .as_object()
            .ok_or_else(|| Stop::Refused(uncertain()))?;
        if !crate::capability_policy::session_scoped(descriptor, inputs) {
            return Ok(false);
        }
        let Some(owner) = self.mutation else {
            return Ok(false);
        };
        let Some(mut accumulator) = run.record.evidence_preflight().cloned() else {
            return Ok(false);
        };
        let Some(steps) = accumulator["steps"].as_array() else {
            return Ok(false);
        };
        if steps
            .first()
            .is_none_or(|s| s["stepID"] != "confirm-evidence-target")
            || EVIDENCE_STEPS.get(steps.len()) != Some(&step.step_id.as_str())
        {
            return Ok(false);
        }
        let key = format!(
            "{}\n{}",
            accumulator["stableIdentitySHA256"]
                .as_str()
                .unwrap_or_default(),
            accumulator["bindingRevision"]
        );
        let Some(carried) = owner.authority.holds.session_evidence(&key) else {
            return Ok(false);
        };
        if carried["stableIdentitySHA256"] != accumulator["stableIdentitySHA256"] {
            return Ok(false);
        }
        let now = run.clock()?;
        let Some(read_at) = carried["confirmedAtUTC"].as_str() else {
            return Ok(false);
        };
        let (Some(before), Some(current)) = (
            crate::format_time::plain_utc_seconds(read_at),
            crate::format_time::plain_utc_seconds(&now),
        ) else {
            return Ok(false);
        };
        if current < before || current - before >= 3600 {
            return Ok(false);
        }
        if step.step_id == "read-evidence-model" {
            accumulator["model"] = carried["model"].clone();
        } else {
            accumulator["firmware"] = carried["firmware"].clone();
            accumulator["confirmedAtUTC"] = json!(now);
        }
        accumulator["steps"].as_array_mut().unwrap().push(json!({"stepID":step.step_id,"stepKind":step.kind,"outcomeAtUTC":now,"carriedFromUTC":read_at}));
        run.record.set_evidence_preflight(accumulator.clone());
        run.record.timeline.push(format!(
            "evidence-preflight {} carried from session readback at {read_at}",
            step.step_id
        ));
        if preflight_complete(&accumulator) {
            let mut observation = accumulator;
            let fields = observation
                .as_object_mut()
                .ok_or_else(|| Stop::Refused(uncertain()))?;
            let steps = fields.remove("steps").unwrap_or_default();
            fields.insert("preflightSteps".into(), steps);
            fields.insert(
                "confirmationMethod".into(),
                json!("machineReadbackSessionCarried"),
            );
            run.record.set_evidence_observation(observation);
            run.record
                .timeline
                .push("evidence-preflight complete".into());
        }
        Ok(true)
    }

    /// Swift `captureEvidencePreflightFragmentIfEligible`: a fragment is
    /// consumed only after its successful outcome is durable, in order, for
    /// one target and tool; the complete prefix becomes the Job's evidence
    /// observation.
    #[allow(clippy::too_many_arguments)]
    fn capture_evidence(
        &self,
        run: &mut Run,
        step: &CatalogStep,
        summary: &BTreeMap<String, String>,
        facts: Option<&DeviceFacts>,
        target_id: &str,
        revision: Option<i64>,
        outcome_at: &str,
    ) -> Result<(), Stop> {
        let incomplete = |detail: &str| Stop::Failed(format!("evidenceIncomplete: {detail}"));
        let Some(facts) = facts else {
            return Err(incomplete(
                "target/binding/routing/tool facts are absent or mismatched",
            ));
        };
        device_facts::validate(facts, target_id, revision)
            .map_err(|reason| Stop::Failed(reason.into()))?;
        let mut accumulator = run.record.evidence_preflight().cloned().unwrap_or_else(|| {
            json!({
                "targetID": target_id, "bindingRevision": facts.binding_revision,
                "stableIdentitySHA256": facts.identity, "providerID": "hdc",
                "toolVersion": facts.tool_version, "toolSHA256": facts.tool_sha256,
                "steps": [],
            })
        });
        if accumulator["targetID"] != target_id
            || accumulator["bindingRevision"] != facts.binding_revision
            || accumulator["stableIdentitySHA256"] != facts.identity.as_str()
            || accumulator["providerID"] != "hdc"
            || accumulator["toolVersion"] != facts.tool_version.as_str()
            || accumulator["toolSHA256"] != facts.tool_sha256.as_str()
        {
            return Err(incomplete(
                "preflight fragments do not share one target/tool correlation",
            ));
        }
        let received = accumulator["steps"].as_array().map_or(0, Vec::len);
        if EVIDENCE_STEPS.get(received) != Some(&step.step_id.as_str()) {
            return Err(incomplete(
                "preflight outcome is duplicated or out of order",
            ));
        }
        let value = || summary.get("value").filter(|value| !value.is_empty());
        match step.step_id.as_str() {
            "confirm-evidence-target" => {
                let transport = summary
                    .get("transport")
                    .filter(|transport| ["usb", "tcp", "uart"].contains(&transport.as_str()));
                let (Some(transport), true) = (
                    transport,
                    summary.get("deviceIdentitySHA256") == Some(&facts.identity),
                ) else {
                    return Err(incomplete(
                        "target confirmation summary is incomplete or mismatched",
                    ));
                };
                accumulator["transport"] = json!(transport);
            }
            "read-evidence-model" => {
                let model = value().ok_or_else(|| incomplete("model readback is empty"))?;
                accumulator["model"] = json!(model);
            }
            "read-evidence-firmware" => {
                let firmware = value().ok_or_else(|| incomplete("firmware readback is empty"))?;
                accumulator["firmware"] = json!(firmware);
                // Fresh only once the complete required prefix is durable.
                accumulator["confirmedAtUTC"] = json!(outcome_at);
            }
            _ => {
                return Err(incomplete(
                    "preflight action does not match its catalog step",
                ));
            }
        }
        if let Some(steps) = accumulator["steps"].as_array_mut() {
            steps.push(json!({"stepID": step.step_id, "stepKind": step.kind,
                "outcomeAtUTC": outcome_at}));
        }
        run.record.set_evidence_preflight(accumulator.clone());
        run.record
            .timeline
            .push(format!("evidence-preflight {}", step.step_id));
        if preflight_complete(&accumulator) {
            let mut observation = accumulator.clone();
            if let Some(fields) = observation.as_object_mut() {
                let steps = fields.remove("steps").unwrap_or_default();
                fields.insert("preflightSteps".into(), steps);
                let carried = fields["preflightSteps"].as_array().is_some_and(|steps| {
                    steps
                        .iter()
                        .any(|step| step.get("carriedFromUTC").is_some())
                });
                fields.insert(
                    "confirmationMethod".into(),
                    json!(if carried {
                        "machineReadbackSessionCarried"
                    } else {
                        "machineReadback"
                    }),
                );
            }
            run.record.set_evidence_observation(observation);
            // observe.device publishes its evidence-bearing products from the
            // final preflight outcome itself; the other operations set this at
            // their first post-preflight device step.
            if run.record.operation() == OBSERVE {
                run.record.set_first_evidence(outcome_at);
            }
        }
        run.persist(self.jobs).map_err(|_| {
            incomplete("could not persist preflight fragment: the Job record is unwritable")
        })?;
        if preflight_fresh(&accumulator)
            && let (Some(owner), Some(descriptor), Some(inputs)) = (
                self.mutation,
                descriptor(run.record.operation()),
                run.record.request["inputs"].as_object(),
            )
            && crate::capability_policy::session_scoped(descriptor, inputs)
        {
            let key = format!("{}\n{}", facts.identity, facts.binding_revision);
            owner
                .authority
                .holds
                .remember_session_evidence(key, accumulator);
        }
        Ok(())
    }

    /// Swift `compensatePortForward`: a confirmed failure that follows a
    /// completed port-rule change restores the exact typed rule. The inverse
    /// change and a second readback run under the inverse operation, which
    /// journals them and judges the readback, against Target facts that must
    /// still name the materialized binding. They consume nothing: the use the
    /// Job consumed before its change covers them. The dispatcher must still
    /// prove the executable it retained, as for every mutation this Runtime
    /// dispatches. A compensation that fails is the Job's failure.
    #[allow(clippy::too_many_arguments)]
    fn compensate_port_rule(
        &self,
        run: &mut Run,
        hdc: &HdcComposition<'_>,
        original: &CatalogOperation,
        failed: &StepAction,
        completed: &BTreeSet<String>,
        target_id: &str,
        revision: Option<i64>,
    ) -> Result<(), Stop> {
        let (changed, inverse) = match original.reference().as_str() {
            "port-forward.create@1" => ("create-port-rule", "port-forward.remove@1"),
            "port-forward.remove@1" => ("remove-port-rule", "port-forward.create@1"),
            _ => return Ok(()),
        };
        // The rule the failed step names, or else the request's own.
        let inputs = run.record.request["inputs"]
            .as_object()
            .cloned()
            .unwrap_or_default();
        let rule = match failed {
            StepAction::Port(action) => Some(action.rule().clone()),
            _ => PortRule::from_inputs(&inputs).ok(),
        };
        let Some(rule) = rule.filter(|_| completed.contains(changed)) else {
            return Ok(());
        };
        let Some(compensating) = descriptor(inverse) else {
            return Err(Stop::Refused(uncertain()));
        };
        let facts = hdc
            .facts(target_id)
            .map_err(|_| Stop::Refused(uncertain()))?;
        materialized_facts(&run.record, Some(&facts), target_id, revision)?;
        let (kind, change) = if inverse == "port-forward.remove@1" {
            ("removePortForward", PortAction::Remove(rule.clone()))
        } else {
            ("createPortForward", PortAction::Create(rule.clone()))
        };
        let step = |step_id: &str, kind: &str, effect: &str, cancellation: &str| CatalogStep {
            step_id: step_id.into(),
            kind: kind.into(),
            effect: effect.into(),
            cancellation: cancellation.into(),
            binding: "confirmedDevice".into(),
            optional: false,
            action: None,
        };
        let steps = [
            (
                step(
                    "compensate-port-rule",
                    kind,
                    "deviceMutation",
                    "atSafeBoundary",
                ),
                StepAction::Port(change),
            ),
            (
                step(
                    "verify-port-rule-compensation",
                    "verifyRemoteState",
                    "readOnly",
                    "immediate",
                ),
                StepAction::Port(PortAction::ReadPresence(rule)),
            ),
        ];
        let restored = steps.iter().try_for_each(|(step, action)| {
            let plan = action
                .plan(
                    &step.step_id,
                    Some(&facts.connect_key),
                    &device_steps::NO_CONTEXT,
                )
                .map_err(|_| Stop::Refused(uncertain()))?;
            if mutates(step) && !hdc.dispatch.mutation_identity_current() {
                return Err(Stop::Failed(
                    "authorizationRequired: fresh tool identity cannot be proved".into(),
                ));
            }
            self.dispatch_step(
                run,
                hdc,
                compensating,
                step,
                action,
                &plan,
                Some(&facts),
                target_id,
                revision,
                &[],
                Journaled::Step,
            )
        });
        // Swift names a failed compensation as it interpolates its
        // `RuntimeDispatchFailure`.
        match restored {
            Ok(()) => {
                run.record
                    .timeline
                    .push(format!("compensated port rule to {inverse}"));
                Ok(())
            }
            Err(stop) => {
                if let Some(failure) = dispatch_failure(&stop) {
                    run.record
                        .timeline
                        .push(format!("port-rule compensation failed closed: {failure}"));
                }
                Err(stop)
            }
        }
    }

    /// Swift `publishDeclaredArtifacts`: the products this step declares,
    /// published after its correlated outcome, a capture's within its job
    /// byte budget; a product that cannot be is recorded missing with its
    /// reason and fails the Job.
    fn publish(
        &self,
        run: &mut Run,
        descriptor: &CatalogOperation,
        step: &CatalogStep,
        summary: &BTreeMap<String, String>,
        window: Option<(String, String)>,
        receipt: &FileReceipt,
    ) -> Result<(), Stop> {
        let owner = Owner::of(&run.record, descriptor);
        let mapping = device_steps::products(&owner.reference, &step.step_id);
        if mapping.is_empty() {
            return Ok(());
        }
        let inputs = run.record.request["inputs"]
            .as_object()
            .cloned()
            .unwrap_or_default();
        let publisher = self.publisher();
        for name in device_steps::publishable(mapping, &inputs) {
            let Some(declaration) = declaration(descriptor, name) else {
                continue;
            };
            let product = owner.product(&step.step_id, declaration, window.clone());
            // A received product is the received bytes or nothing.
            if device_steps::FILE_BACKED.contains(&name) {
                self.publish_received(run, &product, declaration, receipt)?;
                continue;
            }
            let contents = contents(name, &run.record, summary, receipt);
            if owner.reference == CAPTURE {
                let budget = byte_budget(&run.record);
                let used = publisher.published_bytes(&owner.job_id).map_err(|error| {
                    Stop::Publication(format!(
                        "cannot inspect job byte budget before {name}: {error}"
                    ))
                })?;
                if used > budget || contents.len() as u64 > budget - used {
                    let detail =
                        format!("job byte budget {budget} exceeded while publishing {name}");
                    let _ = publisher.record_missing(&product, &detail);
                    return Err(Stop::Publication(detail));
                }
            }
            match publisher.publish(&product, &contents) {
                Ok(metadata) => run.record.timeline.push(format!(
                    "artifact {name} -> {}",
                    metadata["artifactID"].as_str().unwrap_or_default()
                )),
                Err(error) => {
                    let _ = publisher.record_missing(&product, &error);
                    run.record
                        .timeline
                        .push(format!("artifact {name} missing: {error}"));
                    return Err(Stop::Publication(format!(
                        "{name} could not be published: {error}"
                    )));
                }
            }
        }
        Ok(())
    }

    /// Swift `publishFinalizeArtifacts`: every declared product no step
    /// recorded is recorded missing, then the run's own products are composed
    /// from the record and the index as they stand and published under
    /// `finalize-session`, each within the job byte budget.
    fn finalize(&self, run: &mut Run, descriptor: &CatalogOperation) -> Result<(), String> {
        let owner = Owner::of(&run.record, descriptor);
        let names = device_steps::finalize_products(&owner.reference);
        if names.is_empty() {
            return Ok(());
        }
        let publisher = self.publisher();
        let named = |recorded: &[Value], name: &str| recorded.iter().any(|row| row["name"] == name);
        let recorded = publisher.list(&owner.job_id).map_err(|error| {
            format!("cannot inspect Artifact index during finalization: {error}")
        })?;
        for declaration in descriptor.artifacts.iter().filter(|declaration| {
            !names.contains(&declaration.name.as_str()) && !named(&recorded, &declaration.name)
        }) {
            publisher
                .record_missing(
                    &owner.product("finalize-session", declaration, None),
                    "no step produced this declared artifact",
                )
                .map_err(|error| {
                    format!(
                        "cannot record missing product {}: {error}",
                        declaration.name
                    )
                })?;
        }
        let recorded = publisher.list(&owner.job_id).map_err(|error| {
            format!("cannot reopen Artifact index during finalization: {error}")
        })?;
        let mut missing_required: Vec<&str> = descriptor
            .artifacts
            .iter()
            .filter(|declaration| {
                declaration.required
                    && !names.contains(&declaration.name.as_str())
                    && !recorded.iter().any(|row| {
                        row["name"] == declaration.name.as_str()
                            && row["status"].get("published").is_some()
                    })
            })
            .map(|declaration| declaration.name.as_str())
            .collect();
        for name in names {
            let Some(declaration) = declaration(descriptor, name) else {
                continue;
            };
            let contents =
                capture_documents::contents(name, descriptor, &run.record, &recorded, names)
                    .map_err(|error| format!("cannot encode final Artifact {name}: {error}"))?;
            if owner.reference == CAPTURE {
                let budget = byte_budget(&run.record);
                let used = publisher.published_bytes(&owner.job_id).map_err(|error| {
                    format!("cannot inspect final Artifact budget before {name}: {error}")
                })?;
                if used > budget || contents.len() as u64 > budget - used {
                    return Err(format!(
                        "job byte budget {budget} exceeded while finalizing {name}"
                    ));
                }
            }
            publisher
                .publish(
                    &owner.product("finalize-session", declaration, None),
                    &contents,
                )
                .map_err(|error| format!("cannot publish final Artifact {name}: {error}"))?;
        }
        if !missing_required.is_empty() {
            missing_required.sort_unstable();
            let names: Vec<String> = missing_required
                .iter()
                .map(|name| format!("\"{name}\""))
                .collect();
            run.record.timeline.push(format!(
                "incomplete: missing required [{}]",
                names.join(", ")
            ));
        }
        Ok(())
    }
}

/// A resolved input as its provider is given it: its identity, its digest
/// and where its bytes are.
fn resolved_input(leased: LeasedArtifact) -> Result<ResolvedArtifact, Stop> {
    let sha256 = leased.row["sha256"]
        .as_str()
        .ok_or_else(|| Stop::Refused(uncertain()))?
        .to_owned();
    Ok(ResolvedArtifact {
        artifact_id: leased.artifact_id,
        sha256,
        path: leased.path,
    })
}

/// Swift `validateArtifactBinding` for a device-bound input: the lease's
/// Artifact must name the request's target and binding revision and the
/// identity the plan was materialized against (or, with no materialized
/// identity, claim no device binding at all). The refusal is Swift's message.
fn unbound(leased: &LeasedArtifact, record: &JobRecord) -> Option<&'static str> {
    const MISMATCH: &str =
        "Artifact lease target/binding/identity does not match the materialized request";
    let binding = &leased.row["bindingSnapshot"];
    let target = &record.request["target"];
    let revision = target
        .get("expectedBindingRevision")
        .filter(|revision| !revision.is_null());
    if binding["targetID"] != target["targetId"]
        || binding.get("bindingRevision").filter(|v| !v.is_null()) != revision
    {
        return Some(MISMATCH);
    }
    let identity = binding.get("stableIdentitySHA256").and_then(Value::as_str);
    match record.materialized_identity() {
        Some(expected) if identity != Some(expected) => Some(MISMATCH),
        Some(_) => None,
        None if revision.is_some() || identity.is_some() => {
            Some("host-only Artifact lease must not claim a device binding or identity")
        }
        None => None,
    }
}

/// Swift `RuntimeArtifactService.bindingSnapshot(for:)`: the request's target
/// and revision, and the observed identity (the materialized one before the
/// observation exists), absent members omitted.
fn binding_snapshot(record: &JobRecord) -> Value {
    let target = &record.request["target"];
    let mut binding = json!({"targetID": target["targetId"]});
    if let Some(revision) = target["expectedBindingRevision"].as_i64() {
        binding["bindingRevision"] = json!(revision);
    }
    let observed = record
        .evidence_observation()
        .and_then(|observation| observation["stableIdentitySHA256"].as_str());
    if let Some(identity) = observed.or(record.materialized_identity()) {
        binding["stableIdentitySHA256"] = json!(identity);
    }
    binding
}

/// Swift `RuntimeArtifactService.artifactContents` for a step's product: a
/// capture's bytes as the provider received them from its one process, or a
/// facts product.
fn contents(
    name: &str,
    record: &JobRecord,
    summary: &BTreeMap<String, String>,
    receipt: &FileReceipt,
) -> Vec<u8> {
    match name {
        "hilog.txt" | "ui-dump.json" | "advanced-dump.txt" | "crash-index.txt"
        | "crash-log.txt" | "debug-hilog.txt" => receipt
            .subprocesses
            .first()
            .map(|process| process.stdout.clone())
            .unwrap_or_default(),
        _ => facts(name, record, summary),
    }
}

/// A facts product: the product, the operation and the Job, the
/// observation's device facts where there is one, the step's verified facts,
/// and for the binding snapshot the requested target and revision, in Swift's
/// canonical pretty spelling.
fn facts(name: &str, record: &JobRecord, summary: &BTreeMap<String, String>) -> Vec<u8> {
    let mut fields = Map::from_iter([
        ("artifact".to_owned(), json!(name)),
        ("operation".to_owned(), json!(record.operation())),
        ("jobId".to_owned(), json!(record.job_id)),
        ("catalogDigest".to_owned(), json!(record.catalog_digest())),
    ]);
    if let Some(observation) = record.evidence_observation() {
        for (key, field) in [
            ("model", "model"),
            ("firmware", "firmware"),
            ("transport", "transport"),
            ("stableIdentitySha256", "stableIdentitySHA256"),
        ] {
            if let Some(value) = observation[field].as_str() {
                fields.insert(key.into(), json!(value));
            }
        }
    }
    for (key, value) in summary {
        fields.insert(key.clone(), json!(value));
    }
    if name == "binding-snapshot.json" {
        let target = &record.request["target"];
        fields.insert("targetId".into(), target["targetId"].clone());
        if let Some(revision) = target["expectedBindingRevision"].as_i64() {
            fields.insert("expectedBindingRevision".into(), json!(revision));
        }
    }
    session_json::encode_canonical_pretty(&Value::Object(fields)).unwrap_or_else(|_| b"{}".to_vec())
}

#[cfg(test)]
mod session_cache_tests {
    use super::*;

    #[test]
    fn a_carried_fragment_does_not_renew_cache_after_expiry_or_clock_rollback() {
        let mut accumulator = json!({"transport":"usb", "confirmedAtUTC":"2026-09-19T01:00:00Z", "model":"model", "firmware":"firmware", "steps": EVIDENCE_STEPS.map(|id| json!({"stepID":id}))});
        assert!(preflight_fresh(&accumulator));
        // Model was carried just before expiry; firmware was read freshly
        // after expiry (or after the clock rolled back). The complete mixed
        // accumulator must never replace the original cache timestamp.
        accumulator["steps"][1]["carriedFromUTC"] = json!("2026-09-19T00:00:00Z");
        for time in ["2026-09-19T01:00:00Z", "2026-09-18T23:59:59Z"] {
            accumulator["confirmedAtUTC"] = json!(time);
            assert!(preflight_complete(&accumulator));
            assert!(!preflight_fresh(&accumulator));
        }
    }
}
