//! Swift's `runtime hdc impact-preview` and `runtime hdc restart` leaves
//! (`CLICommandRegistry`, `CLIHDCControlActions.swift`): the registry's
//! option grammar when parsing, and the handler's intent and preview-tuple
//! checks before any connection. Both leaves are mutation-capable.
use crate::{CliError, Invocation};
use serde_json::{Map, Value};

/// Swift `HDCControlValue.identifier`: 1 to 128 bytes, a leading ASCII
/// letter or digit, then letters, digits, `-`, `.`, `:` or `_`.
fn identifier(text: &str) -> bool {
    (1..=128).contains(&text.len())
        && text
            .bytes()
            .next()
            .is_some_and(|byte| byte.is_ascii_alphanumeric())
        && text
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'.' | b':' | b'_'))
}

/// Swift `HDCControlValue.digest`, and the `hexDigest(length: 64)` grammar:
/// 64 lowercase hexadecimal digits.
fn digest(text: &str) -> bool {
    text.len() == 64
        && text
            .bytes()
            .all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f'))
}

/// The `positiveInteger(1...Int.max)` grammar, which is also
/// `HDCControlValue.generation`: plain digits, no leading zero, at most
/// `Int64.max`.
fn generation(text: &str) -> bool {
    !text.is_empty()
        && !text.starts_with('0')
        && text.bytes().all(|byte| byte.is_ascii_digit())
        && text
            .parse::<u64>()
            .is_ok_and(|number| number <= i64::MAX as u64)
}

/// The registry's grammar for both leaves:
/// - every option is required;
/// - `--action` is only `restart`;
/// - the generation is a positive integer;
/// - the digest is 64 lowercase hexadecimal digits;
/// - `--timeout` is a duration of at most a day.
///
/// Every failure is `invalidOption`.
pub(crate) fn configure(
    command: &str,
    fields: &mut Map<String, Value>,
    help: bool,
) -> Result<Option<u64>, CliError> {
    let required: &[(&str, &str)] = match command {
        "runtime.hdc.impact-preview" => &[
            ("--action", "action"),
            ("--server-endpoint-ref", "serverEndpointRef"),
            ("--expected-server-generation", "expectedServerGeneration"),
            ("--action-request-id", "actionRequestId"),
        ],
        "runtime.hdc.restart" => &[
            ("--control-action", "controlAction"),
            ("--preview-id", "previewId"),
            ("--preview-digest", "previewDigest"),
        ],
        _ => return Ok(None),
    };
    if help {
        return Ok(None);
    }
    let timeout = fields
        .remove("timeout")
        .map(|value| {
            value
                .as_str()
                .and_then(crate::read_only_resources::duration)
                .ok_or_else(|| {
                    CliError::new(
                        "invalidOption",
                        "`--timeout` must be a duration like `30s`, no larger than 86400000ms",
                    )
                })
        })
        .transpose()?;
    if let Some((flag, _)) = required.iter().find(|(_, key)| !fields.contains_key(*key)) {
        return Err(CliError::new(
            "invalidOption",
            format!("{command} requires {flag}"),
        ));
    }
    let text = |key: &str| fields.get(key).and_then(Value::as_str).unwrap_or_default();
    let refused = if command == "runtime.hdc.restart" {
        (!digest(text("previewDigest")))
            .then_some("`--preview-digest` must be 64 lowercase hexadecimal digits")
    } else if text("action") != "restart" {
        Some("`--action` must be restart")
    } else {
        (!generation(text("expectedServerGeneration")))
            .then_some("`--expected-server-generation` must be a positive integer")
    };
    match refused {
        Some(message) => Err(CliError::new("invalidOption", message)),
        None => Ok(timeout),
    }
}

/// The checks Swift's `runHDCControlAction` makes before any connection:
/// an impact preview's exact restart intent (`HDCControlActionIntent`), or a
/// restart's exact control-action preview tuple. It returns the parameters
/// as the Runtime receives them.
pub fn hdc_control_action_params(invocation: &Invocation) -> Result<Map<String, Value>, CliError> {
    let params = invocation.params.clone().unwrap_or_default();
    let text = |key: &str| params.get(key).and_then(Value::as_str).unwrap_or_default();
    let (exact, message) = match invocation.command {
        "runtime.hdc.impact-preview" => (
            text("action") == "restart"
                && identifier(text("actionRequestId"))
                && text("serverEndpointRef")
                    .strip_prefix("hdc-endpoint:")
                    .is_some_and(digest)
                && generation(text("expectedServerGeneration")),
            "HDC control-action intent failed validation",
        ),
        "runtime.hdc.restart" => (
            identifier(text("controlAction"))
                && identifier(text("previewId"))
                && digest(text("previewDigest")),
            "restart requires one exact control-action preview tuple",
        ),
        _ => {
            return Err(CliError::new(
                "invalidCommand",
                "unsupported control-action command",
            ));
        }
    };
    if !exact {
        return Err(CliError::new("invalidInput", message));
    }
    Ok(params)
}
