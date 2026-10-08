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
        Ok(Materialized {
            _import_use: None,
            _workspace_use: None,
            artifact_facts,
            digest: native_plan_digest(request, descriptor, facts, &context, &now)?,
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

/// Swift `materializeTypedPlanBeforeAuthorization`'s digest of a native
/// deployment: every selected step, then the rollback a failure past the
/// publish applies, over the library and the code-sign helper as `context`
/// names them. Its sends name both files' host paths, so the digest is
/// Swift's for the same request, facts, bytes and paths.
fn native_plan_digest(
    request: &OperationRequest,
    descriptor: &CatalogOperation,
    facts: &DeviceFacts,
    context: &StepContext<'_>,
    now: &str,
) -> Result<String, PlanRefusal> {
    let document = native_plan_document(request, descriptor, facts, context, now)?;
    Ok(sha256_hex(
        &session_json::encode(&document).map_err(|_| internal_failure())?,
    ))
}

fn native_plan_document(
    request: &OperationRequest,
    descriptor: &CatalogOperation,
    facts: &DeviceFacts,
    context: &StepContext<'_>,
    now: &str,
) -> Result<Value, PlanRefusal> {
    let reference = descriptor.reference();
    let mut steps = Vec::new();
    for step in descriptor
        .steps
        .iter()
        .filter(|step| descriptor.step_is_selected(step, &request.inputs))
    {
        steps.push(materialize_step(
            step, &reference, request, facts, context, now,
        )?);
    }
    // The rollback a failure past the publish applies, after every selected
    // step.
    steps.push(materialize_step(
        &device_steps::native_rollback(),
        &reference,
        request,
        facts,
        context,
        now,
    )?);
    Ok(
        json!({"operationReference": reference, "catalogDigest": CATALOG_DIGEST,
        "inputs": request.inputs, "targetID": request.target_id,
        "stableTargetIdentitySHA256": facts.identity, "bindingRevision": facts.binding_revision,
        "providerID": descriptor.provider, "steps": steps}),
    )
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
    let plan = action
        .plan(&step.step_id, Some(&facts.connect_key), context)
        .map_err(preflight)?;
    document["journalArguments"] =
        device_steps::journal_arguments_in(step, reference, &request.inputs, &action, context)
            .ok_or_else(internal_failure)?;
    document["executableSHA256"] = json!("resolved-at-dispatch");
    match plan {
        FilePlan::Process(plan) if device_steps::evidence_preflight_step(step) => {
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
        _ => return Err(internal_failure()),
    }
    Ok(document)
}

#[cfg(test)]
mod tests {
    use super::*;
    use arkdeck_provider_hdc::{CodeSignHelper, CodeSignHelperFacts, NativeAbi};
    use std::path::PathBuf;

    /// Every native deployment the Swift oracle planned, materialized again
    /// from its request over the oracle's library and code-sign helper at the
    /// paths Swift named them (`HDCOracleFake`'s root, which the sends name):
    /// the digest is Swift's byte for byte on every host. The library is
    /// verified as its ABI's code-signed ELF and the helper's facts carried
    /// as they are. A host whose paths are spelled otherwise (a Windows root)
    /// digests the same document with its own paths in the sends.
    #[test]
    fn the_recorded_plans_digest_as_swift_s_over_the_oracle_s_paths() {
        let fixture = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../tests/fixtures/deploy-native-library");
        let read = |path: PathBuf| -> Value {
            serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap()
        };
        let cases = read(fixture.join("cases.json"));
        let descriptor =
            CatalogOperation::lookup("deploy.native-library.app-owned", Some(1)).unwrap();
        let (job, artifact) = cases["lease"]
            .as_str()
            .unwrap()
            .strip_prefix("lease-v1:")
            .and_then(|rest| rest.split_once(':'))
            .unwrap();
        let row = read(fixture.join("artifacts").join(job).join("index.json"))["artifacts"]
            .as_array()
            .unwrap()
            .iter()
            .find(|row| row["artifactID"] == artifact)
            .unwrap()
            .clone();
        let library = LeasedLibrary {
            bytes: std::fs::read(fixture.join("artifacts").join(job).join(artifact)).unwrap(),
            byte_count: row["byteCount"].as_i64().unwrap(),
        };
        let resolved = [ResolvedArtifact {
            artifact_id: artifact.into(),
            sha256: row["sha256"].as_str().unwrap().into(),
            path: PathBuf::from(format!(
                "/private/tmp/arkdeck-hdc-oracle/artifacts/{job}/{artifact}"
            )),
        }];
        let recorded = &cases["codeSignHelper"];
        let helper = CodeSignHelper {
            facts: CodeSignHelperFacts {
                abi: NativeAbi::Arm64,
                build_id: recorded["buildId"].as_str().unwrap().into(),
                sha256: recorded["sha256"].as_str().unwrap().into(),
                byte_count: recorded["byteCount"].as_i64().unwrap(),
            },
            host_path: PathBuf::from(recorded["path"].as_str().unwrap()),
        };
        let context = StepContext {
            job_id: AUTHORIZATION_JOB,
            resolved: &resolved,
            library: Some(&library),
            helper: Some(&helper),
        };
        let target = &cases["target"];
        let facts = DeviceFacts {
            target_id: target["targetId"].as_str().unwrap().into(),
            binding_revision: target["bindingRevision"].as_i64().unwrap(),
            tool_version: target["toolVersion"].as_str().unwrap().into(),
            tool_sha256: String::new(),
            connect_key: target["connectKey"].as_str().unwrap().into(),
            identity: row["bindingSnapshot"]["stableIdentitySHA256"]
                .as_str()
                .unwrap()
                .into(),
        };
        let mut replayed = 0;
        let mut historical_plan = None;
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
            let mut current = native_plan_document(
                &request,
                descriptor,
                &facts,
                &context,
                "2026-09-14T00:00:00Z",
            )
            .unwrap();
            let current_digest = sha256_hex(&session_json::encode(&current).unwrap());
            assert_eq!(
                native_plan_digest(
                    &request,
                    descriptor,
                    &facts,
                    &context,
                    "2026-09-14T00:00:00Z"
                )
                .unwrap(),
                current_digest
            );
            let published = CATALOG_DIGEST
                == "c6e92eb252fe7653ed303a9ce34d12635bbc5f71ffb2a54fb8eb1fa3a9b99036";
            let steps = current["steps"].as_array_mut().unwrap();
            let prefix: Vec<_> = if published {
                Vec::new()
            } else {
                steps.drain(2..5).collect()
            };
            assert_eq!(
                prefix
                    .iter()
                    .map(|step| step["stepID"].as_str().unwrap())
                    .collect::<Vec<_>>(),
                if published {
                    Vec::new()
                } else {
                    vec![
                        "confirm-evidence-target",
                        "read-evidence-model",
                        "read-evidence-firmware",
                    ]
                }
            );
            assert!(prefix.iter().all(|step| step["effect"] == "readOnly"
                && step["binding"] == "confirmedDevice"
                && step["processKind"] == "process"));
            current["catalogDigest"] = exchange["answer"]["result"]["catalogDigest"].clone();
            let historical_digest = sha256_hex(&session_json::encode(&current).unwrap());
            assert_eq!(
                historical_digest,
                exchange["answer"]["result"]["materializedPlanDigest"]
                    .as_str()
                    .unwrap(),
                "{}",
                exchange["name"]
            );
            if published {
                assert_eq!(
                    current_digest, historical_digest,
                    "published inputs keep the full original Native plan"
                );
            } else {
                assert_eq!(
                    CATALOG_DIGEST,
                    "e4e8a47cc4e9f6f099c9f4c47ef701fc928c20103cc42a23a46e887f624ab5f7"
                );
                assert_ne!(
                    current_digest, historical_digest,
                    "the original plan cannot authorize the new prefix"
                );
            }
            if let Some(previous) = &historical_plan {
                assert_eq!(
                    previous, &current,
                    "all five frozen Native plans are identical"
                );
            } else {
                historical_plan = Some(current);
            }
            replayed += 1;
        }
        assert_eq!(replayed, 5);
        // Reconcile's three immutable submit requests use this same complete
        // plan. Produce the independent encoder capsule before any host path
        // projection, never from a Runtime answer or an authority hash label.
        let plan = historical_plan.unwrap();
        let reconcile = fixture
            .parent()
            .unwrap()
            .join("device-mutation-reconcile/nativeLibrary");
        let reconcile_bytes = std::fs::read(reconcile.join("cases.json")).unwrap();
        let provenance_bytes = std::fs::read(reconcile.join("provenance.json")).unwrap();
        assert_eq!(
            sha256_hex(&reconcile_bytes),
            "b26bda6e6f6ee57e1890d492cb8c409e6a005acfa02e13d5049019e179767e5e"
        );
        assert_eq!(
            sha256_hex(&provenance_bytes),
            "736dd3012a56d74b6bb83b0bb4f9767dcc36b711ebc4921b064417176e520413"
        );
        assert_eq!(
            sha256_hex(&std::fs::read(fixture.join("cases.json")).unwrap()),
            "62646bc4cbc150fb4ceb1315453f4ea861b4b87d184d4be4c69e838e06698763"
        );
        let reconcile_cases: Value = serde_json::from_slice(&reconcile_bytes).unwrap();
        let provenance: Value = serde_json::from_slice(&provenance_bytes).unwrap();
        let files = provenance["files"].as_object().unwrap();
        assert_eq!(files.len(), 88);
        for (relative, digest) in files {
            assert!(!relative.starts_with('/') && !relative.contains(['\\', ':']));
            assert!(
                relative
                    .split('/')
                    .all(|part| !matches!(part, "" | "." | ".."))
            );
            assert_eq!(
                sha256_hex(&std::fs::read(reconcile.join(relative)).unwrap()),
                digest.as_str().unwrap(),
                "{relative}"
            );
        }
        for key in ["target", "codeSignHelper", "library", "lease"] {
            assert_eq!(reconcile_cases[key], cases[key], "same source-bound {key}");
        }
        let mut rows = Vec::new();
        for exchange in reconcile_cases["exchanges"].as_array().unwrap() {
            if exchange["method"] != "job.submit" {
                continue;
            }
            let request_json = exchange["params"]["requestJson"].as_str().unwrap();
            let request = OperationRequest::decode(request_json.as_bytes()).unwrap();
            assert_eq!(
                request.reference(),
                plan["operationReference"].as_str().unwrap()
            );
            assert_eq!(json!(request.inputs), plan["inputs"]);
            assert_eq!(request.target_id, plan["targetID"].as_str().unwrap());
            assert_eq!(
                request.expected_binding_revision,
                Some(facts.binding_revision)
            );
            rows.push(json!({"case": exchange["name"], "requestJson": request_json}));
        }
        assert_eq!(
            rows.iter()
                .map(|row| row["case"].as_str().unwrap())
                .collect::<Vec<_>>(),
            vec![
                "published.submit",
                "unpublished.submit",
                "afterUnknown.submit"
            ]
        );
        let plan_sha = sha256_hex(&session_json::encode(&plan).unwrap());
        assert_eq!(
            plan_sha,
            "b60595abb20fc9f86c2e570f31bbf16803b3a95dea1996c037abbd4ad6a6aab3"
        );
        let query = crate::capability_store::CapabilityQuery {
            operation_id: descriptor.id().to_owned(),
            operation_version: descriptor.version(),
            effect: crate::capability_store::Effect::DeviceMutation,
            target_stable_identity_sha256: Some(facts.identity.clone()),
            target_binding_revision: Some(facts.binding_revision),
            plan_digest: Some(plan_sha.clone()),
            inputs: plan["inputs"].as_object().unwrap().clone(),
            artifact_facts: debug_hap_plan::primary_facts(&LeasedArtifact {
                job_id: job.to_owned(),
                artifact_id: artifact.to_owned(),
                row: row.clone(),
                path: resolved[0].path.clone(),
            })
            .unwrap(),
            workspace_identity_sha256: None,
            workspace_revision: None,
            workspace_file_scopes_digest: None,
        };
        assert!(!crate::capability_policy::session_scoped(
            descriptor,
            &query.inputs
        ));
        assert_eq!(
            crate::capability_policy::subject(descriptor, &query.inputs),
            query.inputs
        );
        let mut scope_lines = vec![
            format!("operation={}", query.operation_reference()),
            format!("effect={}", query.effect.raw()),
            format!("target={}", facts.identity),
            format!("bindingRevision={}", facts.binding_revision),
            format!("planDigest={plan_sha}"),
            format!(
                "inputs={}",
                String::from_utf8(
                    session_json::encode(&Value::Object(query.inputs.clone())).unwrap()
                )
                .unwrap()
            ),
        ];
        scope_lines.extend(
            query
                .artifact_facts
                .iter()
                .map(|(key, value)| format!("artifact.{key}={value}")),
        );
        let scope_material = scope_lines.join("\n");
        let compiled_material =
            crate::capability_policy::recovery_policy_material(&query, false, None);
        assert_eq!(
            compiled_material,
            format!(
                "{CATALOG_DIGEST}\n{}\nordinary",
                sha256_hex(scope_material.as_bytes())
            )
        );
        assert_eq!(
            crate::capability_policy::policy_fingerprint(&query, false),
            sha256_hex(compiled_material.as_bytes()).to_uppercase()
        );
        // Test-only backproof of the historical policy identity. No Runtime
        // caller can replace Catalog material or install a capability here.
        let policy_material = format!(
            "{}\n{}\nordinary",
            plan["catalogDigest"].as_str().unwrap(),
            sha256_hex(scope_material.as_bytes())
        );
        let policy_fingerprint = sha256_hex(policy_material.as_bytes()).to_uppercase();
        let policy_id = format!("CAP-RT-POLICY-{}-G1", &policy_fingerprint[..40]);
        let old_capabilities =
            read(reconcile.join("steps/published.run/capabilities/runtime-capabilities.json"));
        assert_eq!(old_capabilities["records"].as_array().unwrap().len(), 1);
        assert_eq!(
            old_capabilities["records"][0]["capability"]["capabilityID"],
            policy_id
        );
        let policy_capsule = json!({
            "schemaVersion": "arkdeck.test-native-reconcile-policy/1",
            "sourceCasesSha256": sha256_hex(&reconcile_bytes),
            "sourceProvenanceSha256": sha256_hex(&provenance_bytes),
            "query": {
                "operationId": query.operation_id, "operationVersion": query.operation_version,
                "effect": query.effect.raw(), "targetStableIdentitySha256": query.target_stable_identity_sha256,
                "targetBindingRevision": query.target_binding_revision, "planDigest": query.plan_digest,
                "inputs": query.inputs, "artifactFacts": query.artifact_facts,
                "workspaceIdentitySha256": query.workspace_identity_sha256,
                "workspaceRevision": query.workspace_revision,
                "workspaceFileScopesDigest": query.workspace_file_scopes_digest,
            },
            "sessionScoped": false, "recovery": null,
            "scopeMaterial": scope_material, "policyMaterial": policy_material,
            "policyFingerprint": policy_fingerprint, "capabilityId": policy_id,
        });
        let policy_path = fixture
            .parent()
            .unwrap()
            .join("catalog-lineage-c6-e4/native-reconcile-c6-policy.json");
        if let Some(output) = std::env::var_os("ARKDECK_RECORD_NATIVE_RECONCILE_POLICY") {
            let destination = PathBuf::from(output);
            let source = std::env::var_os("ARKDECK_CARGO_SOURCE_ROOT").map(PathBuf::from);
            let permitted = source.map_or(policy_path.clone(), |source| {
                source.join(
                    "rust/tests/fixtures/catalog-lineage-c6-e4/native-reconcile-c6-policy.json",
                )
            });
            assert_eq!(
                destination, permitted,
                "only the named versioned policy capsule may be recorded"
            );
            use std::io::Write;
            let mut file = std::fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(destination)
                .unwrap();
            file.write_all(&serde_json::to_vec_pretty(&policy_capsule).unwrap())
                .unwrap();
            file.sync_all().unwrap();
        } else {
            assert_eq!(
                read(policy_path),
                policy_capsule,
                "the complete policy material is reproduced independently"
            );
        }
        let capsule = json!({
            "schemaVersion": "arkdeck.test-native-reconcile-plan/1",
            "sourceCasesSha256": sha256_hex(&reconcile_bytes),
            "sourceProvenanceSha256": sha256_hex(&provenance_bytes),
            "originalNativeCasesSha256": "62646bc4cbc150fb4ceb1315453f4ea861b4b87d184d4be4c69e838e06698763",
            "catalogLineagePacketSha256": "d1a2614926275e9e8b38783ca5ac3054b6ea4fa63f051e2aedacfe59d7c937ab",
            "sourceRoot": "/private/tmp/arkdeck-hdc-oracle",
            "catalogDigest": plan["catalogDigest"],
            "planSha256": plan_sha,
            "completePlan": plan,
            "rows": rows,
        });
        let capsule_path = fixture
            .parent()
            .unwrap()
            .join("catalog-lineage-c6-e4/native-reconcile-c6-plan.json");
        if let Some(output) = std::env::var_os("ARKDECK_RECORD_NATIVE_RECONCILE_PLAN") {
            let destination = PathBuf::from(output);
            let source = std::env::var_os("ARKDECK_CARGO_SOURCE_ROOT").map(PathBuf::from);
            let permitted = source.map_or(capsule_path.clone(), |source| {
                source
                    .join("rust/tests/fixtures/catalog-lineage-c6-e4/native-reconcile-c6-plan.json")
            });
            assert_eq!(
                destination, permitted,
                "only the named versioned capsule may be recorded"
            );
            use std::io::Write;
            let mut file = std::fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(destination)
                .unwrap();
            file.write_all(&serde_json::to_vec_pretty(&capsule).unwrap())
                .unwrap();
            file.sync_all().unwrap();
        } else {
            assert_eq!(
                read(capsule_path),
                capsule,
                "the complete reconcile plan is reproduced independently"
            );
        }
    }
}
