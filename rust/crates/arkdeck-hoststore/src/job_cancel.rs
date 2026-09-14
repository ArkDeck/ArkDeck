//! Swift `RuntimeJobEngine.requestCancel` behind `job.cancel`, for the Jobs the
//! isolated Rust owner admits. A Job that never started closes with zero
//! dispatch — three journaled transitions to `cancelled`, the cancelled
//! failure, its finish time and record — and is then published as a Session
//! like any terminal Job. A Job that already ended, waits for recovery or
//! already carries the request is answered as Swift answers it, with nothing
//! written. A Job that has started is refused: cancelling a running analyzer
//! at its safe boundaries is not ported yet, and a Job left running belongs to
//! recovery (L.1 item 13).
use crate::job_journal_writer::JournalWriter;
use crate::job_owner::JobStore;
use crate::job_record::terminal;
use crate::job_run::{Run, failure};
use crate::session_publication::SessionPublisher;
use arkdeck_contract::WireError;
use serde_json::{Map, Value, json};

/// The states Swift leaves as they are: the request can no longer move them,
/// or already moved them.
const UNCHANGED: [&str; 4] = [
    "waitingForRecovery",
    "reconciling",
    "cancelRequested",
    "cancellingAtSafeBoundary",
];

/// A `job.cancel` refusal, which Swift sends without details.
fn refused(code: &str, message: impl Into<String>) -> WireError {
    WireError {
        code: code.into(),
        message: message.into(),
        details: None,
    }
}

/// A cancellation that could not be carried out durably.
fn internal<E>(_: E) -> WireError {
    refused(
        "internalError",
        "the Runtime could not complete the Job lifecycle request",
    )
}

pub struct JobCanceller<'a> {
    pub jobs: &'a JobStore,
    pub now: fn() -> Option<String>,
    /// As the runner's: the standalone daemon's Session publication writer.
    pub sessions: Option<&'a SessionPublisher<'a>>,
}

impl JobCanceller<'_> {
    /// Swift's `job.cancel` handler over `requestCancel`: once the request is
    /// carried out, or needs nothing, the answer is `cancelRequested`.
    pub fn handle(&self, params: &Map<String, Value>) -> Result<Value, WireError> {
        let Some(id) = params.get("jobId").and_then(Value::as_str) else {
            return Err(refused("invalidParams", "jobId is required"));
        };
        let record = match self.jobs.read_snapshot(id) {
            Ok(record) => record,
            Err(error) if matches!(error.code.as_str(), "notFound" | "invalidInput") => {
                return Err(refused("notFound", format!("unknown job {id}")));
            }
            // Swift renders its engine error as the case is declared.
            Err(error)
                if error
                    .message
                    .starts_with("the referenced Job record is unreadable") =>
            {
                return Err(refused(
                    "rejected",
                    format!("jobRecordUnreadable(\"{id}\")"),
                ));
            }
            Err(_) => {
                return Err(refused(
                    "rejected",
                    format!(
                        "internalFailure(\"Runtime job history index is unreadable for {id}\")"
                    ),
                ));
            }
        };
        let requested = json!({"cancelRequested": true});
        let state = record.state.clone();
        if terminal(&state) || state == "finalizing" || UNCHANGED.contains(&state.as_str()) {
            return Ok(requested);
        }
        let started = || {
            refused(
                "rejected",
                format!(
                    "job {id} is {state}; the Rust Runtime cancels only a Job that never started"
                ),
            )
        };
        if state != "preflight" {
            return Err(started());
        }
        let directory = self.jobs.job_directory(id).map_err(internal)?;
        let journal = JournalWriter::open(&directory, false).map_err(internal)?;
        let facts = journal.facts();
        if facts.has_torn_tail
            || facts.current_state.as_deref() != Some("preflight")
            || !facts.outstanding_intents.is_empty()
            || !facts.unknown_outcomes.is_empty()
            || facts.finalized
        {
            return Err(started());
        }
        let mut run = Run {
            record,
            journal,
            sequence: facts.last_durable_sequence.map_or(0, |last| last + 1),
            now: self.now,
        };
        // Swift completes this zero-dispatch decision durably at once, so an
        // abandoned submission never stays in `preflight`.
        run.transition(
            "preflight",
            "cancelRequested",
            "client-cancel before execution",
        )
        .map_err(internal)?;
        run.transition(
            "cancelRequested",
            "cancellingAtSafeBoundary",
            "no provider intent was dispatched",
        )
        .map_err(internal)?;
        run.transition(
            "cancellingAtSafeBoundary",
            "cancelled",
            "never-started job closed with zero dispatch",
        )
        .map_err(internal)?;
        run.record.set_operation_failure(Some(failure(
            "cancelled",
            "cancelled",
            "notAutomatic",
            "none",
        )));
        run.finish().map_err(internal)?;
        run.persist(self.jobs).map_err(internal)?;
        run.release(self.jobs, self.sessions, &directory)
            .map_err(internal)?;
        Ok(requested)
    }
}
