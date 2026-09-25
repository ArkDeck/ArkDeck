//! What a device-bound HDC step is, for the planner, the runner and the result
//! reader alike: the steps the engine performs itself, the typed provider
//! action a catalog step names with the request's inputs, the arguments Swift
//! journals for it, which steps carry the evidence preflight, and the products
//! each step owns. For `debug.hap@1` also the Artifacts a step is given, the
//! compensation each source step declares on its intent, the residue a
//! failed cleanup leaves, and the mutations only a readback may believe. For
//! `deploy.native-library.app-owned@1` the provider's own action of each
//! step, claimed by the operation, the library each step is given, the
//! rollback its plan holds and the cleanup its failure runs, the residue a
//! failed cleanup leaves, the send only its staging readback may believe, and
//! its two reports. For `capture.screen-sequence@1` its file legs, the product
//! a receive lands and the document its finalization writes.
use crate::cleanup_debt::Residue;
use crate::operation_catalog::{CatalogOperation, CatalogStep};
use crate::session_json;
use arkdeck_contract::sha256_hex;
use arkdeck_provider_hdc::FileAction;
use arkdeck_provider_hdc::{
    Action, CodeSignHelper, DEFAULT_HILOG_BUDGET, Deployment, Expected, FileActionError, FilePlan,
    FileReceipt, HapAction, Inspection, NativeAction, Outcome, PointerAction, PortAction, PortRule,
    ProcessPlan, ResolvedArtifact, STORAGE_ROOT,
};
use serde_json::{Map, Value, json};
use std::collections::BTreeSet;
use std::path::Path;

const HAP: &str = "debug.hap@1";
/// The native library deployment, whose device steps are its provider's
/// alone.
pub(crate) const NATIVE: &str = "deploy.native-library.app-owned@1";
/// Swift `HDCAppOwnedNativeLibraryDeployment.entryAbility`: the ability a
/// native deployment's target is restarted through.
const NATIVE_ABILITY: &str = "EntryAbility";
/// The bounded run of stills, whose capture, receive and cleanup are file legs.
pub(crate) const SCREEN_SEQUENCE: &str = "capture.screen-sequence@1";
/// The diagnostic capture, whose legs beyond its default are file legs or
/// reads [`FileAction`] names.
pub(crate) const CAPTURE: &str = "capture.diagnostics@1";

/// The device-bound operations this Runtime plans and runs.
pub(crate) const DEVICE_OPERATIONS: [&str; 11] = [
    "observe.device@1",
    "debug.template@1",
    "capture.diagnostics@1",
    "input.tap@1",
    "input.long-press@1",
    "input.swipe@1",
    "port-forward.create@1",
    "port-forward.remove@1",
    HAP,
    SCREEN_SEQUENCE,
    NATIVE,
];

/// Swift `evidenceEligibleOperations`: the operations whose device steps wait
/// for a complete evidence preflight.
const EVIDENCE_OPERATIONS: [&str; 8] = [
    "observe.device@1",
    "capture.diagnostics@1",
    "debug.hap@1",
    "port-forward.create@1",
    "port-forward.remove@1",
    "input.tap@1",
    "input.long-press@1",
    "input.swipe@1",
];

/// The catalog that names every approved remote read.
const REMOTE_OPERATIONS: &str = "arkdeck-remote-operations";
/// Swift's storage preflight asks for this much when the request sets no
/// `totalArtifactByteBudget`.
const DEFAULT_REQUIRED_BYTES: i64 = 128 * 1024 * 1024;
/// Swift's journal budget for a HiLog capture is the request's
/// `totalArtifactByteBudget` within these bounds, not the lowered budget.
const MAXIMUM_JOURNALED_HILOG_BUDGET: i64 = 128 * 1024 * 1024;
/// Swift's journal budget for the other stdout captures.
const STDOUT_BUDGET: i64 = 8 * 1024 * 1024;

pub(crate) fn requires_evidence_preflight(reference: &str) -> bool {
    EVIDENCE_OPERATIONS.contains(&reference)
}

/// Swift's engine-internal host steps: materialized as the engine's own, and
/// never dispatched to a provider.
pub(crate) fn engine_step(kind: &str) -> bool {
    matches!(
        kind,
        "preflightHostStorage"
            | "postprocessArtifact"
            | "finalizeSession"
            | "hashFile"
            | "verifyArtifact"
            | "requestConfirmation"
    )
}

/// The `arkdeck-remote-operations` action an approved remote step names.
fn remote_action(step: &CatalogStep) -> Option<&str> {
    step.action
        .as_ref()
        .filter(|(catalog, _)| catalog == REMOTE_OPERATIONS)
        .map(|(_, action)| action.as_str())
}

/// The catalog action a stdout capture names, whichever catalog holds it.
fn catalog_action(step: &CatalogStep) -> Option<&str> {
    step.action.as_ref().map(|(_, action)| action.as_str())
}

fn integer(inputs: &Map<String, Value>, key: &str) -> Option<i64> {
    inputs.get(key).and_then(Value::as_i64)
}

/// Swift's HiLog window: `durationSeconds`, else `diagnosticsDurationSeconds`,
/// within 1 to 600 s, else 30 s.
fn hilog_duration(inputs: &Map<String, Value>) -> i64 {
    integer(inputs, "durationSeconds")
        .or_else(|| integer(inputs, "diagnosticsDurationSeconds"))
        .map_or(30, |seconds| seconds.clamp(1, 600))
}

/// The request's HiLog filters: its string items.
fn hilog_filters(inputs: &Map<String, Value>) -> Vec<&str> {
    inputs
        .get("hilogFilters")
        .and_then(Value::as_array)
        .map(|values| values.iter().filter_map(Value::as_str).collect())
        .unwrap_or_default()
}

/// Why a step the request selected has no typed action here.
pub(crate) enum ActionRefusal {
    /// Swift's provider has one, but this Runtime has not ported it yet.
    Unported,
    /// Swift's provider refuses the request for it, with its interpolated
    /// error.
    Invalid(String),
}

/// What a step is named, journaled and lowered within (Swift
/// `ProviderExecutionContext`): its Job (before admission, the authorization
/// envelope a plan is materialized for), the Artifacts its leases resolved
/// to, the entry package first, and for a native deployment the leased
/// library as read for the step and the code-sign helper its composition
/// verified.
pub(crate) struct StepContext<'a> {
    pub(crate) job_id: &'a str,
    pub(crate) resolved: &'a [ResolvedArtifact],
    pub(crate) library: Option<&'a LeasedLibrary>,
    pub(crate) helper: Option<&'a CodeSignHelper>,
}

/// The context of a step given nothing: no Job's paths, no Artifact, no
/// library and no helper.
pub(crate) const NO_CONTEXT: StepContext<'static> = StepContext {
    job_id: "",
    resolved: &[],
    library: None,
    helper: None,
};

/// A leased native library as the Job owner read it for a step: its bytes,
/// and the byte count its lease records (Swift
/// `ProviderResolvedInputArtifact.byteCount`).
pub(crate) struct LeasedLibrary {
    pub(crate) bytes: Vec<u8>,
    pub(crate) byte_count: i64,
}

/// A device step's typed provider action: an observation or capture action,
/// a pointer gesture, a port rule's change or readback, a debug HAP's action,
/// or a native library deployment's.
pub(crate) enum StepAction {
    Hdc(Action),
    Template(arkdeck_provider_hdc::DebugReadTemplate),
    Pointer(PointerAction),
    Port(PortAction),
    Hap(HapAction),
    Native(Box<NativeAction>),
    /// A screen sequence's capture, receive or cleanup, with the clock of the
    /// provider context it was named in (Swift `context.nowUTC`, which a file
    /// leg's verdict may read).
    File {
        action: FileAction,
        now_utc: String,
    },
}

impl StepAction {
    pub(crate) fn persisted(&self) -> (&'static str, Map<String, Value>) {
        match self {
            Self::Template(template) => (
                "hdc.runDebugTemplate",
                Map::from_iter([("templateId".into(), json!(template.raw()))]),
            ),
            Self::Pointer(action) => action.persisted(),
            Self::Port(action) => action.persisted(),
            Self::Hap(action) => action.persisted(),
            Self::Native(action) => action.persisted(),
            Self::File { action, .. } => {
                let (kind, arguments) = action.persisted();
                let values = arguments
                    .into_iter()
                    .map(|(key, value)| (key.to_owned(), persisted_value(value)))
                    .collect();
                (kind, values)
            }
            Self::Hdc(action) => {
                let (kind, arguments) = action.persisted();
                let values = arguments
                    .into_iter()
                    .map(|(key, value)| {
                        let value = match value {
                            arkdeck_provider_hdc::Persisted::Text(text) => json!(text),
                            arkdeck_provider_hdc::Persisted::Integer(number) => json!(number),
                            arkdeck_provider_hdc::Persisted::Texts(texts) => json!(texts),
                        };
                        (key.to_owned(), value)
                    })
                    .collect();
                (kind, values)
            }
        }
    }

    /// The provider's verdict on the step's receipt. Every action but a debug
    /// HAP's, a native deployment's and a screen sequence's file leg lowers to
    /// one process and is judged by it; a gesture's and a port rule's name no
    /// device fact. A HAP action, a native action and a file leg are judged
    /// over the whole receipt (a file leg's landed bytes included), and a
    /// package readback binds its verdict to the digest of the entry package
    /// the Job resolved (`resolved_sha256`).
    pub(crate) fn verify(
        &self,
        receipt: &FileReceipt,
        expected: Expected<'_>,
        resolved_sha256: Option<&str>,
    ) -> Outcome {
        match (self, receipt.subprocesses.first()) {
            (Self::Hap(action), _) => action.verify(receipt, resolved_sha256),
            (Self::Native(action), _) => action.verify(receipt),
            (Self::File { action, now_utc }, _) => action.verify(receipt, now_utc),
            (_, None) => Outcome::Unknown("dispatch produced no process result".into()),
            (Self::Hdc(action), Some(sole)) => action.verify(sole, expected),
            (Self::Template(template), Some(sole)) => template.verify(sole),
            (Self::Pointer(action), Some(sole)) => action.verify(sole),
            (Self::Port(action), Some(sole)) => action.verify(sole),
        }
    }

    pub(crate) fn effect(&self) -> &'static str {
        match self {
            Self::Hdc(action) => action.effect(),
            Self::Template(_) => "readOnly",
            Self::Pointer(action) => action.effect(),
            Self::Port(action) => action.effect(),
            Self::Hap(action) => action.effect(),
            Self::Native(action) => action.effect(),
            Self::File { action, .. } => action.effect(),
        }
    }

    /// The one process the step lowers to, against the Target's connect key.
    pub(crate) fn lower(
        &self,
        step_id: &str,
        connect_key: Option<&str>,
    ) -> Result<ProcessPlan, String> {
        match self.plan(step_id, connect_key, &NO_CONTEXT)? {
            FilePlan::Process(plan) => Ok(plan),
            _ => Err(format!("{step_id} did not lower to one process")),
        }
    }

    /// The process or process sequence the step's executor runs (Swift
    /// `lower(action:context:)`), against the Target's connect key within the
    /// step's context: the Artifacts a send stages and, for a native
    /// deployment, the byte count the library's lease records and the helper
    /// its send stages.
    pub(crate) fn plan(
        &self,
        step_id: &str,
        connect_key: Option<&str>,
        context: &StepContext<'_>,
    ) -> Result<FilePlan, String> {
        match self {
            Self::Hdc(action) => action.lower(step_id, connect_key).map(FilePlan::Process),
            Self::Template(template) => connect_key
                .map(|key| FilePlan::Process(template.plan(key)))
                .ok_or_else(|| format!("{step_id} requires a bound connect key")),
            Self::Pointer(action) => action.lower(step_id, connect_key),
            Self::Port(action) => action.lower(step_id, connect_key),
            Self::Hap(action) => action.lower(step_id, connect_key, context.resolved),
            Self::Native(action) => action.lower(
                step_id,
                connect_key,
                context.resolved.first(),
                context.library.map(|library| library.byte_count),
                context.helper,
            ),
            // Only a receive's argv names a host path.
            Self::File { action, .. } => action.lower_in(step_id, connect_key, None),
        }
    }

    /// [`Self::plan`] within an HDC composition: a receive lowers with the
    /// composition's host receive root (Swift `hostReceiveRoot`), where the
    /// received file lands; a composition without one receives nothing.
    pub(crate) fn plan_in(
        &self,
        step_id: &str,
        connect_key: Option<&str>,
        context: &StepContext<'_>,
        receive_root: Option<&Path>,
    ) -> Result<FilePlan, String> {
        match self {
            Self::File { action, .. } => action.lower_in(step_id, connect_key, receive_root),
            _ => self.plan(step_id, connect_key, context),
        }
    }
}

/// Swift's interpolation of a provider's refusal of a request: a
/// `DeviceProviderError` describes itself by its detail alone, a bound the
/// request breaks as `HDCE0RequestError` spells it.
pub(crate) fn refusal_detail(error: FileActionError) -> String {
    match error {
        FileActionError::Unsupported(detail) => detail,
        FileActionError::Request(error) => error.to_string(),
    }
}

/// A provider module's answer for a step: its action, no action because the
/// step is not its, or Swift's refusal — the provider error's detail alone,
/// or a bound the request breaks, interpolated.
fn claim<T>(
    answer: Result<Option<T>, FileActionError>,
    wrap: fn(T) -> StepAction,
) -> Option<Result<StepAction, ActionRefusal>> {
    match answer {
        Ok(Some(action)) => Some(Ok(wrap(action))),
        Ok(None) => None,
        Err(FileActionError::Unsupported(detail)) => Some(Err(ActionRefusal::Invalid(detail))),
        Err(FileActionError::Request(error)) => {
            Some(Err(ActionRefusal::Invalid(error.to_string())))
        }
    }
}

/// Swift's journal identity of a port rule.
fn forward_id(rule: &PortRule) -> String {
    format!(
        "port_forward_{}_{}_{}",
        rule.direction.raw(),
        rule.local_port,
        rule.remote_port
    )
}

/// Swift `HDCObservationProviderAdapter.action` for a catalog step of
/// `reference`, with the request's inputs and the provider context's clock.
pub(crate) fn action(
    step: &CatalogStep,
    reference: &str,
    inputs: &Map<String, Value>,
    now_utc: &str,
) -> Result<StepAction, ActionRefusal> {
    if reference == "debug.template@1"
        && step.step_id == "run-debug-template"
        && step.kind == "runApprovedRemoteRead"
    {
        return inputs
            .get("templateId")
            .and_then(Value::as_str)
            .and_then(arkdeck_provider_hdc::DebugReadTemplate::parse)
            .map(StepAction::Template)
            .ok_or_else(|| {
                ActionRefusal::Invalid("a closed Debug template identity is required".into())
            });
    }
    if let Some(action) = Action::for_step(&step.kind, remote_action(step)) {
        return Ok(StepAction::Hdc(action));
    }
    if let Some(answer) = claim(
        PointerAction::for_step(&step.kind, reference, inputs, now_utc),
        StepAction::Pointer,
    ) {
        return answer;
    }
    if let Some(answer) = claim(
        PortAction::for_step(&step.kind, reference, inputs),
        StepAction::Port,
    ) {
        return answer;
    }
    let invalid =
        |error: arkdeck_provider_hdc::RequestError| ActionRefusal::Invalid(error.to_string());
    let action = match (step.kind.as_str(), catalog_action(step)) {
        ("preflightDeviceStorage", _) => Action::observe_storage(
            integer(inputs, "totalArtifactByteBudget").unwrap_or(DEFAULT_REQUIRED_BYTES),
        )
        .map_err(invalid)?,
        ("captureRemoteStdout", Some("windowInventory")) => Action::CaptureWindowList,
        ("captureRemoteStdout", Some("boundedHilog")) => Action::capture_hilog(
            hilog_duration(inputs),
            hilog_filters(inputs)
                .into_iter()
                .map(str::to_owned)
                .collect(),
            DEFAULT_HILOG_BUDGET,
        )
        .map_err(invalid)?,
        _ => return Err(ActionRefusal::Unported),
    };
    Ok(StepAction::Hdc(action))
}

/// Swift `HDCObservationProviderAdapter.action` for a step run within
/// `context`: a native deployment's steps are its provider's alone, claimed
/// by the operation before any step kind, since the other providers share
/// those kinds; a debug HAP's own step kinds are its provider module's, with
/// the owned paths minted for the Job and the Artifacts resolved for the
/// step; a screen sequence's capture, receive and cleanup are its file legs
/// for the Job; every other step is named as [`action`] names it.
pub(crate) fn action_in(
    step: &CatalogStep,
    reference: &str,
    inputs: &Map<String, Value>,
    now_utc: &str,
    context: &StepContext<'_>,
) -> Result<StepAction, ActionRefusal> {
    if reference == NATIVE {
        return native_action(step, inputs, context);
    }
    if reference == HAP
        && let Some(answer) = claim(
            HapAction::for_step(
                &step.step_id,
                &step.kind,
                remote_action(step),
                inputs,
                context.job_id,
                context.resolved,
            ),
            StepAction::Hap,
        )
    {
        return answer;
    }
    // A screen sequence's capture, receive and cleanup are its file legs,
    // each naming the Job's own frame directory and archive.
    if matches!(reference, SCREEN_SEQUENCE | CAPTURE) {
        let named = FileAction::for_step(
            &step.step_id,
            &step.kind,
            catalog_action(step),
            inputs,
            context.job_id,
        );
        match named {
            Ok(Some(action)) => {
                return Ok(StepAction::File {
                    action,
                    now_utc: now_utc.to_owned(),
                });
            }
            Ok(None) => {}
            Err(FileActionError::Unsupported(detail)) => {
                return Err(ActionRefusal::Invalid(detail));
            }
            Err(FileActionError::Request(error)) => {
                return Err(ActionRefusal::Invalid(error.to_string()));
            }
        }
    }
    action(step, reference, inputs, now_utc)
}

/// Swift `nativeLibraryAction`: the deployment the request names over the
/// library its lease resolved to, as the context read it, verified by the
/// provider as the expected ABI's code-signed ELF whose facts are the
/// deployment's, and still the byte count the lease records; then the
/// step's action on it. A refusal is the provider error's detail alone.
fn native_action(
    step: &CatalogStep,
    inputs: &Map<String, Value>,
    context: &StepContext<'_>,
) -> Result<StepAction, ActionRefusal> {
    let refused = |error: FileActionError| match error {
        FileActionError::Unsupported(detail) => ActionRefusal::Invalid(detail),
        FileActionError::Request(error) => ActionRefusal::Invalid(error.to_string()),
    };
    let bytes = context
        .library
        .map_or(&[][..], |library| library.bytes.as_slice());
    let deployment = Deployment::from_inputs(
        inputs,
        context.job_id,
        context.resolved.first(),
        bytes,
        context.helper,
    )
    .map_err(refused)?;
    if context
        .library
        .is_some_and(|library| library.byte_count != deployment.artifact_facts.byte_count)
    {
        return Err(ActionRefusal::Invalid(
            "leased native Artifact bytes drifted during materialization".into(),
        ));
    }
    match NativeAction::for_step(&step.step_id, &deployment).map_err(refused)? {
        Some(action) => Ok(StepAction::Native(Box::new(action))),
        // A host step (`verify-elf-locally`, `hash-library`) is the engine's.
        None => Err(ActionRefusal::Unported),
    }
}

/// Swift `journalStep(for:)` arguments of a native deployment's actions, by
/// the step kind journaling them: what a send stages and from which
/// Artifact, the expectation of the staging readback, the paths, digest and
/// build ID a backup, a publish and a rollback change under the Runtime's
/// admission, the bundle and ability a restart names, the loader probe, and
/// the staging a cleanup removes on behalf of the Job. Never a host path or
/// the helper.
fn native_arguments(
    step: &CatalogStep,
    action: &NativeAction,
    context: &StepContext<'_>,
) -> Option<Value> {
    let deployment = action.deployment();
    let facts = &deployment.artifact_facts;
    let mutation = |action_id: &str| {
        json!({"catalogId": REMOTE_OPERATIONS, "actionId": action_id,
            "parameters": {"targetPath": deployment.target_path,
                "stagingPath": deployment.staging_path, "backupPath": deployment.backup_path,
                "rollbackStagingPath": deployment.rollback_staging_path,
                "expectedSha256": facts.sha256, "buildId": facts.build_id},
            "artifactId": "native-library-mutation",
            "confirmationId": "runtime-capability-admission"})
    };
    Some(match (step.kind.as_str(), action) {
        ("cleanupOwnedRemotePath", NativeAction::Cleanup(_)) => {
            json!({"remotePath": deployment.staging_path,
                "ownershipEvidenceId": format!("owned-{}", context.job_id)})
        }
        ("sendFile", NativeAction::SendToStaging(_)) => {
            let resolved = context.resolved.first()?;
            json!({"sourceArtifactId": resolved.artifact_id,
                "remotePath": deployment.staging_path, "sourceSha256": resolved.sha256})
        }
        (
            "startApplication" | "stopApplication",
            NativeAction::StartTarget(_) | NativeAction::StopTarget(_),
        ) => json!({"bundleName": deployment.bundle.bundle_name(), "abilityName": NATIVE_ABILITY}),
        ("runApprovedRemoteRead", NativeAction::Inspect(_, expectation)) => {
            json!({"catalogId": REMOTE_OPERATIONS, "actionId": "nativeLibraryInspection",
                "parameters": {"expectation": expectation.raw(),
                    "targetPath": deployment.target_path, "expectedSha256": facts.sha256,
                    "buildId": facts.build_id},
                "artifactId": "native-library-readback"})
        }
        ("runApprovedRemoteMutation", NativeAction::Backup(_)) => mutation("nativeLibraryBackup"),
        ("runApprovedRemoteMutation", NativeAction::Publish(_)) => {
            mutation("nativeLibraryAtomicPublish")
        }
        ("runApprovedRemoteMutation", NativeAction::Rollback(_)) => {
            mutation("nativeLibraryRollback")
        }
        ("verifyRemoteState", NativeAction::Inspect(_, Inspection::TargetLoaded)) => {
            json!({"probeId": "native-library-loader",
                "expectedState": format!("loaded:{}", facts.sha256)})
        }
        _ => return None,
    })
}

/// The rollback Swift's engine synthesizes for a native deployment: the step
/// that restores the backed-up library after a failure past the publish,
/// which its plan holds after every selected step.
pub(crate) fn native_rollback() -> CatalogStep {
    CatalogStep {
        step_id: "rollback-native-library".into(),
        kind: "runApprovedRemoteMutation".into(),
        effect: "deviceMutation".into(),
        cancellation: "atSafeBoundary".into(),
        binding: "confirmedDevice".into(),
        optional: false,
        action: None,
    }
}

/// The cleanup Swift's engine synthesizes after a native deployment's
/// failure, whether or not the publish was attempted: what the deployment
/// staged, removed as a best effort.
pub(crate) fn native_compensation_cleanup() -> CatalogStep {
    CatalogStep {
        step_id: "cleanup-native-library-compensation".into(),
        kind: "cleanupOwnedRemotePath".into(),
        effect: "deviceMutation".into(),
        cancellation: "atSafeBoundary".into(),
        binding: "confirmedDevice".into(),
        optional: true,
        action: None,
    }
}

/// Swift `journalStep(for:)` arguments of a debug HAP's own actions: what a
/// send stages and from which Artifact, which package an install names, the
/// bundle a readback, a start, a stop and an uninstall name, and the staging a
/// cleanup removes on behalf of `job_id`.
pub(crate) fn hap_journal_arguments(
    action: &HapAction,
    step: &CatalogStep,
    inputs: &Map<String, Value>,
    job_id: &str,
    resolved: &[ResolvedArtifact],
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
            json!({"remotePath": path.remote_path, "ownershipEvidenceId": format!("owned-{job_id}")})
        }
        HapAction::CleanupStagedPackageSet(set) => {
            json!({"remotePath": set.directory.remote_path,
                "ownershipEvidenceId": format!("owned-{job_id}")})
        }
        HapAction::QueryPackageReadback(bundle) => {
            json!({"catalogId": REMOTE_OPERATIONS, "actionId": "packageInfo",
                "parameters": {"bundleName": bundle.bundle_name()},
                "artifactId": format!("artifact-{}", step.step_id)})
        }
        HapAction::VerifyProcessState(bundle) => {
            json!({"probeId": format!("process.{}", bundle.bundle_name()),
                "expectedState": "running"})
        }
        _ => return None,
    })
}

/// Swift `journalStep(for:)` arguments of a step run within `context`.
pub(crate) fn journal_arguments_in(
    step: &CatalogStep,
    reference: &str,
    inputs: &Map<String, Value>,
    action: &StepAction,
    context: &StepContext<'_>,
) -> Option<Value> {
    match action {
        StepAction::Hap(hap) => {
            hap_journal_arguments(hap, step, inputs, context.job_id, context.resolved)
        }
        StepAction::Native(native) => native_arguments(step, native, context),
        StepAction::File { action, .. } => file_journal_arguments(action, step, context.job_id),
        _ => journal_arguments_for(step, reference, inputs, action),
    }
}

/// Swift `RuntimeDebugHAPFailureFinalization.sourceSteps`, each with the
/// catalog step that undoes it.
const HAP_COMPENSATIONS: [(&str, &str); 3] = [
    ("send-hap", "cleanup-remote-staging"),
    ("install-hap", "cleanup-uninstall"),
    ("start-ability", "stop-ability"),
];

/// Swift `RuntimeDebugHAPFailureFinalization.descriptorID(forCatalogStepID:)`.
pub(crate) fn compensation_id(step_id: &str) -> String {
    format!("compensation-{step_id}")
}

/// Swift `catalogStepID(forSourceStepID:)`: the catalog step that undoes a
/// debug HAP's source step.
pub(crate) fn hap_compensation_step(source: &str) -> Option<&'static str> {
    HAP_COMPENSATIONS
        .iter()
        .find(|(step, _)| *step == source)
        .map(|(_, compensation)| *compensation)
}

/// The source step a debug HAP's cleanup step undoes.
pub(crate) fn hap_source_of(compensation: &str) -> Option<&'static str> {
    HAP_COMPENSATIONS
        .iter()
        .find(|(_, step)| *step == compensation)
        .map(|(source, _)| *source)
}

/// Swift `catalogStepID(forDescriptorID:)`.
pub(crate) fn compensation_catalog_step(descriptor_id: &str) -> Option<&'static str> {
    HAP_COMPENSATIONS
        .iter()
        .map(|(_, step)| *step)
        .find(|step| compensation_id(step) == descriptor_id)
}

/// Swift `debugHAPCompensationStep(forSourceStepID:descriptor:inputs:)`: the
/// catalog step that would undo `source`, where one applies. The uninstall
/// applies only under the `uninstall` cleanup policy; the stop applies even
/// when success leaves the ability running.
pub(crate) fn hap_compensation<'a>(
    descriptor: &'a CatalogOperation,
    inputs: &Map<String, Value>,
    source: &str,
) -> Option<&'a CatalogStep> {
    if descriptor.reference() != HAP {
        return None;
    }
    let step = hap_compensation_step(source)?;
    if source == "install-hap"
        && descriptor.resolved("cleanupPolicy", inputs) != Some(&json!("uninstall"))
    {
        return None;
    }
    descriptor
        .steps
        .iter()
        .find(|catalog| catalog.step_id == step)
}

/// Swift's `CompensationDescriptor` for a compensation step's action: its
/// journal step under the compensation's identity, triggered on failure, with
/// the digest of its arguments.
pub(crate) fn declared_descriptor(
    step: &CatalogStep,
    reference: &str,
    inputs: &Map<String, Value>,
    action: &StepAction,
    context: &StepContext<'_>,
) -> Option<Value> {
    let arguments = journal_arguments_in(step, reference, inputs, action, context)?;
    let hash = sha256_hex(&session_json::encode(&arguments).ok()?);
    Some(json!({
        "id": compensation_id(&step.step_id), "kind": step.kind, "effect": step.effect,
        "cancellation": step.cancellation, "bindingRequirement": step.binding,
        "trigger": "onFailure", "arguments": arguments, "argumentsHash": hash,
    }))
}

/// Swift `debugHAPCompensationDeclaration(for:descriptor:inputs:provider:context:)`:
/// what a debug HAP's source step declares on its intent, the compensation
/// that would undo it named from the provider's action within the source's
/// own context. Every other step declares none; `None` is Swift's internal
/// failure, a compensation whose action does not have its catalog effect.
pub(crate) fn compensation_declarations(
    source: &CatalogStep,
    descriptor: &CatalogOperation,
    inputs: &Map<String, Value>,
    now_utc: &str,
    context: &StepContext<'_>,
) -> Option<Vec<Value>> {
    let Some(step) = hap_compensation(descriptor, inputs, &source.step_id) else {
        return Some(Vec::new());
    };
    let reference = descriptor.reference();
    let action = action_in(step, &reference, inputs, now_utc, context).ok()?;
    if action.effect() != step.effect {
        return None;
    }
    Some(vec![declared_descriptor(
        step, &reference, inputs, &action, context,
    )?])
}

/// Swift `cleanupResidue(for:)`: what a cleanup was to remove, a debug HAP's
/// staged path or installed bundle, a native deployment's staging, or a
/// capture's owned temporary file. A screen sequence's cleanup owes none: its
/// residue is a verdict of its own (`sequenceCleanupResidue`).
pub(crate) fn cleanup_residue(action: &StepAction) -> Option<Residue> {
    match action {
        StepAction::Native(native) => match native.as_ref() {
            NativeAction::Cleanup(deployment) => {
                Some(Residue::RemotePath(deployment.staging_path.clone()))
            }
            _ => None,
        },
        StepAction::Hap(HapAction::CleanupOwnedRemotePath { path }) => {
            Some(Residue::RemotePath(path.remote_path.clone()))
        }
        StepAction::Hap(HapAction::CleanupStagedPackageSet(set)) => {
            Some(Residue::RemotePath(set.directory.remote_path.clone()))
        }
        StepAction::Hap(HapAction::UninstallPackage(bundle)) => {
            Some(Residue::InstalledBundle(bundle.bundle_name().to_owned()))
        }
        // A capture's provider-owned temporary file, whichever leg wrote it.
        StepAction::File {
            action: FileAction::CleanupOwnedRemotePath { path },
            ..
        } => Some(Residue::RemotePath(path.remote_path.clone())),
        _ => None,
    }
}

/// Swift `RuntimeJobEngine.readbackPairs`: the mutations whose truth is
/// delegated to the readback step after them.
const READBACK_PAIRS: [(&str, &str, &str); 5] = [
    (HAP, "install-hap", "package-readback"),
    (HAP, "start-ability", "process-readback"),
    (NATIVE, "send-to-staging", "verify-remote-staging"),
    (
        "port-forward.create@1",
        "create-port-rule",
        "verify-port-rule",
    ),
    (
        "port-forward.remove@1",
        "remove-port-rule",
        "verify-port-rule",
    ),
];

/// Swift `awaitsReadback(step:descriptor:)`: a mutation whose provider
/// cannot believe it on its own succeeds as a dispatch when a required
/// readback step follows, which alone may believe it.
pub(crate) fn awaits_readback(descriptor: &CatalogOperation, step_id: &str) -> bool {
    let reference = descriptor.reference();
    READBACK_PAIRS
        .iter()
        .find(|(operation, mutation, _)| *operation == reference && *mutation == step_id)
        .is_some_and(|(_, _, readback)| {
            descriptor
                .steps
                .iter()
                .any(|step| step.step_id == *readback && !step.optional)
        })
}

/// Which of a Job's input Artifacts a step is given, resolved from their
/// leases again immediately before it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum StepInputs {
    None,
    /// The entry package alone, or a native deployment's library.
    Entry,
    /// The entry package, then every additional package.
    All,
}

/// Swift's input Artifacts per step of the operations run here: a debug
/// HAP's send is given every package it stages, its install and its approved
/// remote reads the entry package; every provider step of a native
/// deployment is given its library. No other operation run here takes one.
pub(crate) fn step_inputs(reference: &str, kind: &str) -> StepInputs {
    match (reference, kind) {
        (HAP, "sendFile") => StepInputs::All,
        (HAP, "installPackage" | "runApprovedRemoteRead") | (NATIVE, _) => StepInputs::Entry,
        _ => StepInputs::None,
    }
}

/// Swift `journalStep(for:)` arguments for the kinds this Runtime
/// materializes, for a step journaled under operation `reference`.
pub(crate) fn journal_arguments(
    step: &CatalogStep,
    inputs: &Map<String, Value>,
    action: &StepAction,
) -> Option<Value> {
    if let StepAction::Template(template) = action {
        return Some(
            json!({"catalogId":"arkdeck-remote-operations","actionId":"debugTemplate","parameters":{"templateId":template.raw()},"artifactId":"template-output"}),
        );
    }
    Some(match step.kind.as_str() {
        "probeHostTool" => {
            json!({"toolIdentity": "hdc", "candidatePath": "resolved-by-provider"})
        }
        "probeHDCServer" => {
            json!({"endpoint": "resolved-by-provider", "clientIdentity": "arkdeck-agentd"})
        }
        "probeDevice" => json!({"evidencePolicy": "coreMinimum"}),
        "runApprovedRemoteRead" => json!({
            "catalogId": REMOTE_OPERATIONS,
            "actionId": remote_action(step)?,
            "parameters": {},
            "artifactId": format!("artifact-{}", step.step_id),
        }),
        "preflightDeviceStorage" => {
            let required = match action {
                StepAction::Hdc(Action::ObserveStorage { required_bytes }) => *required_bytes,
                _ => 1_048_576,
            };
            json!({"remotePath": STORAGE_ROOT, "requiredBytes": required})
        }
        // The gesture and the frame it was mapped against, which a later
        // reader needs to tell what the coordinates meant; not the frame's
        // capture time.
        "injectPointerInput" => {
            let StepAction::Pointer(PointerAction(spec)) = action else {
                return None;
            };
            let (_, mut arguments) = spec.persisted();
            arguments.remove("screenEpochUtc");
            Value::Object(arguments)
        }
        // The rule and its two endpoints, host first whatever the direction.
        "createPortForward" => {
            let StepAction::Port(PortAction::Create(rule)) = action else {
                return None;
            };
            json!({"forwardId": forward_id(rule),
                "hostEndpoint": format!("tcp:{}", rule.local_port),
                "deviceEndpoint": format!("tcp:{}", rule.remote_port)})
        }
        "removePortForward" => {
            let StepAction::Port(PortAction::Remove(rule)) = action else {
                return None;
            };
            json!({"forwardId": forward_id(rule)})
        }
        // The rule's readback; `journal_arguments_for` names what a remove
        // expects instead.
        "verifyRemoteState" => {
            let StepAction::Port(PortAction::ReadPresence(rule)) = action else {
                return None;
            };
            json!({"probeId": format!("port-forward.{}.{}.{}", rule.direction.raw(),
                    rule.local_port, rule.remote_port),
                "expectedState": "present"})
        }
        // The action is the catalog's own, never one guessed from the step.
        "captureRemoteStdout" => {
            let (catalog, action_id) = step.action.as_ref()?;
            let parameters = match action_id.as_str() {
                "boundedHilog" => {
                    let filters: Vec<&str> = hilog_filters(inputs).into_iter().take(16).collect();
                    let budget = integer(inputs, "totalArtifactByteBudget")
                        .map_or(DEFAULT_HILOG_BUDGET, |budget| {
                            budget.clamp(1024, MAXIMUM_JOURNALED_HILOG_BUDGET)
                        });
                    json!({"durationSeconds": hilog_duration(inputs), "filters": filters,
                        "byteBudget": budget})
                }
                "componentTree" | "windowInventory" | "crashIndex" => {
                    json!({"byteBudget": STDOUT_BUDGET})
                }
                _ => return None,
            };
            json!({"catalogId": catalog, "actionId": action_id, "parameters": parameters,
                "artifactId": format!("artifact-{}", step.step_id)})
        }
        _ => return None,
    })
}

/// Swift's journal arguments for a step of the operation `reference`. Only a
/// port rule's readback depends on the operation it serves: a remove expects
/// the rule absent.
pub(crate) fn journal_arguments_for(
    step: &CatalogStep,
    reference: &str,
    inputs: &Map<String, Value>,
    action: &StepAction,
) -> Option<Value> {
    let mut arguments = journal_arguments(step, inputs, action)?;
    if step.kind == "verifyRemoteState" && reference == "port-forward.remove@1" {
        arguments["expectedState"] = json!("absent");
    }
    Some(arguments)
}

/// Swift `isEvidencePreflightStep`.
pub(crate) fn evidence_preflight_step(step: &CatalogStep) -> bool {
    match step.step_id.as_str() {
        "confirm-evidence-target" => step.kind == "probeDevice",
        "read-evidence-model" => {
            step.kind == "runApprovedRemoteRead" && remote_action(step) == Some("deviceModel")
        }
        "read-evidence-firmware" => {
            step.kind == "runApprovedRemoteRead" && remote_action(step) == Some("firmwareBuild")
        }
        _ => false,
    }
}

/// Swift `RuntimeArtifactService.artifactMapping` for these operations: the
/// products a step publishes once its outcome is durable.
pub(crate) fn products(operation: &str, step_id: &str) -> &'static [&'static str] {
    match (operation, step_id) {
        ("observe.device@1", "probe-host-tool") => &["tool-facts.json"],
        ("observe.device@1", "read-evidence-firmware") => {
            &["device-facts.json", "binding-snapshot.json"]
        }
        ("capture.diagnostics@1", "observe-application-liveness") => &["application-liveness.json"],
        ("capture.diagnostics@1", "capture-hilog") => &["hilog.txt"],
        ("capture.diagnostics@1", "capture-ui-dump") => &["ui-dump.json"],
        ("capture.diagnostics@1", "capture-advanced-ui-dump") => &["advanced-dump.txt"],
        ("capture.diagnostics@1", "receive-trace-artifact") => &["trace.htrace"],
        ("capture.diagnostics@1", "receive-ui-tree") => &["ui-tree.json"],
        ("capture.diagnostics@1", "receive-screenshot") => &["screenshot.png", "screenshot.jpeg"],
        ("capture.diagnostics@1", "capture-crash-index") => &["crash-index.txt"],
        ("capture.diagnostics@1", "capture-crash-log") => &["crash-log.txt"],
        ("port-forward.create@1" | "port-forward.remove@1", "verify-port-rule") => {
            &["port-rule-readback.json"]
        }
        ("debug.template@1", "run-debug-template") => {
            &["template-output.txt", "template-report.json"]
        }
        (HAP, "package-readback") => &["install-readback.json"],
        (HAP, "process-readback") => &["process-readback.json"],
        (HAP, "capture-diagnostics") => &["debug-hilog.txt"],
        (SCREEN_SEQUENCE, "receive-screen-sequence") => &["frames.tar"],
        (NATIVE, "atomic-publish") => &["publish-report.json"],
        (NATIVE, "verify-loaded-library") => &["verification-report.json"],
        // The Flash alias reads the canonical operation's products.
        ("flash.full-restore@1" | "flash.dayu200", "rebind-and-verify-build") => {
            &["post-flash-facts.json"]
        }
        ("flash.full-restore@1" | "flash.dayu200", "capture-post-flash-diagnostics") => {
            &["post-flash-hilog.txt"]
        }
        _ => &[],
    }
}

/// Swift `RuntimeArtifactService.finalizeArtifacts`: the products synthesized
/// at finalization rather than by one step.
pub(crate) fn finalize_products(operation: &str) -> &'static [&'static str] {
    match operation {
        "capture.diagnostics@1" => &[
            "capture.log",
            "markers.json",
            "artifact-index.json",
            "capture-summary.json",
        ],
        SCREEN_SEQUENCE => &["sequence.json"],
        _ => &[],
    }
}

/// Swift `RuntimeJobEngine.optionalStepUpstream`: the step whose absence
/// keeps an optional step from running.
pub(crate) fn upstream(operation: &str, step_id: &str) -> Option<&'static str> {
    if operation != "capture.diagnostics@1" {
        return None;
    }
    match step_id {
        "receive-trace-artifact" | "cleanup-remote-temp" => Some("capture-trace"),
        "receive-ui-tree" | "cleanup-ui-tree-temp" => Some("capture-ui-tree"),
        "receive-screenshot" | "cleanup-screenshot-temp" => Some("capture-screenshot"),
        _ => None,
    }
}

/// Swift `RuntimeArtifactService.publishableArtifacts`: of the two encodings
/// of a screenshot, only the one the request asked for.
pub(crate) fn publishable<'a>(mapping: &[&'a str], inputs: &Map<String, Value>) -> Vec<&'a str> {
    const ENCODINGS: [&str; 2] = ["screenshot.png", "screenshot.jpeg"];
    let encoding = inputs
        .get("screenshotImageType")
        .and_then(Value::as_str)
        .filter(|requested| ["png", "jpeg"].contains(requested))
        .unwrap_or("png");
    mapping
        .iter()
        .copied()
        .filter(|name| {
            let alternative = ENCODINGS.contains(name)
                && mapping
                    .iter()
                    .any(|other| other != name && ENCODINGS.contains(other));
            !alternative || name.ends_with(&format!(".{encoding}"))
        })
        .collect()
}

/// Swift `RuntimeJobEngine.intentionallyOmittedArtifactNames`: the products of
/// the optional steps the request did not select, or whose upstream it did
/// not, and the encodings it did not ask for. Only these may stay missing
/// without failing a Job's evidence.
pub(crate) fn omitted_products(
    descriptor: &CatalogOperation,
    inputs: &Map<String, Value>,
) -> BTreeSet<String> {
    let reference = descriptor.reference();
    let mut steps: BTreeSet<&str> = BTreeSet::new();
    for step in descriptor.steps.iter().filter(|step| step.optional) {
        if upstream(&reference, &step.step_id).is_some_and(|upstream| steps.contains(upstream))
            || !descriptor.step_is_selected(step, inputs)
        {
            steps.insert(&step.step_id);
        }
    }
    let mut names = BTreeSet::new();
    for step in &descriptor.steps {
        let mapping = products(&reference, &step.step_id);
        let kept = if steps.contains(step.step_id.as_str()) {
            Vec::new()
        } else {
            publishable(mapping, inputs)
        };
        names.extend(
            mapping
                .iter()
                .filter(|name| !kept.contains(name))
                .map(|name| (*name).to_owned()),
        );
    }
    names
}

/// Swift `RuntimeArtifactService.fileBackedArtifacts`: a received product is
/// the bytes that landed on the host or nothing, published from the landed
/// file; the receive's stdout is only a transfer banner.
pub(crate) const FILE_BACKED: [&str; 6] = [
    "trace.htrace",
    "screenshot.png",
    "screenshot.jpeg",
    "frames.tar",
    "signed.hap",
    "unsigned.hap",
];

/// Swift `journalStep(for:)` arguments of the legs [`FileAction`] names, for
/// the Job `job_id` (before admission, the authorization envelope): a stdout
/// leg's catalog action with its parameters; the liveness readback's probe; a
/// capture's parameters and the owned path it writes (a screen sequence's also
/// its frame directory); the file a receive takes and where it lands among
/// the Job's raw products; and the owned paths a cleanup removes. None of them
/// declares a compensation.
pub(crate) fn file_journal_arguments(
    action: &FileAction,
    step: &CatalogStep,
    job_id: &str,
) -> Option<Value> {
    let artifact_id = format!("artifact-{}", step.step_id);
    // A stdout leg names the catalog's own action, never one guessed from the
    // step (CHG-2026-050), with the parameters Swift journals for it.
    let stdout = |parameters: Value| -> Option<Value> {
        let (catalog, action_id) = step.action.as_ref()?;
        Some(
            json!({"catalogId": catalog, "actionId": action_id, "parameters": parameters,
            "artifactId": artifact_id}),
        )
    };
    Some(match action {
        FileAction::CaptureComponentDetail {
            window_id,
            component_id,
        } => stdout(json!({"windowId": window_id, "componentId": component_id,
            "byteBudget": STDOUT_BUDGET}))?,
        FileAction::CaptureCrashIndex { .. } => stdout(json!({"byteBudget": STDOUT_BUDGET}))?,
        FileAction::CaptureCrashLog { name, .. } => {
            stdout(json!({"byteBudget": STDOUT_BUDGET, "faultLogName": name.value()}))?
        }
        // Swift journals every readback that is not a port rule's, a package
        // process's or a native library's as the generic process probe.
        FileAction::ObserveApplicationLiveness(_) => {
            json!({"probeId": "process-state", "expectedState": "running"})
        }
        FileAction::CaptureScreenshot { path, .. } | FileAction::CaptureComponentTree { path } => {
            json!({"catalogId": "trace-presets", "actionId": "custom", "parameters": {},
                "artifactId": artifact_id, "ownedRemotePath": path.remote_path})
        }
        FileAction::CaptureTrace { request, path } => json!({
            "catalogId": "trace-presets", "actionId": "custom",
            "parameters": {"durationSeconds": request.duration_seconds,
                "categories": request.categories, "bufferKB": request.buffer_kb},
            "artifactId": artifact_id, "ownedRemotePath": path.remote_path,
        }),
        FileAction::CaptureScreenSequence {
            request,
            frames,
            archive,
        } => json!({
            "catalogId": "trace-presets", "actionId": "custom",
            "parameters": {"frameCount": request.frame_count,
                "imageType": request.image_type.raw(), "framesDirectory": frames.remote_path},
            "artifactId": artifact_id, "ownedRemotePath": archive.remote_path,
        }),
        FileAction::ReceiveOwnedArtifact(artifact) => {
            // The landing name carries a still's encoding; every receive
            // that is not the tree's, a still's or a sequence's is the
            // trace's.
            let name = match step.step_id.as_str() {
                "receive-ui-tree" => "ui-tree.json",
                "receive-screenshot" if artifact.path.remote_path.ends_with(".jpeg") => {
                    "screenshot.jpeg"
                }
                "receive-screenshot" => "screenshot.png",
                "receive-screen-sequence" => "frames.tar",
                _ => "trace.htrace",
            };
            let mut arguments = json!({"remotePath": artifact.path.remote_path,
                "artifactId": artifact_id, "localRelativePath": format!("artifacts/raw/{name}")});
            if let Some(expected) = &artifact.expected_sha256 {
                arguments["expectedSha256"] = json!(expected);
            }
            arguments
        }
        FileAction::CleanupOwnedRemotePath { path } => json!({
            "remotePath": path.remote_path, "ownershipEvidenceId": format!("owned-{job_id}"),
        }),
        // Two owned things, not one: the archive and the frame directory.
        FileAction::CleanupScreenSequence {
            frames, archive, ..
        } => json!({
            "remotePath": archive.remote_path, "framesDirectory": frames.remote_path,
            "ownershipEvidenceId": format!("owned-{job_id}"),
        }),
    })
}

/// A persisted argument as Swift's `JSONValue` holds it.
fn persisted_value(value: arkdeck_provider_hdc::Persisted) -> Value {
    match value {
        arkdeck_provider_hdc::Persisted::Text(text) => json!(text),
        arkdeck_provider_hdc::Persisted::Integer(number) => json!(number),
        arkdeck_provider_hdc::Persisted::Texts(texts) => json!(texts),
    }
}
