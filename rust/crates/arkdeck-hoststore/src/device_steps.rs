//! What a device-bound HDC step is, for the planner, the runner and the result
//! reader alike: the steps the engine performs itself, the typed provider
//! action a catalog step names with the request's inputs, the arguments Swift
//! journals for it, which steps carry the evidence preflight, and the products
//! each step owns.
use crate::operation_catalog::{CatalogOperation, CatalogStep};
use arkdeck_provider_hdc::{
    Action, DEFAULT_HILOG_BUDGET, FileActionError, FilePlan, PointerAction, PortAction, PortRule,
    ProcessPlan, STORAGE_ROOT,
};
use serde_json::{Map, Value, json};
use std::collections::BTreeSet;

/// The device-bound operations this Runtime plans and runs.
pub(crate) const DEVICE_OPERATIONS: [&str; 7] = [
    "observe.device@1",
    "capture.diagnostics@1",
    "input.tap@1",
    "input.long-press@1",
    "input.swipe@1",
    "port-forward.create@1",
    "port-forward.remove@1",
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

/// A device step's typed provider action: an observation or capture action,
/// a pointer gesture, or a port rule's change or readback.
pub(crate) enum StepAction {
    Hdc(Action),
    Pointer(PointerAction),
    Port(PortAction),
}

impl StepAction {
    pub(crate) fn persisted(&self) -> (&'static str, Map<String, Value>) {
        match self {
            Self::Pointer(action) => action.persisted(),
            Self::Port(action) => action.persisted(),
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

    /// The provider's verdict on the step's receipt. A gesture's and a port
    /// rule's name no device fact.
    pub(crate) fn verify(
        &self,
        receipt: &arkdeck_provider_hdc::Receipt,
        expected: arkdeck_provider_hdc::Expected<'_>,
    ) -> arkdeck_provider_hdc::Outcome {
        match self {
            Self::Hdc(action) => action.verify(receipt, expected),
            Self::Pointer(action) => action.verify(receipt),
            Self::Port(action) => action.verify(receipt),
        }
    }

    pub(crate) fn effect(&self) -> &'static str {
        match self {
            Self::Hdc(action) => action.effect(),
            Self::Pointer(action) => action.effect(),
            Self::Port(action) => action.effect(),
        }
    }

    /// The one process the step lowers to, against the Target's connect key.
    pub(crate) fn lower(
        &self,
        step_id: &str,
        connect_key: Option<&str>,
    ) -> Result<ProcessPlan, String> {
        let plan = match self {
            Self::Hdc(action) => return action.lower(step_id, connect_key),
            Self::Pointer(action) => action.lower(step_id, connect_key)?,
            Self::Port(action) => action.lower(step_id, connect_key)?,
        };
        match plan {
            FilePlan::Process(plan) => Ok(plan),
            _ => Err(format!("{step_id} did not lower to one process")),
        }
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

/// Swift `journalStep(for:)` arguments for the kinds this Runtime
/// materializes, for a step journaled under operation `reference`.
pub(crate) fn journal_arguments(
    step: &CatalogStep,
    inputs: &Map<String, Value>,
    action: &StepAction,
) -> Option<Value> {
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
