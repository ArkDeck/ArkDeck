//! Swift `materializeTypedPlanBeforeAuthorization` for the workspace
//! operation this Runtime materializes, `workspace.prepare-isolated-copy@1`
//! (TASK-XPA-015, M3): a registered provider that can serve it, the Artifact
//! store its product needs, the host-only descriptor and request, then the
//! step as the provider materializes and lowers it — a host workspace action
//! pinned by the digest of its typed intent, which runs no process.
//!
//! Swift materializes every plan for the authorization envelope's Job, so the
//! plan names the copy that Job would make; a run materializes it again for
//! its own Job. The typed intent carries the engine clock, so two plans of one
//! request agree only within one clock tick, as Swift's do.
use super::*;
use crate::workspace_isolation::DESCRIPTOR;

/// Swift `authorizationPlanJobID`.
const AUTHORIZATION_PLAN_JOB: &str = "job-authorization-envelope";

impl JobPlanner<'_> {
    /// The materialized plan document's digest.
    pub(super) fn materialize_workspace(
        &self,
        request: &OperationRequest,
        descriptor: &CatalogOperation,
    ) -> Result<String, PlanRefusal> {
        let reference = descriptor.reference();
        let Some(workspace) = self.workspace else {
            return Err(refusal(
                "invalidInput",
                format!("provider {} is not registered", descriptor.provider),
            ));
        };
        if let Some(reason) = workspace.provider_unavailability(&reference) {
            return Err(refusal(
                "invalidInput",
                format!("{reference} is runtime unavailable: {reason}"),
            ));
        }
        if self.artifacts.is_none() {
            return Err(refusal(
                "invalidInput",
                format!("{reference} is runtime unavailable: runtime.artifactStoreUnavailable"),
            ));
        }
        descriptor
            .validate_host_only()
            .map_err(|message| refusal("invalidInput", message))?;
        if request.expected_binding_revision.is_some() {
            return Err(refusal(
                "invalidInput",
                format!("{reference} is host-only: a request must not pin a binding revision"),
            ));
        }
        self.refuse_debug_permit(request)?;
        // The provider context's clock, which the typed intent records.
        let now = (workspace.now)().ok_or_else(internal_failure)?;
        let mut steps = Vec::new();
        for step in descriptor
            .steps
            .iter()
            .filter(|step| descriptor.step_is_selected(step, &request.inputs))
        {
            if step.kind != "prepareWorkspaceIsolation" || step.effect != "hostOnly" {
                return Err(internal_failure());
            }
            let intent = workspace
                .isolation_action(&reference, &request.inputs, AUTHORIZATION_PLAN_JOB, &now)
                .map_err(|error| {
                    refusal(
                        "invalidInput",
                        format!("typed plan preflight failed before authorization: {error}"),
                    )
                })?;
            let action = intent.action_sha256().map_err(|_| internal_failure())?;
            steps.push(json!({
                "stepID": step.step_id, "kind": step.kind, "effect": step.effect,
                "cancellation": step.cancellation, "binding": step.binding,
                "isOptional": step.optional, "journalArguments": intent.journal_arguments(),
                "processKind": "hostWorkspace",
                "hostManagedDescriptor": format!("{DESCRIPTOR}#action-sha256:{action}"),
            }));
        }
        let document = json!({
            "operationReference": reference,
            "catalogDigest": CATALOG_DIGEST,
            "inputs": request.inputs,
            "targetID": request.target_id,
            "providerID": descriptor.provider,
            "steps": steps,
        });
        let bytes = session_json::encode(&document).map_err(|_| internal_failure())?;
        Ok(sha256_hex(&bytes))
    }
}
