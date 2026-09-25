//! Current immutable Job discovery consumers. A page is checked in full before
//! it is returned; resource references are never followed by this module.
use crate::{
    CliError,
    read_only_resources::{date, identifier, invalid, keys, known_job_state, publication},
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

const SHOW_KEYS: [&str; 14] = [
    "schemaVersion",
    "job",
    "request",
    "catalogDigest",
    "providerId",
    "materializedPlanDigest",
    "materializedBindingRevision",
    "materializedStableIdentitySha256",
    "actualStepKinds",
    "timeline",
    "events",
    "evidence",
    "ringCoverage",
    "screenSequence",
];
const STATUS_KEYS: [&str; 24] = [
    "schemaVersion",
    "jobId",
    "operation",
    "targetId",
    "state",
    "outcome",
    "waitingForHuman",
    "outcomeUnknown",
    "outstandingResidueCount",
    "executionMode",
    "sessionId",
    "threadId",
    "workspaceKind",
    "actualEffect",
    "createdAtUtc",
    "startedAtUtc",
    "finishedAtUtc",
    "supersededByRecoveryEpochId",
    "recoveryEpochId",
    "resolvedByTargetAliasResolutionId",
    "sessionPublication",
    "nextAction",
    "failure",
    "processProgress",
];

/// Swift `CLIJobReadValidation.validate` for `show`, in its order and words.
pub(crate) fn validate_show(show: &Value, job_id: &str) -> Result<(), CliError> {
    let invalid = || {
        CliError::new(
            "recordUnreadable",
            "the Runtime returned an invalid Job read projection",
        )
    };
    if show["schemaVersion"] != "arkdeck.job/1"
        || !keys(show, &SHOW_KEYS)
        || !show["request"].is_object()
        || !digest(&show["catalogDigest"])
    {
        return Err(invalid());
    }
    let id = validate_status(&show["job"], Some(job_id))?;
    if show["events"] != json!({"method": "job.events", "jobId": id})
        || show["evidence"] != json!({"method": "job.evidence", "jobId": id})
    {
        return Err(invalid());
    }
    validate_timeline(&show["timeline"], &id, false)
}

/// Swift `CLIJobReadValidation.validateStatus`: the closed status every Job
/// read answers, whose identity it returns. It reads even when its next action
/// needs a person or a reconciliation: that is the Job's state, reported as
/// the Runtime answered it, not an unreadable answer.
pub(crate) fn validate_status(status: &Value, expected: Option<&str>) -> Result<String, CliError> {
    let closed = || {
        CliError::new(
            "recordUnreadable",
            "Job status does not match its closed read schema",
        )
    };
    let id = status["jobId"]
        .as_str()
        .filter(|id| identifier(id))
        .ok_or_else(closed)?;
    let outcome = if status["outcomeUnknown"] == true {
        json!("outcomeUnknown")
    } else {
        status["state"].clone()
    };
    if !keys(status, &STATUS_KEYS)
        || expected.is_some_and(|expected| expected != id)
        || status["outcome"] != outcome
        || !date(&status["createdAtUtc"])
    {
        return Err(closed());
    }
    if !publication(&status["sessionPublication"]) {
        return Err(CliError::new(
            "recordUnreadable",
            "Job status carries an unreadable Session publication",
        ));
    }
    // `observed` also refuses a failure awaiting finalization, which Swift's
    // `validatedObservedJobStatus` leaves to the waits that call it: a read
    // reports that Job as it is.
    match crate::job_wait::observed(id, status) {
        Err(error)
            if !matches!(
                error.code,
                "outcomeUnknown" | "humanActionRequired" | "resultNotReady"
            ) =>
        {
            Err(error)
        }
        _ => Ok(id.to_owned()),
    }
}

/// Swift `CLIJobReadValidation.validateTimeline`: a Job's inline timeline or
/// its reference, and a list row's absent one where it was not asked for.
fn validate_timeline(timeline: &Value, job_id: &str, allow_null: bool) -> Result<(), CliError> {
    let unreadable = |message: &str| Err(CliError::new("recordUnreadable", message));
    if allow_null && timeline.is_null() {
        return Ok(());
    }
    if !timeline.is_object() {
        return unreadable("Job timeline is unreadable");
    }
    match timeline["kind"].as_str() {
        Some("inline") => {
            if !keys(timeline, &["kind", "entries"])
                || !timeline["entries"]
                    .as_array()
                    .is_some_and(|entries| entries.iter().all(Value::is_string))
            {
                return unreadable("Job timeline is unreadable");
            }
        }
        Some("snapshotPages") => {
            if !keys(timeline, &["kind", "jobId", "method"])
                || timeline["method"] != "job.timeline"
                || timeline["jobId"] != job_id
            {
                return unreadable("Job timeline reference is unreadable");
            }
        }
        _ => return unreadable("unknown Job timeline projection"),
    }
    Ok(())
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
        let id = validate_status(&status, None)?;
        validate_timeline(
            &row_timeline,
            &id,
            params.get("includeTimeline") != Some(&json!(true)),
        )?;
        let id = id.as_str();
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
        if !seen.insert(id.to_owned()) {
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

#[cfg(test)]
mod tests {
    use super::*;

    /// A recorded Swift daemon status, by the state it was recorded in.
    fn recorded(state: &str) -> Value {
        include_str!(
            "../../../../Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames/job.status.jsonl"
        )
        .lines()
        .map(|line| serde_json::from_str::<Value>(line).unwrap())
        .find(|frame| frame["ok"] == true && frame["result"]["state"] == state)
        .unwrap_or_else(|| panic!("Swift recorded a {state} status"))["result"]
            .clone()
    }

    fn refusal(status: &Value) -> String {
        let id = status["jobId"].as_str().unwrap_or("job-1");
        validate_status(status, Some(id)).unwrap_err().message
    }

    #[test]
    fn a_status_whose_next_action_needs_attention_reads_as_swift_reads_it() {
        // Waiting on a person: its next action is the human action.
        let mut human = recorded("running");
        let id = human["jobId"].as_str().unwrap().to_owned();
        human["waitingForHuman"] = json!(true);
        human["nextAction"] = json!({
            "kind": "humanAction",
            "owner": {"kind": "job", "id": id},
            "resource": {"kind": "humanAction", "id": "human-action-1"},
            "reasonCode": "device.notObserved",
            "resumeReference": "resume-1",
            "expiresAt": null,
        });
        assert_eq!(validate_status(&human, Some(&id)).unwrap(), id);
        // An unknown outcome, and a failure awaiting finalization: the waits
        // refuse them, a read reports them.
        let mut unknown = recorded("running");
        unknown["outcomeUnknown"] = json!(true);
        unknown["outcome"] = json!("outcomeUnknown");
        unknown["nextAction"] = json!({
            "kind": "reconcile",
            "owner": {"kind": "job", "id": id},
            "resource": {"kind": "job", "id": id},
            "reasonCode": "recovery.outcomeUnknown",
        });
        assert!(validate_status(&unknown, None).is_ok());
        let finalizing = recorded("finalizing");
        assert!(validate_status(&finalizing, None).is_ok());
        assert_eq!(
            crate::job_wait::observed(finalizing["jobId"].as_str().unwrap(), &finalizing)
                .unwrap_err()
                .code,
            "resultNotReady"
        );
    }

    #[test]
    fn a_malformed_status_is_refused_in_swifts_words() {
        let status = recorded("running");
        let mut outcome = status.clone();
        outcome["outcome"] = json!("succeeded");
        assert_eq!(
            refusal(&outcome),
            "Job status does not match its closed read schema"
        );
        let mut publication = status.clone();
        publication["sessionPublication"]["reasonCode"] = json!("guessed");
        assert_eq!(
            refusal(&publication),
            "Job status carries an unreadable Session publication"
        );
        let mut next = status.clone();
        next["nextAction"]["kind"] = json!("readResult");
        assert_eq!(refusal(&next), "Job status has no supported next action");
        // A person-waiting status whose next action is not the human action.
        let mut human = status;
        human["waitingForHuman"] = json!(true);
        assert_eq!(refusal(&human), "Job status has no supported next action");
    }
}
