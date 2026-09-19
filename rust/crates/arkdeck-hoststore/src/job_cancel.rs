//! Swift `RuntimeJobEngine.requestCancel` behind `job.cancel`, for the Jobs the
//! isolated Rust owner admits. A Job that never started closes with zero
//! dispatch — three journaled transitions to `cancelled`, the cancelled
//! failure, its finish time and record — and is then published as a Session
//! like any terminal Job. A Job this owner is running is cancelled by its run,
//! which alone writes the Job's Journal: the request waits in the run's
//! [`RunCancellation`] until the run has made it durable at its next safe
//! boundary, or has crossed its success commit, after which Swift changes
//! nothing. A Job that already ended, waits for recovery or already carries
//! the request is answered as Swift answers it, with nothing written, and a
//! Job left active without a run here is refused as Swift refuses a Job it
//! holds no runtime for (L.1 item 13).
use crate::job_journal_writer::JournalWriter;
use crate::job_owner::JobStore;
use crate::job_record::terminal;
use crate::job_run::{Run, failure};
use crate::session_publication::SessionPublisher;
use arkdeck_contract::WireError;
use serde_json::{Map, Value, json};
use std::sync::{Condvar, Mutex};

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

/// Where a request against a running Job stands.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
enum Request {
    /// None yet; the run can still be stopped.
    #[default]
    Open,
    /// A canceller waits for the run to act on it.
    Pending,
    /// The run made the request durable and is closing the Job.
    Carried,
    /// The run's child finished: Swift's success commit, after which a
    /// request changes nothing.
    Committed,
    /// The run returned without acting on a request.
    Ended,
}

/// The cancellation of one Job's run. The run alone writes the Job's
/// Journal, so a canceller records its request here and waits until the run
/// has made it durable, crossed its commit point, or ended. The run's caller
/// ends it once the run has returned.
#[derive(Default)]
pub struct RunCancellation {
    state: Mutex<Request>,
    changed: Condvar,
}

/// What became of a request against a running Job.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CancelledRun {
    /// The run made the request durable, or had crossed its commit point,
    /// where Swift changes nothing: either way Swift answers the request.
    Answered,
    /// The run ended without acting on it, so the Job's record decides.
    Ended,
}

impl RunCancellation {
    /// A canceller's request: recorded unless the run is already past acting
    /// on one, then waited on until the run answers it or ends.
    pub fn request(&self) -> CancelledRun {
        let Ok(mut state) = self.state.lock() else {
            return CancelledRun::Ended;
        };
        if *state == Request::Open {
            *state = Request::Pending;
            self.changed.notify_all();
        }
        loop {
            match *state {
                Request::Carried | Request::Committed => return CancelledRun::Answered,
                Request::Ended => return CancelledRun::Ended,
                Request::Open | Request::Pending => match self.changed.wait(state) {
                    Ok(next) => state = next,
                    Err(_) => return CancelledRun::Ended,
                },
            }
        }
    }
    /// Whether a request waits for the run to act on it.
    pub fn pending(&self) -> bool {
        self.state
            .lock()
            .is_ok_and(|state| *state == Request::Pending)
    }
    /// The run made the pending request durable.
    pub(crate) fn carried(&self) {
        if let Ok(mut state) = self.state.lock() {
            *state = Request::Carried;
            self.changed.notify_all();
        }
    }
    /// The run's child has finished. A request pending at this moment raced
    /// its completion and is still the run's to answer; any later one is too
    /// late to change anything.
    pub(crate) fn commit(&self) -> bool {
        let Ok(mut state) = self.state.lock() else {
            return false;
        };
        match *state {
            Request::Pending => true,
            Request::Open => {
                *state = Request::Committed;
                self.changed.notify_all();
                false
            }
            _ => false,
        }
    }
    /// The run has returned; a request it never acted on falls back to the
    /// Job's record.
    pub fn end(&self) {
        let Ok(mut state) = self.state.lock() else {
            return;
        };
        if matches!(*state, Request::Open | Request::Pending) {
            *state = Request::Ended;
        }
        self.changed.notify_all();
    }
}

/// Swift's answer to a request against a Job this owner is running, once the
/// run has answered it; none when the run ended first and the Job's record
/// must decide.
pub fn cancel_running(running: &RunCancellation) -> Option<Value> {
    match running.request() {
        CancelledRun::Answered => Some(json!({"cancelRequested": true})),
        CancelledRun::Ended => None,
    }
}

pub struct JobCanceller<'a> {
    pub jobs: &'a JobStore,
    pub now: fn() -> Option<String>,
    /// As the runner's: the standalone daemon's Session publication writer.
    pub sessions: Option<&'a SessionPublisher<'a>>,
}

impl JobCanceller<'_> {
    /// Swift's `job.cancel` handler over `requestCancel` for a Job no run
    /// holds: once the request is carried out, or needs nothing, the answer
    /// is `cancelRequested`.
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
        // Swift cancels an active Job only through its resident runtime; a
        // Job no run here holds is one Swift holds no runtime for.
        let not_resident = || {
            refused(
                "rejected",
                format!(
                    "internalFailure(\"job {id} is {state} but is not resident, so its \
                     cancellation cannot be carried out\")"
                ),
            )
        };
        if state != "preflight" {
            return Err(not_resident());
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
            return Err(not_resident());
        }
        let mut run = Run {
            record,
            journal,
            sequence: facts.last_durable_sequence.map_or(0, |last| last + 1),
            now: self.now,
            consumed: None,
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{Duration, Instant};

    /// Waits until the canceller's request is the run's to act on.
    fn wait_for_request(cancellation: &RunCancellation) {
        let deadline = Instant::now() + Duration::from_secs(30);
        while !cancellation.pending() {
            assert!(
                Instant::now() < deadline,
                "the request never reached the run"
            );
            std::thread::yield_now();
        }
    }

    #[test]
    fn a_request_waits_for_the_run_and_is_answered_once_carried() {
        let cancellation = RunCancellation::default();
        std::thread::scope(|scope| {
            let canceller = scope.spawn(|| cancellation.request());
            wait_for_request(&cancellation);
            assert!(!canceller.is_finished());
            cancellation.carried();
            assert_eq!(canceller.join().unwrap(), CancelledRun::Answered);
        });
        // A later request finds the Job already being closed.
        assert_eq!(cancellation.request(), CancelledRun::Answered);
    }

    #[test]
    fn a_request_before_the_commit_races_it_and_one_after_changes_nothing() {
        let raced = RunCancellation::default();
        std::thread::scope(|scope| {
            let canceller = scope.spawn(|| raced.request());
            wait_for_request(&raced);
            // The race is still the run's to answer: it parks, then carries.
            assert!(raced.commit());
            assert!(raced.pending());
            raced.carried();
            assert_eq!(canceller.join().unwrap(), CancelledRun::Answered);
        });
        let committed = RunCancellation::default();
        assert!(!committed.commit());
        assert_eq!(committed.request(), CancelledRun::Answered);
        assert!(!committed.pending());
    }

    #[test]
    fn a_run_that_ends_first_leaves_the_request_to_the_record() {
        let cancellation = RunCancellation::default();
        std::thread::scope(|scope| {
            let canceller = scope.spawn(|| cancellation.request());
            wait_for_request(&cancellation);
            cancellation.end();
            assert_eq!(canceller.join().unwrap(), CancelledRun::Ended);
        });
        assert_eq!(cancellation.request(), CancelledRun::Ended);
        assert_eq!(cancel_running(&cancellation), None);
    }
}
