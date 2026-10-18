//! Swift `RuntimeJobEngine.planOnly` for the ArkForge Flash operations — the
//! canonical `flash.full-restore@1` and its compatibility alias
//! `flash.dayu200` — as `materializeTypedPlanBeforeAuthorization` builds it:
//!
//! - The alias's inputs are projected onto the canonical request
//!   (`ArkForgeFlashRequest.canonicalInputs`).
//! - The provider's availability and the dispatcher's are judged, then the
//!   Target's facts and the leased flash bundle.
//! - Every selected step is materialized as the engine, `arkforged` (a
//!   StepPermit bound to the lane's toolchain) or the Rockchip host (a
//!   host-managed descriptor pinning the canonical digest of its typed
//!   action) will perform it.
//!
//! Nothing is admitted, reserved or dispatched. The ArkForge lane itself is
//! never called: only its toolchain digest is read.
use super::debug_hap_plan::primary_facts;
use super::*;
use crate::device_facts::DeviceFacts;
use crate::flash_facts::{NativeRockUsbIdentity, RockchipFacts};
use crate::rockchip_action::{CaptureRequest, Expectation, RockchipAction};
use std::path::Path;
use std::sync::Mutex;

/// Swift `ArkForgeFlashOperation.canonicalReference`.
const CANONICAL: &str = "flash.full-restore@1";
use crate::job_owner::flash_recommission::{IdentityChain, OPERATION as RECOMMISSION};
/// Swift `RuntimeJobEngine.arkForgeDispatchedSteps`.
const ARKFORGE_STEPS: [&str; 2] = ["flash-partitions", "verify-flash-readback"];
/// Swift `ArkForgeNativeRockUSBToolchain.reportedVersion`.
const TOOL_VERSION: &str = "arkforged native RockUSB";
/// Swift `RockchipFlashProfile.dayu200.runtimeProductModel`.
const PRODUCT_MODEL: &str = "ohos";
/// Swift `TargetStoreRockchipRuntimeFactsPort`'s server fact names.
const CROSS_MODE: &str = "dayu200CrossModeBinding";
const ALIAS_IDENTITY: &str = "dayu200HDCNormalAliasSHA256";
const ALIAS_TOPOLOGY: &str = "dayu200HDCNormalAliasUSBTopology";
/// The DAYU200 profile's mapped partitions, in write order.
pub(crate) const PARTITIONS: [&str; 9] = [
    "uboot",
    "resource",
    "boot_linux",
    "ramdisk",
    "system",
    "vendor",
    "updater",
    "chip_ckm",
    "userdata",
];

/// Whether an operation is one of the ArkForge Flash operations (Swift
/// `ArkForgeFlashOperation.contains`).
pub(crate) fn is_flash(reference: &str) -> bool {
    matches!(reference, CANONICAL | "flash.dayu200" | RECOMMISSION)
        || crate::flash_maintenance::is_maintenance(reference)
}

/// What a Flash plan reads beyond the Artifact and Import owners and the
/// Target's facts, as the daemon composes it: the provider's availability,
/// the dispatcher's and the lane's toolchain.
type RecommissionQuiescence =
    dyn Fn(&arkdeck_provider_arkforge::Execution) -> Result<(), String> + Send + Sync;

pub struct FlashPlanning {
    pub(crate) maintenance:
        Mutex<Option<std::sync::Arc<crate::flash_maintenance::MaintenanceContext>>>,
    unavailable: Option<String>,
    dispatch_unavailable: Box<dyn Fn() -> Option<String> + Send + Sync>,
    toolchain_sha256: Option<String>,
    /// Swift's daemon-lifetime `flashArchiveProfileCache`: the runtime
    /// build version each exact leased archive declares, or none.
    build_versions: Mutex<BTreeMap<(String, String), Option<String>>>,
    recommission_quiescence: Option<Box<RecommissionQuiescence>>,
}

impl FlashPlanning {
    pub fn install_maintenance(
        &self,
        context: std::sync::Arc<crate::flash_maintenance::MaintenanceContext>,
    ) {
        if let Ok(mut slot) = self.maintenance.lock() {
            *slot = Some(context);
        }
    }

    /// `unavailable` is the provider's runtime availability as Swift's lane
    /// composition decides it (none when available); `dispatch_unavailable`
    /// answers Swift's dispatcher `unavailableReason`; `toolchain_sha256` is
    /// the composed lane's, none without a lane.
    pub fn new(
        unavailable: Option<String>,
        dispatch_unavailable: impl Fn() -> Option<String> + Send + Sync + 'static,
        toolchain_sha256: Option<String>,
    ) -> Self {
        Self {
            maintenance: Mutex::new(None),
            unavailable,
            dispatch_unavailable: Box::new(dispatch_unavailable),
            toolchain_sha256,
            build_versions: Mutex::new(BTreeMap::new()),
            recommission_quiescence: None,
        }
    }

    pub fn with_recommission_quiescence(
        mut self,
        observe: impl Fn(&arkdeck_provider_arkforge::Execution) -> Result<(), String>
        + Send
        + Sync
        + 'static,
    ) -> Self {
        self.recommission_quiescence = Some(Box::new(observe));
        self
    }

    pub fn set_recommission_quiescence(
        &mut self,
        observe: impl Fn(&arkdeck_provider_arkforge::Execution) -> Result<(), String>
        + Send
        + Sync
        + 'static,
    ) {
        self.recommission_quiescence = Some(Box::new(observe));
    }

    pub(crate) fn require_recommission_quiescence(
        &self,
        source: &arkdeck_provider_arkforge::Execution,
    ) -> Result<(), String> {
        self.recommission_quiescence
            .as_ref()
            .ok_or("recommission.providerQuiescenceUnavailable")?(source)
    }

    /// The standing host checks used by Flash planning, in the same order.
    /// Discovery must retain a missing campaign, changed tool or unavailable
    /// dispatcher instead of claiming that the provider was never registered.
    pub(crate) fn runtime_unavailable_reason(&self) -> Option<String> {
        self.unavailable
            .clone()
            .or_else(|| (self.dispatch_unavailable)())
            .or_else(|| {
                self.toolchain_sha256
                    .is_none()
                    .then(|| "ArkForge lane is not configured".into())
            })
    }

    /// Swift `declaredRuntimeBuildVersion`: the version the leased archive's
    /// system image declares, read once per exact lease and digest.
    pub(crate) fn build_version(&self, lease: &str, leased: &LeasedArtifact) -> Option<String> {
        let sha256 = leased.row["sha256"].as_str()?.to_owned();
        let key = (lease.to_owned(), sha256);
        let mut cache = self.build_versions.lock().ok()?;
        if let Some(version) = cache.get(&key) {
            return version.clone();
        }
        let version = std::fs::File::open(&leased.path).ok().and_then(|mut file| {
            let summary =
                crate::flash_archive::summarize(&mut file, &leased.path.to_string_lossy()).ok()?;
            let build = crate::flash_archive::describe(&summary).ok()?;
            crate::flash_archive::for_build(&build)
                .ok()
                .map(|board| board.runtime_build_version)
        });
        cache.insert(key, version.clone());
        version
    }
}

/// Swift `ArkForgeNativeRockchipControlDispatcher.unavailableReason` for
/// the Flash operations, as the daemon composes the dispatcher: the
/// configured `arkforged`'s identity first, then the per-action host, which
/// refuses outright without a descriptor-bound HDC and otherwise needs its
/// durable action record root `records`, prepared as Swift's record store
/// prepares it.
pub fn rockchip_dispatch_unavailable(
    identity: &NativeRockUsbIdentity,
    records: Option<&Path>,
) -> Option<String> {
    if let Err(error) = identity.resolve() {
        return Some(format!(
            "ArkForge native RockUSB identity is unavailable: {error}"
        ));
    }
    let Some(records) = records else {
        return Some(
            "the per-action RockUSB host requires descriptor-bound HDC and a product state \
             directory"
                .into(),
        );
    };
    crate::rockchip_records::RockchipRecordStore::new(records).unavailable_reason()
}

/// The Target's facts as Swift's ArkForge facts port reads them
/// (`resolveFacts`), each error as Swift interpolates it.
pub type RockchipFactsPort<'a> = &'a dyn Fn(&str, bool) -> Result<RockchipFacts, String>;

/// `job.plan` over the Flash composition: the ArkForge Flash operations are
/// materialized here, every other request by the planner as before.
pub struct FlashPlanner<'a> {
    pub planner: JobPlanner<'a>,
    /// The Flash composition; without one a Flash request is the planner's,
    /// which does not materialize it.
    pub flash: Option<&'a FlashPlanning>,
    /// The facts port; none when the daemon composed none.
    pub facts: Option<RockchipFactsPort<'a>>,
}

impl<'a> FlashPlanner<'a> {
    /// The `job.plan` control parameters: exactly one bounded `requestJson`.
    pub fn handle(&self, params: &Map<String, Value>) -> Result<Value, PlanRefusal> {
        self.plan(request_json(params)?.as_bytes())
    }

    pub fn plan(&self, request_json: &[u8]) -> Result<Value, PlanRefusal> {
        let request = OperationRequest::decode(request_json)
            .map_err(|rejection| refusal(rejection.code.wire_code(), rejection.message))?;
        let Some(flash) = self.flash.filter(|_| is_flash(&request.reference())) else {
            return self.planner.plan(request_json);
        };
        if request.capability_id.is_some() {
            return Err(refusal(
                "invalidInput",
                "planOnly does not accept or consume a Runtime capability",
            ));
        }
        let Some(descriptor) =
            CatalogOperation::lookup(&request.operation_id, request.operation_version)
        else {
            return Err(refusal(
                "operationUnavailable",
                format!("operation {} is not in the catalog", request.reference()),
            ));
        };
        JobPlanner::validate_inputs(&request, descriptor)?;
        let fingerprint = request.fingerprint();
        let _hold = self.planner.import_hold(&request, descriptor)?;
        let (materialized, blocker) = self.materialize(flash, &request, descriptor)?;
        let effect = descriptor.effective_effect(&request.inputs);
        Ok(json!({
            "schemaVersion": "arkdeck.job-plan/1",
            "executionMode": "planOnly",
            "operation": descriptor.reference(),
            "targetId": request.target_id,
            "bindingRevision": materialized.binding_revision,
            "stableIdentitySha256": materialized.identity,
            "providerId": descriptor.provider,
            "catalogDigest": CATALOG_DIGEST,
            "requestFingerprintSha256": fingerprint,
            "materializedPlanDigest": materialized.digest,
            "stepSetDigestSHA256": step_set_digest(descriptor, &request.inputs)?,
            "inputs": request.inputs,
            "steps": crate::catalog_review::selected_steps(descriptor, &request.inputs),
            "effectiveEffect": effect,
            "authorizationPolicy": descriptor.authorization.get(&effect),
            "providerAdmissionBlocker": blocker,
            "jobAdmitted": false,
            "dispatchDisposition": "notDispatched",
        }))
    }

    /// Swift's Import holds, then `materializeTypedPlanBeforeAuthorization`
    /// for a Flash request being admitted: the holds stay with the plan until
    /// admission is done with it.
    pub(crate) fn admission_materialized(
        &self,
        flash: &FlashPlanning,
        request: &OperationRequest,
        descriptor: &CatalogOperation,
    ) -> Result<(Materialized<'a>, Option<String>), PlanRefusal> {
        let hold = self.planner.import_hold(request, descriptor)?;
        let (mut materialized, blocker) = self.materialize(flash, request, descriptor)?;
        materialized._import_use = hold;
        Ok((materialized, blocker))
    }

    /// Swift `materializeTypedPlanBeforeAuthorization` for a Flash request:
    /// the plan document's digest and what it binds, and the provider's
    /// `executionAdmissionBlocker`.
    pub(crate) fn materialize<'b>(
        &self,
        flash: &FlashPlanning,
        request: &OperationRequest,
        descriptor: &CatalogOperation,
    ) -> Result<(Materialized<'b>, Option<String>), PlanRefusal> {
        let reference = descriptor.reference();
        if crate::flash_maintenance::is_maintenance(&reference) {
            return crate::flash_maintenance::materialize(self, flash, request, descriptor);
        }
        // Converted before anything else is read; a legacy request that
        // cannot be converted fails outside the typed preflight.
        let inputs =
            canonical_inputs(&reference, &request.inputs).map_err(|detail| PlanRefusal {
                swift: Some(detail.into()),
                ..internal_failure()
            })?;
        let unavailable = |reason: &str| {
            refusal(
                "invalidInput",
                format!("{reference} is runtime unavailable: {reason}"),
            )
        };
        if let Some(reason) = &flash.unavailable {
            return Err(unavailable(reason));
        }
        if let Some(reason) = (flash.dispatch_unavailable)() {
            return Err(unavailable(&reason));
        }
        let Some(artifacts) = self.planner.artifacts else {
            return Err(unavailable("runtime.artifactStoreUnavailable"));
        };
        let unmaterialized = |error: &str| {
            refusal(
                "invalidInput",
                format!(
                    "target facts cannot materialize the typed plan before authorization: {error}"
                ),
            )
        };
        // Swift's adapter without a facts port refuses with its
        // `factsUnavailable` detail.
        let facts = match self.facts {
            Some(port) => port(&request.target_id, reference == RECOMMISSION),
            None => Err("production ArkForge target facts are not registered".into()),
        }
        .map_err(|error| unmaterialized(&error))?;
        validate_facts(&facts, &request.target_id, request.expected_binding_revision)
            .map_err(|_| {
                unmaterialized(
                    "failed(\"evidenceIncomplete: target/binding/routing/tool facts are absent or mismatched\")",
                )
            })?;
        let recommission = if reference == RECOMMISSION {
            Some(IdentityChain::from_facts(&facts).map_err(|error| unmaterialized(&error))?)
        } else {
            None
        };
        let lease_name = if matches!(reference.as_str(), CANONICAL | RECOMMISSION) {
            "artifactLease"
        } else {
            "imageBundleLease"
        };
        let Some(Value::String(lease)) = request.inputs.get(lease_name) else {
            return Err(refusal(
                "invalidInput",
                format!("{reference} requires a configured Artifact lease store"),
            ));
        };
        let bound = DeviceFacts {
            target_id: facts.target_id.clone(),
            binding_revision: facts.binding_revision,
            tool_version: TOOL_VERSION.into(),
            tool_sha256: facts.tool_sha256.clone(),
            connect_key: facts.execution_connect_key.clone(),
            identity: facts.identity_sha256.clone(),
        };
        let leased = self
            .planner
            .resolve_bound_lease(artifacts, lease, request, &bound)
            .map_err(|reason| {
                refusal(
                    "invalidInput",
                    format!("flash bundle Artifact lease is not resolvable: {reason}"),
                )
            })?;
        let preflight = |error: String| {
            refusal(
                "invalidInput",
                format!("typed plan preflight failed before authorization: {error}"),
            )
        };
        // Swift `RuntimeDebugAttemptPermitStore.loadExact` on the Runtime
        // clock: a destructive attempt the recovery broker prepared pins its
        // invocation and candidate action into the plan; a record that no
        // longer matches, or whose invocation no longer permits the dispatch,
        // refuses the plan.
        let now = crate::runtime_now();
        let permit = crate::debug_attempt_permit::load_exact(
            self.planner.state_root,
            request,
            now.as_deref(),
        )
        .map_err(|detail| {
            preflight(format!(
                "persistenceFailure({})",
                crate::strict_json::swift_quoted(detail)
            ))
        })?;
        let artifact_facts = primary_facts(&leased)?;
        let retry = if reference == RECOMMISSION
            && request.inputs.contains_key("failedRecommissionJobId")
        {
            let context = crate::flash_maintenance::context(flash).map_err(preflight)?;
            Some(
                crate::flash_recommission_retry::prepare(
                    &context,
                    &self.planner,
                    request,
                    &facts,
                    &leased,
                )
                .map_err(preflight)?,
            )
        } else {
            if request.inputs.contains_key("restorationArtifactLease") {
                return Err(preflight(
                    "recommission.restorationRequiresExplicitControlledRetry".into(),
                ));
            }
            None
        };
        let mut steps = Vec::new();
        for step in descriptor
            .steps
            .iter()
            .filter(|step| descriptor.step_is_selected(step, &request.inputs))
        {
            let mut materialized = json!({
                "stepID": step.step_id, "kind": step.kind, "effect": step.effect,
                "cancellation": step.cancellation, "binding": step.binding,
                "isOptional": step.optional,
            });
            if device_steps::engine_step(&step.kind) {
                materialized["processKind"] = json!("engine");
                steps.push(materialized);
                continue;
            }
            if ARKFORGE_STEPS.contains(&step.step_id.as_str()) {
                let Some(toolchain) = &flash.toolchain_sha256 else {
                    return Err(unavailable("ArkForge lane is not configured"));
                };
                materialized["journalArguments"] =
                    delegated_arguments(&step.step_id, &artifact_facts)
                        .ok_or_else(internal_failure)?;
                materialized["processKind"] = json!("arkforgeStepPermit");
                materialized["hostManagedDescriptor"] =
                    json!(format!("arkforge.stepPermit#toolchain-sha256:{toolchain}"));
                steps.push(materialized);
                continue;
            }
            let mut provider_facts = facts.clone();
            if let Some(chain) = &recommission {
                provider_facts.identity_sha256 = chain.loader_serial_sha256.clone();
            }
            let action = action(&step.step_id, &step.kind, &inputs, &provider_facts, || {
                flash.build_version(lease, &leased)
            })
            .map_err(preflight)?;
            if action.effect() != step.effect {
                return Err(internal_failure());
            }
            materialized["journalArguments"] = journal_arguments(&step.kind, &action);
            materialized["processKind"] = json!("hostManaged");
            materialized["executableSHA256"] = json!(facts.tool_sha256);
            materialized["hostManagedDescriptor"] = json!(format!(
                "{}#action-sha256:{}",
                action.identifier(),
                sha256_hex(
                    &session_json::encode(&action.persisted()).map_err(|_| internal_failure())?
                )
            ));
            steps.push(materialized);
        }
        let mut document = json!({
            "operationReference": if reference == RECOMMISSION { RECOMMISSION } else { CANONICAL },
            "catalogDigest": CATALOG_DIGEST,
            "inputs": inputs,
            "targetID": request.target_id,
            "stableTargetIdentitySHA256": facts.identity_sha256,
            "bindingRevision": facts.binding_revision,
            "providerID": "arkforge",
            "steps": steps,
        });
        if let Some(chain) = &recommission {
            document["recommissionIdentityChain"] = json!(chain);
        }
        if let Some(retry) = &retry {
            document["controlledRetryProgram"] = retry.program.value();
        }
        // Present only for a Runtime-owned debug attempt; an ordinary Job's
        // digest bytes are unchanged (Swift `encodeIfPresent`).
        if let Some(permit) = permit {
            document["runtimeDebugInvocationID"] = json!(permit.invocation_id);
            document["runtimeDebugCandidateActionSHA256"] = json!(permit.candidate_action_sha256);
        }
        let digest = sha256_hex(&session_json::encode(&document).map_err(|_| internal_failure())?);
        Ok((
            Materialized {
                _import_use: None,
                _workspace_use: None,
                digest,
                artifact_facts,
                identity: Some(facts.identity_sha256.clone()),
                binding_revision: Some(facts.binding_revision),
                recommission,
                recommission_retry_program_sha256: retry.map(|retry| retry.program.sha256()),
            },
            operation_admission_blocker(&facts, reference == RECOMMISSION),
        ))
    }
}

/// Swift `ArkForgeFlashRequest.canonicalInputs`: the alias's inputs as the
/// canonical request names them, or the `DeviceProviderError` detail Swift
/// throws when they cannot be converted.
pub(crate) fn canonical_inputs(
    reference: &str,
    inputs: &Map<String, Value>,
) -> Result<Map<String, Value>, &'static str> {
    if matches!(reference, CANONICAL | RECOMMISSION) {
        return Ok(inputs.clone());
    }
    let (Some(lease), Some(profile), Some(partitions)) = (
        inputs
            .get("imageBundleLease")
            .and_then(Value::as_str)
            .filter(|lease| !lease.is_empty()),
        inputs
            .get("deviceProfile")
            .and_then(Value::as_str)
            .filter(|profile| *profile == "dayu200"),
        inputs.get("partitionPlan").and_then(Value::as_array),
    ) else {
        return Err(
            "legacy Flash alias inputs cannot be converted to the canonical full-restore request",
        );
    };
    let partitions = partitions
        .iter()
        .map(Value::as_str)
        .collect::<Option<Vec<&str>>>()
        .ok_or("legacy partitionPlan contains a non-string value")?;
    if partitions != PARTITIONS {
        return Err("legacy partitionPlan must exactly match the selected published profile");
    }
    let verification = inputs
        .get("postFlashVerification")
        .cloned()
        .unwrap_or_else(|| json!("full"));
    Ok(Map::from_iter([
        ("artifactLease".into(), json!(lease)),
        ("deviceProfileRef".into(), json!(profile)),
        ("intent".into(), json!("fullRestore")),
        ("verification".into(), verification),
    ]))
}

fn lowercase_sha256(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

/// Swift `validateEvidenceFacts` for the ArkForge facts, whose provider and
/// tool version are the port's own constants.
fn validate_facts(
    facts: &RockchipFacts,
    target_id: &str,
    expected_binding_revision: Option<i64>,
) -> Result<(), ()> {
    let complete = facts.target_id == target_id
        && expected_binding_revision == Some(facts.binding_revision)
        && !facts.execution_connect_key.is_empty()
        && lowercase_sha256(&facts.identity_sha256)
        && lowercase_sha256(&facts.tool_sha256);
    if complete { Ok(()) } else { Err(()) }
}

/// Swift `ArkForgeFlashProviderAdapter.executionAdmissionBlocker`.
pub(crate) fn admission_blocker(facts: &RockchipFacts) -> Option<String> {
    if facts.server_facts.get(CROSS_MODE).map(String::as_str) != Some("satisfied") {
        return Some(format!(
            "flash.crossModeBindingUnprepared: target {} is not covered by the durable DAYU200 \
             cross-mode binding",
            facts.target_id
        ));
    }
    let routed = facts
        .server_facts
        .get(ALIAS_IDENTITY)
        .filter(|identity| lowercase_sha256(identity))
        .is_some_and(|identity| {
            !facts.execution_connect_key.is_empty()
                && sha256_hex(facts.execution_connect_key.as_bytes()) == *identity
        })
        && facts
            .server_facts
            .get(ALIAS_TOPOLOGY)
            .is_some_and(|topology| {
                !topology.is_empty() && topology.bytes().all(|b| b.is_ascii_digit())
            });
    if !routed && loader_first_expectation(facts).is_none() {
        return Some(format!(
            "flash.postFlashHDCBindingUnprepared: target {} has no trusted HDC identity and USB \
             topology for postflight",
            facts.target_id
        ));
    }
    if !normal_loader_identity_ready(facts) {
        return Some(format!(
            "flash.normalLoaderIdentityUnproven: {}. Normal USB identity alone cannot prove the bound Loader; no mode transition is permitted",
            facts
                .server_facts
                .get("dayu200NormalLoaderHardwareIdentity")
                .map(String::as_str)
                .unwrap_or("normalLoaderIdentity.hardwareProofMissing")
        ));
    }
    None
}

pub(crate) fn operation_admission_blocker(
    facts: &RockchipFacts,
    recommission: bool,
) -> Option<String> {
    if recommission {
        IdentityChain::from_facts(facts).err()
    } else {
        admission_blocker(facts)
    }
}

pub(crate) fn normal_loader_identity_ready(facts: &RockchipFacts) -> bool {
    !(facts.device_mode == "hdc"
        && (facts
            .server_facts
            .get("dayu200NormalLoaderHardwareIdentity")
            .map(String::as_str)
            != Some("satisfied")
            || facts
                .server_facts
                .get("dayu200NormalLoaderSerialSHA256")
                .or_else(|| facts.server_facts.get("dayu200NormalHardwareSerialSHA256"))
                != Some(&facts.identity_sha256)
            || !facts
                .server_facts
                .get("dayu200NormalHardwareSerialSHA256")
                .is_some_and(|value| lowercase_sha256(value))
            || !facts
                .server_facts
                .get("dayu200NormalHardwareObservationSHA256")
                .is_some_and(|value| lowercase_sha256(value))))
}

fn loader_first_expectation(
    facts: &RockchipFacts,
) -> Option<arkdeck_provider_hdc::LoaderReconnectExpectation> {
    if facts.device_mode != "loader"
        || facts
            .server_facts
            .get(crate::flash_facts::LOADER_FIRST_POSTFLIGHT)
            .map(String::as_str)
            != Some("satisfied")
        || facts.server_facts.contains_key(ALIAS_IDENTITY)
        || facts.server_facts.contains_key(ALIAS_TOPOLOGY)
    {
        return None;
    }
    let expectation = arkdeck_provider_hdc::LoaderReconnectExpectation {
        hardware_serial_sha256: facts.identity_sha256.clone(),
        connector_sha256: facts
            .server_facts
            .get(crate::flash_facts::LOADER_FIRST_CONNECTOR)?
            .clone(),
    };
    expectation.validate().ok()?;
    Some(expectation)
}

/// Swift `journalStep`'s arguments for the two steps `arkforged` performs:
/// the resolved archive is their identity.
pub(crate) fn delegated_arguments(
    step: &str,
    artifact: &BTreeMap<String, String>,
) -> Option<Value> {
    let sha256 = artifact.get("artifactSha256")?;
    Some(match step {
        "flash-partitions" => json!({
            "providerOperationId": "arkforge.write-partitions",
            "partition": "dayu200_mapped_set",
            "imageArtifactId": artifact.get("artifactId")?,
            "imageSha256": sha256,
            "imageSize": artifact.get("artifactByteCount")?.parse::<u64>().ok()?,
            "confirmationId": "runtimeE2Admission",
            "safeBoundaryId": "perPartitionWriteBoundary",
        }),
        _ => json!({
            "probeId": "rockusb-partition-readback",
            "expectedState": format!("mapped-set:{sha256}"),
        }),
    })
}

/// Swift `journalStep(..., delegatedArkForgePlanCompletion: true)`'s
/// arguments for the Runtime's projection of a completed ArkForge plan onto
/// one of its catalog steps. It is given no resolved Artifact, so the
/// readback's projection names the generic process-state probe, as Swift's
/// does.
pub(crate) fn plan_completion_arguments(step: &str) -> Option<Value> {
    Some(match step {
        "verify-flash-readback" => json!({"probeId": "process-state", "expectedState": "running"}),
        "reboot-device" => json!({"targetMode": "normal", "reason": "rockusbResetAfterFlash"}),
        "wait-for-hdc" => json!({"deadlineMilliseconds": 120_000, "reason": "normalModeReconnect"}),
        "rebind-and-verify-build" => json!({"evidencePolicy": "postFlashBuild"}),
        _ => return None,
    })
}

/// One step of an admitted Flash the Rockchip host runs itself: the typed
/// action it is given, pinned by the canonical digest of its persisted form,
/// and the arguments its write-ahead intent journals.
pub(crate) struct HostStep {
    pub(crate) identifier: &'static str,
    /// Swift `PersistedTypedProviderAction(.rockchip(action))`.
    pub(crate) action: Value,
    pub(crate) action_sha256: String,
    pub(crate) arguments: Value,
    pub(crate) effect: &'static str,
}

impl FlashPlanning {
    /// Swift `ArkForgeFlashProviderAdapter.action(for:…)` for a step the
    /// Rockchip host runs, over the canonical inputs and the step's facts,
    /// each refusal its `DeviceProviderError` description.
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn host_step(
        &self,
        step: &str,
        kind: &str,
        inputs: &Map<String, Value>,
        facts: &RockchipFacts,
        lease: &str,
        leased: &LeasedArtifact,
        job_id: &str,
    ) -> Result<HostStep, String> {
        let action = if step == "capture-post-flash-diagnostics"
            && facts
                .server_facts
                .get(crate::flash_facts::LOADER_FIRST_VERIFIED_JOB)
                .map(String::as_str)
                == Some(job_id)
        {
            let expectation = arkdeck_provider_hdc::LoaderReconnectExpectation {
                hardware_serial_sha256: facts.identity_sha256.clone(),
                connector_sha256: facts
                    .server_facts
                    .get(crate::flash_facts::LOADER_FIRST_VERIFIED_CONNECTOR)
                    .ok_or("first Loader postflight connector is missing")?
                    .clone(),
            };
            expectation.validate().map_err(|error| error.to_string())?;
            RockchipAction::CaptureLoaderPostFlashDiagnostics {
                expectation,
                request: CaptureRequest::new(30, Vec::new(), 16 * 1024 * 1024)?,
            }
        } else {
            action(step, kind, inputs, facts, || {
                self.build_version(lease, leased)
            })?
        };
        let persisted = action.persisted();
        let action_sha256 = sha256_hex(
            &session_json::encode(&persisted).map_err(|_| "the action cannot be encoded")?,
        );
        Ok(HostStep {
            identifier: action.identifier(),
            action: persisted,
            action_sha256,
            arguments: journal_arguments(kind, &action),
            effect: action.effect(),
        })
    }
}

/// Swift `ArkForgeFlashProviderAdapter.action(for:operation:inputs:context:)`
/// over the canonical inputs, each refusal its `DeviceProviderError`
/// description.
fn action(
    step: &str,
    kind: &str,
    inputs: &Map<String, Value>,
    facts: &RockchipFacts,
    build_version: impl FnOnce() -> Option<String>,
) -> Result<RockchipAction, String> {
    let key = &facts.execution_connect_key;
    let identity = &facts.identity_sha256;
    if key.is_empty() || !lowercase_sha256(identity) {
        return Err(format!(
            "{step} requires a descriptor-bound target identity"
        ));
    }
    let expectation = || -> Result<Expectation, String> {
        let alias = facts
            .server_facts
            .get(ALIAS_IDENTITY)
            .filter(|alias| lowercase_sha256(alias));
        let topology = facts.server_facts.get(ALIAS_TOPOLOGY).filter(|topology| {
            !topology.is_empty() && topology.bytes().all(|b| b.is_ascii_digit())
        });
        match (alias, topology) {
            (Some(alias), Some(topology)) if sha256_hex(key.as_bytes()) == *alias => {
                Ok(Expectation {
                    previous_connect_key: key.clone(),
                    previous_identity_sha256: alias.clone(),
                    usb_topology: topology.clone(),
                })
            }
            _ => Err("post-flash HDC binding expectation is absent or malformed".into()),
        }
    };
    match (step, kind) {
        ("enter-loader-mode", "enterUpdater") => Ok(RockchipAction::EnterLoader(key.clone())),
        ("wait-loader-disconnect", "waitForDisconnect") => {
            Ok(RockchipAction::WaitForHdcDisconnect(key.clone()))
        }
        ("wait-loader-reconnect", "waitForReconnect") => {
            Ok(RockchipAction::WaitForLoader(identity.clone()))
        }
        ("rebind-loader-identity", "probeDevice") => {
            Ok(RockchipAction::RebindLoader(identity.clone()))
        }
        ("reboot-device", "rebootDevice") => Ok(RockchipAction::RebootToNormal(identity.clone())),
        ("wait-for-hdc", "waitForReconnect") => match loader_first_expectation(facts) {
            Some(expectation) => Ok(RockchipAction::WaitForLoaderHdc(expectation)),
            None => Ok(RockchipAction::WaitForBoundHdcReconnect(expectation()?)),
        },
        ("rebind-and-verify-build", "probeDevice") => {
            flash_bundle(inputs)?;
            let Some(version) = build_version().filter(|version| !version.is_empty()) else {
                return Err(
                    "post-flash verification has no declared build version for the resolved \
                     bundle"
                        .into(),
                );
            };
            match loader_first_expectation(facts) {
                Some(expectation) => Ok(RockchipAction::VerifyLoaderBuild {
                    expectation,
                    product_model: PRODUCT_MODEL.to_owned(),
                    build_version: version,
                }),
                None => Ok(RockchipAction::VerifyBoundBuild {
                    expectation: expectation()?,
                    product_model: PRODUCT_MODEL.to_owned(),
                    build_version: version,
                }),
            }
        }
        ("capture-post-flash-diagnostics", "captureRemoteStdout") => {
            // The catalog's bounded HiLog: 30 s, no filters, 16 MiB.
            let request = CaptureRequest::new(30, Vec::new(), 16 * 1024 * 1024)?;
            match loader_first_expectation(facts) {
                Some(expectation) => Ok(RockchipAction::CaptureLoaderPostFlashDiagnostics {
                    expectation,
                    request,
                }),
                None => Ok(RockchipAction::CapturePostFlashDiagnostics {
                    connect_key: key.clone(),
                    request,
                }),
            }
        }
        _ => Err(format!("{step} has no registered Rockchip runtime action")),
    }
}

/// Swift `flashBundle(inputs:context:)`'s checks of the canonical request.
fn flash_bundle(inputs: &Map<String, Value>) -> Result<(), String> {
    if inputs.get("deviceProfileRef") != Some(&json!("dayu200")) {
        return Err("flash requires the published DAYU200 device profile".into());
    }
    if !inputs
        .get("artifactLease")
        .and_then(Value::as_str)
        .is_some_and(|lease| !lease.is_empty())
    {
        return Err("flash requires the engine-resolved imageBundleLease".into());
    }
    if inputs.get("intent") != Some(&json!("fullRestore")) {
        return Err("flash requires the closed fullRestore intent".into());
    }
    Ok(())
}

/// Swift `journalStep`'s arguments for a step the Rockchip host performs.
fn journal_arguments(kind: &str, action: &RockchipAction) -> Value {
    match (kind, action) {
        ("enterUpdater", _) => json!({
            "providerOperationId": "rockusb.enter-loader",
            "expectedMode": "Loader",
            "reconnectDeadlineMilliseconds": 45_000,
        }),
        ("waitForDisconnect", _) => {
            json!({"deadlineMilliseconds": 15_000, "reason": "enterLoader"})
        }
        ("waitForReconnect", RockchipAction::WaitForLoader(_)) => {
            json!({"deadlineMilliseconds": 45_000, "reason": "loaderReconnect"})
        }
        ("waitForReconnect", _) => {
            json!({"deadlineMilliseconds": 120_000, "reason": "normalModeReconnect"})
        }
        ("probeDevice", RockchipAction::RebindLoader(_)) => {
            json!({"evidencePolicy": "rockusbLoaderIdentity"})
        }
        ("probeDevice", _) => json!({"evidencePolicy": "postFlashBuild"}),
        ("rebootDevice", _) => json!({"targetMode": "normal", "reason": "rockusbResetAfterFlash"}),
        _ => json!({
            "catalogId": "arkdeck-diagnostics",
            "actionId": "boundedHilog",
            "parameters": {"durationSeconds": 30, "filters": [], "byteBudget": 16 * 1024 * 1024},
            "artifactId": "artifact-capture-post-flash-diagnostics",
        }),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn loader_first_plan_pins_hardware_postflight_without_inventing_a_normal_identity() {
        let mut facts = RockchipFacts {
            target_id: "TGT-LOADER".into(),
            binding_revision: 1,
            identity_sha256: sha256_hex(b"0123456789abcdef"),
            tool_sha256: "c".repeat(64),
            execution_connect_key: "0123456789abcdef".into(),
            device_mode: "loader".into(),
            build_fingerprint: None,
            profile_id: "dayu200".into(),
            server_facts: BTreeMap::from([
                (CROSS_MODE.into(), "satisfied".into()),
                (
                    crate::flash_facts::LOADER_FIRST_POSTFLIGHT.into(),
                    "satisfied".into(),
                ),
                (
                    crate::flash_facts::LOADER_FIRST_CONNECTOR.into(),
                    "d".repeat(64),
                ),
                (
                    crate::flash_facts::LOADER_FIRST_TOPOLOGY.into(),
                    "42".into(),
                ),
            ]),
        };
        let inputs = json!({"deviceProfileRef":"dayu200","artifactLease":"lease-fixture","intent":"fullRestore"});
        assert_eq!(admission_blocker(&facts), None);
        for (step, kind) in [
            ("wait-for-hdc", "waitForReconnect"),
            ("rebind-and-verify-build", "probeDevice"),
            ("capture-post-flash-diagnostics", "captureRemoteStdout"),
        ] {
            let action = action(step, kind, inputs.as_object().unwrap(), &facts, || {
                Some("published-build".into())
            })
            .unwrap();
            assert!(matches!(
                &action,
                RockchipAction::WaitForLoaderHdc(_)
                    | RockchipAction::VerifyLoaderBuild { .. }
                    | RockchipAction::CaptureLoaderPostFlashDiagnostics { .. }
            ));
            assert_eq!(
                RockchipAction::from_persisted(&action.persisted()).unwrap(),
                action
            );
            let encoded = action.persisted().to_string();
            assert!(encoded.contains(&facts.identity_sha256));
            assert!(encoded.contains(&"d".repeat(64)));
            assert!(!encoded.contains("previousHDC"));
        }
        facts
            .server_facts
            .remove(crate::flash_facts::LOADER_FIRST_CONNECTOR);
        assert!(
            admission_blocker(&facts)
                .unwrap()
                .contains("postFlashHDCBindingUnprepared")
        );
        facts.server_facts.insert(
            crate::flash_facts::LOADER_FIRST_CONNECTOR.into(),
            "d".repeat(64),
        );
        facts.device_mode = "hdc".into();
        assert!(
            admission_blocker(&facts).is_some(),
            "the Loader origin cannot authorize an unproved Normal route"
        );
    }

    #[test]
    fn normal_admission_requires_matching_durable_hardware_proof() {
        let identity = "a".repeat(64);
        let mut facts = RockchipFacts {
            target_id: "TGT-PROOF".into(),
            binding_revision: 1,
            identity_sha256: identity.clone(),
            tool_sha256: "c".repeat(64),
            execution_connect_key: "normal-key".into(),
            device_mode: "hdc".into(),
            build_fingerprint: None,
            profile_id: "dayu200".into(),
            server_facts: BTreeMap::from([
                (CROSS_MODE.into(), "satisfied".into()),
                (ALIAS_IDENTITY.into(), sha256_hex(b"normal-key")),
                (ALIAS_TOPOLOGY.into(), "42".into()),
                (
                    "dayu200NormalLoaderHardwareIdentity".into(),
                    "satisfied".into(),
                ),
                ("dayu200NormalHardwareSerialSHA256".into(), identity),
                (
                    "dayu200NormalHardwareObservationSHA256".into(),
                    "b".repeat(64),
                ),
            ]),
        };
        assert_eq!(admission_blocker(&facts), None);
        for (field, invalid) in [
            ("dayu200NormalLoaderHardwareIdentity", "".into()),
            (
                "dayu200NormalLoaderHardwareIdentity",
                "normalLoaderIdentity.observationPersistenceFailed".into(),
            ),
            ("dayu200NormalHardwareSerialSHA256", "d".repeat(64)),
            (
                "dayu200NormalHardwareObservationSHA256",
                "not-a-record".into(),
            ),
        ] {
            let mut denied = facts.clone();
            denied.server_facts.insert(field.into(), invalid);
            assert!(
                admission_blocker(&denied)
                    .unwrap()
                    .starts_with("flash.normalLoaderIdentityUnproven")
            );
            denied.server_facts.remove(field);
            assert!(
                admission_blocker(&denied)
                    .unwrap()
                    .starts_with("flash.normalLoaderIdentityUnproven")
            );
        }
        // Factory SN and CPU identity stay distinct; neither can be omitted.
        facts.server_facts.insert(
            "dayu200NormalLoaderSerialSHA256".into(),
            facts.identity_sha256.clone(),
        );
        facts
            .server_facts
            .insert("dayu200NormalHardwareSerialSHA256".into(), "d".repeat(64));
        assert_eq!(admission_blocker(&facts), None);
        for field in [
            "dayu200NormalLoaderSerialSHA256",
            "dayu200NormalHardwareSerialSHA256",
            "dayu200NormalHardwareObservationSHA256",
        ] {
            let mut denied = facts.clone();
            denied.server_facts.remove(field);
            assert!(admission_blocker(&denied).is_some(), "missing {field}");
        }
        facts.device_mode = "loader".into();
        facts
            .server_facts
            .remove("dayu200NormalHardwareObservationSHA256");
        assert_eq!(
            admission_blocker(&facts),
            None,
            "an already observed Loader needs no Normal transition"
        );
    }

    /// A record root not spelled as its components rebuild it is refused
    /// before anything is created; each parent here does not exist, so a
    /// path that got through would fail its creation instead.
    #[cfg(unix)]
    #[test]
    fn a_record_root_not_spelled_canonically_is_refused_before_it_is_created() {
        for path in [
            "arkdeck-no-such-parent/rockchip-runtime",
            "/arkdeck-no-such-parent/./rockchip-runtime",
            "/arkdeck-no-such-parent/x/../rockchip-runtime",
            "/arkdeck-no-such-parent//rockchip-runtime",
        ] {
            assert_eq!(
                record_root_unavailable(path),
                Some(
                    "durable Rockchip host record root is unavailable: failed(\"Rockchip record \
                     path is not canonical\")"
                        .to_owned()
                ),
                "{path}"
            );
        }
        assert_eq!(
            record_root_unavailable("/arkdeck-no-such-parent/rockchip-runtime"),
            Some(
                "durable Rockchip host record root is unavailable: failed(\"cannot create \
                 Rockchip record directory (errno 2)\")"
                    .to_owned()
            )
        );
    }

    /// The same on Windows, over drive-letter paths; a missing parent is
    /// `ERROR_PATH_NOT_FOUND` (3) where Darwin reports `ENOENT` (2).
    #[cfg(windows)]
    #[test]
    fn a_record_root_not_spelled_canonically_is_refused_before_it_is_created() {
        for path in [
            r"arkdeck-no-such-parent\rockchip-runtime",
            r"C:\arkdeck-no-such-parent\.\rockchip-runtime",
            r"C:\arkdeck-no-such-parent\x\..\rockchip-runtime",
            r"C:\arkdeck-no-such-parent\\rockchip-runtime",
        ] {
            assert_eq!(
                record_root_unavailable(path),
                Some(
                    "durable Rockchip host record root is unavailable: failed(\"Rockchip record \
                     path is not canonical\")"
                        .to_owned()
                ),
                "{path}"
            );
        }
        assert_eq!(
            record_root_unavailable(r"C:\arkdeck-no-such-parent\rockchip-runtime"),
            Some(
                "durable Rockchip host record root is unavailable: failed(\"cannot create \
                 Rockchip record directory (errno 3)\")"
                    .to_owned()
            )
        );
    }

    fn record_root_unavailable(path: &str) -> Option<String> {
        crate::rockchip_records::RockchipRecordStore::new(Path::new(path)).unavailable_reason()
    }
}
