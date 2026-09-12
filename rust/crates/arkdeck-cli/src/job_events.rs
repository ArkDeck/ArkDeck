//! Validate a complete unary event page before emitting any data.
use crate::{
    CliError,
    read_only_resources::{date, invalid, keys, known_job_state},
};
use serde_json::{Map, Value, json};
use std::collections::BTreeSet;
const KINDS: &[&str] = &[
    "jobCreated",
    "stateTransition",
    "stepIntent",
    "stepOutcome",
    "compensationIntent",
    "compensationOutcome",
    "bindingCandidate",
    "bindingConfirmed",
    "bindingRejected",
    "serverGenerationChanged",
    "sleep",
    "wake",
    "reconcileStarted",
    "reconcileOutcome",
    "abandonIntent",
    "abandonOutcome",
    "warning",
    "error",
    "finalized",
];
pub(super) fn configure(fields: &mut Map<String, Value>) -> Result<(), CliError> {
    let size = fields
        .get("pageSize")
        .map_or(Some(100), |v| {
            v.as_str().and_then(|s| s.parse::<u64>().ok())
        })
        .filter(|n| (1..=1000).contains(n))
        .ok_or_else(|| CliError::new("invalidInput", "Invalid event page size"))?;
    fields.insert("pageSize".into(), json!(size));
    if fields.get("afterCursor").is_some_and(|v| !cursor(v)) {
        return Err(CliError::new(
            "invalidCursor",
            "after-cursor must be a bounded opaque cursor",
        ));
    }
    Ok(())
}
fn decimal(value: &Value) -> Option<i64> {
    let text = value.as_str()?;
    let n = text.parse::<i64>().ok()?;
    (n >= 0 && n.to_string() == text).then_some(n)
}
fn cursor(value: &Value) -> bool {
    value
        .as_str()
        .is_some_and(|s| !s.is_empty() && s.len() <= 2048)
}
fn bounded(value: &Value, nonempty: bool) -> bool {
    value
        .as_str()
        .is_some_and(|s| (!nonempty || !s.is_empty()) && s.len() <= 512)
}
pub(super) fn validate(params: &Map<String, Value>, value: &Value) -> Result<(), CliError> {
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
        || value["pageKind"] != "eventStream"
        || value["order"] != "streamPositionAsc"
        || !cursor(&value["nextCursor"])
    {
        return Err(invalid());
    }
    let revision = decimal(&value["snapshotRevision"]).ok_or_else(invalid)?;
    let items = value["items"].as_array().ok_or_else(invalid)?;
    let more = value["hasMore"].as_bool().ok_or_else(invalid)?;
    if items.len() as u64
        > params
            .get("pageSize")
            .and_then(Value::as_u64)
            .unwrap_or(100)
        || (more && items.is_empty())
    {
        return Err(invalid());
    }
    let mut previous = None;
    let mut ids = BTreeSet::new();
    for row in items {
        let position = decimal(&row["streamPosition"]).ok_or_else(invalid)?;
        if !keys(
            row,
            &[
                "eventId",
                "streamPosition",
                "runtimeRevision",
                "cursor",
                "type",
                "data",
            ],
        ) || !bounded(&row["eventId"], true)
            || !ids.insert(row["eventId"].as_str().unwrap())
            || position == 0
            || position > revision
            || previous.is_some_and(|p: i64| p.checked_add(1) != Some(position))
            || decimal(&row["runtimeRevision"]) != Some(revision)
            || !cursor(&row["cursor"])
        {
            return Err(invalid());
        }
        let data = &row["data"];
        let kind = data["journalKind"].as_str().ok_or_else(invalid)?;
        let mut expected = vec![
            "jobId",
            "sessionId",
            "journalKind",
            "timestamp",
            "stepId",
            "attempt",
            "bindingRevision",
        ];
        if kind == "stateTransition" {
            expected.extend(["fromState", "toState"]);
        }
        if !KINDS.contains(&kind)
            || row["type"]
                != (if kind == "stateTransition" {
                    "stateChanged"
                } else {
                    "journalEvent"
                })
            || !keys(data, &expected)
            || data["jobId"] != params["jobId"]
            || !bounded(&data["sessionId"], true)
            || !date(&data["timestamp"])
            || (!data["stepId"].is_null() && !bounded(&data["stepId"], false))
            || ["attempt", "bindingRevision"]
                .iter()
                .any(|k| !data[*k].is_null() && decimal(&data[*k]).is_none())
        {
            return Err(invalid());
        }
        if kind == "stateTransition"
            && ["fromState", "toState"]
                .iter()
                .any(|k| !data[*k].as_str().is_some_and(known_job_state))
        {
            return Err(invalid());
        }
        previous = Some(position);
    }
    if !more && previous.is_some_and(|p| p != revision) {
        return Err(invalid());
    }
    Ok(())
}
