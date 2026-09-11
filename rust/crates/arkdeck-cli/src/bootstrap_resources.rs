//! Typed Bootstrap resource consumers. Registration and native content
//! verification remain behind the authenticated Runtime endpoint.
use crate::{CliError, Invocation};
use serde_json::{Map, Value};

pub(crate) fn configure(
    command: &str,
    params: &mut Map<String, Value>,
    help: bool,
) -> Result<(), CliError> {
    if command == "runtime.tool.register" {
        if help {
            return Ok(());
        }
        let kind = params.get("kind").and_then(Value::as_str).ok_or_else(|| {
            CliError::new("invalidOption", "runtime.tool.register requires --kind")
        })?;
        if kind == "hdc" {
            return Err(CliError::new(
                "controlMethodUnavailable",
                "HDC registration is not supported by this CLI",
            ));
        }
        if kind != "deveco" {
            return Err(CliError::new(
                "invalidOption",
                "kind must name a supported host tool role",
            ));
        }
        if params.contains_key("file") {
            return Err(CliError::new(
                "invalidInput",
                "DevEco registration requires only --root",
            ));
        }
        let root = params
            .remove("rootPath")
            .ok_or_else(|| CliError::new("invalidInput", "DevEco registration requires --root"))?;
        if !root.as_str().is_some_and(|s| {
            s.starts_with('/')
                && !s.contains('\0')
                && !s.split('/').any(|part| part == "." || part == "..")
        }) {
            return Err(CliError::new(
                "invalidInput",
                "tool registration paths must be canonical absolute local paths",
            ));
        }
        params.insert("root".into(), root);
        return Ok(());
    }
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
/// Registration must be a method in this compiled contract before any connection.
pub fn validate_bootstrap_request(invocation: &Invocation) -> Result<(), CliError> {
    if invocation.command != "runtime.tool.register" {
        return Ok(());
    }
    if !arkdeck_contract::METHODS.contains(&invocation.method) {
        return Err(CliError::new(
            "controlMethodUnavailable",
            "DevEco registration is not published in this CLI contract",
        ));
    }
    arkdeck_contract::validate_method_value(
        invocation.method,
        "request",
        &Value::Object(invocation.params.clone().unwrap_or_default()),
    )
    .map_err(|error| {
        CliError::from_client(
            arkdeck_client::ClientError::Contract(error),
            invocation.method,
        )
    })
}

pub fn validate_bootstrap_response(invocation: &Invocation, value: &Value) -> Result<(), CliError> {
    let registering = invocation.command == "runtime.tool.register";
    let (input, output, schema, prefix, content_schema) = match invocation.command {
        "runtime.tool.register" => (
            "root",
            "toolRef",
            "arkdeck.runtime-tool/1",
            "toolchain:sha256:",
            "arkdeck.deveco-toolchain-content/2",
        ),
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
    let reference = if registering {
        value["toolRef"].as_str().ok_or_else(unreadable)?
    } else {
        invocation
            .params
            .as_ref()
            .and_then(|p| p.get(input))
            .and_then(Value::as_str)
            .ok_or_else(unreadable)?
    };
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
    if registering
        && (value["state"] != "available"
            || value["generation"] != "1"
            || value["selected"] != false
            || value["source"] != "registeredRoot")
    {
        return Err(unreadable());
    }
    Ok(())
}
