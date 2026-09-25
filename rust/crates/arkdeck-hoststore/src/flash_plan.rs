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
use crate::strict_json::swift_quoted;
use std::path::{Component, Path};
use std::sync::Mutex;

/// Swift `ArkForgeFlashOperation.canonicalReference`.
const CANONICAL: &str = "flash.full-restore@1";
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
const PARTITIONS: [&str; 9] = [
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
    reference == CANONICAL || reference == "flash.dayu200"
}

/// What a Flash plan reads beyond the Artifact and Import owners and the
/// Target's facts, as the daemon composes it: the provider's availability,
/// the dispatcher's and the lane's toolchain.
pub struct FlashPlanning {
    unavailable: Option<String>,
    dispatch_unavailable: Box<dyn Fn() -> Option<String> + Send + Sync>,
    toolchain_sha256: Option<String>,
    /// Swift's daemon-lifetime `flashArchiveProfileCache`: the runtime
    /// build version each exact leased archive declares, or none.
    build_versions: Mutex<BTreeMap<(String, String), Option<String>>>,
}

impl FlashPlanning {
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
            unavailable,
            dispatch_unavailable: Box::new(dispatch_unavailable),
            toolchain_sha256,
            build_versions: Mutex::new(BTreeMap::new()),
        }
    }

    /// Swift `declaredRuntimeBuildVersion`: the version the leased archive's
    /// system image declares, read once per exact lease and digest.
    fn build_version(&self, lease: &str, leased: &LeasedArtifact) -> Option<String> {
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
    prepare_record_root(records)
        .err()
        .map(|error| format!("durable Rockchip host record root is unavailable: {error}"))
}

/// Swift `RockchipRuntimeActionRecordStore.prepareDirectory(allowExisting:
/// true)`: the root created owner-only when missing, its parent then
/// synchronized, and otherwise required to be an owner-only real directory;
/// each refusal as Swift interpolates its `RuntimeDispatchFailure`.
fn prepare_record_root(root: &Path) -> Result<(), String> {
    use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt};
    let failed = |detail: String| format!("failed({})", swift_quoted(&detail));
    // Swift compares the path with its standardized form; here it must be
    // absolute, name no parent, and be spelled exactly as its components
    // rebuild it (no `.`, empty or trailing component). Declared difference:
    // Foundation also strips `/private` from an existing `/private/tmp/…`
    // path, so Swift refuses such a root once it exists; this one does not.
    let canonical = root.is_absolute()
        && !root
            .components()
            .any(|component| component == Component::ParentDir)
        && root
            .components()
            .collect::<std::path::PathBuf>()
            .as_os_str()
            == root.as_os_str();
    if !canonical {
        return Err(failed("Rockchip record path is not canonical".into()));
    }
    let created = match std::fs::DirBuilder::new().mode(0o700).create(root) {
        Ok(()) => true,
        Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => false,
        Err(error) => {
            return Err(failed(format!(
                "cannot create Rockchip record directory (errno {})",
                error.raw_os_error().unwrap_or(0)
            )));
        }
    };
    let owner_only = std::fs::symlink_metadata(root).is_ok_and(|metadata| {
        metadata.file_type().is_dir() && metadata.permissions().mode() & 0o077 == 0
    });
    if !owner_only {
        return Err(failed(
            "Rockchip record directory is not an owner-only real directory".into(),
        ));
    }
    if created {
        let parent = std::fs::OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(root.parent().unwrap_or(root))
            .map_err(|_| {
                failed("cannot open Rockchip record directory for synchronization".into())
            })?;
        parent.sync_all().map_err(|error| {
            failed(format!(
                "cannot synchronize Rockchip record directory (errno {})",
                error.raw_os_error().unwrap_or(0)
            ))
        })?;
    }
    Ok(())
}

/// The Target's facts as Swift's ArkForge facts port reads them
/// (`resolveFacts`), each error as Swift interpolates it.
pub type RockchipFactsPort<'a> = &'a dyn Fn(&str) -> Result<RockchipFacts, String>;

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

impl FlashPlanner<'_> {
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

    /// Swift `materializeTypedPlanBeforeAuthorization` for a Flash request:
    /// the plan document's digest and what it binds, and the provider's
    /// `executionAdmissionBlocker`.
    fn materialize<'b>(
        &self,
        flash: &FlashPlanning,
        request: &OperationRequest,
        descriptor: &CatalogOperation,
    ) -> Result<(Materialized<'b>, Option<String>), PlanRefusal> {
        let reference = descriptor.reference();
        // Converted before anything else is read; a legacy request that
        // cannot be converted fails outside the typed preflight.
        let inputs = canonical_inputs(&reference, &request.inputs).ok_or_else(internal_failure)?;
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
            Some(port) => port(&request.target_id),
            None => Err("production ArkForge target facts are not registered".into()),
        }
        .map_err(|error| unmaterialized(&error))?;
        validate_facts(&facts, &request.target_id, request.expected_binding_revision)
            .map_err(|_| {
                unmaterialized(
                    "failed(\"evidenceIncomplete: target/binding/routing/tool facts are absent or mismatched\")",
                )
            })?;
        let lease_name = if reference == CANONICAL {
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
        self.planner.refuse_debug_permit(request)?;
        let artifact_facts = primary_facts(&leased)?;
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
            let action = action(&step.step_id, &step.kind, &inputs, &facts, || {
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
        let document = json!({
            "operationReference": CANONICAL,
            "catalogDigest": CATALOG_DIGEST,
            "inputs": inputs,
            "targetID": request.target_id,
            "stableTargetIdentitySHA256": facts.identity_sha256,
            "bindingRevision": facts.binding_revision,
            "providerID": "arkforge",
            "steps": steps,
        });
        let digest = sha256_hex(&session_json::encode(&document).map_err(|_| internal_failure())?);
        Ok((
            Materialized {
                _import_use: None,
                _workspace_use: None,
                digest,
                artifact_facts,
                identity: Some(facts.identity_sha256.clone()),
                binding_revision: Some(facts.binding_revision),
            },
            admission_blocker(&facts),
        ))
    }
}

/// Swift `ArkForgeFlashRequest.canonicalInputs`: the alias's inputs as the
/// canonical request names them; none when they cannot be converted.
fn canonical_inputs(reference: &str, inputs: &Map<String, Value>) -> Option<Map<String, Value>> {
    if reference == CANONICAL {
        return Some(inputs.clone());
    }
    let lease = inputs
        .get("imageBundleLease")?
        .as_str()
        .filter(|lease| !lease.is_empty())?;
    let profile = inputs
        .get("deviceProfile")?
        .as_str()
        .filter(|profile| *profile == "dayu200")?;
    let partitions = inputs
        .get("partitionPlan")?
        .as_array()?
        .iter()
        .map(|partition| partition.as_str())
        .collect::<Option<Vec<&str>>>()?;
    if partitions != PARTITIONS {
        return None;
    }
    let verification = inputs
        .get("postFlashVerification")
        .cloned()
        .unwrap_or_else(|| json!("full"));
    Some(Map::from_iter([
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
fn admission_blocker(facts: &RockchipFacts) -> Option<String> {
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
    if !routed {
        return Some(format!(
            "flash.postFlashHDCBindingUnprepared: target {} has no trusted HDC identity and USB \
             topology for postflight",
            facts.target_id
        ));
    }
    None
}

/// Swift `journalStep`'s arguments for the two steps `arkforged` performs:
/// the resolved archive is their identity.
fn delegated_arguments(step: &str, artifact: &BTreeMap<String, String>) -> Option<Value> {
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

/// Swift `RockchipHDCReconnectExpectation`.
#[derive(Clone, Debug, PartialEq, Eq)]
struct Expectation {
    connect_key: String,
    identity: String,
    topology: String,
}

/// Swift `RockchipProviderAction`, the actions a Flash plan names.
#[derive(Clone, Debug, PartialEq, Eq)]
enum Action {
    EnterLoader(String),
    WaitForDisconnect(String),
    WaitForLoader(String),
    RebindLoader(String),
    RebootToNormal(String),
    WaitForBoundReconnect(Expectation),
    VerifyBoundBuild(Expectation, String),
    CaptureDiagnostics(String),
}

impl Action {
    fn effect(&self) -> &'static str {
        match self {
            Self::EnterLoader(_) | Self::RebootToNormal(_) => "deviceMutation",
            _ => "readOnly",
        }
    }

    /// Swift `RockchipHostManagedActionCatalog.identifier(for:)`.
    fn identifier(&self) -> &'static str {
        match self {
            Self::EnterLoader(_) => "rockchip.hdc.enter-loader.v1",
            Self::WaitForDisconnect(_) => "rockchip.hdc.wait-disconnect.v1",
            Self::WaitForLoader(_) => "rockchip.rockusb.wait-loader.v1",
            Self::RebindLoader(_) => "rockchip.rockusb.rebind-loader.v1",
            Self::RebootToNormal(_) => "rockchip.rockusb.reboot-normal.v1",
            Self::WaitForBoundReconnect(_) => "rockchip.hdc.wait-bound-reconnect.v1",
            Self::VerifyBoundBuild(..) => "rockchip.hdc.verify-bound-build.v1",
            Self::CaptureDiagnostics(_) => "rockchip.hdc.capture-post-flash-hilog.v1",
        }
    }

    /// Swift `PersistedTypedProviderAction(.rockchip(action))`, whose
    /// canonical encoding the host-managed descriptor pins.
    fn persisted(&self) -> Value {
        let expectation = |expectation: &Expectation| {
            json!({
                "previousConnectKey": expectation.connect_key,
                "previousIdentitySha256": expectation.identity,
                "usbTopology": expectation.topology,
            })
        };
        let (kind, arguments) = match self {
            Self::EnterLoader(key) => ("rockchip.enterLoader", json!({"connectKey": key})),
            Self::WaitForDisconnect(key) => {
                ("rockchip.waitForHDCDisconnect", json!({"connectKey": key}))
            }
            Self::WaitForLoader(identity) => (
                "rockchip.waitForLoader",
                json!({"stableIdentitySha256": identity}),
            ),
            Self::RebindLoader(identity) => (
                "rockchip.rebindLoader",
                json!({"stableIdentitySha256": identity}),
            ),
            Self::RebootToNormal(identity) => (
                "rockchip.rebootToNormal",
                json!({"stableIdentitySha256": identity}),
            ),
            Self::WaitForBoundReconnect(bound) => {
                ("rockchip.waitForBoundHDCReconnect", expectation(bound))
            }
            Self::VerifyBoundBuild(bound, version) => {
                let mut arguments = expectation(bound);
                arguments["expectedProductModel"] = json!(PRODUCT_MODEL);
                arguments["expectedBuildVersion"] = json!(version);
                ("rockchip.verifyBoundBuild", arguments)
            }
            Self::CaptureDiagnostics(key) => (
                "rockchip.capturePostFlashDiagnostics",
                json!({"connectKey": key, "durationSeconds": 30, "filters": [],
                    "byteBudget": 16 * 1024 * 1024}),
            ),
        };
        json!({"kind": kind, "arguments": arguments})
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
) -> Result<Action, String> {
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
                    connect_key: key.clone(),
                    identity: alias.clone(),
                    topology: topology.clone(),
                })
            }
            _ => Err("post-flash HDC binding expectation is absent or malformed".into()),
        }
    };
    match (step, kind) {
        ("enter-loader-mode", "enterUpdater") => Ok(Action::EnterLoader(key.clone())),
        ("wait-loader-disconnect", "waitForDisconnect") => {
            Ok(Action::WaitForDisconnect(key.clone()))
        }
        ("wait-loader-reconnect", "waitForReconnect") => {
            Ok(Action::WaitForLoader(identity.clone()))
        }
        ("rebind-loader-identity", "probeDevice") => Ok(Action::RebindLoader(identity.clone())),
        ("reboot-device", "rebootDevice") => Ok(Action::RebootToNormal(identity.clone())),
        ("wait-for-hdc", "waitForReconnect") => Ok(Action::WaitForBoundReconnect(expectation()?)),
        ("rebind-and-verify-build", "probeDevice") => {
            flash_bundle(inputs)?;
            let Some(version) = build_version().filter(|version| !version.is_empty()) else {
                return Err(
                    "post-flash verification has no declared build version for the resolved \
                     bundle"
                        .into(),
                );
            };
            Ok(Action::VerifyBoundBuild(expectation()?, version))
        }
        ("capture-post-flash-diagnostics", "captureRemoteStdout") => {
            Ok(Action::CaptureDiagnostics(key.clone()))
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
fn journal_arguments(kind: &str, action: &Action) -> Value {
    match (kind, action) {
        ("enterUpdater", _) => json!({
            "providerOperationId": "rockusb.enter-loader",
            "expectedMode": "Loader",
            "reconnectDeadlineMilliseconds": 45_000,
        }),
        ("waitForDisconnect", _) => {
            json!({"deadlineMilliseconds": 15_000, "reason": "enterLoader"})
        }
        ("waitForReconnect", Action::WaitForLoader(_)) => {
            json!({"deadlineMilliseconds": 45_000, "reason": "loaderReconnect"})
        }
        ("waitForReconnect", _) => {
            json!({"deadlineMilliseconds": 120_000, "reason": "normalModeReconnect"})
        }
        ("probeDevice", Action::RebindLoader(_)) => {
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

    /// A record root not spelled as its components rebuild it is refused
    /// before anything is created; each parent here does not exist, so a
    /// path that got through would fail its creation instead.
    #[test]
    fn a_record_root_not_spelled_canonically_is_refused_before_it_is_created() {
        for path in [
            "arkdeck-no-such-parent/rockchip-runtime",
            "/arkdeck-no-such-parent/./rockchip-runtime",
            "/arkdeck-no-such-parent/x/../rockchip-runtime",
            "/arkdeck-no-such-parent//rockchip-runtime",
        ] {
            assert_eq!(
                prepare_record_root(Path::new(path)),
                Err("failed(\"Rockchip record path is not canonical\")".to_owned()),
                "{path}"
            );
        }
        assert_eq!(
            prepare_record_root(Path::new("/arkdeck-no-such-parent/rockchip-runtime")),
            Err("failed(\"cannot create Rockchip record directory (errno 2)\")".to_owned())
        );
    }
}
