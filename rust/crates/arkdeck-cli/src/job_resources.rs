//! Current immutable Job discovery consumers. A page is checked in full before
//! it is returned; resource references are never followed by this module.
use crate::{
    CliError,
    read_only_resources::{date, invalid, keys, known_job_state, validate_job_status},
    session_resources::{digest, uuid},
};
use serde_json::{Map, Value, json};
use std::collections::BTreeSet;

pub(super) fn configure_list(fields: &mut Map<String, Value>) -> Result<(), CliError> {
    // --target shares the top-level parser with Session/history commands;
    // the current Job query contract deliberately calls this field `target`.
    if let Some(value) = fields.remove("targetId") {
        fields.insert("target".into(), value);
    }
    for key in ["state", "operation", "target", "thread"] {
        if let Some(value) = fields.get(key) {
            let text = value
                .as_str()
                .filter(|s| {
                    !s.is_empty() && s.len() <= 256 && !s.chars().any(|c| c < ' ' || c == '\u{7f}')
                })
                .ok_or_else(|| {
                    CliError::new(
                        "invalidInput",
                        format!("{key} must be a bounded query value"),
                    )
                })?;
            if key == "state" && !known_job_state(text) {
                return Err(CliError::new(
                    "invalidInput",
                    "state is not a published Job state",
                ));
            }
        }
    }
    if let Some(value) = fields.get("pageSize") {
        let text = value.as_str().unwrap_or_default();
        let size = text
            .parse::<u64>()
            .ok()
            .filter(|n| (1..=1000).contains(n) && n.to_string() == text)
            .ok_or_else(|| {
                CliError::new("invalidOption", "page-size must be between 1 and 1000")
            })?;
        fields.insert("pageSize".into(), json!(size));
    }
    if let Some(value) = fields.get("order")
        && !matches!(
            value.as_str(),
            Some("createdAtDescJobIdAsc" | "createdAtAscJobIdAsc")
        )
    {
        return Err(CliError::new(
            "invalidInput",
            "order must name a published complete Job order",
        ));
    }
    if let Some(value) = fields.get("cursor")
        && !value
            .as_str()
            .is_some_and(|s| !s.is_empty() && s.len() <= 2048)
    {
        return Err(CliError::new(
            "invalidCursor",
            "cursor must be a bounded snapshot token",
        ));
    }
    Ok(())
}

fn timeline(value: &Value, job_id: &str, allow_null: bool) -> bool {
    if value.is_null() {
        return allow_null;
    }
    match value["kind"].as_str() {
        Some("inline") => {
            keys(value, &["kind", "entries"])
                && value["entries"]
                    .as_array()
                    .is_some_and(|entries| entries.iter().all(Value::is_string))
        }
        Some("snapshotPages") => {
            keys(value, &["kind", "jobId", "method"])
                && value["jobId"] == job_id
                && value["method"] == "job.timeline"
        }
        _ => false,
    }
}

pub(super) fn validate_show(id: &str, value: &Value) -> Result<(), CliError> {
    if value["schemaVersion"] != "arkdeck.job/1"
        || !digest(&value["catalogDigest"])
        || value["events"] != json!({"method":"job.events", "jobId":id})
        || value["evidence"] != json!({"method":"job.evidence", "jobId":id})
        || !timeline(&value["timeline"], id, false)
    {
        return Err(invalid());
    }
    validate_job_status(id, &value["job"])
}

// The producer sorts parsed Dates, not their textual timezone/fraction spelling.
// Use Date's 2001 reference epoch and floating-point seconds for the same order.
pub(super) fn date_seconds(value: &Value) -> Option<f64> {
    if !date(value) {
        return None;
    }
    let s = value.as_str()?;
    let n = |start, end| s[start..end].parse::<i64>().unwrap();
    let (year, month, day) = (n(0, 4), n(5, 7), n(8, 10));
    let preceding_year = year - 1;
    let before_month =
        [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334][(month - 1) as usize];
    let leap = i64::from(month > 2 && year % 4 == 0 && (year % 100 != 0 || year % 400 == 0));
    let days = 365 * preceding_year + preceding_year / 4 - preceding_year / 100
        + preceding_year / 400
        + before_month
        + leap
        + day
        - 1;
    let mut seconds =
        ((days - 730_485) * 86_400 + n(11, 13) * 3600 + n(14, 16) * 60 + n(17, 19)) as f64;
    let mut suffix = &s[19..];
    if suffix.starts_with('.') {
        let length = 1 + suffix[1..].bytes().take_while(u8::is_ascii_digit).count();
        seconds += suffix[..length].parse::<f64>().ok()?;
        suffix = &suffix[length..];
    }
    if suffix != "Z" {
        let offset =
            suffix[1..3].parse::<i64>().ok()? * 3600 + suffix[4..6].parse::<i64>().ok()? * 60;
        seconds -= (if suffix.starts_with('-') {
            -offset
        } else {
            offset
        }) as f64;
    }
    Some(seconds)
}

pub(super) fn validate_list(params: &Map<String, Value>, value: &Value) -> Result<(), CliError> {
    let order = params
        .get("order")
        .and_then(Value::as_str)
        .unwrap_or("createdAtDescJobIdAsc");
    let revision = value["snapshotRevision"]
        .as_str()
        .filter(|s| uuid(s))
        .ok_or_else(invalid)?;
    let rows = value["items"].as_array().ok_or_else(invalid)?;
    let more = value["hasMore"].as_bool().ok_or_else(invalid)?;
    if value["schemaVersion"] != "arkdeck.cli.page/1"
        || value["pageKind"] != "snapshot"
        || value["order"] != order
        || rows.len()
            > params
                .get("pageSize")
                .and_then(Value::as_u64)
                .unwrap_or(100) as usize
        || rows.len() > 1000
    {
        return Err(invalid());
    }
    if let Some(cursor) = params.get("cursor").and_then(Value::as_str)
        && cursor
            .split_once('.')
            .is_none_or(|(snapshot, _)| snapshot != revision)
    {
        return Err(invalid());
    }
    if more {
        let cursor = value["nextCursor"].as_str().ok_or_else(invalid)?;
        if rows.is_empty()
            || cursor.len() > 2048
            || cursor
                .split_once('.')
                .is_none_or(|(snapshot, token)| snapshot != revision || !uuid(token))
            || params.get("cursor") == Some(&value["nextCursor"])
        {
            return Err(invalid());
        }
    } else if !value["nextCursor"].is_null() {
        return Err(invalid());
    }
    let mut seen = BTreeSet::new();
    let mut previous: Option<(f64, String)> = None;
    for row in rows {
        let mut status = row.as_object().ok_or_else(invalid)?.clone();
        if status.remove("schemaVersion") != Some(json!("arkdeck.job-summary/1"))
            || !status.remove("current").is_some_and(|v| v.is_boolean())
        {
            return Err(invalid());
        }
        let row_timeline = status.remove("timeline").ok_or_else(invalid)?;
        status.insert("schemaVersion".into(), json!("arkdeck.job-status/1"));
        let status = Value::Object(status);
        let id = status["jobId"].as_str().ok_or_else(invalid)?;
        validate_job_status(id, &status)?;
        for (key, field) in [
            ("state", "state"),
            ("operation", "operation"),
            ("target", "targetId"),
            ("thread", "threadId"),
        ] {
            if params
                .get(key)
                .is_some_and(|expected| expected != &status[field])
            {
                return Err(invalid());
            }
        }
        if !seen.insert(id.to_owned())
            || !timeline(
                &row_timeline,
                id,
                params.get("includeTimeline") != Some(&json!(true)),
            )
        {
            return Err(invalid());
        }
        let date = date_seconds(&status["createdAtUtc"]).ok_or_else(invalid)?;
        if let Some((previous_date, previous_id)) = &previous
            && if *previous_date == date {
                previous_id.as_bytes() >= id.as_bytes()
            } else if order == "createdAtDescJobIdAsc" {
                *previous_date < date
            } else {
                *previous_date > date
            }
        {
            return Err(invalid());
        }
        previous = Some((date, id.to_owned()));
    }
    Ok(())
}

// A continuation page may begin at any valid entry/part pair. Only pairs
// within this one immutable page are required to be contiguous.
pub(super) fn validate_timeline_page(
    params: &Map<String, Value>,
    value: &Value,
) -> Result<(), CliError> {
    let rows = value["items"].as_array().ok_or_else(invalid)?;
    let more = value["hasMore"].as_bool().ok_or_else(invalid)?;
    if !keys(
        value,
        &[
            "schemaVersion",
            "pageKind",
            "items",
            "order",
            "snapshotRevision",
            "hasMore",
            "nextCursor",
        ],
    ) || value["schemaVersion"] != "arkdeck.cli.page/1"
        || value["pageKind"] != "snapshot"
        || value["order"] != "entryIndexAscPartIndexAsc"
        || !value["snapshotRevision"].as_str().is_some_and(uuid)
        || rows.len() > 1000
        || rows.len()
            > params
                .get("pageSize")
                .and_then(Value::as_u64)
                .unwrap_or(1000) as usize
        || if more {
            rows.is_empty()
                || !value["nextCursor"]
                    .as_str()
                    .is_some_and(|s| !s.is_empty() && s.len() <= 2048)
        } else {
            !value["nextCursor"].is_null()
        }
    {
        return Err(invalid());
    }
    let decimal = |v: &Value| {
        v.as_str().and_then(|s| {
            s.parse::<i64>()
                .ok()
                .filter(|n| *n >= 0 && n.to_string() == s)
        })
    };
    let mut previous: Option<(i64, i64, bool)> = None;
    for row in rows {
        let index = decimal(&row["entryIndex"]).ok_or_else(invalid)?;
        let part = decimal(&row["partIndex"]).ok_or_else(invalid)?;
        let last = row["lastPart"].as_bool().ok_or_else(invalid)?;
        if !keys(row, &["entryIndex", "partIndex", "text", "lastPart"])
            || !row["text"].as_str().is_some_and(|s| s.len() <= 64 * 1024)
        {
            return Err(invalid());
        }
        if let Some((previous_index, previous_part, previous_last)) = previous {
            let contiguous = if previous_index == index {
                !previous_last && previous_part.checked_add(1) == Some(part)
            } else {
                previous_last && previous_index.checked_add(1) == Some(index) && part == 0
            };
            if !contiguous {
                return Err(invalid());
            }
        }
        previous = Some((index, part, last));
    }
    Ok(())
}
