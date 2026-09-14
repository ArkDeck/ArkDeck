//! Swift `RuntimeJobEngine.runOwned` over `executeSteps` and `dispatchWithWAL`
//! for an admitted device-bound HDC Job (`observe.device@1` and the default
//! legs of `capture.diagnostics@1`), as the isolated Rust owner runs it
//! through its HDC composition: the running transition; every catalog step in
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
//! loop honours it.
use crate::artifact_publication::{ArtifactPublisher, Product};
use crate::artifact_read_owner::swift_string;
use crate::capture_documents;
use crate::device_facts::{self, DeviceFacts, HdcComposition};
use crate::device_steps::{self, ActionRefusal};
use crate::job_cancel::RunCancellation;
use crate::job_journal_events::{self as events, Target};
use crate::job_record::JobRecord;
use crate::job_run::{JobRunner, Run, RunRefusal, failure, uncertain};
use crate::operation_catalog::{CatalogArtifact, CatalogOperation, CatalogStep};
use crate::session_json;
use arkdeck_provider_hdc::{
    Action, DispatchFailure, Expected, Outcome, Persisted, ProcessPlan, Receipt,
};
use serde_json::{Map, Value, json};
use std::collections::{BTreeMap, BTreeSet};

const OBSERVE: &str = "observe.device@1";
const CAPTURE: &str = "capture.diagnostics@1";

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

fn persisted_value(value: Persisted) -> Value {
    match value {
        Persisted::Text(text) => json!(text),
        Persisted::Integer(number) => json!(number),
        Persisted::Texts(texts) => json!(texts),
    }
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
    /// Swift `runOwned` for a device-bound HDC operation.
    pub(crate) fn execute_device(
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
        match self.steps(run, hdc, descriptor) {
            Ok(()) => {}
            Err(Stop::Failed(reason)) => return self.fail(run, &reason),
            Err(Stop::Unknown(reason)) => return self.park(run, &reason),
            Err(Stop::Publication(detail)) => {
                run.record.set_operation_failure(Some(failure(
                    "artifactPublicationFailed",
                    "storage",
                    "notAutomatic",
                    "inspectJob",
                )));
                return self.close(run, &format!("artifact publication failed: {detail}"));
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
        let inputs = run.record.request["inputs"]
            .as_object()
            .cloned()
            .unwrap_or_default();
        let target_id = run.record.request["target"]["targetId"]
            .as_str()
            .unwrap_or_default()
            .to_owned();
        let revision = run.record.request["target"]["expectedBindingRevision"].as_i64();
        let mut skipped = BTreeSet::new();
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
            let Some(now) = (hdc.now)() else {
                return Err(Stop::Refused(uncertain()));
            };
            let action = match device_steps::action(step, &descriptor.reference(), &inputs, &now) {
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
            // No pointer gesture is dispatched here yet: `DEVICE_OPERATIONS`
            // keeps the operations that inject one out of this lane.
            let device_steps::StepAction::Hdc(action) = action else {
                return Err(Stop::Refused(uncertain()));
            };
            let plan = action
                .lower(
                    &step.step_id,
                    facts.as_ref().map(|facts| facts.connect_key.as_str()),
                )
                .map_err(|_| Stop::Refused(uncertain()))?;
            match self.dispatch_step(
                run,
                hdc,
                descriptor,
                step,
                &action,
                &plan,
                facts.as_ref(),
                &target_id,
                revision,
            ) {
                Ok(()) => {}
                // Optional steps are the partial-success surface: one that
                // fails is skipped with its failure and the Job goes on. An
                // unknown outcome is never tolerated.
                Err(Stop::Failed(reason)) if step.optional => {
                    let reason = format!("failed({})", swift_string(&reason));
                    self.skip(run, descriptor, step, &reason, &mut skipped);
                }
                Err(stop) => return Err(stop),
            }
        }
        Ok(())
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

    /// Swift `dispatchWithWAL` for one HDC step.
    #[allow(clippy::too_many_arguments)]
    fn dispatch_step(
        &self,
        run: &mut Run,
        hdc: &HdcComposition<'_>,
        descriptor: &CatalogOperation,
        step: &CatalogStep,
        action: &Action,
        plan: &ProcessPlan,
        facts: Option<&DeviceFacts>,
        target_id: &str,
        revision: Option<i64>,
    ) -> Result<(), Stop> {
        let device = step.binding == "confirmedDevice";
        let intent_id = format!("intent-{}", step.step_id);
        // The journal mirrors the descriptor-bound facts without the raw key.
        let identity = facts.map_or_else(|| "0".repeat(64), |facts| facts.identity.clone());
        let inputs = run.record.request["inputs"]
            .as_object()
            .cloned()
            .unwrap_or_default();
        let Some(arguments) = device_steps::journal_arguments(
            step,
            &inputs,
            &device_steps::StepAction::Hdc(action.clone()),
        ) else {
            return Err(Stop::Refused(uncertain()));
        };
        let journal_step = json!({
            "id": step.step_id, "kind": step.kind, "effect": step.effect,
            "cancellation": step.cancellation, "bindingRequirement": step.binding,
            "arguments": arguments, "compensationDescriptors": [],
        });
        let intent = events::step_intent(
            &run.envelope(intent_id.clone())?,
            &journal_step,
            &Target {
                scope: if device { "device" } else { "host" }.into(),
                target_id: target_id.into(),
                connect_key: device.then(|| format!("sha256:{identity}")),
                identity_snapshot_hash: device.then(|| identity.clone()),
            },
            1,
            device.then(|| revision.unwrap_or(1)),
        )
        .map_err(|_| Stop::Refused(uncertain()))?;
        // The exact typed action is durable before its intent can be.
        let (kind, persisted) = action.persisted();
        let persisted: Map<String, Value> = persisted
            .into_iter()
            .map(|(key, value)| (key.to_owned(), persisted_value(value)))
            .collect();
        run.record.set_recovery(
            Some(&step.step_id),
            Some(&intent_id),
            Some(json!({"kind": kind, "arguments": persisted})),
        );
        run.persist(self.jobs)?;
        if run.append(intent).is_err() {
            run.record.set_recovery(None, None, None);
            let _ = run.persist(self.jobs);
            return Err(Stop::Refused(uncertain()));
        }
        run.record.timeline.push(format!("intent {}", step.step_id));
        run.record.add_step_kind(&step.kind);
        // A device step after the preflight is where a Job's evidence starts.
        if device && !device_steps::evidence_preflight_step(step) {
            let now = run.clock()?;
            run.record.set_first_evidence(&now);
        }
        // Only now may the executor start.
        let Some(opened) = (self.precise_now)() else {
            run.step_outcome(&step.step_id, &intent_id, "failed", None)?;
            run.record.timeline.push(format!("failed {}", step.step_id));
            run.record.set_recovery(None, None, None);
            return Err(Stop::Failed(
                "dispatch refused: the Runtime clock is unavailable".into(),
            ));
        };
        let receipt = match hdc.dispatch.dispatch(plan) {
            Ok(receipt) => receipt,
            Err(DispatchFailure::Unobservable(reason)) => {
                run.record.timeline.push(format!(
                    "outcomeUnknown {}; durable intent left outstanding",
                    step.step_id
                ));
                return Err(Stop::Unknown(reason));
            }
            Err(DispatchFailure::Refused(reason)) => {
                run.step_outcome(&step.step_id, &intent_id, "failed", None)?;
                run.record.timeline.push(format!("failed {}", step.step_id));
                run.record.set_recovery(None, None, None);
                return Err(Stop::Failed(reason));
            }
        };
        let window = (self.precise_now)().map(|closed| (opened, closed));
        let expected = Expected {
            connect_key: facts.map(|facts| facts.connect_key.as_str()),
            identity_sha256: facts.map(|facts| facts.identity.as_str()),
            tool_version: facts.map(|facts| facts.tool_version.as_str()),
        };
        match action.verify(&receipt, expected) {
            Outcome::Verified(summary) => {
                let outcome_at = run.clock()?;
                run.step_outcome_at(&step.step_id, &intent_id, "succeeded", None, &outcome_at)?;
                run.record.timeline.push(format!(
                    "verified {} {}",
                    step.step_id,
                    fact_names(&summary)
                ));
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
                run.step_outcome(&step.step_id, &intent_id, "failed", None)?;
                run.record.set_recovery(None, None, None);
                run.record
                    .timeline
                    .push(format!("failed {}: {code}: {detail}", step.step_id));
                Err(Stop::Failed(format!("{code}: {detail}")))
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
                fields.insert("confirmationMethod".into(), json!("machineReadback"));
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
        })
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
        receipt: &Receipt,
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
/// capture's bytes as the provider received them, or a facts product.
fn contents(
    name: &str,
    record: &JobRecord,
    summary: &BTreeMap<String, String>,
    receipt: &Receipt,
) -> Vec<u8> {
    match name {
        "hilog.txt" | "ui-dump.json" | "advanced-dump.txt" | "crash-index.txt"
        | "crash-log.txt" => receipt.stdout.clone(),
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
