//! Closed clients for project registration, mutation and discovery, and for
//! preset registration, mutation and discovery; no local root authority, and
//! a preset names its toolchain and credential only by reference.
use crate::{CliError, Invocation};
use serde_json::{Map, Value};

/// Swift's `positiveInteger` grammar: `^[1-9][0-9]*$` inside `1...maximum`.
fn positive_integer(value: &Value, maximum: u64) -> bool {
    value.as_str().is_some_and(|text| {
        !text.starts_with('0')
            && text.bytes().all(|byte| byte.is_ascii_digit())
            && text
                .parse::<u64>()
                .is_ok_and(|n| (1..=maximum).contains(&n))
    })
}
pub(crate) fn configure(
    command: &str,
    fields: &mut Map<String, Value>,
    help: bool,
) -> Result<Option<u64>, CliError> {
    if help
        || !(command.starts_with("workspace.project.") || command.starts_with("workspace.preset."))
    {
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
        "workspace.project.update" => &["projectRef", "expectedGeneration", "kind", "root"],
        "workspace.project.remove" => &["projectRef", "expectedGeneration"],
        "workspace.preset.list" => &["projectRef"],
        "workspace.preset.show" => &["projectRef", "presetRef"],
        "workspace.preset.register" => &[
            "registrationRequestId",
            "projectRef",
            "kind",
            "templateRef",
            "timeoutSeconds",
        ],
        "workspace.preset.update" => &[
            "mutationRequestId",
            "projectRef",
            "presetRef",
            "expectedGeneration",
            "kind",
            "templateRef",
            "timeoutSeconds",
        ],
        "workspace.preset.remove" => &[
            "mutationRequestId",
            "projectRef",
            "presetRef",
            "expectedGeneration",
        ],
        _ => &[],
    };
    if keys.iter().any(|k| !fields.contains_key(*k)) {
        return Err(CliError::new(
            "invalidOption",
            "workspace project requires its exact registration or project options",
        ));
    }
    if (command == "workspace.project.register" || command == "workspace.project.update")
        && !matches!(fields["kind"].as_str(), Some("arkdeck" | "openharmony"))
    {
        return Err(CliError::new(
            "invalidOption",
            "--kind must be arkdeck or openharmony",
        ));
    }
    if command.starts_with("workspace.preset.")
        && fields.get("kind").is_some_and(|kind| {
            !matches!(kind.as_str(), Some("build" | "test" | "signing" | "symbol"))
        })
    {
        return Err(CliError::new(
            "invalidOption",
            "--kind must be build, test, signing or symbol",
        ));
    }
    // The registry's value grammars, refused before any request is sent.
    for (key, maximum, message) in [
        (
            "expectedGeneration",
            i64::MAX as u64,
            "--expected-generation must be a positive integer",
        ),
        (
            "toolchainGeneration",
            i64::MAX as u64,
            "--toolchain-generation must be a positive integer",
        ),
        (
            "timeoutSeconds",
            3600,
            "--timeout-seconds must be an integer from 1 to 3600",
        ),
    ] {
        if fields
            .get(key)
            .is_some_and(|value| !positive_integer(value, maximum))
        {
            return Err(CliError::new("invalidOption", message));
        }
    }
    Ok(timeout)
}
pub fn validate_workspace_project_response(
    invocation: &Invocation,
    result: &Value,
) -> Result<(), CliError> {
    if invocation.method.starts_with("workspace.preset.") {
        return validate_workspace_preset_response(invocation, result);
    }
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

/// A preset resource names its project and kind and carries its generation
/// as canonical text; a list is sorted and belongs to the requested project.
fn validate_workspace_preset_response(
    invocation: &Invocation,
    result: &Value,
) -> Result<(), CliError> {
    let invalid = || {
        CliError::new(
            "recordUnreadable",
            "Runtime returned an inconsistent workspace preset resource",
        )
    };
    let requested = |key: &str| invocation.params.as_ref().and_then(|p| p.get(key).cloned());
    let resource = |r: &Value| -> bool {
        let generation = r["generation"].as_str().and_then(|s| {
            s.parse::<u64>()
                .ok()
                .filter(|n| *n > 0 && *n <= i64::MAX as u64 && n.to_string() == s)
        });
        r["schemaVersion"] == "arkdeck.workspace-preset/1"
            && generation.is_some()
            && r["presetRef"]
                .as_str()
                .is_some_and(|s| s.starts_with("preset-"))
            && Some(r["projectRef"].clone()) == requested("projectRef")
            && matches!(
                r["kind"].as_str(),
                Some("build" | "test" | "signing" | "symbol")
            )
    };
    if invocation.method.ends_with(".list") {
        let rows = result["presets"].as_array().ok_or_else(invalid)?;
        if result["schemaVersion"] != "arkdeck.workspace-preset-list/1"
            || Some(result["projectRef"].clone()) != requested("projectRef")
            || rows.iter().any(|r| !resource(r))
            || requested("kind").is_some_and(|kind| rows.iter().any(|r| r["kind"] != kind))
            || rows
                .windows(2)
                .any(|w| w[0]["presetRef"].as_str() >= w[1]["presetRef"].as_str())
        {
            return Err(invalid());
        }
    } else if !resource(result) {
        return Err(invalid());
    } else if invocation.method == "workspace.preset.register" {
        // Swift names a preset by its registration identity and replays a
        // registration only under that same name.
        let derived = requested("registrationRequestId")
            .and_then(|request| request.as_str().map(str::to_owned))
            .map(|request| {
                format!(
                    "preset-{}",
                    &arkdeck_contract::sha256_hex(request.as_bytes())[..24]
                )
            });
        if result["presetRef"].as_str() != derived.as_deref()
            || Some(result["kind"].clone()) != requested("kind")
        {
            return Err(invalid());
        }
    } else if Some(result["presetRef"].clone()) != requested("presetRef")
        || (invocation.method == "workspace.preset.remove"
            && result["configurationStatus"] != "removed")
    {
        return Err(invalid());
    }
    Ok(())
}
