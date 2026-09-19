//! Closed clients for project registration/discovery; no local root authority.
use crate::{CliError, Invocation};
use serde_json::{Map, Value};
pub(crate) fn configure(
    command: &str,
    fields: &mut Map<String, Value>,
    help: bool,
) -> Result<Option<u64>, CliError> {
    if help || !command.starts_with("workspace.project.") {
        return Ok(None);
    }
    let timeout = fields
        .remove("timeout")
        .map(|v| {
            v.as_str()
                .and_then(crate::read_only_resources::duration)
                .ok_or_else(|| CliError::new("invalidOption", "timeout must be a bounded duration"))
        })
        .transpose()?;
    if let Some(root) = fields.remove("rootPath") {
        fields.insert("root".into(), root);
    }
    let keys: &[&str] = match command {
        "workspace.project.register" => &["registrationRequestId", "kind", "root"],
        "workspace.project.show" => &["projectRef"],
        _ => &[],
    };
    if keys.iter().any(|k| !fields.contains_key(*k)) {
        return Err(CliError::new(
            "invalidOption",
            "workspace project requires its exact registration or project options",
        ));
    }
    if command.ends_with(".register")
        && !matches!(fields["kind"].as_str(), Some("arkdeck" | "openharmony"))
    {
        return Err(CliError::new(
            "invalidOption",
            "--kind must be arkdeck or openharmony",
        ));
    }
    Ok(timeout)
}
pub fn validate_workspace_project_response(
    invocation: &Invocation,
    result: &Value,
) -> Result<(), CliError> {
    if !invocation.method.starts_with("workspace.project.") {
        return Ok(());
    }
    let invalid = || {
        CliError::new(
            "recordUnreadable",
            "Runtime returned an inconsistent workspace project resource",
        )
    };
    let resource = |r: &Value| -> bool {
        let generation = r["generation"].as_str().and_then(|s| {
            s.parse::<u64>()
                .ok()
                .filter(|n| *n > 0 && *n <= i64::MAX as u64 && n.to_string() == s)
        });
        r["schemaVersion"] == "arkdeck.workspace-project/1"
            && generation.is_some()
            && r["projectRef"].as_str().is_some_and(|s| !s.is_empty())
            && matches!(r["kind"].as_str(), Some("arkdeck" | "openharmony"))
            && matches!(
                r["availability"].as_str(),
                Some("available" | "unavailable" | "removed")
            )
    };
    if invocation.method.ends_with(".list") {
        let rows = result["projects"].as_array().ok_or_else(invalid)?;
        if result["schemaVersion"] != "arkdeck.workspace-project-list/1"
            || rows.iter().any(|r| !resource(r))
            || rows
                .windows(2)
                .any(|w| w[0]["projectRef"].as_str() >= w[1]["projectRef"].as_str())
        {
            return Err(invalid());
        }
    } else if !resource(result)
        || (invocation.method.ends_with(".show")
            && invocation
                .params
                .as_ref()
                .is_none_or(|p| p["projectRef"] != result["projectRef"]))
    {
        return Err(invalid());
    }
    Ok(())
}
