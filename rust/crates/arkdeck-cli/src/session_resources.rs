//! Semantic checks required by the current Session CLI consumer, beyond the
//! generated structural schema. No partial page is printed on a failed check.
use crate::{CliError, Invocation, valid_correlation};
use serde_json::Value;
use std::collections::BTreeSet;

fn failure() -> CliError {
    CliError::new(
        "recordUnreadable",
        "The Runtime returned an invalid Session resource or page",
    )
}
fn decimal(value: &Value) -> Option<u64> {
    let text = value.as_str()?;
    let number = text.parse::<u64>().ok()?;
    (number <= i64::MAX as u64 && number.to_string() == text).then_some(number)
}
fn uuid(text: &str) -> bool {
    text.len() == 36
        && text.bytes().enumerate().all(|(index, byte)| {
            if [8, 13, 18, 23].contains(&index) {
                byte == b'-'
            } else {
                byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte)
            }
        })
}
fn plain_date(text: &str) -> bool {
    if text.len() != 20
        || !text.bytes().enumerate().all(|(index, byte)| match index {
            4 | 7 => byte == b'-',
            10 => byte == b'T',
            13 | 16 => byte == b':',
            19 => byte == b'Z',
            _ => byte.is_ascii_digit(),
        })
    {
        return false;
    }
    let number = |a, b| text[a..b].parse::<u32>().unwrap();
    let (year, month, day) = (number(0, 4), number(5, 7), number(8, 10));
    let days = match month {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        2 if year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) => 29,
        2 => 28,
        _ => 0,
    };
    year > 0
        && day > 0
        && day <= days
        && number(11, 13) < 24
        && number(14, 16) < 60
        && number(17, 19) < 60
}
fn row(value: &Value) -> Result<(&str, u64, &str), CliError> {
    let fields = value.as_object().ok_or_else(failure)?;
    let keys = [
        "schemaVersion",
        "sessionId",
        "generation",
        "completedAtUtc",
        "expiresAtUtc",
        "sizeBytes",
        "pinned",
        "policyGeneration",
    ];
    if fields.len() != keys.len()
        || keys.iter().any(|key| !fields.contains_key(*key))
        || value["schemaVersion"] != "arkdeck.session/1"
        || !value["pinned"].is_boolean()
        || decimal(&value["sizeBytes"]).is_none()
        || decimal(&value["policyGeneration"]).is_none_or(|value| value == 0)
    {
        return Err(failure());
    }
    let id = value["sessionId"]
        .as_str()
        .filter(|id| valid_correlation(id))
        .ok_or_else(failure)?;
    let generation = decimal(&value["generation"]).ok_or_else(failure)?;
    let completed = value["completedAtUtc"]
        .as_str()
        .filter(|value| plain_date(value))
        .ok_or_else(failure)?;
    let expires = value["expiresAtUtc"]
        .as_str()
        .filter(|value| plain_date(value))
        .ok_or_else(failure)?;
    if expires <= completed {
        return Err(failure());
    }
    Ok((id, generation, completed))
}
pub fn validate_session_response(invocation: &Invocation, value: &Value) -> Result<(), CliError> {
    if invocation.command != "session.list" {
        if matches!(
            invocation.command,
            "session.show" | "session.pin" | "session.unpin"
        ) {
            row(value)?;
        }
        return Ok(());
    }
    let fields = value.as_object().ok_or_else(failure)?;
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
        || value["order"] != "completedAtDescSessionIdAsc"
    {
        return Err(failure());
    }
    let revision = value["snapshotRevision"]
        .as_str()
        .filter(|value| uuid(value))
        .ok_or_else(failure)?;
    let items = value["items"].as_array().ok_or_else(failure)?;
    let size = invocation
        .params
        .as_ref()
        .and_then(|fields| fields.get("pageSize"))
        .and_then(Value::as_u64)
        .unwrap_or(100);
    if items.len() as u64 > size {
        return Err(failure());
    }
    match value["hasMore"].as_bool() {
        Some(true) => {
            let cursor = value["nextCursor"]
                .as_str()
                .filter(|value| value.len() <= 2048)
                .ok_or_else(failure)?;
            let (prefix, token) = cursor.split_once('.').ok_or_else(failure)?;
            if items.is_empty() || prefix != revision || !uuid(token) {
                return Err(failure());
            }
        }
        Some(false) if value["nextCursor"].is_null() => (),
        _ => return Err(failure()),
    }
    let mut prior = None;
    let mut ids = BTreeSet::new();
    for item in items {
        let current = row(item)?;
        if !ids.insert(current.0)
            || prior.is_some_and(|(id, generation, completed)| {
                generation != current.1
                    || completed < current.2
                    || (completed == current.2 && id >= current.0)
            })
        {
            return Err(failure());
        }
        prior = Some(current);
    }
    Ok(())
}
