//! Rust `job.run` of an admitted ArkForge Flash Job — the canonical
//! `flash.full-restore@1` and its compatibility alias `flash.dayu200` — as
//! Swift `runOwned` runs it with an ArkForge lane composed:
//!
//! - the running transition, then the lane's archive prewarm, started only
//!   once the Job is durably admitted and running;
//! - every step in the Target's mutation lane, in catalog order: the archive
//!   verified on the host, the destructive intent bound to the Job's
//!   Runtime-owned capability, the Loader transition and the way back out
//!   left to the lane's own plan;
//! - at `flash-partitions`, the prewarm awaited, the capability consumed
//!   against a freshly materialized plan and fresh facts, the daemon job
//!   prepared and its correlation made durable before the write-ahead intent,
//!   then the one delegated drive and its terminal receipt validated and made
//!   durable before the step's outcome;
//! - the completed plan projected onto the readback, reboot, reconnect and
//!   postflight steps, each as its own intent and outcome, the postflight's
//!   facts published first;
//! - the optional post-flash HiLog captured through the Rockchip host under
//!   its own write-ahead intent;
//! - the finalization product, the terminal state and the capability use's
//!   outcome.
//!
//! A Flash a reconcile confirmed at its safe boundary resumes there, under
//! the use its first run consumed: the steps its journal confirms are
//! skipped, and the rest are projected from the durable completed-plan
//! receipt; the lane is never asked to drive the plan again.
//!
//! What stopped a run is classified as Swift classifies it: an unknown
//! outcome parks the Job with its intent outstanding and is never replayed;
//! a confirmed non-execution fails it with its use safe to reflash; a
//! confirmed failure fails it; anything else is answered as a refusal and
//! leaves the Job where it stood. The record is persisted exactly where
//! Swift persists it, so its index row counts the same writes.
use super::*;
use crate::artifact_publication::{ArtifactPublisher, Product};
use crate::capability_store::{CapabilityQuery, Effect, UseOutcome};
use crate::flash_facts::RockchipFacts;
use crate::job_owner::arkforge_job_state::ArkForgeJobState;
use crate::job_plan::{
    FlashPlanner, FlashPlanning, JobPlanner, RockchipFactsPort, admission_blocker,
    canonical_inputs, delegated_arguments, is_flash, plan_completion_arguments,
};
use crate::operation_catalog::{CatalogOperation, CatalogStep};
use crate::operation_request::OperationRequest;
use arkdeck_contract::sha256_hex;
use arkdeck_provider_arkforge::{
    ActionReceipt, DeviceBinding, Execution, FlashLane, HostAction, LaneArtifact, LaneFailure,
    PrewarmReceipt, RockchipHost, validate_completion,
};
use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;
use std::time::Instant;

/// Swift `RuntimeJobEngine.arkForgeDispatchedSteps`.
const DISPATCHED: [&str; 2] = ["flash-partitions", "verify-flash-readback"];
/// Swift `RuntimeJobEngine.arkForgeOwnedModeSteps`: the transition into
/// Loader and the way back out, which the lane's own plan performs.
const OWNED_MODE: [&str; 7] = [
    "enter-loader-mode",
    "wait-loader-disconnect",
    "wait-loader-reconnect",
    "rebind-loader-identity",
    "reboot-device",
    "wait-for-hdc",
    "rebind-and-verify-build",
];
/// Swift `RuntimeJobEngine.arkForgePlanCompletionSteps`.
const PLAN_COMPLETION: [&str; 4] = [
    "verify-flash-readback",
    "reboot-device",
    "wait-for-hdc",
    "rebind-and-verify-build",
];
/// Swift `arkForgePlanCompletionSemanticCode`.
const PLAN_COMPLETION_CODE: &str = "arkForgePlanCompletion";
/// Swift `confirmedNotExecutedSemanticCode`.
const NOT_EXECUTED_CODE: &str = "confirmedNotExecuted";
/// Swift `ArkForgeNativeRockUSBToolchain.reportedVersion`.
const TOOL_VERSION: &str = "arkforged native RockUSB";
/// The one product a Flash publishes at finalization.
const REPORT: &str = "flash-report.json";

/// What an admitted Flash runs through, as the daemon composes it.
#[derive(Clone, Copy)]
pub struct FlashExecution<'a> {
    /// What a fresh plan reads beyond the Artifact and Import owners.
    pub planning: &'a FlashPlanning,
    /// Swift's ArkForge facts port.
    pub facts: RockchipFactsPort<'a>,
    pub lane: &'a dyn FlashLane,
    /// The exact `id@version` of the DeviceProfile the lane's `arkforged`
    /// loaded (Swift `arkForgeDeviceProfileID`).
    pub profile_id: &'a str,
    /// The Rockchip per-action host the optional HiLog capture runs through.
    pub host: &'a dyn RockchipHost,
    /// The Target owner whose per-Target mutation lane the steps run in.
    pub targets: &'a crate::TargetStore,
}

/// `job.run` over the Flash composition: an admitted Flash Job runs here,
/// every other Job by the runner as before.
pub struct FlashRunner<'a> {
    pub runner: JobRunner<'a>,
    pub flash: Option<FlashExecution<'a>>,
}

/// What stopped a Flash run: Swift's `RuntimeDispatchFailure` cases, its
/// Artifact publication failure, or a refusal answered as it is.
enum Stop {
    Refused(RunRefusal),
    Failed(String),
    NotExecuted(String),
    Unknown(String),
    Publication(String),
}

impl From<RunRefusal> for Stop {
    fn from(refusal: RunRefusal) -> Self {
        Self::Refused(refusal)
    }
}

type Stepped<T> = Result<T, Stop>;

/// Swift's `"\(error)"` of a lane or host failure, as a skipped step's reason
/// quotes it.
fn described(failure: &LaneFailure) -> String {
    let quoted = crate::strict_json::swift_quoted;
    match failure {
        LaneFailure::Failed(reason) => format!("failed({})", quoted(reason)),
        LaneFailure::ConfirmedNotExecuted(reason) => {
            format!("confirmedNotExecuted({})", quoted(reason))
        }
        LaneFailure::OutcomeUnknown(reason) => format!("outcomeUnknown({})", quoted(reason)),
        LaneFailure::Other(description) => description.clone(),
    }
}

/// Swift `ProviderResolvedInputArtifact`: the flash bundle as this step
/// resolved it.
struct Resolved {
    artifact_id: String,
    sha256: String,
    byte_count: u64,
    path: PathBuf,
    lease: String,
    leased: LeasedArtifact,
}

impl Resolved {
    /// The Artifact facts a capability is bound to.
    fn facts(&self) -> BTreeMap<String, String> {
        BTreeMap::from([
            ("artifactId".to_owned(), self.artifact_id.clone()),
            ("artifactSha256".to_owned(), self.sha256.clone()),
            ("artifactByteCount".to_owned(), self.byte_count.to_string()),
        ])
    }
}

/// One run's Flash state beside the record: the lane's durable join and
/// receipt, the steps confirmed, and the prewarm until it is awaited.
struct Flash<'s> {
    state: ArkForgeJobState,
    completed: BTreeSet<String>,
    prewarm: Option<std::thread::ScopedJoinHandle<'s, Result<PrewarmReceipt, LaneFailure>>>,
    prewarm_confirmed: bool,
}

/// How a host-managed step ended short of success.
enum HostStop {
    /// The provider has no action for it.
    NoAction,
    /// A confirmed dispatch failure, as Swift describes it.
    Dispatch(String),
    Other(Stop),
}

/// The catalog descriptor a Job record names, versioned or not.
fn descriptor_of(reference: &str) -> Option<&'static CatalogOperation> {
    match reference.rsplit_once('@') {
        Some((id, version)) => CatalogOperation::lookup(id, version.parse().ok()),
        None => CatalogOperation::lookup(reference, None),
    }
}

impl FlashRunner<'_> {
    pub fn handle(&self, params: &Map<String, Value>) -> Result<Value, RunRefusal> {
        let (Some(flash), Some(id)) = (
            self.flash,
            params
                .get("jobId")
                .and_then(Value::as_str)
                .filter(|id| params.len() == 1 && valid_identifier(id)),
        ) else {
            return self.runner.handle(params);
        };
        let jobs = self.runner.jobs;
        let Ok(record) = jobs.read_snapshot(id) else {
            return self.runner.handle(params);
        };
        if !is_flash(record.operation()) {
            return self.runner.handle(params);
        }
        let state = record.state.clone();
        if terminal(&state) {
            return Err(proven(
                "resourceConflict",
                format!("job {id} is {state}, not runnable"),
                Some(id),
            ));
        }
        if !RUNNABLE.contains(&state.as_str()) {
            return Err(proven(
                "resourceConflict",
                format!("job {id} is {state}, not runnable"),
                None,
            ));
        }
        // A Flash resumes only from the confirmed safe boundary a reconcile
        // reached; a lost execution is parked, never left `running`, and a
        // complete-overwrite recovery is not admitted here.
        let resumed = state == "resumeAtConfirmedSafeBoundary";
        if state != "preflight" && !resumed {
            return Err(proven(
                "resourceConflict",
                format!(
                    "job {id} is {state}; the Rust Runtime resumes no {} Job from it",
                    record.operation()
                ),
                None,
            ));
        }
        if record.catalog_digest() != CATALOG_DIGEST {
            return Err(proven(
                "resourceConflict",
                format!("job {id} was materialized against a different catalog digest"),
                None,
            ));
        }
        let Some(descriptor) = descriptor_of(record.operation()) else {
            return Err(uncertain());
        };
        let directory = jobs.job_directory(id).map_err(|_| uncertain())?;
        let journal = JournalWriter::open(&directory, false).map_err(|_| uncertain())?;
        let facts = journal.facts();
        let decided =
            !resumed || facts.last_reconcile_outcome_certainty.as_deref() == Some("confirmed");
        if facts.has_torn_tail
            || facts.current_state.as_deref() != Some(state.as_str())
            || facts.finalized
            || !facts.outstanding_intents.is_empty()
            || !facts.unknown_outcomes.is_empty()
            || !decided
            || record.outcome_unknown()
        {
            return Err(proven(
                "resourceConflict",
                format!(
                    "job {id}'s journal does not stand at its {state} boundary; nothing was \
                     dispatched"
                ),
                None,
            ));
        }
        let arkforge = jobs.arkforge_state(id).map_err(|_| uncertain())?;
        let mut run = Run {
            record,
            journal,
            sequence: facts.last_durable_sequence.map_or(0, |last| last + 1),
            now: self.runner.now,
            consumed: None,
        };
        // A resumed Flash continues under the use its first run consumed,
        // never a new one.
        if resumed {
            self.runner
                .take_over_held_use(&mut run)
                .map_err(|message| proven("rejected", message, Some(id)))?;
        }
        self.run(&mut run, &flash, descriptor, arkforge)?;
        run.release(jobs, self.runner.sessions, &directory)?;
        Ok(run.record.status())
    }

    /// Swift `runOwned` from the admitted boundary, or from the confirmed
    /// safe boundary a reconcile reached: the running transition, the
    /// admitted steps, and the terminal state their end decides.
    fn run(
        &self,
        run: &mut Run,
        flash: &FlashExecution<'_>,
        descriptor: &CatalogOperation,
        state: ArkForgeJobState,
    ) -> Result<(), RunRefusal> {
        let started = run.clock()?;
        run.record.start(&started);
        // Swift `completedStepIDs`: none from the admitted boundary; from a
        // confirmed safe boundary, every step the journal confirms succeeded
        // — the delegated write a reconcile proved among them — which the
        // run never performs again.
        let confirmed = if run.record.state == "resumeAtConfirmedSafeBoundary" {
            let confirmed = self.confirmed_steps(run)?;
            run.transition(
                "resumeAtConfirmedSafeBoundary",
                "running",
                "resume confirmed durable provider boundary",
            )?;
            confirmed
        } else {
            run.transition("preflight", "running", "steps-start")?;
            BTreeSet::new()
        };
        let mut completed = BTreeSet::new();
        let outcome = std::thread::scope(|scope| {
            let mut job = Flash {
                state,
                completed: confirmed,
                prewarm: None,
                prewarm_confirmed: false,
            };
            let outcome = self.admitted_steps(run, flash, descriptor, &mut job, scope);
            // The prewarm is joined on every exit, so no archive upload
            // outlives the run; only then is the lane's bookkeeping released.
            if let Some(prewarm) = job.prewarm.take() {
                let _ = prewarm.join();
            }
            flash.lane.finish_prewarm(&run.record.job_id);
            completed = job.completed;
            outcome
        });
        match outcome {
            Ok(()) => self.finalize(run, descriptor, &completed),
            Err(Stop::Refused(refusal)) => Err(refusal),
            Err(Stop::Unknown(reason)) => {
                run.record.set_operation_failure(Some(failure(
                    "outcomeUnknown",
                    "unknownOutcome",
                    "runtimeDecisionRequired",
                    "awaitRuntimeReconciliation",
                )));
                let from = run.record.state.clone();
                run.transition(
                    &from,
                    "waitingForRecovery",
                    &format!("outcomeUnknown: {reason}"),
                )?;
                run.record.set_outcome_unknown();
                run.finish()?;
                run.persist(self.runner.jobs)?;
                self.runner.settle_mutation(run, UseOutcome::OutcomeUnknown)
            }
            Err(Stop::NotExecuted(reason)) => {
                run.record.set_operation_failure(Some(failure(
                    "executionConfirmedNotPerformed",
                    "externalTool",
                    "runtimeDecisionRequired",
                    "submitNewTypedRequestAfterRuntimeProof",
                )));
                self.close(run, &reason)?;
                self.runner.settle_mutation(run, UseOutcome::SafeToReflash)
            }
            Err(Stop::Failed(reason)) => {
                run.record.set_operation_failure(Some(failure(
                    "executionFailed",
                    "execution",
                    "runtimeDecisionRequired",
                    "inspectJob",
                )));
                self.close(run, &reason)?;
                self.runner.settle_mutation(run, UseOutcome::Confirmed)
            }
            Err(Stop::Publication(detail)) => {
                run.record.set_operation_failure(Some(failure(
                    "artifactPublicationFailed",
                    "storage",
                    "notAutomatic",
                    "inspectJob",
                )));
                self.close(run, &format!("artifact publication failed: {detail}"))?;
                self.runner.settle_mutation(run, UseOutcome::Confirmed)
            }
        }
    }

    /// Swift `confirmedSucceededStepIDs`: every step whose confirmed outcome
    /// in the Job's durable journal is a success.
    fn confirmed_steps(&self, run: &Run) -> Result<BTreeSet<String>, RunRefusal> {
        let bytes = self
            .runner
            .jobs
            .journal_bytes(&run.record.job_id)
            .map_err(|_| uncertain())?;
        let durable = bytes
            .iter()
            .rposition(|byte| *byte == b'\n')
            .map_or(0, |last| last + 1);
        let mut steps = BTreeSet::new();
        for line in bytes[..durable]
            .split(|byte| *byte == b'\n')
            .filter(|line| !line.is_empty())
        {
            let event: Value = serde_json::from_slice(line).map_err(|_| uncertain())?;
            if event["kind"] == "stepOutcome"
                && event["payload"]["outcomeCertainty"] == "confirmed"
                && event["payload"]["result"] == "succeeded"
                && let Some(step) = event["stepId"].as_str()
            {
                steps.insert(step.to_owned());
            }
        }
        Ok(steps)
    }

    /// The failure already recorded, persisted, then closed through
    /// `finalizing` to `failed` from the state the run reached.
    fn close(&self, run: &mut Run, reason: &str) -> Result<(), RunRefusal> {
        run.persist(self.runner.jobs)?;
        let from = run.record.state.clone();
        run.transition(&from, "finalizing", reason)?;
        run.transition("finalizing", "failed", reason)?;
        run.finish()?;
        run.persist(self.runner.jobs)
    }

    /// Swift `runOwned` once every step is confirmed: `finalizing`, the
    /// finalization product, `succeeded`, and the use's outcome.
    fn finalize(
        &self,
        run: &mut Run,
        descriptor: &CatalogOperation,
        completed: &BTreeSet<String>,
    ) -> Result<(), RunRefusal> {
        let from = run.record.state.clone();
        run.transition(&from, "finalizing", "steps-complete")?;
        if let Err(detail) = self.publish_final(run, descriptor, completed) {
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
            run.persist(self.runner.jobs)?;
            return self.runner.settle_mutation(run, UseOutcome::Confirmed);
        }
        run.record.set_operation_failure(None);
        run.transition("finalizing", "succeeded", "finalized")?;
        run.finish()?;
        run.persist(self.runner.jobs)?;
        self.runner.settle_mutation(run, UseOutcome::Confirmed)
    }

    fn publisher(&self) -> ArtifactPublisher<'_> {
        ArtifactPublisher {
            store: self.runner.artifacts,
            quota: self.runner.quota,
            home: self.runner.home,
            now: self.runner.now,
        }
    }

    /// Publishes `contents` as the declared product `name` of `step`, or
    /// records it missing with `reason`.
    fn product(
        &self,
        run: &Run,
        descriptor: &CatalogOperation,
        step: &str,
        name: &str,
        outcome: Result<&[u8], &str>,
        window: Option<(String, String)>,
    ) -> Result<Value, String> {
        let Some(declaration) = descriptor.artifacts.iter().find(|a| a.name == name) else {
            return Err(format!("{name} has no declaration"));
        };
        let session = format!("session-{}", run.record.job_id);
        let reference = descriptor.reference();
        let product = Product {
            job_id: &run.record.job_id,
            session_id: &session,
            step_id: step,
            name,
            media_type: &declaration.media_type,
            privacy: &declaration.privacy,
            retention_class: &declaration.retention_class,
            source_operation: &reference,
            provider_id: &descriptor.provider,
            binding: binding_snapshot(&run.record),
            observation_window: window,
        };
        match outcome {
            Ok(contents) => self.publisher().publish(&product, contents),
            Err(reason) => self.publisher().record_missing(&product, reason),
        }
    }

    /// Swift `publishDeclaredArtifacts` for the one product a Flash step
    /// made: published and named in the timeline with its identity, or
    /// recorded missing with why, named missing, and the publication failed.
    fn publish_step_product(
        &self,
        run: &mut Run,
        descriptor: &CatalogOperation,
        step: &str,
        name: &str,
        contents: &[u8],
        window: Option<(String, String)>,
    ) -> Result<(), String> {
        match self.product(run, descriptor, step, name, Ok(contents), window) {
            Ok(metadata) => {
                run.record.timeline.push(format!(
                    "artifact {name} -> {}",
                    metadata["artifactID"].as_str().unwrap_or_default()
                ));
                Ok(())
            }
            Err(error) => {
                let _ = self.product(run, descriptor, step, name, Err(&error), None);
                run.record
                    .timeline
                    .push(format!("artifact {name} missing: {error}"));
                Err(format!("{name} could not be published: {error}"))
            }
        }
    }

    /// Swift `publishFinalizeArtifacts` for a Flash: every declared product
    /// no step recorded is recorded missing, then the report is published;
    /// a required product that was not published fails the Job.
    fn publish_final(
        &self,
        run: &mut Run,
        descriptor: &CatalogOperation,
        completed: &BTreeSet<String>,
    ) -> Result<(), String> {
        let publisher = self.publisher();
        let mut recorded = publisher.list(&run.record.job_id).map_err(|error| {
            format!("cannot inspect Artifact index during finalization: {error}")
        })?;
        for declaration in &descriptor.artifacts {
            if declaration.name == REPORT
                || recorded
                    .iter()
                    .any(|row| row["name"] == declaration.name.as_str())
            {
                continue;
            }
            self.product(
                run,
                descriptor,
                "finalize-session",
                &declaration.name,
                Err("no step produced this declared artifact"),
                None,
            )
            .map_err(|error| {
                format!(
                    "cannot record missing product {}: {error}",
                    declaration.name
                )
            })?;
        }
        recorded = publisher.list(&run.record.job_id).map_err(|error| {
            format!("cannot reopen Artifact index during finalization: {error}")
        })?;
        let mut missing: Vec<&str> = descriptor
            .artifacts
            .iter()
            .filter(|declaration| {
                declaration.required
                    && declaration.name != REPORT
                    && !recorded.iter().any(|row| {
                        row["name"] == declaration.name.as_str()
                            && row["status"].get("published").is_some()
                    })
            })
            .map(|declaration| declaration.name.as_str())
            .collect();
        let steps: Vec<&str> = completed.iter().map(String::as_str).collect();
        let report =
            crate::capture_documents::flash_report(descriptor, &run.record, &recorded, &steps)
                .map_err(|error| format!("cannot encode final Artifact {REPORT}: {error}"))?;
        self.product(
            run,
            descriptor,
            "finalize-session",
            REPORT,
            Ok(&report),
            None,
        )
        .map_err(|error| format!("cannot publish final Artifact {REPORT}: {error}"))?;
        if !missing.is_empty() {
            missing.sort_unstable();
            run.record.timeline.push(format!(
                "incomplete: missing required {}",
                swift_array(&missing)
            ));
            return Err(format!(
                "required Flash artifacts are missing: {}",
                missing.join(", ")
            ));
        }
        Ok(())
    }

    /// Swift `executeAdmittedSteps` for a Flash: the prewarm started once
    /// the Job runs, then every step in the Target's mutation lane.
    fn admitted_steps<'s, 'e: 's>(
        &'e self,
        run: &mut Run,
        flash: &'e FlashExecution<'e>,
        descriptor: &CatalogOperation,
        job: &mut Flash<'s>,
        scope: &'s std::thread::Scope<'s, 'e>,
    ) -> Stepped<()> {
        let resolved = self.resolved_input(run).map_err(|error| {
            Stop::NotExecuted(format!(
                "input Artifact lease became unreadable before ArkForge prewarm; nothing was \
                 dispatched and the device was not touched: {error}"
            ))
        })?;
        let artifact = LaneArtifact {
            path: resolved.path.clone(),
            sha256: resolved.sha256.clone(),
            profile_id: flash.profile_id.to_owned(),
        };
        run.record
            .timeline
            .push("ArkForge artifact prewarm started after durable admission".into());
        let job_id = run.record.job_id.clone();
        let lane = flash.lane;
        job.prewarm = Some(scope.spawn(move || lane.prewarm(&job_id, &artifact)));
        let target = run.record.request["target"]["targetId"]
            .as_str()
            .unwrap_or_default()
            .to_owned();
        let holder = run.record.job_id.clone();
        let _lane = match flash.targets.enter_mutation_lane(&target, &holder, None) {
            Ok(Some(lane)) => lane,
            Ok(None) | Err(_) => return Err(Stop::Refused(uncertain())),
        };
        for step in &descriptor.steps {
            self.step(run, flash, descriptor, job, step)?;
        }
        Ok(())
    }

    /// Swift `executeSteps` for one catalog step of a Flash.
    fn step(
        &self,
        run: &mut Run,
        flash: &FlashExecution<'_>,
        descriptor: &CatalogOperation,
        job: &mut Flash<'_>,
        step: &CatalogStep,
    ) -> Stepped<()> {
        let id = step.step_id.as_str();
        if job.completed.contains(id) {
            run.record
                .timeline
                .push(format!("resume skipped journal-confirmed step {id}"));
            return Ok(());
        }
        if OWNED_MODE.contains(&id) {
            run.record
                .timeline
                .push(format!("delegated {id} to the ArkForge lane's own plan"));
            if PLAN_COMPLETION.contains(&id) {
                if id == "rebind-and-verify-build" {
                    self.publish_postflight_facts(run, flash, descriptor, job, step)?;
                }
                self.journal_plan_completion(run, flash, job, step)?;
            }
            job.completed.insert(id.to_owned());
            return Ok(());
        }
        match step.kind.as_str() {
            "verifyArtifact" | "hashFile" => {
                self.verify_host_input(run, flash, step)?;
                run.record.timeline.push(format!("host-step {id}"));
                return Ok(());
            }
            "requestConfirmation" => return self.confirm_intent(run),
            "postprocessArtifact" | "finalizeSession" => {
                run.record.timeline.push(format!("host-step {id}"));
                return Ok(());
            }
            _ => {}
        }
        let inputs = run.record.request["inputs"]
            .as_object()
            .cloned()
            .unwrap_or_default();
        if !descriptor.step_is_selected(step, &inputs) {
            return self.record_skipped(
                run,
                descriptor,
                step,
                "step not selected by the request inputs",
            );
        }
        let resolved = self.resolved_input(run).map_err(|error| {
            Stop::Failed(format!(
                "input Artifact lease became unreadable before {id}: {error}"
            ))
        })?;
        let target = run.record.request["target"]["targetId"]
            .as_str()
            .unwrap_or_default()
            .to_owned();
        let facts = if step.binding == "confirmedDevice" {
            match (flash.facts)(&target) {
                Ok(facts) => Some(facts),
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
        if effect_rank(&step.effect) >= effect_rank("deviceMutation")
            && let Some(blocker) = facts.as_ref().and_then(admission_blocker)
        {
            return Err(Stop::Failed(format!(
                "provider execution prerequisite blocked before external effect: {blocker}"
            )));
        }
        // The context's clock is read once the facts are resolved.
        let now = run.clock()?;
        if DISPATCHED.contains(&id) {
            self.confirm_prewarm(run, flash, job, &resolved)?;
            if id != "flash-partitions" && job.state.completion.is_some() {
                self.journal_plan_completion(run, flash, job, step)?;
                job.completed.insert(id.to_owned());
                return Ok(());
            }
            if effect_rank(&step.effect) >= effect_rank("deviceMutation") {
                self.consume(run, flash, descriptor, facts.as_ref(), &resolved)?;
            }
            self.dispatch_through_arkforge(run, flash, job, step, facts.as_ref(), &resolved)?;
            job.completed.insert(id.to_owned());
            return Ok(());
        }
        match self.host_step(
            run,
            flash,
            descriptor,
            step,
            facts.as_ref(),
            &resolved,
            &now,
        ) {
            Ok(()) => {
                job.completed.insert(id.to_owned());
                Ok(())
            }
            Err(HostStop::Other(stop)) => Err(stop),
            Err(HostStop::NoAction) if step.optional => self.record_skipped(
                run,
                descriptor,
                step,
                "provider has no action for this step",
            ),
            Err(HostStop::Dispatch(reason)) if step.optional => {
                self.record_skipped(run, descriptor, step, &reason)
            }
            Err(HostStop::NoAction) => Err(Stop::Refused(uncertain())),
            Err(HostStop::Dispatch(reason)) => Err(Stop::Failed(reason)),
        }
    }

    /// Swift `resolvedInputArtifact`: the flash bundle's lease resolved
    /// again, its binding the materialized one and its bytes unchanged.
    fn resolved_input(&self, run: &Run) -> Result<Resolved, String> {
        let inputs = &run.record.request["inputs"];
        let lease = inputs["artifactLease"]
            .as_str()
            .or_else(|| inputs["imageBundleLease"].as_str())
            .ok_or("the Flash request names no image bundle lease")?;
        let leased = self.leased(lease)?;
        if let Some(reason) = binding_refusal(&leased, &run.record) {
            return Err(reason);
        }
        if !self.runner.artifacts.payload_matches(&leased) {
            return Err("the leased payload no longer matches its digest".into());
        }
        Ok(Resolved {
            artifact_id: leased.artifact_id.clone(),
            sha256: leased.row["sha256"]
                .as_str()
                .ok_or("the leased payload has no digest")?
                .to_owned(),
            byte_count: leased.row["byteCount"]
                .as_u64()
                .ok_or("the leased payload has no size")?,
            path: leased.path.clone(),
            lease: lease.to_owned(),
            leased,
        })
    }

    fn leased(&self, lease: &str) -> Result<LeasedArtifact, String> {
        match crate::job_owner::import_references::ImportReference::parse(lease) {
            Ok(Some(reference)) => self
                .runner
                .imports
                .ok_or_else(|| "Import owner is unavailable".to_owned())
                .and_then(|owner| {
                    owner
                        .resolve_input(self.runner.artifacts, &reference)
                        .map_err(|error| error.message)
                }),
            Ok(None) => self.runner.artifacts.lease(lease),
            Err(error) => Err(error.message),
        }
    }

    /// Swift `verifyHostInputArtifact` for a Flash: the leased archive read
    /// as a usable DAYU200 images archive, its declared build and digest
    /// noted.
    fn verify_host_input(
        &self,
        run: &mut Run,
        flash: &FlashExecution<'_>,
        step: &CatalogStep,
    ) -> Stepped<()> {
        let unresolvable = || {
            Stop::Failed("flash host verification cannot resolve its typed imageBundleLease".into())
        };
        let inputs = &run.record.request["inputs"];
        let (lease, profile) = match (
            inputs["artifactLease"].as_str(),
            inputs["imageBundleLease"].as_str(),
        ) {
            (Some(lease), _) => (lease.to_owned(), inputs["deviceProfileRef"].as_str()),
            (None, Some(lease)) => (lease.to_owned(), inputs["deviceProfile"].as_str()),
            _ => return Err(unresolvable()),
        };
        let resolved = self.resolved_input(run).map_err(|_| unresolvable())?;
        let Some(profile) = profile.filter(|profile| *profile == "dayu200") else {
            return Err(Stop::Failed(
                "flash request names no published DAYU200 board profile".into(),
            ));
        };
        let Some(build) = flash.planning.build_version(&lease, &resolved.leased) else {
            return Err(Stop::Failed(
                "flash bundle is not a usable DAYU200 images archive".into(),
            ));
        };
        run.record.timeline.push(format!(
            "{} profile={profile} build={build} sha256={}",
            step.step_id, resolved.sha256
        ));
        Ok(())
    }

    /// Swift's `requestConfirmation` step: the destructive intent is bound
    /// to the exact Runtime-owned capability the Job was admitted under.
    fn confirm_intent(&self, run: &mut Run) -> Stepped<()> {
        let refused = || {
            Stop::Failed("destructive intent step has no matching Runtime-owned capability".into())
        };
        let capability = run.record.request["authorization"]["capabilityId"]
            .as_str()
            .ok_or_else(refused)?
            .to_owned();
        let owner = self.runner.mutation.ok_or_else(refused)?;
        let status = owner
            .authority
            .capabilities
            .handle(
                "capability.inspect",
                json!({"capabilityId": capability}).as_object().unwrap(),
            )
            .map_err(|_| refused())?;
        let envelope = &status["capability"];
        if envelope["issuer"]["kind"] != "runtimeDefaultPolicy"
            || envelope["effectCeiling"] != "destructive"
            || envelope["exactPlanDigest"].as_str() != run.record.materialized_plan()
        {
            return Err(refused());
        }
        run.record.timeline.push(format!(
            "destructive intent bound to Runtime capability {capability}"
        ));
        Ok(())
    }

    /// Swift `recordSkippedOptionalStep`: the reason kept, and every product
    /// the step owned recorded missing with it.
    fn record_skipped(
        &self,
        run: &mut Run,
        descriptor: &CatalogOperation,
        step: &CatalogStep,
        reason: &str,
    ) -> Stepped<()> {
        run.record
            .timeline
            .push(format!("skipped {}: {reason}", step.step_id));
        run.record.set_skip_reason(&step.step_id, reason);
        if step.step_id == "capture-post-flash-diagnostics" {
            let _ = self.product(
                run,
                descriptor,
                &step.step_id,
                "post-flash-hilog.txt",
                Err(reason),
                None,
            );
        }
        Ok(())
    }

    /// Swift's prewarm await at the first delegated step: the receipt must
    /// name the exact archive and profile, or nothing is consumed.
    fn confirm_prewarm(
        &self,
        run: &mut Run,
        flash: &FlashExecution<'_>,
        job: &mut Flash<'_>,
        resolved: &Resolved,
    ) -> Stepped<()> {
        if job.prewarm_confirmed {
            return Ok(());
        }
        let Some(prewarm) = job.prewarm.take() else {
            return Ok(());
        };
        let waited = Instant::now();
        let receipt = prewarm
            .join()
            .unwrap_or_else(|_| Err(LaneFailure::Other("the prewarm thread panicked".into())))
            .map_err(|error| {
                Stop::NotExecuted(format!(
                    "arkforged artifact prewarm failed before capability consumption; nothing \
                     was dispatched and the device was not touched: {}",
                    described(&error)
                ))
            })?;
        if receipt.artifact_sha256 != resolved.sha256 || receipt.profile_id != flash.profile_id {
            return Err(Stop::NotExecuted(
                "arkforged artifact prewarm identity drifted before capability consumption; \
                 nothing was dispatched and the device was not touched"
                    .into(),
            ));
        }
        run.record.timeline.push(format!(
            "ArkForge artifact prewarm ready ({}, total {} ms, consume wait {} ms)",
            if receipt.imported {
                "imported"
            } else {
                "store-hit"
            },
            receipt.duration_milliseconds,
            waited.elapsed().as_millis()
        ));
        job.prewarm_confirmed = true;
        Ok(())
    }

    /// Swift `consumeCapabilityBeforeMutation` for a Flash: the typed plan
    /// materialized again against fresh facts and equal to the admitted one,
    /// the Target lineage clear, the capability's policy identity recomputed,
    /// then the Job's one use consumed and its correlated evidence durable
    /// before any intent exists.
    fn consume(
        &self,
        run: &mut Run,
        flash: &FlashExecution<'_>,
        descriptor: &CatalogOperation,
        facts: Option<&RockchipFacts>,
        resolved: &Resolved,
    ) -> Stepped<()> {
        let reject = |detail: &str| Stop::Failed(format!("authorizationRequired: {detail}"));
        let owner = self
            .runner
            .mutation
            .ok_or_else(|| reject("Runtime mutation owner is unavailable"))?;
        let _reservation = owner
            .authority
            .holds
            .mutation_reservation_guard()
            .map_err(|detail| reject(&detail))?;
        owner
            .authority
            .require_state(self.runner.jobs)
            .map_err(|error| reject(&error.message))?;
        if run.record.admission_evidence().is_some() {
            return Err(reject("persisted mutation evidence cannot be replayed"));
        }
        let request = OperationRequest::decode(
            &serde_json::to_vec(&run.record.request).map_err(|_| Stop::Refused(uncertain()))?,
        )
        .map_err(|_| Stop::Refused(uncertain()))?;
        let Some(capability) = request.capability_id.clone() else {
            return Err(reject("mutation has no runtime capability reference"));
        };
        let drifted = "materialized plan or verified target binding is absent or drifted";
        let Some(plan_digest) = run
            .record
            .materialized_plan()
            .filter(|digest| crate::job_record::digest(digest))
            .map(str::to_owned)
        else {
            return Err(reject(drifted));
        };
        let planner = FlashPlanner {
            planner: JobPlanner {
                artifacts: Some(self.runner.artifacts),
                imports: self.runner.imports,
                analyzer: None,
                state_root: owner.state_root,
                hdc: None,
                workspace: None,
            },
            flash: Some(flash.planning),
            facts: Some(flash.facts),
        };
        let (fresh, _) = planner
            .materialize(flash.planning, &request, descriptor)
            .map_err(|refusal| {
                reject(&format!(
                    "fresh typed plan could not be materialized: {}",
                    refusal.swift_description()
                ))
            })?;
        if fresh.digest != plan_digest
            || fresh.identity.as_deref() != run.record.materialized_identity()
            || fresh.binding_revision != run.record.materialized_binding()
        {
            return Err(reject(
                "fresh typed plan, target or binding drifted before dispatch",
            ));
        }
        drop(fresh);
        let (Some(identity), Some(binding)) = (
            run.record
                .materialized_identity()
                .filter(|identity| crate::job_record::digest(identity))
                .map(str::to_owned),
            run.record
                .materialized_binding()
                .filter(|binding| *binding > 0),
        ) else {
            return Err(reject(drifted));
        };
        let target = request.target_id.clone();
        if request.expected_binding_revision != Some(binding)
            || facts.is_none_or(|facts| {
                facts.target_id != target
                    || facts.binding_revision != binding
                    || facts.identity_sha256 != identity
            })
        {
            return Err(reject(drifted));
        }
        let query = CapabilityQuery {
            operation_id: descriptor.id().to_owned(),
            operation_version: descriptor.version(),
            effect: Effect::Destructive,
            target_stable_identity_sha256: Some(identity.clone()),
            target_binding_revision: Some(binding),
            plan_digest: Some(plan_digest.clone()),
            inputs: request.inputs.clone(),
            artifact_facts: resolved.facts(),
            workspace_identity_sha256: None,
            workspace_revision: None,
            workspace_file_scopes_digest: None,
        };
        // Swift `freshCompleteOverwriteRecoveryProof`: the facts that would
        // prove a recovery are fresh and complete, and no recovery is
        // admitted by this Runtime yet.
        let facts = facts.ok_or_else(|| reject(drifted))?;
        if !crate::job_record::digest(&facts.tool_sha256) || facts.device_mode.is_empty() {
            return Err(Stop::Failed(
                "completeOverwriteRecovery.freshTargetTopologyOrToolMissing".into(),
            ));
        }
        let epochs = self
            .runner
            .jobs
            .recovery_epochs()
            .map_err(|_| Stop::Refused(uncertain()))?;
        let superseded: BTreeSet<String> = epochs
            .iter()
            .filter(|epoch| {
                crate::swift_decoding::same_text(
                    &epoch.draft.stable_target_identity_sha256,
                    &identity,
                ) && epoch.draft.binding_revision == binding
            })
            .flat_map(|epoch| {
                epoch
                    .draft
                    .covered_intents
                    .iter()
                    .map(|intent| intent.job_id.clone())
            })
            .collect();
        let store = owner.authority.capabilities;
        let denied = |error: String| {
            Stop::Failed(format!(
                "authorizationRequired: capability denied before mutation: {error}"
            ))
        };
        if let Some(unresolved) = store
            .unresolved_use_beyond(
                &identity,
                binding,
                Some((&request.idempotency_key, &run.record.job_id)),
                &superseded,
            )
            .map_err(|error| denied(error.swift()))?
        {
            return Err(denied(unresolved.blocker().swift()));
        }
        let status = store
            .handle(
                "capability.inspect",
                json!({"capabilityId": capability}).as_object().unwrap(),
            )
            .map_err(|_| {
                denied(
                    crate::capability_store::CapabilityStoreError::NotFound(capability.clone())
                        .swift(),
                )
            })?;
        if status["capability"]["issuer"]["kind"] == "runtimeDefaultPolicy" {
            let fingerprint =
                crate::capability_policy::recovery_policy_fingerprint(&query, false, None);
            if !capability.starts_with(&format!("CAP-RT-POLICY-{}-G", &fingerprint[..40])) {
                return Err(Stop::Failed(
                    "completeOverwriteRecovery.freshProofDrifted".into(),
                ));
            }
        }
        owner
            .authority
            .require_state(self.runner.jobs)
            .map_err(|error| reject(&error.message))?;
        let now = run.clock()?;
        let step_set = crate::job_plan::step_set_digest(descriptor, &request.inputs)
            .map_err(|_| Stop::Refused(uncertain()))?;
        let consumed = store
            .consume(
                &capability,
                &request.idempotency_key,
                Some(&run.record.job_id),
                &query,
                &now,
            )
            .map_err(|error| denied(error.swift()))?;
        let evidence = json!({
            "kind": "runtimeCapability", "reference": capability,
            "admittedAtUTC": consumed.consumed_at_utc,
            "validUntilUTC": status["capability"]["expiresAtUTC"],
            "consumptionFingerprintSHA256": consumed.query_fingerprint_sha256,
            "runtimeCapabilityCorrelation": {
                "reservationID": consumed.reservation_id, "useOrdinal": consumed.ordinal,
                "planDigestSHA256": plan_digest, "stepSetDigestSHA256": step_set,
                "targetBindingDigestSHA256":
                    sha256_hex(format!("{identity}\n{binding}").as_bytes()),
                "artifactSHA256": resolved.sha256,
            },
        });
        run.record.set_admission_evidence(evidence.clone());
        run.record
            .timeline
            .push("capability consumed before first mutation".into());
        run.consumed = Some(evidence);
        run.persist(self.runner.jobs).map_err(|_| {
            Stop::Failed(
                "authorizationRequired: capability admission could not become durable".into(),
            )
        })?;
        Ok(())
    }

    /// Swift `dispatchThroughArkForge`: the daemon job prepared and its join
    /// made durable before the intent, the one drive, and its terminal
    /// receipt validated and made durable before the outcome.
    fn dispatch_through_arkforge(
        &self,
        run: &mut Run,
        flash: &FlashExecution<'_>,
        job: &mut Flash<'_>,
        step: &CatalogStep,
        facts: Option<&RockchipFacts>,
        resolved: &Resolved,
    ) -> Stepped<()> {
        let id = step.step_id.as_str();
        let job_id = run.record.job_id.clone();
        let jobs = self.runner.jobs;
        let (Some(facts), Some(identity)) = (facts, run.record.materialized_identity()) else {
            return Err(Stop::Refused(uncertain()));
        };
        if facts.execution_connect_key.is_empty() {
            return Err(Stop::Refused(uncertain()));
        }
        let Some(topology) = facts
            .server_facts
            .get("dayu200HDCNormalAliasUSBTopology")
            .filter(|topology| !topology.is_empty())
        else {
            return Err(Stop::Refused(uncertain()));
        };
        let _ = identity;
        let artifact = LaneArtifact {
            path: resolved.path.clone(),
            sha256: resolved.sha256.clone(),
            profile_id: flash.profile_id.to_owned(),
        };
        let revision = run.record.request["target"]["expectedBindingRevision"]
            .as_i64()
            .unwrap_or(1);
        let binding = DeviceBinding {
            connect_key: facts.execution_connect_key.clone(),
            stable_identity_sha256: facts.identity_sha256.clone(),
            target_id: run.record.request["target"]["targetId"]
                .as_str()
                .unwrap_or_default()
                .to_owned(),
            binding_revision: revision,
            usb_topology: topology.clone(),
        };
        let purpose = if run
            .record
            .admission_evidence()
            .is_some_and(|evidence| evidence.get("completeOverwriteRecovery").is_some())
        {
            "supersedingRecovery"
        } else {
            "primaryFlash"
        };
        let toolchain = flash.lane.toolchain_sha256().to_owned();
        let execution = match job.state.execution.clone() {
            Some(execution) => execution,
            None => {
                let execution = flash
                    .lane
                    .prepare(&job_id, &artifact, &binding, purpose)
                    .map_err(lane_stop)?;
                correlated(
                    &execution, &job_id, &artifact, &binding, purpose, &toolchain,
                )?;
                job.state.execution = Some(execution.clone());
                jobs.persist_arkforge_state(&job_id, &job.state)
                    .map_err(|_| Stop::Refused(uncertain()))?;
                execution
            }
        };
        correlated(
            &execution, &job_id, &artifact, &binding, purpose, &toolchain,
        )?;
        let intent = format!("intent-{id}");
        let arguments =
            delegated_arguments(id, &resolved.facts()).ok_or_else(|| Stop::Refused(uncertain()))?;
        let workflow = json!({
            "id": id, "kind": step.kind, "effect": step.effect,
            "cancellation": step.cancellation, "bindingRequirement": step.binding,
            "arguments": arguments, "compensationDescriptors": [],
        });
        let device_identity = facts.identity_sha256.clone();
        self.append_intent(run, &intent, &workflow, &device_identity, revision)?;
        let action = run.record.recovery_action().cloned();
        run.record.set_recovery(Some(id), Some(&intent), action);
        run.record.timeline.push(format!(
            "intent {id} correlated daemon-job={}",
            execution.daemon_job_id
        ));
        run.persist(jobs)?;
        let receipt = match flash.lane.perform(id, &execution, &artifact, &binding) {
            Ok(receipt) => receipt,
            Err(LaneFailure::OutcomeUnknown(reason)) => {
                run.record.timeline.push(format!(
                    "outcomeUnknown {id}; correlated daemon job retained"
                ));
                let action = run.record.recovery_action().cloned();
                run.record.set_recovery(Some(id), Some(&intent), action);
                run.persist(jobs)?;
                return Err(Stop::Unknown(reason));
            }
            Err(failure @ (LaneFailure::Failed(_) | LaneFailure::ConfirmedNotExecuted(_))) => {
                let not_executed = matches!(failure, LaneFailure::ConfirmedNotExecuted(_));
                let at = run.clock()?;
                run.step_outcome_at(
                    id,
                    &intent,
                    "failed",
                    not_executed.then_some(NOT_EXECUTED_CODE),
                    &at,
                )?;
                let action = run.record.recovery_action().cloned();
                run.record.set_recovery(None, None, action);
                run.persist(jobs)?;
                return Err(match failure {
                    LaneFailure::ConfirmedNotExecuted(reason) => Stop::NotExecuted(reason),
                    LaneFailure::Failed(reason) => Stop::Failed(reason),
                    _ => unreachable!(),
                });
            }
            Err(LaneFailure::Other(description)) => {
                run.record.timeline.push(format!(
                    "outcomeUnknown {id}; correlated daemon observation failed: {description}"
                ));
                run.persist(jobs)?;
                return Err(Stop::Unknown(format!(
                    "lost the terminal state of correlated arkforged job {}: {description}",
                    execution.daemon_job_id
                )));
            }
        };
        if !validate_completion(&receipt, Some(&execution)) {
            run.record.timeline.push(format!(
                "outcomeUnknown {id}; daemon terminal receipt failed canonical validation"
            ));
            run.persist(jobs)?;
            return Err(Stop::Unknown(described(&LaneFailure::OutcomeUnknown(
                format!(
                    "ArkForge returned no canonical completed-plan postflight receipt for {job_id}"
                ),
            ))));
        }
        job.state.completion = Some(receipt.clone());
        jobs.persist_arkforge_state(&job_id, &job.state)
            .map_err(|_| Stop::Refused(uncertain()))?;
        let at = run.clock()?;
        let envelope = run.envelope_at(format!("outcome-{id}"), at);
        run.append(events::step_outcome(
            &envelope,
            id,
            1,
            &intent,
            "succeeded",
            "confirmed",
            Some(PLAN_COMPLETION_CODE),
            Some(&completion_summary(&receipt)),
        ))?;
        let action = run.record.recovery_action().cloned();
        run.record.set_recovery(None, None, action);
        run.persist(jobs)?;
        Ok(())
    }

    /// A step intent of this Job on the Target the plan binds.
    fn append_intent(
        &self,
        run: &mut Run,
        intent: &str,
        workflow: &Value,
        identity: &str,
        revision: i64,
    ) -> Stepped<()> {
        let target = Target {
            scope: "device".into(),
            target_id: run.record.request["target"]["targetId"]
                .as_str()
                .unwrap_or_default()
                .to_owned(),
            connect_key: Some(format!("sha256:{identity}")),
            identity_snapshot_hash: Some(identity.to_owned()),
        };
        let envelope = run.envelope(intent.to_owned())?;
        let event = events::step_intent(&envelope, workflow, &target, 1, Some(revision))
            .map_err(|_| Stop::Refused(uncertain()))?;
        run.append(event)?;
        Ok(())
    }

    /// Swift `arkForgePlanCompletionReceipt`: the durable receipt, or the
    /// lane's cache of this Job's completed run.
    fn completion_receipt(
        &self,
        flash: &FlashExecution<'_>,
        job: &Flash<'_>,
        job_id: &str,
    ) -> Option<ActionReceipt> {
        job.state
            .completion
            .clone()
            .or_else(|| flash.lane.completed_plan_receipt(job_id))
    }

    /// Swift `journalArkForgePlanCompletion`: one catalog step closed from
    /// the completed plan, as its own intent and confirmed outcome; nothing
    /// is dispatched.
    fn journal_plan_completion(
        &self,
        run: &mut Run,
        flash: &FlashExecution<'_>,
        job: &Flash<'_>,
        step: &CatalogStep,
    ) -> Stepped<()> {
        let id = step.step_id.as_str();
        let job_id = run.record.job_id.clone();
        let Some(receipt) = self.completion_receipt(flash, job, &job_id) else {
            return Err(Stop::Failed(format!(
                "{id} cannot be confirmed: ArkForge has no completed-plan receipt for {job_id}"
            )));
        };
        if !validate_completion(&receipt, job.state.execution.as_ref()) {
            return Err(Stop::Unknown(format!(
                "ArkForge returned no canonical completed-plan postflight receipt for {job_id}"
            )));
        }
        let arguments = plan_completion_arguments(id).ok_or_else(|| Stop::Refused(uncertain()))?;
        let workflow = json!({
            "id": id, "kind": step.kind, "effect": step.effect,
            "cancellation": step.cancellation, "bindingRequirement": step.binding,
            "arguments": arguments, "compensationDescriptors": [],
        });
        let (Some(identity), Some(revision)) = (
            run.record
                .materialized_identity()
                .filter(|identity| crate::job_record::digest(identity))
                .map(str::to_owned),
            run.record
                .materialized_binding()
                .filter(|revision| *revision > 0),
        ) else {
            return Err(Stop::Refused(uncertain()));
        };
        let intent = format!("intent-{id}");
        self.append_intent(run, &intent, &workflow, &identity, revision)?;
        let action = run.record.recovery_action().cloned();
        run.record.set_recovery(Some(id), Some(&intent), action);
        run.persist(self.runner.jobs)?;
        let at = run.clock()?;
        let envelope = run.envelope_at(format!("outcome-{id}"), at);
        run.append(events::step_outcome(
            &envelope,
            id,
            1,
            &intent,
            "succeeded",
            "confirmed",
            Some(PLAN_COMPLETION_CODE),
            Some(&completion_summary(&receipt)),
        ))?;
        Ok(())
    }

    /// Swift `publishLanePostflightFacts`: the completed plan's postflight
    /// facts become the Job's evidence observation, and its declared facts
    /// product is published from them.
    fn publish_postflight_facts(
        &self,
        run: &mut Run,
        flash: &FlashExecution<'_>,
        descriptor: &CatalogOperation,
        job: &Flash<'_>,
        step: &CatalogStep,
    ) -> Stepped<()> {
        let id = step.step_id.as_str();
        let job_id = run.record.job_id.clone();
        let Some(receipt) = self.completion_receipt(flash, job, &job_id) else {
            return Err(Stop::Failed(format!(
                "{id} was delegated but the lane holds no completed-plan receipt for {job_id}"
            )));
        };
        if !validate_completion(&receipt, job.state.execution.as_ref()) {
            return Err(Stop::Unknown(format!(
                "ArkForge returned no canonical completed-plan postflight receipt for {job_id}"
            )));
        }
        let facts: BTreeMap<String, String> = receipt.facts.iter().cloned().collect();
        let confirmed = run.clock()?;
        let target = &run.record.request["target"];
        let mut observation = json!({
            "providerID": run.record.provider(), "toolVersion": TOOL_VERSION,
            "toolSHA256": flash.lane.toolchain_sha256(), "transport": "usb",
            "confirmedAtUTC": confirmed, "confirmationMethod": "machineReadback",
            "preflightSteps": [], "targetID": target["targetId"],
        });
        if let Some(revision) = target["expectedBindingRevision"].as_i64() {
            observation["bindingRevision"] = json!(revision);
        }
        if let Some(identity) = facts
            .get("stableIdentitySHA256")
            .map(String::as_str)
            .or(run.record.materialized_identity())
        {
            observation["stableIdentitySHA256"] = json!(identity);
        }
        if let Some(model) = facts.get("const.product.model") {
            observation["model"] = json!(model);
        }
        if let Some(firmware) = facts.get("const.ohos.fullname") {
            observation["firmware"] = json!(firmware);
        }
        run.record.set_evidence_observation(observation);
        run.record.set_first_evidence(&confirmed);
        run.persist(self.runner.jobs)?;
        let contents = crate::capture_documents::flash_facts(
            descriptor,
            &run.record,
            "post-flash-facts.json",
            &facts,
        )
        .map_err(Stop::Publication)?;
        self.publish_step_product(
            run,
            descriptor,
            id,
            "post-flash-facts.json",
            &contents,
            None,
        )
        .map_err(Stop::Publication)
    }

    /// Swift `dispatchWithWAL` for the one host-managed step a delegated
    /// Flash runs itself: its typed action persisted, its intent durable, the
    /// Rockchip host's receipt judged by its durable record, the outcome, and
    /// its product published.
    #[allow(clippy::too_many_arguments)]
    fn host_step(
        &self,
        run: &mut Run,
        flash: &FlashExecution<'_>,
        descriptor: &CatalogOperation,
        step: &CatalogStep,
        facts: Option<&RockchipFacts>,
        resolved: &Resolved,
        now: &str,
    ) -> Result<(), HostStop> {
        let id = step.step_id.as_str();
        let reference = descriptor.reference();
        let inputs = run.record.request["inputs"]
            .as_object()
            .cloned()
            .unwrap_or_default();
        let canonical = canonical_inputs(&reference, &inputs).map_err(|_| HostStop::NoAction)?;
        let Some(facts) = facts else {
            return Err(HostStop::NoAction);
        };
        let host = flash
            .planning
            .host_step(
                id,
                &step.kind,
                &canonical,
                facts,
                &resolved.lease,
                &resolved.leased,
            )
            .map_err(|_| HostStop::NoAction)?;
        let Some(revision) = run.record.request["target"]["expectedBindingRevision"].as_i64()
        else {
            return Err(HostStop::Other(Stop::Refused(uncertain())));
        };
        // Swift's lowering returns the very action it was given, whose effect
        // is its catalog step's.
        if host.effect != step.effect {
            return Err(HostStop::Other(Stop::Refused(uncertain())));
        }
        let workflow = json!({
            "id": id, "kind": step.kind, "effect": step.effect,
            "cancellation": step.cancellation, "bindingRequirement": step.binding,
            "arguments": host.arguments, "compensationDescriptors": [],
        });
        let intent = format!("intent-{id}");
        run.record
            .set_recovery(Some(id), Some(&intent), Some(host.action.clone()));
        run.persist(self.runner.jobs)
            .map_err(|refusal| HostStop::Other(refusal.into()))?;
        self.append_intent(run, &intent, &workflow, &facts.identity_sha256, revision)
            .map_err(HostStop::Other)?;
        run.record.timeline.push(format!("intent {id}"));
        run.record.add_step_kind(&step.kind);
        run.record.set_first_evidence(now);
        let action_text = String::from_utf8(
            crate::session_json::encode(&host.action)
                .map_err(|_| HostStop::Other(Stop::Refused(uncertain())))?,
        )
        .map_err(|_| HostStop::Other(Stop::Refused(uncertain())))?;
        // The window a published capture was observed in opens here and
        // closes where the dispatch returns (Swift `stepObservationWindows`).
        let opened = (self.runner.precise_now)();
        let dispatched = flash.host.dispatch(&HostAction {
            identifier: host.identifier.to_owned(),
            job_id: run.record.job_id.clone(),
            step_id: id.to_owned(),
            target_id: run.record.request["target"]["targetId"]
                .as_str()
                .unwrap_or_default()
                .to_owned(),
            binding_revision: revision,
            connect_key: facts.execution_connect_key.clone(),
            expected_identity_sha256: facts.identity_sha256.clone(),
            provider_executable_sha256: facts.tool_sha256.clone(),
            action_sha256: host.action_sha256.clone(),
            action: action_text,
            output_byte_budget: None,
        });
        let window = opened.zip((self.runner.precise_now)());
        let receipt = match dispatched {
            Ok(receipt) => receipt,
            Err(LaneFailure::OutcomeUnknown(reason)) => {
                run.record.timeline.push(format!(
                    "outcomeUnknown {id}; durable intent left outstanding"
                ));
                return Err(HostStop::Other(Stop::Unknown(reason)));
            }
            Err(failure @ (LaneFailure::Failed(_) | LaneFailure::ConfirmedNotExecuted(_))) => {
                let not_executed = matches!(failure, LaneFailure::ConfirmedNotExecuted(_));
                let at = run
                    .clock()
                    .map_err(|refusal| HostStop::Other(refusal.into()))?;
                run.step_outcome_at(
                    id,
                    &intent,
                    "failed",
                    not_executed.then_some(NOT_EXECUTED_CODE),
                    &at,
                )
                .map_err(|refusal| HostStop::Other(refusal.into()))?;
                run.record.timeline.push(if not_executed {
                    format!("confirmed not executed {id}")
                } else {
                    format!("failed {id}")
                });
                run.record.set_recovery(None, None, None);
                return Err(HostStop::Dispatch(described(&failure)));
            }
            Err(LaneFailure::Other(_)) => return Err(HostStop::Other(Stop::Refused(uncertain()))),
        };
        let Some(record_id) = receipt
            .record_id
            .clone()
            .filter(|record| !record.is_empty())
        else {
            run.record.timeline.push(format!(
                "outcomeUnknown {id}; durable intent left outstanding"
            ));
            return Err(HostStop::Other(Stop::Unknown(
                "host-managed execution returned no durable record reference".into(),
            )));
        };
        let mut summary = receipt.summary.clone();
        summary.insert("recordId".into(), record_id);
        let at = run
            .clock()
            .map_err(|refusal| HostStop::Other(refusal.into()))?;
        run.step_outcome_at(id, &intent, "succeeded", None, &at)
            .map_err(|refusal| HostStop::Other(refusal.into()))?;
        let names: Vec<&str> = summary.keys().map(String::as_str).collect();
        run.record
            .timeline
            .push(format!("verified {id} {}", swift_array(&names)));
        run.record.set_recovery(None, None, None);
        if id == "capture-post-flash-diagnostics" {
            self.publish_step_product(
                run,
                descriptor,
                id,
                "post-flash-hilog.txt",
                &receipt.stdout,
                window,
            )
            .map_err(|detail| HostStop::Other(Stop::Publication(detail)))?;
        }
        Ok(())
    }
}

/// Swift `validateArkForgeLaneExecution`: the daemon job the lane prepared
/// is this exact Runtime attempt's.
fn correlated(
    execution: &Execution,
    job_id: &str,
    artifact: &LaneArtifact,
    binding: &DeviceBinding,
    purpose: &str,
    toolchain: &str,
) -> Stepped<()> {
    let lowercase_digest = |value: &str| crate::job_record::digest(value);
    let matches = execution.arkdeck_job_id == job_id
        && !execution.daemon_job_id.is_empty()
        && !execution.plan_id.is_empty()
        && lowercase_digest(&execution.plan_sha256)
        && execution.execution_purpose == purpose
        && execution.artifact_sha256 == artifact.sha256.to_lowercase()
        && execution.artifact_profile_id == artifact.profile_id
        && execution.target_id == binding.target_id
        && execution.binding_revision == binding.binding_revision
        && execution.stable_identity_sha256 == binding.stable_identity_sha256.to_lowercase()
        && execution.usb_topology == binding.usb_topology
        && !execution.observation_mode.is_empty()
        && execution.toolchain_sha256 == toolchain.to_lowercase();
    if matches {
        Ok(())
    } else {
        Err(Stop::NotExecuted(
            "persisted ArkForge execution correlation does not match the admitted Runtime \
             attempt; no permit was signed by this call"
                .into(),
        ))
    }
}

/// A lane failure as the run classifies it; any other error escapes the
/// run and leaves the Job where it stood.
fn lane_stop(failure: LaneFailure) -> Stop {
    match failure {
        LaneFailure::Failed(reason) => Stop::Failed(reason),
        LaneFailure::ConfirmedNotExecuted(reason) => Stop::NotExecuted(reason),
        LaneFailure::OutcomeUnknown(reason) => Stop::Unknown(reason),
        LaneFailure::Other(_) => Stop::Refused(uncertain()),
    }
}

/// Swift `arkForgePlanCompletionSummary`.
fn completion_summary(receipt: &ActionReceipt) -> String {
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

/// Swift `WorkflowEffect.riskRank`.
fn effect_rank(effect: &str) -> u8 {
    match effect {
        "hostOnly" => 0,
        "readOnly" => 1,
        "deviceMutation" => 2,
        _ => 3,
    }
}

/// Swift's `"\(array)"` of strings: `["a", "b"]`.
fn swift_array(items: &[&str]) -> String {
    let quoted: Vec<String> = items
        .iter()
        .map(|item| crate::strict_json::swift_quoted(item))
        .collect();
    format!("[{}]", quoted.join(", "))
}

/// Swift `RuntimeArtifactService.bindingSnapshot(for:)`.
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
