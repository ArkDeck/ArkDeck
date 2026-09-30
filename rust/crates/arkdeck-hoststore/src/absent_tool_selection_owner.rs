//! The tool-selection owner on Windows, as a type with no value
//! (TASK-XPA-005).
//!
//! Its durable records are the same code on both platforms
//! (`tool_selection.rs`); the owner that selects an executable reads the
//! Bootstrap tool registry (`arkdeck_bootstrap::ToolRegistryStore`), which
//! is not built on Windows yet. Until it is, the union control-action owner
//! is the same code with no tool-selection owner: `runtime.tool.select` is
//! refused as macOS refuses it without one, before a parameter is read.
use super::ToolSelectionRecord;
use crate::hdc_control_action::ImpactSource;
use arkdeck_contract::WireError;
use serde_json::{Map, Value};

/// The tool-selection owner, not composed on Windows yet.
pub enum ToolSelectionActions {}

/// The executor a tool selection restarts the HDC with; none on Windows yet.
pub trait ToolSelectionDriver {}

impl ToolSelectionActions {
    pub fn select(
        &self,
        _fields: &Map<String, Value>,
        _source: &dyn ImpactSource,
    ) -> Result<Value, WireError> {
        match *self {}
    }

    pub fn list_records(&self) -> Result<Vec<ToolSelectionRecord>, WireError> {
        match *self {}
    }

    pub fn show(&self, _id: &str, _source: &dyn ImpactSource) -> Result<Value, WireError> {
        match *self {}
    }

    pub(crate) fn human_action_rows(
        &self,
        _owner: Option<&str>,
    ) -> Result<Vec<crate::agent_execution::ActionRow>, WireError> {
        match *self {}
    }

    pub fn issue_interactive_challenge(
        &self,
        _action: &str,
        _reference: &str,
    ) -> Result<Value, WireError> {
        match *self {}
    }

    pub fn consume_interactive_challenge(
        &self,
        _id: &str,
        _reference: &str,
        _response: &str,
        _jobs: &crate::JobStore,
        _source: &dyn ImpactSource,
        _driver: &dyn ToolSelectionDriver,
    ) -> Result<Value, WireError> {
        match *self {}
    }
}
