//! Plan-only HAP materialization. No dispatch, capability issue or consumption.
//! Mirrors RuntimeJobEngine's input binding, authorization-envelope lowering,
//! and failure-only compensations, while retaining the enclosing Import hold.
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
                &resolved,
                &now,
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
                &resolved,
                &now,
            )?);
        }
        let document = json!({"operationReference": descriptor.reference(), "catalogDigest": CATALOG_DIGEST,
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
        let bound = |lease: &str| -> Result<LeasedArtifact, String> {
            let leased = self.resolve_lease(artifacts, lease, request)?;
            let binding = &leased.row["bindingSnapshot"];
            if binding["targetID"] != request.target_id.as_str()
                || binding["bindingRevision"].as_i64() != request.expected_binding_revision
                || binding["stableIdentitySHA256"] != facts.identity.as_str()
            {
                return Err(format!(
                    "rejected(ArkDeckRuntime.RuntimeOperationErrorCode.invalidInput, {})",
                    swift_string(
                        "Artifact lease target/binding/identity does not match the materialized request"
                    )
                ));
            }
            Ok(leased)
        };
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
        let arguments =
            hap_arguments(&action, resolved, &request.inputs, step).ok_or_else(internal_failure)?;
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

fn hap_arguments(
    action: &HapAction,
    resolved: &[ResolvedArtifact],
    inputs: &Map<String, Value>,
    step: &CatalogStep,
) -> Option<Value> {
    Some(match action {
        HapAction::SendArtifactToStaging(staged) => {
            json!({"sourceArtifactId": resolved.first()?.artifact_id,
            "sourceSha256": resolved.first()?.sha256, "remotePath": staged.path.remote_path})
        }
        HapAction::SendPackageSetToStaging(set) => {
            json!({"sourceArtifactId": resolved.first()?.artifact_id,
            "sourceSha256": resolved.first()?.sha256, "remotePath": set.directory.remote_path})
        }
        HapAction::InstallPackage { staged, .. } => {
            json!({"packageArtifactId": staged.artifact_lease_id.rsplit(':').next()?,
            "packageName": inputs.get("bundleName")?, "replacePolicy": "allow"})
        }
        HapAction::InstallPackageSet { set, .. } => {
            json!({"packageArtifactId": set.packages.first()?.artifact_lease_id.rsplit(':').next()?,
            "packageName": inputs.get("bundleName")?, "replacePolicy": "allow"})
        }
        HapAction::UninstallPackage(bundle) => json!({"packageName": bundle.bundle_name()}),
        HapAction::StartAbility(ability) | HapAction::StopAbility(ability) => {
            json!({"bundleName": ability.bundle.bundle_name(), "abilityName": ability.ability_name})
        }
        HapAction::CleanupOwnedRemotePath { path } => {
            json!({"remotePath": path.remote_path, "ownershipEvidenceId": format!("owned-{AUTHORIZATION_JOB}")})
        }
        HapAction::CleanupStagedPackageSet(set) => {
            json!({"remotePath": set.directory.remote_path, "ownershipEvidenceId": format!("owned-{AUTHORIZATION_JOB}")})
        }
        HapAction::QueryPackageReadback(bundle) => {
            json!({"catalogId": "arkdeck-remote-operations", "actionId": "packageInfo",
            "parameters": {"bundleName": bundle.bundle_name()}, "artifactId": format!("artifact-{}", step.step_id)})
        }
        HapAction::VerifyProcessState(bundle) => {
            json!({"probeId": format!("process.{}", bundle.bundle_name()), "expectedState": "running"})
        }
        _ => return None,
    })
}

pub(super) fn compensations<'a>(
    descriptor: &'a CatalogOperation,
    inputs: &Map<String, Value>,
) -> Result<Vec<&'a CatalogStep>, PlanRefusal> {
    [
        "stop-ability",
        "cleanup-uninstall",
        "cleanup-remote-staging",
    ]
    .into_iter()
    .filter(|id| {
        *id != "cleanup-uninstall"
            || inputs.get("cleanupPolicy").and_then(Value::as_str) != Some("retain")
    })
    .map(|id| {
        descriptor
            .steps
            .iter()
            .find(|step| step.step_id == id)
            .ok_or_else(internal_failure)
    })
    .collect()
}

fn primary_facts(entry: &LeasedArtifact) -> Result<BTreeMap<String, String>, PlanRefusal> {
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
