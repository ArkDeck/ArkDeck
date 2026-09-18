//! Read-only human-action leaves, matching Swift's command registry and
//! `RuntimeCLI.runRuntimeExecution`. Selection and resume remain Runtime owned.
use crate::{CliError, valid_correlation};
use serde_json::{Map, Value, json};

pub(super) fn configure(
    command: &str,
    fields: &mut Map<String, Value>,
    help: bool,
) -> Result<Option<u64>, CliError> {
    if help || !matches!(command, "human-action.list" | "human-action.show") {
        return Ok(None);
    }
    if command == "human-action.show" {
        let id = fields.get("humanAction").ok_or_else(|| {
            CliError::new("invalidOption", "human-action show requires --human-action")
        })?;
        if !id
            .as_str()
            .is_some_and(|id| valid_correlation(id) && !id.contains(':'))
        {
            return Err(CliError::new(
                "invalidInput",
                "an exact human-action identity is required",
            ));
        }
    } else {
        if fields
            .get("ownerKind")
            .is_some_and(|kind| !matches!(kind.as_str(), Some("agentExecution" | "controlAction")))
        {
            return Err(CliError::new(
                "invalidOption",
                "owner-kind must be agentExecution or controlAction",
            ));
        }
        if fields.contains_key("ownerKind") != fields.contains_key("owner") {
            return Err(CliError::new(
                "invalidInput",
                "owner-kind and owner must be supplied together",
            ));
        }
        if let Some(text) = fields.get("pageSize").and_then(Value::as_str) {
            let size = text
                .parse::<u64>()
                .ok()
                .filter(|size| (1..=1000).contains(size) && size.to_string() == text)
                .ok_or_else(|| {
                    CliError::new("invalidOption", "page-size must be between 1 and 1000")
                })?;
            fields.insert("pageSize".into(), json!(size));
        }
    }
    match fields.remove("timeout") {
        None => Ok(None),
        Some(value) => value
            .as_str()
            .and_then(crate::read_only_resources::duration)
            .map(Some)
            .ok_or_else(|| CliError::new("invalidOption", "timeout must be a bounded duration")),
    }
}
