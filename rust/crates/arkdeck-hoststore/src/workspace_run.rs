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
use super::*;
use crate::workspace_composition::WorkspaceComposition;
use crate::workspace_isolation::{Inspection, IsolationIntent, IsolationResult};
use std::collections::BTreeMap;

pub(crate) const WORKSPACE_OPERATION: &str = "workspace.prepare-isolated-copy@1";
const WORKSPACE_STEP: &str = "prepare-isolated-copy";
const WORKSPACE_STEP_KIND: &str = "prepareWorkspaceIsolation";
const WORKSPACE_INTENT: &str = "intent-prepare-isolated-copy";
const PRODUCT: &str = "isolated-workspace.json";

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

    /// Swift `publishDeclaredArtifacts` for `isolated-workspace.json`, whose
    /// bytes are the default envelope: the product, its operation, Job and
    /// catalog, and the verified facts. A failure is recorded and returned
    /// as the reason the Job fails with.
    fn publish_isolation(
        &self,
        run: &mut Run,
        target: &str,
        summary: &BTreeMap<String, String>,
        window: Option<(String, String)>,
    ) -> Result<(), String> {
        let job_id = run.record.job_id.clone();
        let session_id = format!("session-{job_id}");
        let mut fields = Map::from_iter([
            ("artifact".to_owned(), json!(PRODUCT)),
            ("operation".to_owned(), json!(WORKSPACE_OPERATION)),
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
            step_id: WORKSPACE_STEP,
            name: PRODUCT,
            media_type: "application/json",
            privacy: "standard",
            retention_class: "pinnedUntilVerified",
            source_operation: WORKSPACE_OPERATION,
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
                    "artifact {PRODUCT} -> {}",
                    metadata["artifactID"].as_str().unwrap_or_default()
                ));
                Ok(())
            }
            Err(error) => {
                // A publication failure is recorded, never swallowed.
                let _ = publisher.record_missing(&product, &error);
                run.record
                    .timeline
                    .push(format!("artifact {PRODUCT} missing: {error}"));
                run.record.set_operation_failure(Some(failure(
                    "artifactPublicationFailed",
                    "storage",
                    "notAutomatic",
                    "inspectJob",
                )));
                Err(format!(
                    "artifact publication failed: {PRODUCT} could not be published: {error}"
                ))
            }
        }
    }

    /// Swift `runOwned`'s drain of a cancellation at a safe boundary between
    /// steps: the durable request already carried, the Job closed cancelled.
    fn drain(&self, run: &mut Run) -> Result<(), RunRefusal> {
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
