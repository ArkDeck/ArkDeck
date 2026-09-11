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
    if invocation.command == "runtime.bundle.list" {
        return validate_bundle_page(invocation, value);
    }
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
    validate_record(value, reference, output, schema, prefix, content_schema)?;
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

fn unreadable() -> CliError {
    CliError::new(
        "recordUnreadable",
        "Runtime returned an inconsistent Bootstrap resource",
    )
}

fn validate_record(
    value: &Value,
    reference: &str,
    output: &str,
    schema: &str,
    prefix: &str,
    content_schema: &str,
) -> Result<(), CliError> {
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

fn uuid(value: &str) -> bool {
    value.len() == 36
        && value.bytes().enumerate().all(|(index, byte)| {
            if [8, 13, 18, 23].contains(&index) {
                byte == b'-'
            } else {
                byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte)
            }
        })
}

fn validate_bundle_page(invocation: &Invocation, value: &Value) -> Result<(), CliError> {
    arkdeck_contract::validate_method_value(invocation.method, "result", value)
        .map_err(|_| unreadable())?;
    let fields = value.as_object().ok_or_else(unreadable)?;
    let keys = [
        "schemaVersion",
        "pageKind",
        "items",
        "order",
        "snapshotRevision",
        "hasMore",
        "nextCursor",
    ];
    if fields.len() != keys.len()
        || keys.iter().any(|key| !fields.contains_key(*key))
        || value["schemaVersion"] != "arkdeck.cli.page/1"
        || value["pageKind"] != "snapshot"
        || value["order"] != "bundleRef:asc"
    {
        return Err(unreadable());
    }
    let revision = value["snapshotRevision"]
        .as_str()
        .filter(|v| uuid(v))
        .ok_or_else(unreadable)?;
    let rows = value["items"].as_array().ok_or_else(unreadable)?;
    let params = invocation.params.as_ref().ok_or_else(unreadable)?;
    let size = params
        .get("pageSize")
        .and_then(Value::as_u64)
        .filter(|n| (1..=1000).contains(n))
        .ok_or_else(unreadable)?;
    if rows.len() as u64 > size {
        return Err(unreadable());
    }
    if let Some(cursor) = params.get("cursor") {
        let (prefix, token) = cursor
            .as_str()
            .and_then(|v| v.split_once('.'))
            .ok_or_else(unreadable)?;
        if prefix != revision || !uuid(token) {
            return Err(unreadable());
        }
    }
    match value["hasMore"].as_bool() {
        Some(true) => {
            let cursor = value["nextCursor"].as_str().ok_or_else(unreadable)?;
            let (prefix, token) = cursor.split_once('.').ok_or_else(unreadable)?;
            if rows.is_empty()
                || prefix != revision
                || !uuid(token)
                || params.get("cursor").and_then(Value::as_str) == Some(cursor)
            {
                return Err(unreadable());
            }
        }
        Some(false) if value["nextCursor"].is_null() => (),
        _ => return Err(unreadable()),
    }
    let mut previous: Option<&str> = None;
    for row in rows {
        let reference = row["bundleRef"].as_str().ok_or_else(unreadable)?;
        validate_record(
            row,
            reference,
            "bundleRef",
            "arkdeck.runtime-bundle/1",
            "bundle:sha256:",
            "arkdeck.bundle-content/1",
        )?;
        if previous.is_some_and(|prior| prior >= reference) {
            return Err(unreadable());
        }
        previous = Some(reference);
    }
    Ok(())
}
