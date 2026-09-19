//! Swift `HDCControlValue` (CHG-2026-074): the value grammar both control-action
//! owners' records share — the HDC lifecycle owner's (`hdc_control_action.rs`)
//! and the tool-selection owner's (`tool_selection.rs`) — with the digest over
//! canonical bytes and the records' instant spelling.
use crate::control_action::{identifier, unreadable};
use crate::format_time::{precise_utc_millis, utc_precise_from_millis};
use arkdeck_contract::{WireError, canonical_json, sha256_hex};
use serde_json::{Map, Value, json};

/// 64 lowercase hex digits.
pub(crate) fn digest(text: &str) -> bool {
    text.len() == 64
        && text
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

/// A canonical decimal from 1 to `Int64.max`.
pub(crate) fn generation(text: &str) -> Option<u64> {
    let number = text.parse::<u64>().ok()?;
    (number > 0 && number <= i64::MAX as u64 && number.to_string() == text).then_some(number)
}

pub(crate) fn optional_generation(value: Option<&Value>) -> bool {
    match value {
        Some(Value::Null) => true,
        Some(Value::String(text)) => generation(text).is_some(),
        _ => false,
    }
}

pub(crate) fn optional_identifier(value: Option<&Value>) -> bool {
    match value {
        Some(Value::Null) => true,
        Some(Value::String(text)) => identifier(text),
        _ => false,
    }
}

pub(crate) fn optional_digest(value: Option<&Value>) -> bool {
    match value {
        Some(Value::Null) => true,
        Some(Value::String(text)) => digest(text),
        _ => false,
    }
}

/// Printable text of 1 to `maximum` bytes, or null.
pub(crate) fn optional_text(value: Option<&Value>, maximum: usize) -> bool {
    match value {
        Some(Value::Null) => true,
        Some(Value::String(text)) => {
            (1..=maximum).contains(&text.len())
                && text
                    .chars()
                    .all(|scalar| scalar as u32 >= 32 && scalar as u32 != 127)
        }
        _ => false,
    }
}

pub(crate) fn one_of(value: Option<&Value>, allowed: &[&str]) -> bool {
    value
        .and_then(Value::as_str)
        .is_some_and(|text| allowed.contains(&text))
}

/// The SHA-256 of the RFC 8785 canonical bytes.
pub(crate) fn hash(value: &Value) -> Result<String, WireError> {
    Ok(sha256_hex(
        &canonical_json(value).map_err(|_| unreadable())?,
    ))
}

/// An instant as the records spell it: UTC with milliseconds, and only the
/// spelling that reads back to itself.
pub(crate) fn time(text: &str) -> Option<u64> {
    precise_utc_millis(text)
}

pub(crate) fn timestamp(milliseconds: u64) -> String {
    utc_precise_from_millis(milliseconds)
}

pub(crate) fn exact_keys(fields: &Map<String, Value>, keys: &[&str]) -> bool {
    fields.len() == keys.len() && keys.iter().all(|key| fields.contains_key(*key))
}

pub(crate) fn owner(id: &str) -> Value {
    json!({"kind": "controlAction", "id": id})
}

pub(crate) fn record_unreadable(message: &str) -> WireError {
    crate::control_action::refused("recordUnreadable", message)
}
