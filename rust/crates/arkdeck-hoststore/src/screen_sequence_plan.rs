//! File-backed and read-leg `capture.diagnostics@1` and
//! `capture.screen-sequence@1` materialization for `job.plan`, `job.submit`
//! and each mutation of its run, as Swift
//! `materializeTypedPlanBeforeAuthorization` materializes it: every step under
//! the authorization envelope, the legs [`FileAction`] names as the HDC
//! provider names and lowers them — a capture's process or process sequence
//! and its readback, the receive landing under the composition's host receive
//! root, the cleanup's exact removals and readback, the stdout reads and the
//! liveness readback — and the other device steps as every device-bound plan
//! lowers them. A receive's argv names the landing path, so the plan digest,
//! and with it the automatic capability, follows the host receive root; a
//! plan that selects no receive does not depend on one. Nothing is
//! dispatched, issued or consumed.
use super::*;
use crate::device_facts::DeviceFacts;
use crate::operation_catalog::CatalogStep;
use arkdeck_provider_hdc::{FileAction, FilePlan};

const AUTHORIZATION_JOB: &str = "job-authorization-envelope";

impl<'a> JobPlanner<'a> {
    pub(super) fn materialize_file_capture(
        &self,
        request: &OperationRequest,
        descriptor: &CatalogOperation,
        facts: &DeviceFacts,
    ) -> Result<Materialized<'a>, PlanRefusal> {
        self.refuse_debug_permit(request)?;
        let hdc = self.hdc.ok_or_else(internal_failure)?;
        let now = (hdc.now)().ok_or_else(internal_failure)?;
        let mut steps = Vec::new();
        for step in descriptor
            .steps
            .iter()
            .filter(|step| descriptor.step_is_selected(step, &request.inputs))
        {
            steps.push(materialize_step(
                step,
                &descriptor.reference(),
                request,
                facts,
                hdc.receive_root,
                &now,
            )?);
        }
        let document = json!({"operationReference": descriptor.reference(), "catalogDigest": CATALOG_DIGEST,
            "inputs": request.inputs, "targetID": request.target_id,
            "stableTargetIdentitySHA256": facts.identity, "bindingRevision": facts.binding_revision,
            "providerID": descriptor.provider, "steps": steps});
        Ok(Materialized {
            _import_use: None,
            artifact_facts: BTreeMap::new(),
            digest: sha256_hex(&session_json::encode(&document).map_err(|_| internal_failure())?),
            identity: Some(facts.identity.clone()),
            binding_revision: Some(facts.binding_revision),
        })
    }
}

/// One step of the materialized plan document: an engine step, or a device
/// step with its journal arguments and its process or process sequence. A
/// receive needs the composition's host receive root: a composition that
/// names none cannot say where the file would land.
fn materialize_step(
    step: &CatalogStep,
    reference: &str,
    request: &OperationRequest,
    facts: &DeviceFacts,
    receive_root: Option<&Path>,
    now: &str,
) -> Result<Value, PlanRefusal> {
    let mut document = json!({"stepID": step.step_id, "kind": step.kind, "effect": step.effect,
        "cancellation": step.cancellation, "binding": step.binding, "isOptional": step.optional});
    if device_steps::engine_step(&step.kind) {
        document["processKind"] = json!("engine");
        return Ok(document);
    }
    // Swift interpolates the provider's refusal of the request.
    let preflight = |reason: String| {
        refusal(
            "invalidInput",
            format!("typed plan preflight failed before authorization: {reason}"),
        )
    };
    let named = FileAction::for_step(
        &step.step_id,
        &step.kind,
        step.action.as_ref().map(|(_, action)| action.as_str()),
        &request.inputs,
        AUTHORIZATION_JOB,
    )
    .map_err(|error| preflight(device_steps::refusal_detail(error)))?;
    let (plan, arguments) = if let Some(action) = named {
        if action.effect() != step.effect {
            return Err(internal_failure());
        }
        if action.receives() && receive_root.is_none() {
            return Err(refusal(
                "rejected",
                format!(
                    "{reference} is not materialized by the Rust Runtime without a host receive \
                     root"
                ),
            ));
        }
        let arguments = device_steps::file_journal_arguments(&action, step, AUTHORIZATION_JOB)
            .ok_or_else(internal_failure)?;
        (
            action
                .lower_in(&step.step_id, Some(&facts.connect_key), receive_root)
                .map_err(preflight)?,
            arguments,
        )
    } else {
        let action = device_steps::action(step, reference, &request.inputs, now).map_err(
            |error| match error {
                ActionRefusal::Invalid(reason) => preflight(reason),
                ActionRefusal::Unported => refusal(
                    "rejected",
                    format!(
                        "{} of {reference} is not materialized by the Rust Runtime yet",
                        step.step_id
                    ),
                ),
            },
        )?;
        if action.effect() != step.effect {
            return Err(internal_failure());
        }
        let arguments =
            device_steps::journal_arguments_for(step, reference, &request.inputs, &action)
                .ok_or_else(internal_failure)?;
        (
            FilePlan::Process(
                action
                    .lower(&step.step_id, Some(&facts.connect_key))
                    .map_err(preflight)?,
            ),
            arguments,
        )
    };
    document["journalArguments"] = arguments;
    // Swift lowers the executable's identity at dispatch.
    document["executableSHA256"] = json!("resolved-at-dispatch");
    match plan {
        // A receive is one process; its landing is the dispatcher's to prepare
        // and inspect, and only its argv names it here.
        FilePlan::Process(plan) | FilePlan::Receive { process: plan, .. } => {
            document["processKind"] = json!("process");
            document["argumentSummary"] = json!(plan.arguments);
            document["timeoutSeconds"] = json!(plan.timeout.as_secs());
        }
        FilePlan::Sequence(invocations) => {
            document["processKind"] = json!("processSequence");
            document["processInvocations"] = invocations
                .iter()
                .map(|invocation| {
                    json!({"arguments": invocation.arguments,
                        "timeoutSeconds": invocation.timeout.as_secs(),
                        "continueAfterNonZero": invocation.continue_after_non_zero})
                })
                .collect();
        }
    }
    Ok(document)
}
