//! Swift `RuntimeJobEngine.runOwned` over `executeSteps` and `dispatchWithWAL`
//! for an admitted `observe.device@1` Job, as the isolated Rust owner runs it
//! through its HDC composition: the running transition; every step in
//! catalog order, the engine's own recorded and the provider's dispatched,
//! each with its exact typed action persisted before its write-ahead intent
//! is durable and the executor started only after that intent, its receipt
//! verified as Swift's HDC provider verifies it and its correlated outcome
//! appended; the evidence preflight the device steps prove, the products each
//! step declares, and the terminal transitions. A step whose outcome cannot
//! be observed leaves its intent outstanding and parks the Job; nothing is
//! dispatched twice and no Job is resumed. A cancellation is honoured at the
//! next step boundary, where Swift's step loop honours it.
use crate::artifact_publication::{ArtifactPublisher, Product};
use crate::device_facts::{self, DeviceFacts, HdcComposition};
use crate::device_steps;
use crate::job_cancel::RunCancellation;
use crate::job_journal_events::{self as events, Target};
use crate::job_record::JobRecord;
use crate::job_run::{JobRunner, Run, RunRefusal, failure, uncertain};
use crate::operation_catalog::{CatalogOperation, CatalogStep};
use crate::session_json;
use arkdeck_provider_hdc::{Action, DispatchFailure, Expected, Outcome, ProcessPlan};
use serde_json::{Map, Value, json};
use std::collections::BTreeMap;

pub(crate) const OPERATION: &str = "observe.device@1";

/// Swift's evidence preflight, in the order its fragments must arrive.
const EVIDENCE_STEPS: [&str; 3] = [
    "confirm-evidence-target",
    "read-evidence-model",
    "read-evidence-firmware",
];

/// Swift `RuntimeArtifactService.artifacts(reference:stepID:)` for
/// `observe.device@1`.
fn products(step_id: &str) -> &'static [&'static str] {
    match step_id {
        "probe-host-tool" => &["tool-facts.json"],
        "read-evidence-firmware" => &["device-facts.json", "binding-snapshot.json"],
        _ => &[],
    }
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
        let Some(descriptor) = CatalogOperation::lookup("observe.device", Some(1)) else {
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
        // Swift's finalization publishes no product of `observe.device@1`.
        run.transition("running", "finalizing", "steps-complete")?;
        run.record.set_operation_failure(None);
        run.transition("finalizing", "succeeded", "finalized")?;
        run.finish()?;
        run.persist(self.jobs)
    }

    /// Swift `executeSteps` over the steps the plan selected.
    fn steps(
        &self,
        run: &mut Run,
        hdc: &HdcComposition<'_>,
        descriptor: &CatalogOperation,
    ) -> Result<(), Stop> {
        let inputs = run.record.request["inputs"]
            .as_object()
            .cloned()
            .unwrap_or_default();
        let target_id = run.record.request["target"]["targetId"]
            .as_str()
            .unwrap_or_default()
            .to_owned();
        let revision = run.record.request["target"]["expectedBindingRevision"].as_i64();
        for step in descriptor
            .steps
            .iter()
            .filter(|step| descriptor.step_is_selected(step, &inputs))
        {
            // The safe boundary between steps; the canceller's intent becomes
            // durable here and the run then drains.
            if self.cancellation.is_some_and(RunCancellation::pending) {
                self.carry(run)?;
                return Err(Stop::Cancelled);
            }
            if device_steps::engine_step(&step.kind) {
                if step.kind != "finalizeSession" {
                    return Err(Stop::Refused(uncertain()));
                }
                run.record
                    .timeline
                    .push(format!("host-step {}", step.step_id));
                continue;
            }
            let evidence = device_steps::evidence_preflight_step(step);
            let facts = if step.binding == "confirmedDevice" {
                match hdc.facts(&target_id) {
                    Ok(facts) => Some(facts),
                    Err(error) if evidence => {
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
            if step.binding == "confirmedDevice" {
                // Every device step of this operation is an evidence step;
                // a later device step would wait for the complete preflight.
                let Some(facts) = facts.as_ref().filter(|_| evidence) else {
                    return Err(Stop::Refused(uncertain()));
                };
                device_facts::validate(facts, &target_id, revision)
                    .map_err(|reason| Stop::Failed(reason.into()))?;
            }
            let Some(action) = device_steps::action(step) else {
                return Err(Stop::Refused(uncertain()));
            };
            let plan = action
                .lower(
                    &step.step_id,
                    facts.as_ref().map(|facts| facts.connect_key.as_str()),
                )
                .map_err(|_| Stop::Refused(uncertain()))?;
            self.dispatch_step(
                run,
                hdc,
                step,
                action,
                &plan,
                facts.as_ref(),
                &target_id,
                revision,
            )?;
        }
        Ok(())
    }

    /// Swift `dispatchWithWAL` for one HDC step.
    #[allow(clippy::too_many_arguments)]
    fn dispatch_step(
        &self,
        run: &mut Run,
        hdc: &HdcComposition<'_>,
        step: &CatalogStep,
        action: Action,
        plan: &ProcessPlan,
        facts: Option<&DeviceFacts>,
        target_id: &str,
        revision: Option<i64>,
    ) -> Result<(), Stop> {
        let device = step.binding == "confirmedDevice";
        let intent_id = format!("intent-{}", step.step_id);
        // The journal mirrors the descriptor-bound facts without the raw key.
        let identity = facts.map_or_else(|| "0".repeat(64), |facts| facts.identity.clone());
        let Some(arguments) = device_steps::journal_arguments(step) else {
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
            .map(|(key, value)| (key.to_owned(), json!(value)))
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
                if device_steps::requires_evidence_preflight(OPERATION)
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
                self.publish(run, step, &summary, window)
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
        let complete = ["transport", "confirmedAtUTC", "model", "firmware"]
            .iter()
            .all(|key| accumulator.get(*key).is_some())
            && accumulator["steps"].as_array().is_some_and(|steps| {
                steps
                    .iter()
                    .map(|step| step["stepID"].clone())
                    .collect::<Vec<_>>()
                    == EVIDENCE_STEPS.map(Value::from)
            });
        if complete {
            let mut observation = accumulator.clone();
            if let Some(fields) = observation.as_object_mut() {
                let steps = fields.remove("steps").unwrap_or_default();
                fields.insert("preflightSteps".into(), steps);
                fields.insert("confirmationMethod".into(), json!("machineReadback"));
            }
            run.record.set_evidence_observation(observation);
            // observe.device publishes its evidence-bearing products from the
            // final preflight outcome itself.
            run.record.set_first_evidence(outcome_at);
        }
        run.persist(self.jobs).map_err(|_| {
            incomplete("could not persist preflight fragment: the Job record is unwritable")
        })
    }

    /// Swift `publishDeclaredArtifacts`: the products this step declares,
    /// published after its correlated outcome; a product that cannot be is
    /// recorded missing with its reason and fails the Job.
    fn publish(
        &self,
        run: &mut Run,
        step: &CatalogStep,
        summary: &BTreeMap<String, String>,
        window: Option<(String, String)>,
    ) -> Result<(), Stop> {
        let names = products(&step.step_id);
        if names.is_empty() {
            return Ok(());
        }
        let Some(descriptor) = CatalogOperation::lookup("observe.device", Some(1)) else {
            return Err(Stop::Refused(uncertain()));
        };
        let job_id = run.record.job_id.clone();
        let session_id = format!("session-{job_id}");
        let binding = binding_snapshot(&run.record);
        let publisher = ArtifactPublisher {
            store: self.artifacts,
            quota: self.quota,
            home: self.home,
            now: self.now,
        };
        for name in names {
            let Some(declaration) = descriptor
                .artifacts
                .iter()
                .find(|artifact| artifact.name == *name)
            else {
                continue;
            };
            let product = Product {
                job_id: &job_id,
                session_id: &session_id,
                step_id: &step.step_id,
                name,
                media_type: &declaration.media_type,
                privacy: &declaration.privacy,
                retention_class: &declaration.retention_class,
                source_operation: OPERATION,
                provider_id: "hdc",
                binding: binding.clone(),
                observation_window: window.clone(),
            };
            match publisher.publish(&product, &contents(name, &run.record, summary)) {
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

/// Swift `RuntimeArtifactService.artifactContents` for a facts product: the
/// product, the operation and the Job, the observation's device facts where
/// there is one, the step's verified facts, and for the binding snapshot the
/// requested target and revision, in Swift's canonical pretty spelling.
fn contents(name: &str, record: &JobRecord, summary: &BTreeMap<String, String>) -> Vec<u8> {
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
    session_json::encode_pretty(&Value::Object(fields)).unwrap_or_else(|_| b"{}".to_vec())
}
