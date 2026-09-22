//! Foreground console interaction for the Runtime's immutable impact preview.
//! The Runtime remains responsible for console identity and admission. No
//! command option, environment value or file can supply the challenge answer.
use crate::CliError;
use arkdeck_contract::{canonical_json, sha256_hex, validate_method_value};
use serde_json::{Value, json};
use std::io::{Read, Write};

fn unreadable() -> CliError {
    CliError::new(
        "recordUnreadable",
        "Runtime impact challenge lacks its immutable control-action preview",
    )
}

/// Validate the published response, immutable preview digest and identity
/// bindings before rendering any Runtime text to the console.
fn review(challenge: &Value) -> Result<(&str, Value), CliError> {
    validate_method_value("human-action.resume", "result", challenge).map_err(|_| unreadable())?;
    let expected = challenge["challenge"].as_str().ok_or_else(unreadable)?;
    let action = &challenge["controlAction"];
    let preview = &action["preview"];
    let human = &challenge["humanAction"];
    let binding = &challenge["binding"];
    let action_id = action["controlActionId"]
        .as_str()
        .filter(|id| !id.is_empty())
        .ok_or_else(unreadable)?;
    let human_id = human["actionId"]
        .as_str()
        .filter(|id| !id.is_empty())
        .ok_or_else(unreadable)?;
    let mut unsigned = preview.as_object().cloned().ok_or_else(unreadable)?;
    let digest = unsigned.remove("previewDigest").ok_or_else(unreadable)?;
    let bytes = canonical_json(&Value::Object(unsigned)).map_err(|_| unreadable())?;
    let hdc = preview["schemaVersion"] == "arkdeck.hdc-control-preview/1"
        && preview["kind"] == "hdcLifecycle"
        && preview["action"] == "restart";
    let tool = preview["schemaVersion"] == "arkdeck.tool-selection-preview/1"
        && preview["kind"] == "runtimeToolSelection"
        && preview["action"] == "select";
    if challenge["schemaVersion"] != "arkdeck.impact-approval-challenge/1"
        || challenge["interactionOrigin"] != "interactiveConsole"
        || expected.len() != 17
        || !expected.starts_with("ARKDECK-")
        || !expected[8..]
            .bytes()
            .all(|byte| byte.is_ascii_uppercase() || byte.is_ascii_digit())
        || action["schemaVersion"] != "arkdeck.control-action/1"
        || action["state"] != "awaitingImpactApproval"
        || action["dispatchCount"] != 0
        || !action["generation"].is_string()
        || human["schemaVersion"] != "arkdeck.human-action/1"
        || !(hdc || tool)
        || preview["controlActionId"] != action_id
        || preview["owner"] != json!({"kind":"controlAction","id":action_id})
        || preview["confirmationRequired"] != true
        || preview["dispatchCount"] != 0
        || preview["digestAlgorithm"] != "sha256-jcs"
        || !preview["previewId"].is_string()
        || digest != sha256_hex(&bytes)
        || binding["controlActionId"] != action_id
        || binding["humanActionId"] != human_id
        || binding["previewId"] != preview["previewId"]
        || binding["previewDigest"] != digest
    {
        return Err(unreadable());
    }
    Ok((
        expected,
        json!({"controlActionId":action_id,"generation":action["generation"],"preview":preview}),
    ))
}

/// Swift's bounded console read. The binary passes stdin's actual terminal
/// status; the injectable streams keep byte/error paths independently testable.
pub fn read_console_challenge(
    challenge: &Value,
    terminal: bool,
    input: &mut impl Read,
    output: &mut impl Write,
) -> Result<String, CliError> {
    if !terminal {
        return Err(unreadable());
    }
    let (expected, review) = review(challenge)?;
    let rendered = serde_json::to_string_pretty(&review).map_err(|_| unreadable())?;
    write!(output, "Review the complete immutable Runtime control-action impact:\n{rendered}\nType this one-time challenge exactly: {expected}\n> ")
        .and_then(|()| output.flush())
        .map_err(|_| CliError::new("ioFailure", "could not display the Runtime impact preview"))?;
    let mut bytes = Vec::new();
    while bytes.len() <= 64 {
        let mut byte = [0];
        match input.read(&mut byte) {
            Ok(0) => break,
            Ok(_) if matches!(byte[0], b'\n' | b'\r') => break,
            Ok(_) if byte[0] < 32 || byte[0] == 127 => {
                return Err(CliError::new(
                    "invalidInput",
                    "impact challenge contains invalid console bytes",
                ));
            }
            Ok(_) => bytes.push(byte[0]),
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(_) => {
                return Err(CliError::new(
                    "ioFailure",
                    "could not read the foreground impact challenge",
                ));
            }
        }
    }
    if bytes != expected.as_bytes() {
        return Err(CliError::new(
            "admissionDenied",
            "the typed impact challenge did not match; zero dispatch",
        ));
    }
    Ok(expected.to_owned())
}

pub fn validate_control_action_result(value: &Value) -> Result<(), CliError> {
    if value["schemaVersion"] != "arkdeck.control-action/1"
        || !value["state"].is_string()
        || !value["dispatchCount"]
            .as_u64()
            .is_some_and(|count| count <= 1)
    {
        return Err(CliError::new(
            "recordUnreadable",
            "HDC restart returned no valid control action",
        ));
    }
    Ok(())
}

pub(crate) fn control_action_exit(value: &Value) -> Option<(u8, String)> {
    let (code, message) = match value["state"].as_str() {
        Some("succeeded") => return None,
        Some("failed") => (
            1,
            "Runtime control action failed before a confirmed external effect",
        ),
        Some("outcomeUnknown") => (
            75,
            "Runtime control action entered its launch window; inspect and reconcile it without replaying the request",
        ),
        _ => (
            if value["dispatchCount"] == 0 { 77 } else { 75 },
            "Runtime control action did not reach a trustworthy terminal state",
        ),
    };
    Some((code, message.into()))
}
