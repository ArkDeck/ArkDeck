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
            replayed += 1;
        }
        assert_eq!(replayed, 5);
    }
}
