//! Closed doctor envelope validation shared by the native distribution loaders.
use crate::arktrace_envelope::{boolean, exact_keys, integer, integer_tokens};
use serde_json::{Map, Value};

pub(crate) struct DoctorEnvelopeContract {
    pub executable_sha256: String,
    pub product_version: String,
    pub timeout_seconds: i64,
    pub output_byte_budget: u64,
}

fn safe_name(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 128
        && !value.chars().any(arkdeck_platform::host_control_character)
}

/// Swift `ArkTraceDoctorEnvelopeValidator.validate`.
pub(crate) fn valid_envelope(bytes: &[u8], contract: &DoctorEnvelopeContract) -> bool {
    if crate::strict_json::validate(bytes).is_err() || !integer_tokens(bytes) {
        return false;
    }
    let Ok(Value::Object(root)) = serde_json::from_slice::<Value>(bytes) else {
        return false;
    };
    let object = |key: &str| root.get(key).and_then(Value::as_object);
    let closed = exact_keys(
        &root,
        &[
            "schemaVersion",
            "tool",
            "request",
            "trace",
            "provenance",
            "limits",
            "dataQuality",
            "truncation",
            "result",
        ],
    ) && root.get("schemaVersion").and_then(Value::as_str) == Some("1.0")
        && root.get("trace") == Some(&Value::Null)
        && root.get("provenance") == Some(&Value::Null);
    if !closed {
        return false;
    }
    let (Some(tool), Some(request), Some(limits), Some(quality), Some(truncation), Some(result)) = (
        object("tool"),
        object("request"),
        object("limits"),
        object("dataQuality"),
        object("truncation"),
        object("result"),
    ) else {
        return false;
    };
    fn text<'a>(fields: &'a Map<String, Value>, key: &str) -> Option<&'a str> {
        fields.get(key).and_then(Value::as_str)
    }
    let empty = |value: Option<&Value>| value.and_then(Value::as_array).is_some_and(Vec::is_empty);
    let well_formed = exact_keys(tool, &["name", "version", "buildRevision"])
        && text(tool, "name") == Some("arktrace")
        && text(tool, "version") == Some(contract.product_version.as_str())
        && text(tool, "buildRevision") == Some(contract.executable_sha256.as_str())
        && exact_keys(request, &["command", "parameters"])
        && text(request, "command") == Some("doctor")
        && request
            .get("parameters")
            .and_then(Value::as_object)
            .is_some_and(|parameters| {
                exact_keys(parameters, &["selfTest"])
                    && boolean(parameters.get("selfTest")) == Some(true)
            })
        && exact_keys(
            limits,
            &["timeoutMs", "maxRows", "maxEvents", "maxOutputBytes"],
        )
        && integer(limits.get("timeoutMs")) == Some(contract.timeout_seconds * 1_000)
        && integer(limits.get("maxRows")) == Some(10_000)
        && integer(limits.get("maxEvents")) == Some(10_000)
        && integer(limits.get("maxOutputBytes")) == Some(contract.output_byte_budget as i64)
        && exact_keys(quality, &["status", "warnings"])
        && text(quality, "status") == Some("ok")
        && empty(quality.get("warnings"))
        && exact_keys(truncation, &["truncated", "sections"])
        && boolean(truncation.get("truncated")) == Some(false)
        && empty(truncation.get("sections"))
        && exact_keys(result, &["checks", "selfTest"])
        && boolean(result.get("selfTest")) == Some(true);
    if !well_formed {
        return false;
    }
    let Some(checks) = result.get("checks").and_then(Value::as_array) else {
        return false;
    };
    let Some(checks) = checks
        .iter()
        .map(Value::as_object)
        .collect::<Option<Vec<_>>>()
    else {
        return false;
    };
    const CODES: [&str; 9] = [
        "tool",
        "os",
        "architecture",
        "parserManifest",
        "parserIdentity",
        "sqlite",
        "cache",
        "schemaAdapter",
        "selfTest",
    ];
    checks.len() == CODES.len()
        && checks.iter().zip(CODES).all(|(check, code)| {
            exact_keys(check, &["code", "name", "status"])
                && text(check, "code") == Some(code)
                && text(check, "status") == Some("ok")
                && text(check, "name").is_some_and(safe_name)
        })
}
