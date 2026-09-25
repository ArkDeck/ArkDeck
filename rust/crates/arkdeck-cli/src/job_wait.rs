//! `arkdeck job wait`: Swift's `job wait`, which waits for a Job to settle
//! and never cancels it. It takes one of two paths, as Swift's handler picks
//! them:
//!
//! - **Polling** (`emitJobWait`), without `--after-cursor`, `--page-size` or
//!   the `jsonl` stream. It reads `job.status` with a backoff that doubles
//!   from 250 ms to 2 s. There is no deadline unless `--timeout` sets one,
//!   because a flash may legitimately run for half an hour.
//! - **Events** (`emitJobEventObservation` as `wait`), otherwise. It follows
//!   the durable event stream as `job watch` does. Each time the stream is
//!   drained it reads a strictly validated `job.status`, drains once more
//!   after a terminal one, and ends with that status.
//!
//! Either way a settled Job is a successful read: the outcome travels in the
//! exit status (`run_exit`), and in `job.outcome` of the status it emits.
use crate::{
    CliError,
    read_only_resources::{date, duration, identifier, keys, publication, terminal_job_state},
};
use serde_json::{Map, Value, json};

/// A refusal of Swift's registry parser, which names the leaf, before any
/// request.
fn refused(message: String, details: Map<String, Value>) -> CliError {
    let mut error = CliError::new("invalidOption", message);
    error.details = details;
    error.details.insert("command".into(), json!("job.wait"));
    error.command = Some("job.wait");
    error
}

/// The registry's grammar of the leaf, in its declaration order, as Swift's
/// parser judges it: `--job` required, `--timeout` a duration of at most a
/// day, `--page-size` within 1…1000. Then, on the event path, the handler's
/// own checks of the identity and the cursor (`job_events::configure`).
///
/// Returns the caller's `--timeout` in milliseconds; each path reads its
/// absence its own way.
pub(super) fn configure(
    fields: &mut Map<String, Value>,
    jsonl: bool,
) -> Result<Option<u64>, CliError> {
    let Some(job) = fields
        .get("jobId")
        .and_then(Value::as_str)
        .map(str::to_owned)
    else {
        return Err(refused(
            "`job wait` requires --job <job-id>".into(),
            Map::from_iter([("option".into(), json!("--job"))]),
        ));
    };
    let timeout = match fields.remove("timeout") {
        None => None,
        Some(value) => Some(value.as_str().and_then(duration).ok_or_else(|| {
            refused(
                "`job wait` --timeout must be a duration like `30s` (digits then ms|s|m|h, no \
                 larger than 86400000ms)"
                    .into(),
                Map::from_iter([("option".into(), json!("--timeout"))]),
            )
        })?),
    };
    if let Some(size) = fields.get("pageSize") {
        let text = size.as_str().unwrap_or_default();
        let plain = !text.is_empty()
            && text.bytes().all(|byte| byte.is_ascii_digit())
            && !text.starts_with('0');
        if !plain || !text.parse::<u64>().is_ok_and(|size| size <= 1000) {
            return Err(refused(
                "`job wait` --page-size must be 1...1000".into(),
                Map::from_iter([
                    ("option".into(), json!("--page-size")),
                    ("value".into(), json!(text)),
                ]),
            ));
        }
    }
    // The handler's own refusals name the leaf too: Swift's session stamps
    // its command on every failure it raises.
    if follows_events(fields, jsonl) {
        let named = |mut error: CliError| {
            error.command = Some("job.wait");
            error
        };
        if !identifier(&job) {
            return Err(named(CliError::new(
                "invalidInput",
                "an exact Job identity is required",
            )));
        }
        crate::job_events::configure(fields).map_err(named)?;
    }
    Ok(timeout)
}

/// Swift's choice of path: the event stream for `jsonl`, or once a cursor or
/// a page size is given; polling otherwise.
pub fn follows_events(fields: &Map<String, Value>, jsonl: bool) -> bool {
    jsonl || fields.contains_key("afterCursor") || fields.contains_key("pageSize")
}

/// Where one polled status leaves the wait.
#[derive(Debug, PartialEq)]
pub enum Poll {
    /// Terminal, or its outcome unknown: emit it and exit by `run_exit`.
    Settled,
    /// Still moving, in this state: read it again.
    Pending(String),
}

/// Swift `emitJobWait`'s judgement of one `job.status` answer.
pub fn poll(job: &str, status: &Value) -> Result<Poll, CliError> {
    let Some(fields) = status.as_object() else {
        return Err(CliError::new(
            "recordUnreadable",
            format!("job {job} returned no readable status"),
        ));
    };
    let Some(state) = fields.get("state").and_then(Value::as_str) else {
        return Err(CliError::new(
            "recordUnreadable",
            format!("job {job} reported no state this build understands"),
        ));
    };
    if let Some(next) = fields.get("nextAction").and_then(Value::as_object)
        && next.get("reasonCode") == Some(&json!("job.finalizationPending"))
    {
        crate::read_only_resources::validate_job_status(job, status)?;
        return Err(finalization_pending(job, next));
    }
    if terminal_job_state(state) || fields.get("outcomeUnknown") == Some(&json!(true)) {
        return Ok(Poll::Settled);
    }
    // A Job waiting on a person does not settle by being waited on longer.
    if fields.get("waitingForHuman") == Some(&json!(true)) {
        let mut error = CliError::new(
            "humanActionRequired",
            format!("job {job} is waiting for a human action and will not settle on its own"),
        );
        error.details =
            Map::from_iter([("jobId".into(), json!(job)), ("state".into(), json!(state))]);
        return Err(error);
    }
    Ok(Poll::Pending(state.to_owned()))
}

/// The polling wait's deadline, which says nothing about the Job: it is
/// still running and still readable.
pub fn stopped_waiting(job: &str, state: &str) -> CliError {
    let mut error = CliError::new(
        "clientTimeout",
        format!("stopped waiting for job {job}; it is {state} and still running"),
    );
    error.details = Map::from_iter([("jobId".into(), json!(job)), ("state".into(), json!(state))]);
    error
}

fn finalization_pending(job: &str, next: &Map<String, Value>) -> CliError {
    let mut error = CliError::new(
        "resultNotReady",
        format!(
            "Job failure finalization requires reconciliation. Run: arkdeck job reconcile --job {job}"
        ),
    );
    error
        .details
        .insert("nextAction".into(), Value::Object(next.clone()));
    error
}

/// Swift `validatedObservedJobStatus`, which the event path applies to every
/// status it reads before it may end the wait on it. Answers whether the Job
/// is terminal.
///
/// - A human action is refused as `humanActionRequired`, with the next action.
/// - An unknown or recovering outcome is refused as `outcomeUnknown`: the
///   observation never replays an effect.
/// - A failure awaiting finalization is refused as `resultNotReady`.
/// - Any other shape is `recordUnreadable`.
pub fn observed(job: &str, status: &Value) -> Result<bool, CliError> {
    let unreadable = || {
        CliError::new(
            "recordUnreadable",
            "Job status has no supported next action",
        )
    };
    let next = &status["nextAction"];
    let (Some(state), Some(unknown), Some(human), Some(kind)) = (
        status["state"].as_str(),
        status["outcomeUnknown"].as_bool(),
        status["waitingForHuman"].as_bool(),
        next["kind"].as_str(),
    ) else {
        return Err(unreadable());
    };
    if status["schemaVersion"] != "arkdeck.job-status/1"
        || status["jobId"] != job
        || !crate::read_only_resources::known_job_state(state)
        || !next.is_object()
        || next["owner"] != json!({"kind": "job", "id": job})
        || !publication(&status["sessionPublication"])
    {
        return Err(unreadable());
    }
    let base = ["kind", "owner", "resource", "reasonCode"];
    if kind == "humanAction" {
        let resource = &next["resource"];
        let shaped = human
            && !unknown
            && keys(
                next,
                &[
                    "kind",
                    "owner",
                    "resource",
                    "reasonCode",
                    "resumeReference",
                    "expiresAt",
                ],
            )
            && keys(resource, &["kind", "id"])
            && resource["kind"] == "humanAction"
            && resource["id"].as_str().is_some_and(identifier)
            && next["resumeReference"].as_str().is_some_and(identifier)
            && next["reasonCode"].as_str().is_some_and(|reason| {
                [
                    "device.notObserved",
                    "device.trustPending",
                    "device.identityAmbiguous",
                ]
                .contains(&reason)
            })
            && (next["expiresAt"].is_null() || date(&next["expiresAt"]));
        if !shaped {
            return Err(unreadable());
        }
        let mut error = CliError::new(
            "humanActionRequired",
            "the Job needs the referenced human action",
        );
        error.details.insert("nextAction".into(), next.clone());
        return Err(error);
    }
    if human || next["resource"] != next["owner"] {
        return Err(unreadable());
    }
    let terminal = terminal_job_state(state);
    let uncertain = unknown || ["waitingForRecovery", "reconciling"].contains(&state);
    let finalizing = !uncertain
        && state == "finalizing"
        && status["operation"] == "debug.hap@1"
        && crate::read_only_resources::typed_failure(&status["failure"])
        && status["failure"]["code"] != "outcomeUnknown";
    let (expected, reason) = if uncertain {
        ("reconcile", "recovery.outcomeUnknown")
    } else if finalizing {
        ("reconcile", "job.finalizationPending")
    } else if terminal {
        ("readResult", "job.resultAvailable")
    } else {
        ("wait", "job.running")
    };
    let shaped = kind == expected
        && next["reasonCode"] == reason
        && if kind == "wait" {
            keys(
                next,
                &["kind", "owner", "resource", "reasonCode", "retryAfter"],
            ) && next["retryAfter"].as_str().and_then(duration).is_some()
        } else {
            keys(next, &base)
        };
    if !shaped {
        return Err(unreadable());
    }
    if uncertain {
        let mut error = CliError::new(
            "outcomeUnknown",
            "the Job requires reconciliation; observation never replays an effect",
        );
        error.details.insert("nextAction".into(), next.clone());
        return Err(error);
    }
    if finalizing {
        return Err(finalization_pending(
            job,
            next.as_object().expect("a checked next action"),
        ));
    }
    Ok(terminal)
}

#[cfg(test)]
mod tests {
    use super::*;

    const JOB: &str = "job-2b395b58efa418650be51432f3a2c9b0";

    fn status(state: &str, next: Value) -> Value {
        json!({
            "schemaVersion": "arkdeck.job-status/1", "jobId": JOB, "state": state,
            "outcomeUnknown": false, "waitingForHuman": false, "nextAction": next,
            "sessionPublication": {"state": "pending", "manifestSha256": null,
                "catalogGeneration": null, "reasonCode": "jobNotTerminal"},
        })
    }

    fn owned(kind: &str, reason: &str) -> Value {
        json!({"kind": kind, "owner": {"kind": "job", "id": JOB},
            "resource": {"kind": "job", "id": JOB}, "reasonCode": reason})
    }

    #[test]
    fn the_stream_reads_only_the_next_action_a_state_publishes() {
        let mut running = owned("wait", "job.running");
        running["retryAfter"] = json!("2s");
        assert!(!observed(JOB, &status("running", running.clone())).unwrap());
        assert!(
            observed(
                JOB,
                &status("succeeded", owned("readResult", "job.resultAvailable"))
            )
            .unwrap()
        );
        // A running Job whose next action reads a result, a wait without its
        // hint, another Job's status: none is a status this build can read.
        let mut hintless = running.clone();
        hintless.as_object_mut().unwrap().remove("retryAfter");
        let mut foreign = status("running", running.clone());
        foreign["jobId"] = json!("job-00000000000000000000000000000000");
        for unreadable in [
            status("running", owned("readResult", "job.resultAvailable")),
            status("running", hintless),
            foreign,
        ] {
            assert_eq!(
                observed(JOB, &unreadable).unwrap_err().code,
                "recordUnreadable"
            );
        }
        // Recovering is an unknown outcome to the stream.
        let error = observed(
            JOB,
            &status("reconciling", owned("reconcile", "recovery.outcomeUnknown")),
        )
        .unwrap_err();
        assert_eq!((error.code, error.exit_code()), ("outcomeUnknown", 75));
        assert_eq!(
            error.details["nextAction"],
            owned("reconcile", "recovery.outcomeUnknown")
        );
    }

    #[test]
    fn a_person_is_named_only_by_a_complete_human_action() {
        let action = json!({"kind": "humanAction", "owner": {"kind": "job", "id": JOB},
            "resource": {"kind": "humanAction", "id": "har-1"},
            "reasonCode": "device.trustPending", "resumeReference": "resume-1",
            "expiresAt": "2026-09-25T00:00:00Z"});
        let mut waiting = status("waitingForDevice", action.clone());
        waiting["waitingForHuman"] = json!(true);
        let error = observed(JOB, &waiting).unwrap_err();
        assert_eq!(
            (error.code, error.message.as_str()),
            (
                "humanActionRequired",
                "the Job needs the referenced human action"
            )
        );
        assert_eq!(error.details["nextAction"], action);
        // A reason Swift's physical actions never give, or a person the Job
        // does not say it waits for, is unreadable.
        let mut unknown_reason = waiting.clone();
        unknown_reason["nextAction"]["reasonCode"] = json!("device.unplugged");
        let mut not_waiting = waiting.clone();
        not_waiting["waitingForHuman"] = json!(false);
        for unreadable in [unknown_reason, not_waiting] {
            assert_eq!(
                observed(JOB, &unreadable).unwrap_err().code,
                "recordUnreadable"
            );
        }
    }

    #[test]
    fn polling_settles_on_a_terminal_state_or_an_unknown_outcome_only() {
        let running = json!({"state": "running", "outcomeUnknown": false});
        assert_eq!(
            poll(JOB, &running).unwrap(),
            Poll::Pending("running".into())
        );
        assert_eq!(
            poll(JOB, &json!({"state": "planned"})).unwrap(),
            Poll::Settled
        );
        assert_eq!(
            poll(JOB, &json!({"state": "running", "outcomeUnknown": true})).unwrap(),
            Poll::Settled
        );
        // A state this build does not know keeps the wait going until the
        // caller's deadline, as Swift's does.
        assert_eq!(
            poll(JOB, &json!({"state": "rebooting"})).unwrap(),
            Poll::Pending("rebooting".into())
        );
        assert_eq!(
            poll(JOB, &json!({"outcomeUnknown": false}))
                .unwrap_err()
                .message,
            format!("job {JOB} reported no state this build understands")
        );
        assert_eq!(
            poll(JOB, &json!([])).unwrap_err().message,
            format!("job {JOB} returned no readable status")
        );
    }
}
