//! The union control-action owner on Windows, as a type with no value
//! (TASK-XPA-005).
//!
//! The combined human-action owner (`human_action.rs`) pages an execution's
//! physical-assistance actions beside every control action's impact
//! approval (`control_action.rs`). The control actions are the HDC
//! lifecycle's and the tool selection's, which need a registered HDC and its
//! managed server, not built on Windows yet. Until they are, the human-action
//! owner is the same code with no control-action owner: it pages the
//! executions' actions alone, as macOS does without one.
use crate::agent_execution::ActionRow;
use arkdeck_contract::WireError;

/// The union control-action owner, not composed on Windows yet.
pub enum ControlActionResources {}

impl ControlActionResources {
    pub(crate) fn human_action_rows(
        &self,
        _owner: Option<&str>,
    ) -> Result<Vec<ActionRow>, WireError> {
        match *self {}
    }
}

/// Swift's `runtime.tool.select` answer with no tool-selection owner, which
/// the Windows daemon gives: no Windows HDC can be registered while no
/// Windows HDC tuple is (CHG-2026-078), so no selection candidate exists.
pub fn tool_selection_without_owner() -> WireError {
    WireError {
        code: "operationUnavailable".into(),
        message: "the Runtime tool-selection owner is unavailable".into(),
        details: Some(serde_json::Map::from_iter([(
            "newDispatchCount".into(),
            serde_json::json!(0),
        )])),
    }
}
