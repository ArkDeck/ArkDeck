//! Native library materialization for `job.plan` and `job.submit`: Swift
//! `materializeTypedPlanBeforeAuthorization` for
//! `deploy.native-library.app-owned@1`. Once the Target's facts hold, the
//! library's lease is resolved and bound to them as a HAP's package is; its
//! bytes are read as Swift's provider reads them, and each step's action is
//! named from them, which verifies them as the expected ABI's code-signed ELF
//! still the byte count the lease records. The plan then holds the rollback a
//! failure past the publish applies. Nothing here dispatches, issues or
//! consumes a capability: admission issues one from the library's facts this
//! returns.
use super::*;
use crate::device_facts::DeviceFacts;
use crate::device_steps::{LeasedLibrary, StepContext};
use crate::operation_catalog::CatalogStep;
use arkdeck_provider_hdc::{FilePlan, MAXIMUM_LIBRARY_BYTES, ResolvedArtifact};
use std::io::Read;

const AUTHORIZATION_JOB: &str = "job-authorization-envelope";

/// A leased native library's bytes, read no further than one byte past what
/// Swift's validator accepts: a library that large is refused either way.
pub(crate) fn read_library(path: &Path) -> io::Result<Vec<u8>> {
    let mut bytes = Vec::new();
    std::fs::File::open(path)?
        .take(MAXIMUM_LIBRARY_BYTES as u64 + 1)
        .read_to_end(&mut bytes)?;
    Ok(bytes)
}

impl<'a> JobPlanner<'a> {
    pub(super) fn materialize_native(
        &self,
        request: &OperationRequest,
        descriptor: &CatalogOperation,
        facts: &DeviceFacts,
    ) -> Result<Materialized<'a>, PlanRefusal> {
        let hdc = self.hdc.ok_or_else(internal_failure)?;
        let (resolved, artifact_facts, byte_count) = self.resolve_native_lease(request, facts)?;
        self.refuse_debug_permit(request)?;
        // Swift's provider reads the library as it names each step's action.
        let bytes = read_library(&resolved.path).map_err(|error| {
            refusal(
                "invalidInput",
                format!(
                    "typed plan preflight failed before authorization: native library Artifact \
                     is unreadable: {error}"
                ),
            )
        })?;
        let library = LeasedLibrary { bytes, byte_count };
        let resolved = [resolved];
        let context = StepContext {
            job_id: AUTHORIZATION_JOB,
            resolved: &resolved,
            library: Some(&library),
            helper: hdc.code_sign_helper,
        };
        let now = (hdc.now)().ok_or_else(internal_failure)?;
        let reference = descriptor.reference();
        let mut steps = Vec::new();
        for step in descriptor
            .steps
            .iter()
            .filter(|step| descriptor.step_is_selected(step, &request.inputs))
        {
            steps.push(materialize_step(
                step, &reference, request, facts, &context, &now,
            )?);
        }
        // The rollback a failure past the publish applies, after every
        // selected step.
        steps.push(materialize_step(
            &device_steps::native_rollback(),
            &reference,
            request,
            facts,
            &context,
            &now,
        )?);
        let document = json!({"operationReference": reference, "catalogDigest": CATALOG_DIGEST,
            "inputs": request.inputs, "targetID": request.target_id,
            "stableTargetIdentitySHA256": facts.identity, "bindingRevision": facts.binding_revision,
            "providerID": descriptor.provider, "steps": steps});
        Ok(Materialized {
            _import_use: None,
            artifact_facts,
            digest: sha256_hex(&session_json::encode(&document).map_err(|_| internal_failure())?),
            identity: Some(facts.identity.clone()),
            binding_revision: Some(facts.binding_revision),
        })
    }

    /// Swift's input Artifact of a native deployment: the library's lease
    /// resolved and bound to the materialized Target, the facts it is
    /// authorized by, and the byte count its lease records.
    fn resolve_native_lease(
        &self,
        request: &OperationRequest,
        facts: &DeviceFacts,
    ) -> Result<(ResolvedArtifact, BTreeMap<String, String>, i64), PlanRefusal> {
        let (Some(artifacts), Some(Value::String(lease))) =
            (self.artifacts, request.inputs.get("libraryArtifactLease"))
        else {
            return Err(refusal(
                "invalidInput",
                format!(
                    "{} requires a configured Artifact lease store",
                    device_steps::NATIVE
                ),
            ));
        };
        let leased = self
            .resolve_bound_lease(artifacts, lease, request, facts)
            .map_err(|reason| {
                refusal(
                    "invalidInput",
                    format!("native library Artifact lease is not resolvable: {reason}"),
                )
            })?;
        let artifact_facts = debug_hap_plan::primary_facts(&leased)?;
        let byte_count = leased.row["byteCount"]
            .as_i64()
            .ok_or_else(internal_failure)?;
        Ok((resolved_input(leased)?, artifact_facts, byte_count))
    }
}

/// A resolved input as its provider is given it: its identity, its digest
/// and where its bytes are.
fn resolved_input(leased: LeasedArtifact) -> Result<ResolvedArtifact, PlanRefusal> {
    let sha256 = leased.row["sha256"]
        .as_str()
        .ok_or_else(internal_failure)?
        .to_owned();
    Ok(ResolvedArtifact {
        artifact_id: leased.artifact_id,
        sha256,
        path: leased.path,
    })
}

/// One step of the plan document: the engine's own, or the provider's
/// action lowered to its exact process sequence with Swift's journal
/// arguments.
fn materialize_step(
    step: &CatalogStep,
    reference: &str,
    request: &OperationRequest,
    facts: &DeviceFacts,
    context: &StepContext<'_>,
    now: &str,
) -> Result<Value, PlanRefusal> {
    let mut document = json!({"stepID": step.step_id, "kind": step.kind, "effect": step.effect,
        "cancellation": step.cancellation, "binding": step.binding, "isOptional": step.optional});
    if device_steps::engine_step(&step.kind) {
        document["processKind"] = json!("engine");
        return Ok(document);
    }
    let preflight = |reason: String| {
        refusal(
            "invalidInput",
            format!("typed plan preflight failed before authorization: {reason}"),
        )
    };
    let action = device_steps::action_in(step, reference, &request.inputs, now, context).map_err(
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
    let FilePlan::Sequence(invocations) = action
        .plan(&step.step_id, Some(&facts.connect_key), context)
        .map_err(preflight)?
    else {
        return Err(internal_failure());
    };
    document["journalArguments"] =
        device_steps::journal_arguments_in(step, reference, &request.inputs, &action, context)
            .ok_or_else(internal_failure)?;
    document["processKind"] = json!("processSequence");
    document["executableSHA256"] = json!("resolved-at-dispatch");
    document["processInvocations"] = invocations
        .iter()
        .map(|invocation| {
            json!({"arguments": invocation.arguments,
                "timeoutSeconds": invocation.timeout.as_secs(),
                "continueAfterNonZero": invocation.continue_after_non_zero})
        })
        .collect();
    Ok(document)
}
