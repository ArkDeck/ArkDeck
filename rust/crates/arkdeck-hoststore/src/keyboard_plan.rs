//! Private keyboard inputs are resolved before admission and hashed into the
//! complete plan. No private payload or lowered argv is returned to a caller.
use super::*;
use crate::{device_facts::DeviceFacts, device_steps::StepContext};
use arkdeck_provider_hdc::{FilePlan, ResolvedArtifact};

impl<'a> JobPlanner<'a> {
    pub(super) fn materialize_keyboard(
        &self,
        request: &OperationRequest,
        descriptor: &CatalogOperation,
        facts: &DeviceFacts,
    ) -> Result<Materialized<'a>, PlanRefusal> {
        let invalid = || {
            refusal(
                "invalidInput",
                "keyboard input requires an intact sensitive keyboard Artifact for this exact binding",
            )
        };
        let artifacts = self.artifacts.ok_or_else(invalid)?;
        let lease = request
            .inputs
            .get("keyboardArtifactLease")
            .and_then(Value::as_str)
            .ok_or_else(invalid)?;
        let leased = self
            .resolve_bound_lease(artifacts, lease, request, facts)
            .map_err(|_| invalid())?;
        if leased.row["privacy"] != "sensitive"
            || leased.row["mediaType"] != arkdeck_contract::KEYBOARD_MEDIA_TYPE
        {
            return Err(invalid());
        }
        let artifact_facts = debug_hap_plan::primary_facts(&leased)?;
        let resolved = [ResolvedArtifact {
            artifact_id: leased.artifact_id,
            sha256: leased.row["sha256"].as_str().ok_or_else(invalid)?.into(),
            path: leased.path,
        }];
        self.refuse_debug_permit(request)?;
        let context = StepContext {
            job_id: "job-authorization-envelope",
            resolved: &resolved,
            library: None,
            helper: None,
        };
        let now = (self.hdc.ok_or_else(internal_failure)?.now)().ok_or_else(internal_failure)?;
        let mut steps = Vec::new();
        for step in &descriptor.steps {
            let mut document = json!({"stepID": step.step_id, "kind": step.kind, "effect": step.effect,
                "cancellation": step.cancellation, "binding": step.binding, "isOptional": step.optional});
            if device_steps::engine_step(&step.kind) {
                document["processKind"] = json!("engine");
            } else {
                let action = device_steps::action_in(
                    step,
                    "input.keyboard@1",
                    &request.inputs,
                    &now,
                    &context,
                )
                .map_err(|_| invalid())?;
                if action.effect() != step.effect {
                    return Err(internal_failure());
                }
                let FilePlan::Process(plan) = action
                    .plan(&step.step_id, Some(&facts.connect_key), &context)
                    .map_err(|_| invalid())?
                else {
                    return Err(internal_failure());
                };
                document["journalArguments"] = device_steps::journal_arguments_in(
                    step,
                    "input.keyboard@1",
                    &request.inputs,
                    &action,
                    &context,
                )
                .ok_or_else(internal_failure)?;
                document["processKind"] = json!("process");
                document["executableSHA256"] = json!("resolved-at-dispatch");
                // The exact plan participates only in this ephemeral hash;
                // audit summaries use the separate Artifact-only arguments.
                document["argumentSummary"] = json!(plan.arguments);
                document["timeoutSeconds"] = json!(plan.timeout.as_secs());
            }
            steps.push(document);
        }
        let document = json!({"operationReference":"input.keyboard@1", "catalogDigest":CATALOG_DIGEST,
            "inputs":request.inputs, "targetID":request.target_id, "stableTargetIdentitySHA256":facts.identity,
            "bindingRevision":facts.binding_revision, "providerID":descriptor.provider, "steps":steps});
        Ok(Materialized {
            _import_use: None,
            _workspace_use: None,
            artifact_facts,
            digest: sha256_hex(&session_json::encode(&document).map_err(|_| internal_failure())?),
            identity: Some(facts.identity.clone()),
            binding_revision: Some(facts.binding_revision),
        })
    }
}
