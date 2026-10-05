//! Actual host workspace mutations retain their consumed Runtime authority.
//! This projection never grants authority, dispatches a child, or rewrites
//! the historical Job: every host exception is an exact current Catalog step.
use super::*;
use crate::operation_catalog::CatalogOperation;
use crate::operation_request::OperationRequest;

pub(crate) fn workspace_mutation(
    reference: &str,
) -> Option<(&'static str, &'static str, &'static str)> {
    Some(match reference {
        "workspace.apply-patch@1" => ("apply-patch", "applyWorkspacePatch", "atSafeBoundary"),
        "workspace.revert-patch@1" => ("revert-patch", "revertWorkspacePatch", "atSafeBoundary"),
        "workspace.build-openharmony@1" => {
            ("build-project", "buildWorkspaceOpenHarmony", "immediate")
        }
        "workspace.create-checkpoint@1" => (
            "create-checkpoint",
            "createWorkspaceCheckpoint",
            "atSafeBoundary",
        ),
        "workspace.run-tests@1" => ("run-tests", "runWorkspaceTests", "immediate"),
        _ => return None,
    })
}

pub(super) struct WorkspaceContext {
    pub(super) target: Value,
    pub(super) toolchain: Value,
    pub(super) authority: Value,
}

pub(super) fn workspace_context(
    record: &JobRecord,
    events: &[Value],
    replay: &ReplayFacts,
    mode: &str,
    context: Option<WorkspaceSessionContext<'_>>,
) -> Result<Option<WorkspaceContext>, Stop> {
    let Some((id, kind, cancellation)) = workspace_mutation(record.operation()) else {
        return Ok(None);
    };
    let refused = || {
        stop(
            "sourceIntegrityFailed",
            "host workspace Session lacks matching original plan, Journal, consumption or tool provenance",
        )
    };
    if record.provider() != "workspace"
        || record.catalog_digest() != arkdeck_contract::CATALOG_DIGEST
        || mode != "execute"
        || !["succeeded", "failed", "cancelled"].contains(&record.state.as_str())
        || record.outcome_unknown()
        || record.residues().is_some_and(|count| count != 0)
        || record.actual_effect() != Some("deviceMutation")
        || record.evidence_fields()["actualStepKinds"] != json!([kind])
        || record.materialized_binding().is_some()
        || record.materialized_identity().is_some()
        || record.evidence_observation().is_some()
        || record.recovery_action().is_some()
        || record.recovery_step().is_some()
        || record.recovery_intent().is_some()
        || replay.has_torn_tail
        || replay.current_state.as_deref() != Some(&record.state)
        || !replay.outstanding_intents.is_empty()
        || !replay.unknown_outcomes.is_empty()
        || replay.requires_unknown_finalized_outcome
        || events.iter().any(|event| {
            event["jobId"] != record.job_id
                || event["sessionId"] != format!("session-{}", record.job_id)
                || !matches!(
                    event["kind"].as_str(),
                    Some(
                        "jobCreated"
                            | "stateTransition"
                            | "stepIntent"
                            | "stepOutcome"
                            | "finalized"
                    )
                )
        })
    {
        return Err(refused());
    }
    let bytes = crate::session_json::encode(&record.request).map_err(|_| refused())?;
    let request = OperationRequest::decode(&bytes).map_err(|_| refused())?;
    let descriptor = CatalogOperation::lookup(&request.operation_id, request.operation_version)
        .filter(|descriptor| {
            descriptor.reference() == record.operation()
                && descriptor.provider == "workspace"
                && descriptor.steps.len() == 1
                && descriptor.steps[0].step_id == id
                && descriptor.steps[0].kind == kind
                && descriptor.steps[0].effect == "deviceMutation"
                && descriptor.steps[0].cancellation == cancellation
                && descriptor.steps[0].binding == "none"
        })
        .ok_or_else(refused)?;
    if request.expected_binding_revision.is_some() {
        return Err(refused());
    }
    let context = context.ok_or_else(refused)?;
    let rematerialized;
    let materialization = match context.materialization {
        Some(original) => original,
        None => {
            rematerialized = context
                .planner
                .workspace_materialization(&request, descriptor)
                .map_err(|_| refused())?;
            &rematerialized
        }
    };
    let plan = materialization.digest().map_err(|_| refused())?;
    let admission = record.admission().ok_or_else(refused)?;
    let correlation = &admission["runtimeCapabilityCorrelation"];
    let step_set =
        crate::job_step_digest::step_set_digest(descriptor, &request.inputs).ok_or_else(refused)?;
    let seconds = crate::format_time::format_timestamp_seconds;
    let admitted = admission["admittedAtUTC"]
        .as_str()
        .and_then(seconds)
        .ok_or_else(refused)?;
    let valid_until = admission["validUntilUTC"]
        .as_str()
        .and_then(seconds)
        .ok_or_else(refused)?;
    let created = seconds(record.created()).ok_or_else(refused)?;
    let completed = record.finished_at().and_then(seconds).ok_or_else(refused)?;
    if admission["kind"] != "runtimeCapability"
        || admission["reference"].as_str() != request.capability_id.as_deref()
        || !admission["reference"]
            .as_str()
            .is_some_and(|s| !s.is_empty())
        || !admission["completeOverwriteRecovery"].is_null()
        || created > admitted
        || admitted > completed
        || admitted >= valid_until
        || !admission["consumptionFingerprintSHA256"]
            .as_str()
            .is_some_and(lowercase_sha256)
        || correlation["reservationID"] != request.idempotency_key
        || !correlation["useOrdinal"].as_u64().is_some_and(|n| n > 0)
        || correlation["planDigestSHA256"].as_str() != Some(plan.as_str())
        || record.materialized_plan() != Some(plan.as_str())
        || correlation["stepSetDigestSHA256"].as_str() != Some(step_set.as_str())
        || correlation["targetBindingDigestSHA256"] != sha256_hex(b"-\n-")
    {
        return Err(refused());
    }
    let artifact = materialization.artifact_facts.get("artifactSha256");
    if match artifact {
        Some(digest) => correlation["artifactSHA256"].as_str() != Some(digest.as_str()),
        None => !correlation["artifactSHA256"].is_null(),
    } {
        return Err(refused());
    }
    let selected = materialization.document["steps"]
        .as_array()
        .filter(|steps| steps.len() == 1)
        .ok_or_else(refused)?;
    let process = &selected[0];
    if process["processKind"] != "process" || process["stepID"] != id || process["kind"] != kind {
        return Err(refused());
    }
    let mut arguments = process["journalArguments"].clone();
    // Authorization materialization uses its fixed envelope Job id; the
    // dispatched apply intent names the actual Job's own deterministic attempt.
    if record.operation() == "workspace.apply-patch@1" {
        let project = request.inputs["projectRef"].as_str().ok_or_else(refused)?;
        let digest = artifact.ok_or_else(refused)?;
        let actual = sha256_hex(format!("{}\n{digest}\n{project}", record.job_id).as_bytes());
        arguments["patchAttemptRef"] = json!(format!("patch-{}", &actual[..32]));
    }
    let intents: Vec<_> = events
        .iter()
        .filter(|event| event["kind"] == "stepIntent")
        .collect();
    let outcomes: Vec<_> = events
        .iter()
        .filter(|event| event["kind"] == "stepOutcome")
        .collect();
    if intents.len() != 1 || outcomes.len() != 1 {
        return Err(refused());
    }
    let intent = intents[0];
    let outcome = outcomes[0];
    if intent["stepId"] != id
        || intent["attempt"] != 1
        || !intent["bindingRevision"].is_null()
        || intent["payload"]["target"]
            != json!({"targetId": request.target_id,
            "scope": "host", "connectKey": null, "identitySnapshotHash": null})
        || intent["payload"]["step"]
            != json!({"id": id, "kind": kind,
            "effect": "deviceMutation", "cancellation": cancellation,
            "bindingRequirement": "none", "compensationDescriptors": [], "arguments": arguments})
        || outcome["stepId"] != id
        || outcome["attempt"] != 1
        || outcome["payload"]["correlatesToIntentEventId"] != intent["eventId"]
        || outcome["payload"]["outcomeCertainty"] != "confirmed"
        || !matches!(
            outcome["payload"]["result"].as_str(),
            Some("succeeded" | "failed")
        )
        || intent["timestamp"]
            .as_str()
            .and_then(seconds)
            .is_none_or(|at| at < admitted || at > completed)
        || outcome["timestamp"]
            .as_str()
            .and_then(seconds)
            .is_none_or(|at| at < admitted || at > completed)
    {
        return Err(refused());
    }
    let path = materialization
        .executable_path
        .as_deref()
        .ok_or_else(refused)?;
    let digest = process["executableSHA256"]
        .as_str()
        .filter(|digest| lowercase_sha256(digest))
        .ok_or_else(refused)?;
    let tool = arkdeck_platform::VerifiedTool::open(path, digest).map_err(|_| refused())?;
    let version = tool_version(&tool).map_err(|_| refused())?;
    // No device observation is invented for an Artifact's target association.
    // The unchanged request target still belongs to the consumed plan and Job.
    Ok(Some(WorkspaceContext {
        target: json!({"kind": "host", "connectKey": null, "transport": "host",
            "identitySnapshot": {"workspaceScope": request.target_id,
                "projectRef": request.inputs["projectRef"], "providerId": "workspace",
                "catalogDigest": record.catalog_digest()}}),
        toolchain: json!({"kind": "hostTool", "providerIdentity": "workspace",
            "profileIdentifier": record.operation(), "reportedVersion": version, "sha256": digest}),
        authority: json!({"kind": "runtimeCapability", "reference": admission["reference"],
            "admittedAtUtc": admission["admittedAtUTC"], "validUntilUtc": admission["validUntilUTC"],
            "consumptionFingerprintSha256": admission["consumptionFingerprintSHA256"],
            "reservationId": correlation["reservationID"], "useOrdinal": correlation["useOrdinal"],
            "planDigest": correlation["planDigestSHA256"], "stepSetDigest": correlation["stepSetDigestSHA256"],
            "targetBindingDigest": correlation["targetBindingDigestSHA256"], "artifactDigest": correlation["artifactSHA256"]}),
    }))
}

#[cfg(windows)]
fn tool_version(tool: &arkdeck_platform::VerifiedTool) -> io::Result<String> {
    let before = tool.launch_identity()?;
    let current = arkdeck_platform::host_resolved_path(&std::env::current_exe()?)
        .ok_or_else(|| io::Error::other("current Runtime image is unresolved"))?;
    let version = if arkdeck_platform::host_resolved_path(tool.path()).as_ref() == Some(&current) {
        let own = arkdeck_platform::VerifiedTool::open(&current, tool.sha256())?;
        if own.launch_identity()? != before {
            return Err(io::Error::other("Runtime image identity differs"));
        }
        env!("CARGO_PKG_VERSION").to_owned()
    } else {
        tool.file_version()?
    };
    if tool.launch_identity()? != before {
        return Err(io::Error::other("workspace tool identity changed"));
    }
    Ok(version)
}

// This increment never launches a version probe on Unix. Without an existing
// version source the original host mutation remains truthfully unpublishable.
#[cfg(target_os = "macos")]
fn tool_version(_tool: &arkdeck_platform::VerifiedTool) -> io::Result<String> {
    Err(io::Error::other(
        "host workspace tool has no retained version source",
    ))
}

#[cfg(all(test, windows))]
#[path = "session_workspace_publication_tests.rs"]
mod tests;
