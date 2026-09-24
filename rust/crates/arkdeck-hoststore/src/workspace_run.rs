//! Swift `runOwned` through `dispatchWithWAL` for an admitted
//! `workspace.prepare-isolated-copy@1` Job (TASK-XPA-015, M3): the running
//! transition, the typed intent materialized again for this Job, the exact
//! action persisted before its write-ahead intent is durable, the copy made
//! only after that intent, the provider's verification — the receipt against
//! the typed action, then the copy read back from disk — the correlated
//! outcome, the derived Artifact published after it, and the terminal
//! transitions, each spelled as Swift writes them.
//!
//! The copy is a host action with a safe-boundary cancellation: a request
//! that arrives before the intent closes the Job with zero dispatch; one that
//! arrives while the copy runs is honored at the boundary after it, as
//! Swift's engine honors it. A crash while the copy runs leaves its intent
//! outstanding, which start-up recovery parks for a readback; nothing here
//! replays it.
//!
//! One difference from Swift, on the refusing side: when the provider
//! refuses the step before its intent exists (the source moved since
//! admission, the profile is gone), Swift's run escapes and leaves the Job
//! `running` for a later run to retry; this Runtime resumes no host Job from
//! `running`, so the refusal fails the Job instead, with zero dispatch.
//!
//! `workspace.apply-patch@1` and `workspace.revert-patch@1` run one process
//! each, as Swift's `runOwned` runs them: the patch lease resolved again for
//! an apply, the typed action materialized for this Job, lowered against the
//! tree as it is now, the Job's capability use consumed and made durable,
//! the exact action persisted before the write-ahead intent, and only then
//! the pinned tool started; its receipt and the declared files read back
//! decide the correlated outcome, and the product is published after it. A
//! child whose outcome cannot be observed, or whose effect cannot be read
//! back, leaves its intent outstanding and parks the Job: a patch is never
//! run twice. The use is then settled with the Job's state.
use super::*;
use crate::capability_store::UseOutcome;
use crate::mutation_execution::MutationConsumption;
use crate::operation_catalog::CatalogOperation;
use crate::workspace_composition::{LeasedPatch, PatchVerdict, WorkspaceComposition};
use crate::workspace_isolation::{Inspection, IsolationIntent, IsolationResult};
use crate::workspace_patch::{PatchAction, ToolFailure, ToolInvocation};
use std::collections::BTreeMap;

pub(crate) const WORKSPACE_OPERATION: &str = "workspace.prepare-isolated-copy@1";
const WORKSPACE_STEP: &str = "prepare-isolated-copy";
const WORKSPACE_STEP_KIND: &str = "prepareWorkspaceIsolation";
const WORKSPACE_INTENT: &str = "intent-prepare-isolated-copy";
const PRODUCT: &str = "isolated-workspace.json";
pub(crate) const APPLY: &str = "workspace.apply-patch@1";
pub(crate) const REVERT: &str = "workspace.revert-patch@1";

/// Whether a Job of this operation runs through the workspace composition.
pub(crate) fn runs(operation: &str) -> bool {
    [WORKSPACE_OPERATION, APPLY, REVERT].contains(&operation)
}

/// One patch step's catalog identity and its product.
struct PatchStep {
    operation: &'static str,
    step: &'static str,
    kind: &'static str,
    product: &'static str,
    retention: &'static str,
}

fn patch_step(operation: &str) -> Option<PatchStep> {
    match operation {
        APPLY => Some(PatchStep {
            operation: APPLY,
            step: "apply-patch",
            kind: "applyWorkspacePatch",
            product: "applied-patch.json",
            retention: "pinnedUntilVerified",
        }),
        REVERT => Some(PatchStep {
            operation: REVERT,
            step: "revert-patch",
            kind: "revertWorkspacePatch",
            product: "revert-report.json",
            retention: "default",
        }),
        _ => None,
    }
}

/// Swift's interpolation of a `[String]`.
fn swift_keys(summary: &BTreeMap<String, String>) -> String {
    let quoted: Vec<String> = summary.keys().map(|key| swift_string(key)).collect();
    format!("[{}]", quoted.join(", "))
}

/// Swift `WorkspaceOperationsProvider.verify` for the isolation action: the
/// facts it verified, or the failure code and detail.
fn verify(
    workspace: &WorkspaceComposition,
    intent: &IsolationIntent,
    prepared: &IsolationResult,
) -> Result<BTreeMap<String, String>, (&'static str, &'static str)> {
    // The receipt Swift's dispatcher returns: the copy's identity and the
    // result's summary.
    let receipt = prepared.summary();
    if prepared.workspace_id != intent.workspace_id
        || receipt.get("projectRef") != Some(&intent.workspace_project_ref)
        || receipt.get("workspaceRevision") != Some(&intent.isolated_workspace_revision)
        || receipt.get("sourceWorkspaceRevision") != Some(&intent.expected_workspace_revision)
    {
        return Err((
            "workspace.isolationReceiptInvalid",
            "isolated workspace receipt is absent or disagrees with the typed action",
        ));
    }
    if workspace.isolation.is_none() {
        return Err((
            "workspace.isolationManagerUnavailable",
            "isolated workspace lifecycle is unavailable",
        ));
    }
    match workspace.inspect(intent) {
        Inspection::Prepared(read) if read.summary() == receipt => Ok(read.summary()),
        Inspection::Absent => Err((
            "workspace.isolationReadbackAbsent",
            "isolated workspace was not durable after preparation",
        )),
        Inspection::Prepared(_) | Inspection::Conflicted(_) => Err((
            "workspace.isolationReadbackDrifted",
            "isolated workspace manifest or copied revision drifted",
        )),
    }
}

impl JobRunner<'_> {
    /// Swift `runOwned` for the one isolation step.
    pub(super) fn execute_workspace(
        &self,
        run: &mut Run,
        workspace: &WorkspaceComposition,
    ) -> Result<(), RunRefusal> {
        let started = run.clock()?;
        run.record.start(&started);
        run.transition("preflight", "running", "steps-start")?;
        // Swift's safe boundary before the step.
        if self.cancellation.is_some_and(RunCancellation::pending) {
            self.carry(run)?;
            return self.drain(run);
        }
        let job_id = run.record.job_id.clone();
        let now = run.clock()?;
        let inputs = run.record.request["inputs"]
            .as_object()
            .cloned()
            .unwrap_or_default();
        let intent = match workspace.isolation_action(WORKSPACE_OPERATION, &inputs, &job_id, &now) {
            Ok(intent) => intent,
            Err(detail) => return self.fail(run, &detail),
        };
        // Swift `dispatchWithWAL`'s last boundary before an intent.
        if self.cancellation.is_some_and(RunCancellation::pending) {
            self.carry(run)?;
            return self.close_cancelled(run, false);
        }
        let target = run.record.request["target"]["targetId"]
            .as_str()
            .unwrap_or_default()
            .to_owned();
        let step = json!({
            "id": WORKSPACE_STEP, "kind": WORKSPACE_STEP_KIND, "effect": "hostOnly",
            "bindingRequirement": "none", "cancellation": "atSafeBoundary",
            "compensationDescriptors": [], "arguments": intent.journal_arguments(),
        });
        let event = events::step_intent(
            &run.envelope(WORKSPACE_INTENT.into())?,
            &step,
            &Target {
                scope: "host".into(),
                target_id: target.clone(),
                connect_key: None,
                identity_snapshot_hash: None,
            },
            1,
            None,
        )
        .map_err(|_| uncertain())?;
        // The exact typed action is durable before its intent can be.
        let persisted = intent.persisted().map_err(|_| uncertain())?;
        run.record.set_recovery(
            Some(WORKSPACE_STEP),
            Some(WORKSPACE_INTENT),
            Some(persisted),
        );
        run.persist(self.jobs)?;
        if run.append(event).is_err() {
            run.record.set_recovery(None, None, None);
            let _ = run.persist(self.jobs);
            return Err(uncertain());
        }
        run.record.timeline.push(format!("intent {WORKSPACE_STEP}"));
        run.record.add_step_kind(WORKSPACE_STEP_KIND);
        // Only now may the copy be made.
        let opened = (self.precise_now)();
        let dispatched = match opened {
            Some(_) => workspace
                .prepare(&intent)
                .map_err(|failure| failure.reason()),
            None => Err("dispatch refused: the Runtime clock is unavailable".to_owned()),
        };
        let window = opened.zip((self.precise_now)());
        let prepared = match dispatched {
            Ok(prepared) => prepared,
            Err(reason) => {
                let at = run.clock()?;
                run.step_outcome_at(WORKSPACE_STEP, WORKSPACE_INTENT, "failed", None, &at)?;
                run.record.timeline.push(format!("failed {WORKSPACE_STEP}"));
                run.record.set_recovery(None, None, None);
                return self.fail(run, &reason);
            }
        };
        let summary = match verify(workspace, &intent, &prepared) {
            Ok(summary) => summary,
            Err((code, detail)) => {
                let at = run.clock()?;
                run.step_outcome_at(WORKSPACE_STEP, WORKSPACE_INTENT, "failed", None, &at)?;
                run.record.set_recovery(None, None, None);
                run.record
                    .timeline
                    .push(format!("failed {WORKSPACE_STEP}: {code}: {detail}"));
                return self.fail(run, &format!("{code}: {detail}"));
            }
        };
        let at = run.clock()?;
        run.step_outcome_at(WORKSPACE_STEP, WORKSPACE_INTENT, "succeeded", None, &at)?;
        run.record.timeline.push(format!(
            "verified {WORKSPACE_STEP} {}",
            swift_keys(&summary)
        ));
        run.record.set_recovery(None, None, None);
        // The declared product is published after the correlated outcome.
        if let Err(reason) = self.publish_isolation(run, &target, &summary, window) {
            return self.close(run, &reason);
        }
        // Swift's step loop ends at a safe boundary, where `runOwned` drains
        // a cancellation that arrived while the copy ran.
        if self.cancellation.is_some_and(RunCancellation::pending) {
            self.carry(run)?;
            return self.drain(run);
        }
        run.transition("running", "finalizing", "steps-complete")?;
        run.record.set_operation_failure(None);
        run.transition("finalizing", "succeeded", "finalized")?;
        run.finish()?;
        run.persist(self.jobs)
    }

    /// Swift `publishDeclaredArtifacts` for `isolated-workspace.json`.
    fn publish_isolation(
        &self,
        run: &mut Run,
        target: &str,
        summary: &BTreeMap<String, String>,
        window: Option<(String, String)>,
    ) -> Result<(), String> {
        let product = WorkspaceProduct {
            name: PRODUCT,
            operation: WORKSPACE_OPERATION,
            step: WORKSPACE_STEP,
            retention: "pinnedUntilVerified",
        };
        self.publish_workspace_product(run, &product, target, summary, window)
    }

    /// Swift `publishDeclaredArtifacts` for a workspace product, whose bytes
    /// are the default envelope: the product, its operation, Job and catalog,
    /// and the verified facts. A failure is recorded and returned as the
    /// reason the Job fails with.
    fn publish_workspace_product(
        &self,
        run: &mut Run,
        declared: &WorkspaceProduct,
        target: &str,
        summary: &BTreeMap<String, String>,
        window: Option<(String, String)>,
    ) -> Result<(), String> {
        let job_id = run.record.job_id.clone();
        let session_id = format!("session-{job_id}");
        let mut fields = Map::from_iter([
            ("artifact".to_owned(), json!(declared.name)),
            ("operation".to_owned(), json!(declared.operation)),
            ("jobId".to_owned(), json!(job_id)),
            (
                "catalogDigest".to_owned(),
                json!(run.record.catalog_digest()),
            ),
        ]);
        if let Some(observation) = run.record.evidence_observation() {
            for (field, key) in [
                ("model", "model"),
                ("firmware", "firmware"),
                ("transport", "transport"),
                ("stableIdentitySHA256", "stableIdentitySha256"),
            ] {
                if let Some(value) = observation.get(field).and_then(Value::as_str) {
                    fields.insert(key.into(), json!(value));
                }
            }
        }
        for (key, value) in summary {
            fields.insert(key.clone(), json!(value));
        }
        let mut binding = json!({"targetID": target});
        if let Some(revision) = run.record.request["target"]["expectedBindingRevision"].as_i64() {
            binding["bindingRevision"] = json!(revision);
        }
        if let Some(identity) = run.record.materialized_identity() {
            binding["stableIdentitySHA256"] = json!(identity);
        }
        let product = Product {
            job_id: &job_id,
            session_id: &session_id,
            step_id: declared.step,
            name: declared.name,
            media_type: "application/json",
            privacy: "standard",
            retention_class: declared.retention,
            source_operation: declared.operation,
            provider_id: "workspace",
            binding,
            observation_window: window,
        };
        let publisher = ArtifactPublisher {
            store: self.artifacts,
            quota: self.quota,
            home: self.home,
            now: self.now,
        };
        let published = crate::session_json::encode_canonical_pretty(&Value::Object(fields))
            .map_err(|_| "artifact envelope could not be encoded".to_owned())
            .and_then(|contents| publisher.publish(&product, &contents));
        match published {
            Ok(metadata) => {
                run.record.timeline.push(format!(
                    "artifact {} -> {}",
                    declared.name,
                    metadata["artifactID"].as_str().unwrap_or_default()
                ));
                Ok(())
            }
            Err(error) => {
                // A publication failure is recorded, never swallowed.
                let _ = publisher.record_missing(&product, &error);
                let name = declared.name;
                run.record
                    .timeline
                    .push(format!("artifact {name} missing: {error}"));
                run.record.set_operation_failure(Some(failure(
                    "artifactPublicationFailed",
                    "storage",
                    "notAutomatic",
                    "inspectJob",
                )));
                Err(format!(
                    "artifact publication failed: {name} could not be published: {error}"
                ))
            }
        }
    }

    /// Swift `runOwned`'s drain of a cancellation at a safe boundary between
    /// steps: the durable request already carried, the Job closed cancelled.
    /// A device Job drains the same way (`device_run.rs`).
    pub(crate) fn drain(&self, run: &mut Run) -> Result<(), RunRefusal> {
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
        run.persist(self.jobs)
    }
}

/// A workspace operation's declared product.
struct WorkspaceProduct {
    name: &'static str,
    operation: &'static str,
    step: &'static str,
    retention: &'static str,
}

impl JobRunner<'_> {
    /// Swift `runOwned` for one patch step, then `recordCapabilityOutcome`
    /// for the use it ran under: unknown while the Job is parked, confirmed
    /// with the Job's state otherwise.
    pub(super) fn execute_workspace_patch(
        &self,
        run: &mut Run,
        workspace: &WorkspaceComposition,
    ) -> Result<(), RunRefusal> {
        self.patch_steps(run, workspace)?;
        let outcome = if run.record.state == "waitingForRecovery" {
            UseOutcome::OutcomeUnknown
        } else {
            UseOutcome::Confirmed
        };
        self.settle_mutation(run, outcome)
    }

    /// Swift `resolvedInputArtifact` for an admitted apply, before its step:
    /// the lease resolved again and still bound to the request's target. The
    /// refusal is the reason the Job fails with.
    fn patch_lease(&self, run: &Run) -> Result<LeasedPatch, String> {
        let Some(reference) = run.record.request["inputs"]["patchArtifactRef"].as_str() else {
            return Err("workspace patch Artifact lease is absent".into());
        };
        let resolved = match crate::job_owner::import_references::ImportReference::parse(reference)
        {
            Ok(Some(reference)) => self
                .imports
                .ok_or_else(|| "Import owner is unavailable".to_owned())
                .and_then(|owner| {
                    owner
                        .resolve_input(self.artifacts, &reference)
                        .map_err(|error| error.message)
                }),
            Ok(None) => self.artifacts.lease(reference),
            Err(error) => Err(error.message),
        };
        let leased = resolved.map_err(|error| {
            format!("input Artifact lease became unreadable before apply-patch: {error}")
        })?;
        if let Some(reason) = binding_refusal(&leased, &run.record) {
            return Err(reason);
        }
        let (Some(path), Some(sha256), Some(byte_count)) = (
            leased.path.to_str(),
            leased.row["sha256"].as_str(),
            leased.row["byteCount"].as_u64(),
        ) else {
            return Err("input Artifact lease became unreadable before apply-patch".into());
        };
        Ok(LeasedPatch {
            artifact_id: leased.artifact_id.clone(),
            path: path.to_owned(),
            sha256: sha256.to_owned(),
            byte_count,
        })
    }

    /// Swift `executeAdmittedSteps` for one patch Job: its one step, run in
    /// the host target's mutation lane.
    fn patch_steps(
        &self,
        run: &mut Run,
        workspace: &WorkspaceComposition,
    ) -> Result<(), RunRefusal> {
        let operation = run.record.operation().to_owned();
        let (Some(declared), Some(descriptor)) = (
            patch_step(&operation),
            operation
                .rsplit_once('@')
                .and_then(|(id, version)| CatalogOperation::lookup(id, version.parse().ok())),
        ) else {
            return Err(uncertain());
        };
        let started = run.clock()?;
        run.record.start(&started);
        run.transition("preflight", "running", "steps-start")?;
        // Swift's mutation lane for the Job's target, held through its last
        // step: a patch that waited for another one sees the tree it left.
        let Ok(_lane) = workspace.lane.lock() else {
            return self.fail(run, "workspace mutation lane is unavailable");
        };
        // Swift's safe boundary before the step.
        if self.cancellation.is_some_and(RunCancellation::pending) {
            self.carry(run)?;
            return self.drain(run);
        }
        let job_id = run.record.job_id.clone();
        let inputs = run.record.request["inputs"]
            .as_object()
            .cloned()
            .unwrap_or_default();
        // The engine resolves an apply's lease again before its step; one
        // that no longer resolves fails the Job before any intent.
        let leased = if operation == APPLY {
            match self.patch_lease(run) {
                Ok(leased) => Some(leased),
                Err(reason) => return self.fail(run, &reason),
            }
        } else {
            None
        };
        // The provider context's clock, which an applied attempt records.
        let now = run.clock()?;
        let action = match leased.as_ref() {
            Some(leased) => workspace
                .apply_action(APPLY, &inputs, &job_id, Some(leased))
                .map(PatchAction::Apply),
            None => workspace
                .revert_action(REVERT, &inputs)
                .map(PatchAction::Revert),
        };
        // A provider refusal before any intent fails the Job: the tree moved
        // since admission, or the attempt is no longer active.
        let action = match action {
            Ok(action) => action,
            Err(detail) => return self.fail(run, &detail),
        };
        if let Err(detail) = workspace.lower(&action) {
            return self.fail(run, &detail);
        }
        match self.consume_workspace_authority(run, descriptor, workspace, leased.as_ref()) {
            Ok(MutationConsumption::Consumed | MutationConsumption::Held) => {}
            Ok(MutationConsumption::Cancelled) => {
                self.carry(run)?;
                return self.close_cancelled(run, false);
            }
            Ok(MutationConsumption::PersistenceUncertain) => return Err(uncertain()),
            Err(reason) => return self.fail(run, &reason),
        }
        // Swift `dispatchWithWAL`'s last boundary before an intent.
        if self.cancellation.is_some_and(RunCancellation::pending) {
            self.carry(run)?;
            return self.close_cancelled(run, false);
        }
        let target = run.record.request["target"]["targetId"]
            .as_str()
            .unwrap_or_default()
            .to_owned();
        let arguments = match &action {
            PatchAction::Apply(intent) => intent.journal_arguments(),
            PatchAction::Revert(_) => json!({
                "projectRef": inputs.get("projectRef"),
                "patchAttemptRef": inputs.get("patchAttemptRef"),
            }),
        };
        let step = json!({
            "id": declared.step, "kind": declared.kind, "effect": "deviceMutation",
            "bindingRequirement": "none", "cancellation": "atSafeBoundary",
            "compensationDescriptors": [], "arguments": arguments,
        });
        let intent_id = format!("intent-{}", declared.step);
        let event = events::step_intent(
            &run.envelope(intent_id.clone())?,
            &step,
            &Target {
                scope: "host".into(),
                target_id: target.clone(),
                connect_key: None,
                identity_snapshot_hash: None,
            },
            1,
            None,
        )
        .map_err(|_| uncertain())?;
        // The exact typed action is durable before its intent can be.
        let persisted = action.persisted().map_err(|_| uncertain())?;
        run.record
            .set_recovery(Some(declared.step), Some(&intent_id), Some(persisted));
        run.persist(self.jobs)?;
        if run.append(event).is_err() {
            run.record.set_recovery(None, None, None);
            let _ = run.persist(self.jobs);
            return Err(uncertain());
        }
        run.record
            .timeline
            .push(format!("intent {}", declared.step));
        run.record.add_step_kind(declared.kind);
        // Only now may the tool start.
        let invocation = action.invocation();
        let opened = (self.precise_now)();
        let dispatched = match opened {
            Some(_) => workspace.tool.dispatch(&ToolInvocation {
                executable_path: &invocation.executable_path,
                executable_sha256: &invocation.executable_sha256,
                arguments: &invocation.arguments,
                working_directory: &invocation.project_root,
                timeout_seconds: invocation.timeout_seconds,
            }),
            None => Err(ToolFailure::Failed(
                "dispatch refused: the Runtime clock is unavailable".into(),
            )),
        };
        let window = opened.zip((self.precise_now)());
        let receipt = match dispatched {
            Ok(receipt) => receipt,
            Err(ToolFailure::OutcomeUnknown(reason)) => {
                // The intent stays outstanding: no outcome is invented, and
                // the patch is never started again.
                run.record.timeline.push(format!(
                    "outcomeUnknown {}; durable intent left outstanding",
                    declared.step
                ));
                return self.park(run, &reason);
            }
            Err(ToolFailure::Failed(reason)) => {
                let at = run.clock()?;
                run.step_outcome_at(declared.step, &intent_id, "failed", None, &at)?;
                run.record
                    .timeline
                    .push(format!("failed {}", declared.step));
                run.record.set_recovery(None, None, None);
                return self.fail(run, &reason);
            }
        };
        match workspace.verify(&action, &receipt, &now) {
            PatchVerdict::Verified(summary) => {
                let at = run.clock()?;
                run.step_outcome_at(declared.step, &intent_id, "succeeded", None, &at)?;
                run.record.timeline.push(format!(
                    "verified {} {}",
                    declared.step,
                    swift_keys(&summary)
                ));
                run.record.set_recovery(None, None, None);
                let product = WorkspaceProduct {
                    name: declared.product,
                    operation: declared.operation,
                    step: declared.step,
                    retention: declared.retention,
                };
                if let Err(reason) =
                    self.publish_workspace_product(run, &product, &target, &summary, window)
                {
                    return self.close(run, &reason);
                }
                if self.cancellation.is_some_and(RunCancellation::pending) {
                    self.carry(run)?;
                    return self.drain(run);
                }
                run.transition("running", "finalizing", "steps-complete")?;
                run.record.set_operation_failure(None);
                run.transition("finalizing", "succeeded", "finalized")?;
                run.finish()?;
                run.persist(self.jobs)
            }
            PatchVerdict::Failed(code, detail) => {
                let at = run.clock()?;
                run.step_outcome_at(declared.step, &intent_id, "failed", None, &at)?;
                run.record.set_recovery(None, None, None);
                run.record
                    .timeline
                    .push(format!("failed {}: {code}: {detail}", declared.step));
                self.fail(run, &format!("{code}: {detail}"))
            }
            // The child ran but what it left cannot be read back: the intent
            // stays outstanding for a readback, never for a second run.
            PatchVerdict::Unknown(reason) => {
                run.record.timeline.push(format!(
                    "outcomeUnknown {}; durable intent left outstanding",
                    declared.step
                ));
                self.park(run, &reason)
            }
        }
    }
}
