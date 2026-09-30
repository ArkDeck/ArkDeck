//! The workspace provider on Windows, as a type with no value
//! (TASK-XPA-005).
//!
//! The Job planner materializes a workspace operation against
//! `WorkspaceComposition` (`workspace_composition.rs`), the workspace
//! provider over the registered projects, which needs the workspace
//! provider crate and the DevEco toolchain and signing owners, not built on
//! Windows yet. Until they are, the planner is the same code with
//! `workspace: None`: a workspace operation's provider is not registered,
//! as on macOS without one. No value of this type exists, so its methods are
//! never called.
use crate::WorkspaceUse;
use crate::operation_catalog::CatalogOperation;
use serde_json::{Map, Value};

/// The workspace provider, not composed on Windows yet.
pub enum WorkspaceComposition {}

impl WorkspaceComposition {
    pub(crate) fn acquire(
        &self,
        _descriptor: &CatalogOperation,
        _inputs: &Map<String, Value>,
    ) -> Result<Option<WorkspaceUse<'_>>, (&'static str, String)> {
        match *self {}
    }

    pub(crate) fn provider_unavailability(
        &self,
        _reference: &str,
    ) -> Option<(&'static str, String)> {
        match *self {}
    }

    pub(crate) fn dispatcher_unavailability(&self) -> Option<String> {
        match *self {}
    }
}
