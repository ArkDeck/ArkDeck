//! What a device-bound HDC step is, for the planner and the runner alike:
//! the steps the engine performs itself, the typed provider action a catalog
//! step names, the arguments Swift journals for it, and which steps carry the
//! evidence preflight.
use crate::operation_catalog::CatalogStep;
use arkdeck_provider_hdc::Action;
use serde_json::{Value, json};

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

/// Swift `HDCObservationProviderAdapter.action` for a catalog step.
pub(crate) fn action(step: &CatalogStep) -> Option<Action> {
    Action::for_step(&step.kind, remote_action(step))
}

/// Swift `journalStep(for:)` arguments for the kinds an observation takes.
pub(crate) fn journal_arguments(step: &CatalogStep) -> Option<Value> {
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
        _ => return None,
    })
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
