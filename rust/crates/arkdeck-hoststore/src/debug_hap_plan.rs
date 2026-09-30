//! HAP materialization for `job.plan`, `job.submit` and every mutation of its
//! run. Nothing here dispatches, issues or consumes a capability; admission
//! issues one from the primary Artifact facts this returns. Mirrors
//! RuntimeJobEngine's input binding, authorization-envelope lowering, and
//! failure-only compensations, while retaining the enclosing Import hold.
use super::*;
use crate::device_facts::DeviceFacts;
use crate::operation_catalog::CatalogStep;
use arkdeck_provider_hdc::{FileActionError, FilePlan, HapAction, ResolvedArtifact};

const AUTHORIZATION_JOB: &str = "job-authorization-envelope";

impl<'a> JobPlanner<'a> {
    pub(super) fn materialize_hap(
        &self,
        request: &OperationRequest,
        descriptor: &CatalogOperation,
        facts: &DeviceFacts,
    ) -> Result<Materialized<'a>, PlanRefusal> {
        let (resolved, artifact_facts) = self.resolve_hap_leases(request, descriptor, facts)?;
        self.refuse_debug_permit(request)?;
        let now = (self.hdc.ok_or_else(internal_failure)?.now)().ok_or_else(internal_failure)?;
        Ok(Materialized {
            _import_use: None,
            _workspace_use: None,
            artifact_facts,
            digest: hap_plan_digest(request, descriptor, facts, &resolved, &now)?,
            identity: Some(facts.identity.clone()),
            binding_revision: Some(facts.binding_revision),
        })
    }
    /// Swift `resolveLease`, then `validateArtifactBinding` for a device-bound
    /// input: the lease's Artifact must name the request's target and binding
    /// revision and the identity the Target's facts carry. A refusal is the
    /// error Swift interpolates.
    pub(super) fn resolve_bound_lease(
        &self,
        artifacts: &ArtifactReadStore,
        lease: &str,
        request: &OperationRequest,
        facts: &DeviceFacts,
    ) -> Result<LeasedArtifact, String> {
        let leased = self.resolve_lease(artifacts, lease, request)?;
        let binding = &leased.row["bindingSnapshot"];
        if binding["targetID"] != request.target_id.as_str()
            || binding["bindingRevision"].as_i64() != request.expected_binding_revision
            || binding["stableIdentitySHA256"] != facts.identity.as_str()
        {
            return Err(format!(
                "rejected(ArkDeckCore.RuntimeOperationErrorCode.invalidInput, {})",
                swift_string(
                    "Artifact lease target/binding/identity does not match the materialized request"
                )
            ));
        }
        Ok(leased)
    }

    fn resolve_hap_leases(
        &self,
        request: &OperationRequest,
        descriptor: &CatalogOperation,
        facts: &DeviceFacts,
    ) -> Result<(Vec<ResolvedArtifact>, BTreeMap<String, String>), PlanRefusal> {
        let reference = descriptor.reference();
        if reference != "debug.hap@1" {
            return Err(internal_failure());
        }
        let (Some(artifacts), Some(Value::String(entry))) =
            (self.artifacts, request.inputs.get("hapArtifactLease"))
        else {
            return Err(refusal(
                "invalidInput",
                format!("{reference} requires a configured Artifact lease store"),
            ));
        };
        let bound = |lease: &str| self.resolve_bound_lease(artifacts, lease, request, facts);
        let resolved_artifact = |leased: LeasedArtifact| {
            let sha256 = leased.row["sha256"].as_str().unwrap_or_default().to_owned();
            ResolvedArtifact {
                artifact_id: leased.artifact_id,
                sha256,
                path: leased.path,
            }
        };
        let entry = bound(entry).map_err(|reason| {
            refusal(
                "invalidInput",
                format!("HAP Artifact lease is not resolvable: {reason}"),
            )
        })?;
        // The durable owner validates metadata and payload before this point.
        // Preserve Swift String(byteCount), never a JSON number or caller fact.
        let artifact_facts = primary_facts(&entry)?;
        let mut resolved = vec![resolved_artifact(entry)];
        let additional = match request.inputs.get("additionalHapArtifactLeases") {
            Some(Value::Array(leases)) => leases.as_slice(),
            _ => &[],
        };
        for value in additional {
            let Some(lease) = value.as_str() else {
                return Err(refusal(
                    "invalidInput",
                    "additionalHapArtifactLeases must be artifact leases",
                ));
            };
            let leased = bound(lease).map_err(|reason| {
                refusal(
                    "invalidInput",
                    format!("additional HAP Artifact lease is not resolvable: {reason}"),
                )
            })?;
            resolved.push(resolved_artifact(leased));
        }
        Ok((resolved, artifact_facts))
    }
}

/// Swift `materializeTypedPlanBeforeAuthorization`'s digest of a HAP plan:
/// the selected steps, then the failure-only compensations, over the packages
/// as the engine resolved them. A send names its package's host path, so the
/// digest is Swift's for the same request, facts, packages and paths.
fn hap_plan_digest(
    request: &OperationRequest,
    descriptor: &CatalogOperation,
    facts: &DeviceFacts,
    resolved: &[ResolvedArtifact],
    now: &str,
) -> Result<String, PlanRefusal> {
    let mut steps = Vec::new();
    for step in descriptor
        .steps
        .iter()
        .filter(|step| descriptor.step_is_selected(step, &request.inputs))
    {
        steps.push(materialize_step(
            step,
            &step.step_id,
            request,
            facts,
            resolved,
            now,
        )?);
    }
    // Reverse source order: start, install, send. Stop is still present
    // when the successful plan intentionally leaves the ability running.
    for step in compensations(descriptor, &request.inputs)? {
        let id = &step.step_id;
        steps.push(materialize_step(
            step,
            &format!("compensation-{id}"),
            request,
            facts,
            resolved,
            now,
        )?);
    }
    let document = json!({"operationReference": descriptor.reference(), "catalogDigest": CATALOG_DIGEST,
        "inputs": request.inputs, "targetID": request.target_id,
        "stableTargetIdentitySHA256": facts.identity, "bindingRevision": facts.binding_revision,
        "providerID": descriptor.provider, "steps": steps});
    Ok(sha256_hex(
        &session_json::encode(&document).map_err(|_| internal_failure())?,
    ))
}

fn materialize_step(
    step: &CatalogStep,
    row: &str,
    request: &OperationRequest,
    facts: &DeviceFacts,
    resolved: &[ResolvedArtifact],
    now: &str,
) -> Result<Value, PlanRefusal> {
    let mut document = json!({"stepID": row, "kind": step.kind, "effect": step.effect,
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
    let remote = step
        .action
        .as_ref()
        .filter(|(catalog, _)| catalog == "arkdeck-remote-operations")
        .map(|(_, action)| action.as_str());
    let hap = HapAction::for_step(
        &step.step_id,
        &step.kind,
        remote,
        &request.inputs,
        AUTHORIZATION_JOB,
        resolved,
    )
    .map_err(|error| {
        preflight(match error {
            FileActionError::Unsupported(detail) => detail,
            FileActionError::Request(error) => error.to_string(),
        })
    })?;
    let (plan, arguments) = if let Some(action) = hap {
        if action.effect() != step.effect {
            return Err(internal_failure());
        }
        let arguments = device_steps::hap_journal_arguments(
            &action,
            step,
            &request.inputs,
            AUTHORIZATION_JOB,
            resolved,
        )
        .ok_or_else(internal_failure)?;
        (
            action
                .lower(&step.step_id, Some(&facts.connect_key), resolved)
                .map_err(preflight)?,
            arguments,
        )
    } else {
        let action =
            device_steps::action(step, "debug.hap@1", &request.inputs, now).map_err(|error| {
                match error {
                    ActionRefusal::Invalid(reason) => preflight(reason),
                    ActionRefusal::Unported => refusal(
                        "rejected",
                        format!(
                            "{} of debug.hap@1 is not materialized by the Rust Runtime yet",
                            step.step_id
                        ),
                    ),
                }
            })?;
        if action.effect() != step.effect {
            return Err(internal_failure());
        }
        let arguments = device_steps::journal_arguments(step, &request.inputs, &action)
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
    document["executableSHA256"] = json!("resolved-at-dispatch");
    match plan {
        FilePlan::Process(plan) => {
            document["processKind"] = json!("process");
            document["argumentSummary"] = json!(plan.arguments);
            document["timeoutSeconds"] = json!(plan.timeout.as_secs());
        }
        FilePlan::Sequence(invocations) => {
            document["processKind"] = json!("processSequence");
            document["processInvocations"] = invocations
                .iter()
                .map(|invocation| {
                    json!({
                "arguments": invocation.arguments, "timeoutSeconds": invocation.timeout.as_secs(),
                "continueAfterNonZero": invocation.continue_after_non_zero})
                })
                .collect();
        }
        FilePlan::Receive { .. } => return Err(internal_failure()),
    }
    Ok(document)
}

pub(super) fn compensations<'a>(
    descriptor: &'a CatalogOperation,
    inputs: &Map<String, Value>,
) -> Result<Vec<&'a CatalogStep>, PlanRefusal> {
    crate::job_step_digest::hap_compensations(descriptor, inputs).ok_or_else(internal_failure)
}

/// Swift `MaterializedAdmission.artifactFacts` of a resolved input: its
/// identity, digest and `String(byteCount)` as its owner validated them.
pub(super) fn primary_facts(
    entry: &LeasedArtifact,
) -> Result<BTreeMap<String, String>, PlanRefusal> {
    Ok(BTreeMap::from([
        ("artifactId".into(), entry.artifact_id.clone()),
        (
            "artifactSha256".into(),
            entry.row["sha256"]
                .as_str()
                .ok_or_else(internal_failure)?
                .to_owned(),
        ),
        (
            "artifactByteCount".into(),
            entry.row["byteCount"]
                .as_u64()
                .ok_or_else(internal_failure)?
                .to_string(),
        ),
    ]))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::capability_store::{CapabilityQuery, Effect};
    use std::path::PathBuf;
    #[test]
    fn owner_facts_use_swift_strings_and_reproduce_native_policy_identity() {
        let index: Value = serde_json::from_slice(include_bytes!(
            "../../../tests/fixtures/debug-hap/artifacts/job-input-hap/index.json"
        ))
        .unwrap();
        let row = index["artifacts"]
            .as_array()
            .unwrap()
            .iter()
            .find(|r| r["name"] == "entry.hap")
            .unwrap()
            .clone();
        let mut entry = LeasedArtifact {
            job_id: "job-input-hap".into(),
            artifact_id: row["artifactID"].as_str().unwrap().into(),
            row,
            path: PathBuf::from("/unused-owner-test"),
        };
        let facts = primary_facts(&entry).unwrap();
        assert_eq!(facts.len(), 3);
        assert_eq!(facts["artifactByteCount"], "24");
        let encoded = session_json::encode(&serde_json::to_value(&facts).unwrap()).unwrap();
        let expected = format!(
            "{{\"artifactByteCount\":\"24\",\"artifactId\":\"{}\",\"artifactSha256\":\"{}\"}}",
            entry.artifact_id,
            entry.row["sha256"].as_str().unwrap()
        );
        assert_eq!(encoded, expected.as_bytes());
        let record: Value = serde_json::from_slice(include_bytes!("../../../tests/fixtures/debug-hap/store/jobs/job-e79d1b4e261f4a13d0bfb58a97fbf163/job-record.json")).unwrap();
        let mut query = CapabilityQuery {
            operation_id: "debug.hap".into(),
            operation_version: Some(1),
            effect: Effect::DeviceMutation,
            target_stable_identity_sha256: record["materializedStableTargetIdentitySHA256"]
                .as_str()
                .map(str::to_owned),
            target_binding_revision: record["materializedBindingRevision"].as_i64(),
            plan_digest: record["materializedPlanDigest"].as_str().map(str::to_owned),
            inputs: record["request"]["inputs"].as_object().unwrap().clone(),
            artifact_facts: facts,
            workspace_identity_sha256: None,
            workspace_revision: None,
            workspace_file_scopes_digest: None,
        };
        let policy = crate::capability_policy::policy_fingerprint(&query, false);
        assert!(
            record["request"]["authorization"]["capabilityId"]
                .as_str()
                .unwrap()
                .starts_with(&format!("CAP-RT-POLICY-{}-G", &policy[..40]))
        );
        for field in ["artifactId", "artifactSha256", "artifactByteCount"] {
            let original = query.artifact_facts[field].clone();
            query
                .artifact_facts
                .insert(field.into(), "different".into());
            assert_ne!(
                crate::capability_policy::policy_fingerprint(&query, false),
                policy
            );
            query.artifact_facts.insert(field.into(), original);
        }
        query.artifact_facts.clear();
        assert_ne!(
            crate::capability_policy::policy_fingerprint(&query, false),
            policy
        );
        entry.row["byteCount"] = json!("24");
        assert!(
            primary_facts(&entry).is_err(),
            "metadata count must be an integer, never an injected string"
        );
    }
    /// Every plan the Swift debug-hap oracle answered, materialized again from
    /// its request with its packages at the oracle's root as Swift spelled
    /// their paths (`HDCOracleFake`'s, which each send names): the digest is
    /// Swift's byte for byte on every host, since a path keeps the spelling it
    /// is given. A host whose Artifact root is spelled otherwise (a Windows
    /// root) digests the same document with its own paths in the sends.
    #[test]
    fn the_recorded_plans_digest_as_swift_s_over_the_oracle_s_package_paths() {
        let fixture =
            std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/fixtures/debug-hap");
        let read = |path: std::path::PathBuf| -> Value {
            serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap()
        };
        let cases = read(fixture.join("cases.json"));
        let targets = read(fixture.join("targets-state").join("targets.json"));
        let target = &targets["targets"][0];
        let descriptor = CatalogOperation::lookup("debug.hap", Some(1)).unwrap();
        let resolve = |lease: &str| {
            let mut parts = lease.split(':');
            let (Some("lease-v1"), Some(job), Some(artifact), None) =
                (parts.next(), parts.next(), parts.next(), parts.next())
            else {
                panic!("{lease} is not a lease");
            };
            let index = read(fixture.join("artifacts").join(job).join("index.json"));
            let row = index["artifacts"]
                .as_array()
                .unwrap()
                .iter()
                .find(|row| row["artifactID"] == artifact)
                .unwrap();
            ResolvedArtifact {
                artifact_id: artifact.into(),
                sha256: row["sha256"].as_str().unwrap().into(),
                path: PathBuf::from(format!(
                    "/private/tmp/arkdeck-hdc-oracle/artifacts/{job}/{artifact}"
                )),
            }
        };
        let mut replayed = 0;
        for exchange in cases["exchanges"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|row| row["method"] == "job.plan" && row["answer"]["ok"] == true)
        {
            let request = OperationRequest::decode(
                exchange["params"]["requestJson"]
                    .as_str()
                    .unwrap()
                    .as_bytes(),
            )
            .unwrap();
            let facts = DeviceFacts {
                target_id: request.target_id.clone(),
                binding_revision: target["bindingRevision"].as_i64().unwrap(),
                tool_version: target["toolVersion"].as_str().unwrap().into(),
                tool_sha256: String::new(),
                connect_key: target["connectKey"].as_str().unwrap().into(),
                identity: target["stablePhysicalIdentitySHA256"]
                    .as_str()
                    .unwrap()
                    .into(),
            };
            let mut resolved = vec![resolve(
                request.inputs["hapArtifactLease"].as_str().unwrap(),
            )];
            if let Some(Value::Array(additional)) =
                request.inputs.get("additionalHapArtifactLeases")
            {
                resolved.extend(
                    additional
                        .iter()
                        .map(|lease| resolve(lease.as_str().unwrap())),
                );
            }
            assert_eq!(
                hap_plan_digest(
                    &request,
                    descriptor,
                    &facts,
                    &resolved,
                    "2026-09-14T00:00:00Z"
                )
                .unwrap(),
                exchange["answer"]["result"]["materializedPlanDigest"]
                    .as_str()
                    .unwrap(),
                "{}",
                exchange["name"]
            );
            replayed += 1;
        }
        assert_eq!(replayed, 10);
    }
    #[test]
    fn native_consumed_step_digest_includes_ordered_compensations() {
        let record: Value = serde_json::from_slice(include_bytes!("../../../tests/fixtures/debug-hap/store/jobs/job-e79d1b4e261f4a13d0bfb58a97fbf163/job-record.json")).unwrap();
        let descriptor = CatalogOperation::lookup("debug.hap", Some(1)).unwrap();
        let mut inputs = record["request"]["inputs"].as_object().unwrap().clone();
        assert_eq!(
            step_set_digest(descriptor, &inputs).unwrap(),
            record["admissionEvidence"]["runtimeCapabilityCorrelation"]["stepSetDigestSHA256"]
        );
        assert_eq!(
            compensations(descriptor, &inputs)
                .unwrap()
                .iter()
                .map(|s| s.step_id.as_str())
                .collect::<Vec<_>>(),
            [
                "stop-ability",
                "cleanup-uninstall",
                "cleanup-remote-staging"
            ]
        );
        inputs.insert("cleanupPolicy".into(), json!("retain"));
        inputs.insert("postRunAbilityState".into(), json!("running"));
        assert_eq!(
            compensations(descriptor, &inputs)
                .unwrap()
                .iter()
                .map(|s| s.step_id.as_str())
                .collect::<Vec<_>>(),
            ["stop-ability", "cleanup-remote-staging"]
        );
    }
}
