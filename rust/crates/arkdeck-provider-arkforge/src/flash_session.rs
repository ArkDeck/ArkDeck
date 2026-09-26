//! Swift `ArkForgeFlashSession` (`ArkForgeFlashSession.swift`): drives one
//! correlated ArkForge job across the daemon boundary.
//!
//! The daemon never calls out. It asks on its job's event stream and waits
//! for this side to call back in, so this is a loop that polls events and
//! answers them: admissions through the execution authority, control requests
//! through the performer and the managed-control port. It decides nothing
//! itself. Completion is stated only by the daemon's `outcomeClassified`;
//! silence is never an answer, and a job that stays silent past the
//! operation-wide bound has an unknown outcome.

use crate::authority::{Decision, ExecutionAuthority};
use crate::managed_control::{self, Observation, ReceiptRefusal};
use arkforge_ipc::messages::{
    ActionReceiptSummary, JobEvent, JobEventKind, ManagedControlRequest, StepAdmissionSnapshot,
    SubmissionOutcome, SubmitManagedControlReceiptRequest, SubmitStepPermitRequest,
};
use std::collections::BTreeSet;
use std::time::Duration;

/// Swift `pollIntervalMilliseconds`: the wait before polling again when the
/// daemon has nothing queued.
pub const POLL_INTERVAL: Duration = Duration::from_millis(500);

/// Swift `quietPollLimit`: consecutive quiet polls before the outcome is
/// unknown. It outlasts the catalog's 1800 s full restore rather than
/// declaring a still-running write missing.
pub const QUIET_POLL_LIMIT: u64 = 4200;

/// Swift `ArkForgeFlashSession.Daemon`, narrowed to what driving and
/// observing a correlated job call. An error is its description.
pub trait SessionDaemon {
    /// One poll of the job's events after `after_sequence` (Swift
    /// `watchJob`): the events queued at that instant, in order.
    fn job_events(&mut self, job_id: &str, after_sequence: u64) -> Result<Vec<JobEvent>, String>;

    fn submit_permit(
        &mut self,
        submission: &SubmitStepPermitRequest,
    ) -> Result<SubmissionOutcome, String>;

    fn submit_control_receipt(
        &mut self,
        receipt: &SubmitManagedControlReceiptRequest,
    ) -> Result<SubmissionOutcome, String>;

    /// Asks the daemon to cancel the job at its last journal sequence
    /// `expected_sequence`; zero names none, which ArkForge's encoder omits.
    fn cancel(&mut self, job_id: &str, expected_sequence: u64) -> Result<(), String>;
}

/// ArkForge's controller session is the production daemon: the client
/// already has these calls, so a drift between them is a compile error. Its
/// errors read as their code and message.
impl SessionDaemon for arkforge_client::ControllerClient {
    fn job_events(&mut self, job_id: &str, after_sequence: u64) -> Result<Vec<JobEvent>, String> {
        arkforge_client::ControllerClient::job_events(self, job_id, after_sequence)
            .map_err(|error| client_error(&error))
    }

    fn submit_permit(
        &mut self,
        submission: &SubmitStepPermitRequest,
    ) -> Result<SubmissionOutcome, String> {
        arkforge_client::ControllerClient::submit_permit(self, submission)
            .map_err(|error| client_error(&error))
    }

    fn submit_control_receipt(
        &mut self,
        receipt: &SubmitManagedControlReceiptRequest,
    ) -> Result<SubmissionOutcome, String> {
        arkforge_client::ControllerClient::submit_control_receipt(self, receipt)
            .map_err(|error| client_error(&error))
    }

    fn cancel(&mut self, job_id: &str, expected_sequence: u64) -> Result<(), String> {
        arkforge_client::ControllerClient::cancel(self, job_id, expected_sequence)
            .map(drop)
            .map_err(|error| client_error(&error))
    }
}

/// An ArkForge client error as this lane reports it: its code and message.
/// Swift's client names the API and status as well, which ArkForge's Rust
/// error does not carry.
pub fn client_error(error: &arkforge_client::ClientError) -> String {
    format!("{}: {}", error.code, error.message)
}

/// Swift `ControlPerformer`: how a control request is performed on the
/// device. It takes the whole request, since a read names the fact it needs
/// confirmed. An error is its description.
pub trait ControlPerformer {
    fn perform(&mut self, request: &ManagedControlRequest) -> Result<Observation, String>;
}

/// Swift `Outcome`: what a finished job amounts to.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SessionOutcome {
    Completed(Vec<ActionReceiptSummary>),
    /// A conclusive failure, never a completion receipt.
    ConfirmedFailed {
        reason: String,
        receipts: Vec<ActionReceiptSummary>,
    },
    /// Cancelled with proof nothing external happened.
    CancelledSafe(Vec<ActionReceiptSummary>),
    /// No authoritative terminal answer; the permit must not be signed again.
    OutcomeUnknown {
        reason: String,
        receipts: Vec<ActionReceiptSummary>,
    },
}

/// Why a drive stopped without a terminal answer: Swift `SessionError`, the
/// port's receipt refusal, or the daemon's error, each as it reads.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SessionError {
    PermitRejected {
        step_id: String,
        code: String,
        message: String,
    },
    ControlReceiptRejected {
        request_id: String,
        code: String,
        message: String,
    },
    Receipt(ReceiptRefusal),
    Daemon(String),
}

impl std::fmt::Display for SessionError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::PermitRejected {
                step_id,
                code,
                message,
            } => write!(
                f,
                "arkforged rejected the permit for {step_id}: {code} {message}"
            ),
            Self::ControlReceiptRejected {
                request_id,
                code,
                message,
            } => write!(
                f,
                "arkforged rejected the control receipt for {request_id}: {code} {message}. The \
                 job was cancelled rather than left waiting for a receipt it refuses"
            ),
            Self::Receipt(refusal) => refusal.fmt(f),
            Self::Daemon(error) => f.write_str(error),
        }
    }
}

impl std::error::Error for SessionError {}

/// Swift `ArkForgeFlashSession`: the authority, the performer and the daemon
/// it answers between, and what the daemon published.
pub struct FlashSession<'a> {
    daemon: &'a mut dyn SessionDaemon,
    authority: &'a mut ExecutionAuthority,
    performer: &'a mut dyn ControlPerformer,
    /// How a quiet poll waits: [`POLL_INTERVAL`], unless a test paces it.
    pause: Box<dyn FnMut(Duration) + 'a>,
    receipts: Vec<ActionReceiptSummary>,
    refusals: Vec<String>,
}

impl<'a> FlashSession<'a> {
    pub fn new(
        daemon: &'a mut dyn SessionDaemon,
        authority: &'a mut ExecutionAuthority,
        performer: &'a mut dyn ControlPerformer,
    ) -> Self {
        Self::paced(daemon, authority, performer, std::thread::sleep)
    }

    /// A session whose quiet polls wait through `pause`.
    pub fn paced(
        daemon: &'a mut dyn SessionDaemon,
        authority: &'a mut ExecutionAuthority,
        performer: &'a mut dyn ControlPerformer,
        pause: impl FnMut(Duration) + 'a,
    ) -> Self {
        Self {
            daemon,
            authority,
            performer,
            pause: Box::new(pause),
            receipts: Vec::new(),
            refusals: Vec::new(),
        }
    }

    /// Swift `publishedReceipts`: every receipt the daemon published, in
    /// order.
    pub fn published_receipts(&self) -> &[ActionReceiptSummary] {
        &self.receipts
    }

    /// Swift `declinedAdmissions`: admissions this authority declined, and
    /// permits the daemon rejected, with their reasons.
    pub fn declined_admissions(&self) -> &[String] {
        &self.refusals
    }

    /// Swift `runExisting(jobID:)`: drives the daemon job that was started
    /// earlier and durably correlated before any permit was signed. It never
    /// starts one, so recovering the controller cannot create a replacement
    /// destructive attempt.
    ///
    /// Each poll's events after the cursor are read in order until a
    /// terminal classification; admissions are then answered, then control
    /// requests, each in event order. A quiet poll waits and polls again;
    /// past [`QUIET_POLL_LIMIT`] of them the outcome is unknown.
    pub fn run_existing(&mut self, daemon_job_id: &str) -> Result<SessionOutcome, SessionError> {
        self.authority.adopt_daemon_job(daemon_job_id);
        let mut terminal = None;
        // The last sequence answered; the daemon's cursor is exclusive.
        let mut cursor = 0u64;
        let mut quiet_polls = 0u64;
        // Steps whose permit was signed and whose receipt has not arrived.
        let mut awaiting_receipts = BTreeSet::new();
        while terminal.is_none() {
            let mut admissions = Vec::new();
            let mut controls = Vec::new();
            let mut saw_event = false;
            let events = self
                .daemon
                .job_events(daemon_job_id, cursor)
                .map_err(SessionError::Daemon)?;
            for event in events {
                if event.job_id != daemon_job_id || event.sequence <= cursor {
                    continue;
                }
                saw_event = true;
                cursor = event.sequence;
                match event.kind {
                    JobEventKind::StepAdmissionRequested => admissions.extend(event.admission),
                    JobEventKind::ManagedControlRequested => controls.extend(event.control_request),
                    JobEventKind::ActionReceipt => {
                        if let Some(receipt) = event.receipt {
                            awaiting_receipts.remove(&receipt.step_id);
                            self.receipts.push(receipt);
                        }
                    }
                    JobEventKind::OutcomeClassified => {
                        terminal = Some(terminal_outcome(&event, self.receipts.clone()));
                        break;
                    }
                    _ => {}
                }
            }
            for admission in &admissions {
                if self.answer_admission(admission, daemon_job_id)?
                    && !self
                        .receipts
                        .iter()
                        .any(|receipt| receipt.step_id == admission.step_id)
                {
                    awaiting_receipts.insert(admission.step_id.clone());
                }
            }
            for control in &controls {
                self.answer_control(control, daemon_job_id)?;
            }
            if terminal.is_some() {
                break;
            }
            if saw_event {
                quiet_polls = 0;
            } else {
                quiet_polls += 1;
                if quiet_polls > QUIET_POLL_LIMIT {
                    return Ok(SessionOutcome::OutcomeUnknown {
                        reason: format!(
                            "arkforged produced no explicit terminal outcome for {}s{}",
                            QUIET_POLL_LIMIT * POLL_INTERVAL.as_millis() as u64 / 1000,
                            if awaiting_receipts.is_empty() {
                                ""
                            } else {
                                " while a signed permit still owed evidence"
                            }
                        ),
                        receipts: self.receipts.clone(),
                    });
                }
                (self.pause)(POLL_INTERVAL);
            }
        }
        Ok(terminal.expect("the loop ends only at a terminal answer"))
    }

    /// Swift `answer(_ admission:)`: asks the authority and relays its
    /// decision. Returns whether a permit was signed and taken, which alone
    /// leaves a receipt owed.
    fn answer_admission(
        &mut self,
        admission: &StepAdmissionSnapshot,
        job_id: &str,
    ) -> Result<bool, SessionError> {
        match self.authority.admit(admission) {
            Decision::Sign(permit) => {
                let answer = self
                    .daemon
                    .submit_permit(&SubmitStepPermitRequest {
                        job_id: job_id.to_owned(),
                        request_id: admission.request_id.clone(),
                        permit_cbor: permit.signing_body,
                        integrity_tag: permit.integrity_tag,
                        pairing_epoch: permit.pairing_epoch,
                        refusal: String::new(),
                    })
                    .map_err(SessionError::Daemon)?;
                if answer.accepted {
                    return Ok(true);
                }
                self.refusals.push(format!(
                    "{}: permit rejected: {} {}",
                    admission.step_id, answer.rejection_code, answer.rejection_message
                ));
                // The one rejection that heals itself: the snapshot ages out
                // and the admission runs again with a fresher one.
                if answer.rejection_code == "SNAPSHOT_EXPIRED" {
                    return Ok(false);
                }
                Err(SessionError::PermitRejected {
                    step_id: admission.step_id.clone(),
                    code: answer.rejection_code,
                    message: answer.rejection_message,
                })
            }
            Decision::Refuse(why) => {
                // Reported, not withheld: silence would let the snapshot
                // expire and the admission run again.
                self.refusals.push(format!("{}: {why}", admission.step_id));
                self.daemon
                    .submit_permit(&SubmitStepPermitRequest {
                        job_id: job_id.to_owned(),
                        request_id: admission.request_id.clone(),
                        refusal: why.to_string(),
                        ..SubmitStepPermitRequest::default()
                    })
                    .map_err(SessionError::Daemon)?;
                Ok(false)
            }
        }
    }

    /// Swift `answer(_ request:)`: performs the control action and relays
    /// what was observed. A failure to perform is not "nothing happened" —
    /// the action may have taken effect — so it travels as an unaccepted
    /// observation with its reason. A rejected receipt is answered with
    /// Swift's cancel, and the drive stops.
    fn answer_control(
        &mut self,
        request: &ManagedControlRequest,
        job_id: &str,
    ) -> Result<(), SessionError> {
        let observation = self
            .performer
            .perform(request)
            .unwrap_or_else(|error| Observation {
                failure_reason: format!("control action did not complete: {error}"),
                ..Observation::default()
            });
        let receipt =
            managed_control::receipt(job_id, &request.request_id, request.action, &observation)
                .map_err(SessionError::Receipt)?;
        let answer = self
            .daemon
            .submit_control_receipt(&receipt)
            .map_err(SessionError::Daemon)?;
        if !answer.accepted {
            // Swift's `cancelJob(jobID:)`, which names no journal sequence.
            // ArkForge's cancel requires one, so the daemon refuses it
            // (`EXPECTED_SEQUENCE_REQUIRED`) and, as Swift's `try?` does, the
            // refusal is ignored: the job waits for its request's deadline, as
            // it did on the GJ-4 bench. Whether a cancel should take effect
            // here is the maintainer's to rule (F3, 2026-09-26).
            let _ = self.daemon.cancel(job_id, 0);
            return Err(SessionError::ControlReceiptRejected {
                request_id: request.request_id.clone(),
                code: answer.rejection_code,
                message: answer.rejection_message,
            });
        }
        if observation.accepted {
            self.authority
                .record_managed_control_facts(&observation.facts);
        }
        Ok(())
    }
}

/// Swift `observeTerminal(daemon:jobID:)`: the already-journaled terminal of
/// one exact job, read in one poll from the start. It never starts, admits,
/// performs or cancels anything. A later classification supersedes an
/// earlier `outcomeUnknown`; `None` means none exists.
pub fn observe_terminal(
    daemon: &mut dyn SessionDaemon,
    job_id: &str,
) -> Result<Option<SessionOutcome>, String> {
    let mut receipts = Vec::new();
    let mut terminal = None;
    for event in daemon.job_events(job_id, 0)? {
        if event.job_id != job_id {
            continue;
        }
        match event.kind {
            JobEventKind::ActionReceipt => receipts.extend(event.receipt.clone()),
            JobEventKind::OutcomeClassified => {
                terminal = Some(terminal_outcome(&event, receipts.clone()))
            }
            _ => {}
        }
    }
    Ok(terminal)
}

/// Swift `terminalOutcome(from:receipts:)`: only the exact `succeeded`
/// completes. The detail is the first `reason` fact, else every other fact
/// as `key=value`, space-separated.
fn terminal_outcome(event: &JobEvent, receipts: Vec<ActionReceiptSummary>) -> SessionOutcome {
    let fact = |key: &str| {
        event
            .facts
            .iter()
            .find(|fact| fact.key == key)
            .map(|fact| fact.value.clone())
    };
    let outcome = fact("outcome").unwrap_or_default();
    let detail = fact("reason").unwrap_or_else(|| {
        event
            .facts
            .iter()
            .filter(|fact| fact.key != "outcome")
            .map(|fact| format!("{}={}", fact.key, fact.value))
            .collect::<Vec<_>>()
            .join(" ")
    });
    match outcome.as_str() {
        "succeeded" => SessionOutcome::Completed(receipts),
        "confirmedFailed" => SessionOutcome::ConfirmedFailed {
            reason: if detail.is_empty() {
                "the daemon classified this job as confirmedFailed".to_owned()
            } else {
                format!("the daemon classified this job as confirmedFailed: {detail}")
            },
            receipts,
        },
        "outcomeUnknown" | "recoveryAssessable" => SessionOutcome::OutcomeUnknown {
            reason: if detail.is_empty() {
                format!("the daemon classified this job's outcome as {outcome}")
            } else {
                format!("the daemon classified this job's outcome as {outcome}: {detail}")
            },
            receipts,
        },
        "cancelledSafe" => SessionOutcome::CancelledSafe(receipts),
        "" => SessionOutcome::OutcomeUnknown {
            reason: "arkforged emitted outcomeClassified without an outcome fact".to_owned(),
            receipts,
        },
        _ => SessionOutcome::OutcomeUnknown {
            reason: format!("arkforged emitted unsupported terminal outcome {outcome}"),
            receipts,
        },
    }
}

#[cfg(test)]
mod tests;
