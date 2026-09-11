//! Typed consumers of Bootstrap read-owner projections. Store paths and native
//! content verification remain behind the authenticated Runtime endpoint.
use crate::{CliError, Invocation};
use serde_json::{Map, Value};

pub(crate) fn configure(
    command: &str,
    params: &Map<String, Value>,
    help: bool,
) -> Result<(), CliError> {
    let key = match command {
        "runtime.tool.inspect" => "tool",
        "runtime.bundle.inspect" => "bundle",
        _ => return Ok(()),
    };
    if !help && params.get(key).and_then(Value::as_str).is_none() {
        return Err(CliError::new(
            "invalidOption",
            format!("{command} requires --{key}"),
        ));
    }
    Ok(())
}
pub fn validate_bootstrap_response(invocation: &Invocation, value: &Value) -> Result<(), CliError> {
    let (input, output, schema, prefix, content_schema) = match invocation.command {
        "runtime.bundle.inspect" => (
            "bundle",
            "bundleRef",
            "arkdeck.runtime-bundle/1",
            "bundle:sha256:",
            "arkdeck.bundle-content/1",
        ),
        "runtime.tool.inspect"
            if invocation
                .params
                .as_ref()
                .and_then(|p| p.get("tool"))
                .and_then(Value::as_str)
                .is_some_and(|v| v.starts_with("toolchain:sha256:")) =>
        {
            (
                "tool",
                "toolRef",
                "arkdeck.runtime-tool/1",
                "toolchain:sha256:",
                "arkdeck.deveco-toolchain-content/2",
            )
        }
        "runtime.tool.inspect" => (
            "tool",
            "toolRef",
            "arkdeck.runtime-tool/1",
            "tool:sha256:",
            "arkdeck.tool-content/1",
        ),
        _ => return Ok(()),
    };
    let unreadable = || {
        CliError::new(
            "recordUnreadable",
            "Runtime returned an inconsistent Bootstrap resource",
        )
    };
    arkdeck_contract::validate_method_value(invocation.method, "result", value)
        .map_err(|_| unreadable())?;
    let reference = invocation
        .params
        .as_ref()
        .and_then(|p| p.get(input))
        .and_then(Value::as_str)
        .ok_or_else(unreadable)?;
    let digest = reference.strip_prefix(prefix).ok_or_else(unreadable)?;
    if digest.len() != 64
        || !digest
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        || value[output] != reference
        || value["contentDigest"] != digest
        || value["schemaVersion"] != schema
        || value["contentSchemaVersion"] != content_schema
        || value["digestAlgorithm"] != "sha256-jcs"
        || value["platform"] != "macos"
        || !value["generation"].as_str().is_some_and(|v| {
            v.parse::<u64>()
                .is_ok_and(|n| n > 0 && n <= i64::MAX as u64 && n.to_string() == v)
        })
        || !matches!(value["state"].as_str(), Some("available" | "removed"))
        || value["trust"]["executionAssessment"] != "notPerformed"
    {
        return Err(unreadable());
    }
    let (kind, retained) = match prefix {
        "bundle:sha256:" => ("daemon-bundle", true),
        "tool:sha256:" => ("hdc", true),
        _ => ("deveco", false),
    };
    if value["kind"] != kind || value["contentRetained"].as_bool() != Some(retained) {
        return Err(unreadable());
    }
    Ok(())
}
