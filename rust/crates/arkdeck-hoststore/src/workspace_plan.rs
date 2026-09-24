//! Swift `materializeTypedPlanBeforeAuthorization` for the workspace
//! operations this Runtime materializes (TASK-XPA-015, M3): a registered
//! provider that can serve the operation, the Artifact store its product
//! needs, the host-only descriptor and request, the patch Artifact's lease
//! resolved for `workspace.apply-patch@1`, then the step as the provider
//! materializes and lowers it.
//!
//! - `workspace.prepare-isolated-copy@1` is a host workspace action pinned by
//!   the digest of its typed intent, which runs no process.
//! - `workspace.apply-patch@1` and `workspace.revert-patch@1` are one process
//!   each: the patch preset's pinned executable with the exact argv its
//!   dispatch will run, in the project root that argv names. The plan binds
//!   the executable by its digest, and an apply also by its patch Artifact's
//!   facts, which name the capability it is admitted under.
//!
//! Swift materializes every plan for the authorization envelope's Job, so the
//! plan names what that Job would do — the copy it would make, the attempt it
//! would record; a run materializes it again for its own Job. The typed intent
//! of a copy carries the engine clock, so two plans of one request agree only
//! within one clock tick, as Swift's do.
use super::*;
use crate::workspace_composition::LeasedPatch;
use crate::workspace_isolation::DESCRIPTOR;
use crate::workspace_patch::PatchAction;

/// Swift `authorizationPlanJobID`.
pub(crate) const AUTHORIZATION_PLAN_JOB: &str = "job-authorization-envelope";

/// The facts a leased Artifact names, as Swift's materialization records
/// them for the capability.
fn artifact_facts(leased: &LeasedPatch) -> BTreeMap<String, String> {
    BTreeMap::from([
        ("artifactId".to_owned(), leased.artifact_id.clone()),
        ("artifactSha256".to_owned(), leased.sha256.clone()),
        (
            "artifactByteCount".to_owned(),
            leased.byte_count.to_string(),
        ),
    ])
}

impl JobPlanner<'_> {
    /// Swift `resolvedInputArtifact` plus `validateResolvedInputArtifact` for
    /// a workspace patch: its lease resolved, bound to the request's own
    /// target, as the payload file it names.
    pub(crate) fn resolve_patch(
        &self,
        request: &OperationRequest,
    ) -> Result<LeasedPatch, PlanRefusal> {
        let (Some(artifacts), Some(Value::String(lease))) =
            (self.artifacts, request.inputs.get("patchArtifactRef"))
        else {
            return Err(refusal(
                "invalidInput",
                "workspace.apply-patch@1 requires a configured Artifact lease store",
            ));
        };
        let leased = self
            .resolve_lease(artifacts, lease, request)
            .map_err(|reason| {
                refusal(
                    "invalidInput",
                    format!("workspace patch Artifact lease is not resolvable: {reason}"),
                )
            })?;
        let (Some(path), Some(sha256), Some(byte_count)) = (
            leased.path.to_str(),
            leased.row["sha256"].as_str(),
            leased.row["byteCount"].as_u64(),
        ) else {
            return Err(internal_failure());
        };
        Ok(LeasedPatch {
            artifact_id: leased.artifact_id.clone(),
            path: path.to_owned(),
            sha256: sha256.to_owned(),
            byte_count,
        })
    }

    /// The materialized plan document's digest and the Artifact facts it
    /// binds.
    pub(super) fn materialize_workspace(
        &self,
        request: &OperationRequest,
        descriptor: &CatalogOperation,
    ) -> Result<(String, BTreeMap<String, String>), PlanRefusal> {
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
        // The patch lease is resolved before anything else is materialized.
        let leased = if reference == "workspace.apply-patch@1" {
            Some(self.resolve_patch(request)?)
        } else {
            None
        };
        self.refuse_debug_permit(request)?;
        let preflight = |error: String| {
            refusal(
                "invalidInput",
                format!("typed plan preflight failed before authorization: {error}"),
            )
        };
        let mut steps = Vec::new();
        for step in descriptor
            .steps
            .iter()
            .filter(|step| descriptor.step_is_selected(step, &request.inputs))
        {
            let materialized = match (reference.as_str(), step.kind.as_str()) {
                ("workspace.prepare-isolated-copy@1", "prepareWorkspaceIsolation") => {
                    // The provider context's clock, which the typed intent
                    // records.
                    let now = (workspace.now)().ok_or_else(internal_failure)?;
                    let intent = workspace
                        .isolation_action(&reference, &request.inputs, AUTHORIZATION_PLAN_JOB, &now)
                        .map_err(preflight)?;
                    let action = intent.action_sha256().map_err(|_| internal_failure())?;
                    json!({
                        "journalArguments": intent.journal_arguments(),
                        "processKind": "hostWorkspace",
                        "hostManagedDescriptor": format!("{DESCRIPTOR}#action-sha256:{action}"),
                    })
                }
                ("workspace.apply-patch@1", "applyWorkspacePatch")
                | ("workspace.revert-patch@1", "revertWorkspacePatch") => {
                    let action = if let Some(leased) = &leased {
                        let intent = workspace
                            .apply_action(
                                &reference,
                                &request.inputs,
                                AUTHORIZATION_PLAN_JOB,
                                Some(leased),
                            )
                            .map_err(preflight)?;
                        PatchAction::Apply(intent)
                    } else {
                        PatchAction::Revert(
                            workspace
                                .revert_action(&reference, &request.inputs)
                                .map_err(preflight)?,
                        )
                    };
                    workspace.lower(&action).map_err(preflight)?;
                    let journal = match &action {
                        PatchAction::Apply(intent) => intent.journal_arguments(),
                        PatchAction::Revert(_) => json!({
                            "projectRef": request.inputs.get("projectRef"),
                            "patchAttemptRef": request.inputs.get("patchAttemptRef"),
                        }),
                    };
                    let invocation = action.invocation();
                    let mut process = json!({
                        "journalArguments": journal,
                        "processKind": "process",
                        "executableSHA256": invocation.executable_sha256,
                        "workingDirectory": invocation.project_root,
                        "argumentSummary": invocation.arguments,
                        "timeoutSeconds": invocation.timeout_seconds,
                    });
                    if let Some(zero) = &invocation.argument_zero {
                        process["argumentZero"] = json!(zero);
                    }
                    process
                }
                _ => return Err(internal_failure()),
            };
            let mut entry = json!({
                "stepID": step.step_id, "kind": step.kind, "effect": step.effect,
                "cancellation": step.cancellation, "binding": step.binding,
                "isOptional": step.optional,
            });
            if let (Some(entry), Some(fields)) = (entry.as_object_mut(), materialized.as_object()) {
                entry.extend(fields.clone());
            }
            steps.push(entry);
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
        Ok((
            sha256_hex(&bytes),
            leased.as_ref().map(artifact_facts).unwrap_or_default(),
        ))
    }
}
