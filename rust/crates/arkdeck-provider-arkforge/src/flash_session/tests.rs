//! Swift `ArkForgeFlashSessionContractTests`' loop cases, over a scripted
//! daemon that polls as Swift's does: every poll returns the whole script,
//! and a script without a terminal answer ends in `succeeded` once the
//! session has read all of it. Swift's test-only `run` and `cancel` have no
//! Rust counterpart; the drive starts from a correlated job, as production
//! does.
use super::*;
use crate::authority::{ApprovedPlan, AuthorityBinding, PERMIT_LIFETIME_MS};
use arkforge_authority_api::{ControllerPairingSecret, PairingEpoch};
use arkforge_ipc::messages::{KeyValue, ManagedControlAction};
use std::collections::{BTreeMap, HashMap};

const PLAN_DIGEST: [u8; 32] = [0x11; 32];
const DEVICE_FACTS: [u8; 32] = [0x22; 32];

/// Swift's `ScriptedDaemon`.
#[derive(Default)]
struct ScriptedDaemon {
    events: Vec<JobEvent>,
    permits: Vec<SubmitStepPermitRequest>,
    controls: Vec<SubmitManagedControlReceiptRequest>,
    /// Admission request ids whose permit this daemon rejects, inside an OK
    /// answer as the real one does.
    permit_rejections: HashMap<String, (String, String)>,
    /// Every control receipt rejected with this code and message.
    control_rejection: Option<(String, String)>,
    cancels: Vec<(String, u64)>,
    polls: Vec<u64>,
    /// Events the daemon publishes only once it has taken a control
    /// receipt, as it asks for the next step only after its control request
    /// was answered.
    after_control: Vec<JobEvent>,
    /// Every submission, in the order the daemon received them.
    answers: Vec<String>,
}

impl ScriptedDaemon {
    fn with(events: Vec<JobEvent>) -> Self {
        Self {
            events,
            ..Self::default()
        }
    }
}

impl SessionDaemon for ScriptedDaemon {
    fn job_events(&mut self, _job_id: &str, after_sequence: u64) -> Result<Vec<JobEvent>, String> {
        self.polls.push(after_sequence);
        let mut events = self.events.clone();
        if !self.controls.is_empty() {
            events.extend(self.after_control.iter().cloned());
        }
        let terminal = events
            .iter()
            .any(|event| event.kind == JobEventKind::OutcomeClassified);
        let last = events.iter().map(|event| event.sequence).max().unwrap_or(0);
        if !terminal && (events.is_empty() || (last > 0 && after_sequence >= last)) {
            events.push(classified(last + 1, &[("outcome", "succeeded")]));
        }
        Ok(events)
    }

    fn submit_permit(
        &mut self,
        submission: &SubmitStepPermitRequest,
    ) -> Result<SubmissionOutcome, String> {
        self.permits.push(submission.clone());
        self.answers
            .push(format!("permit {}", submission.request_id));
        if let Some((code, message)) = self.permit_rejections.get(&submission.request_id) {
            return Ok(SubmissionOutcome {
                accepted: false,
                rejection_code: code.clone(),
                rejection_message: message.clone(),
            });
        }
        Ok(SubmissionOutcome {
            accepted: submission.refusal.is_empty(),
            ..SubmissionOutcome::default()
        })
    }

    fn submit_control_receipt(
        &mut self,
        receipt: &SubmitManagedControlReceiptRequest,
    ) -> Result<SubmissionOutcome, String> {
        self.controls.push(receipt.clone());
        self.answers.push(format!("control {}", receipt.request_id));
        Ok(match &self.control_rejection {
            Some((code, message)) => SubmissionOutcome {
                accepted: false,
                rejection_code: code.clone(),
                rejection_message: message.clone(),
            },
            None => SubmissionOutcome {
                accepted: true,
                ..SubmissionOutcome::default()
            },
        })
    }

    fn cancel(&mut self, job_id: &str, expected_sequence: u64) -> Result<(), String> {
        self.cancels.push((job_id.to_owned(), expected_sequence));
        Ok(())
    }
}

/// Swift's `StubPerformer` and `FailingPerformer`.
struct Performer(Result<Observation, String>);

impl ControlPerformer for Performer {
    fn perform(&mut self, _request: &ManagedControlRequest) -> Result<Observation, String> {
        self.0.clone()
    }
}

fn accepting() -> Performer {
    Performer(Ok(Observation {
        accepted: true,
        ..Observation::default()
    }))
}

fn authority() -> ExecutionAuthority {
    ExecutionAuthority::new(
        ApprovedPlan {
            job_id: "JOB-1".into(),
            plan_id: "PLAN-1".into(),
            plan_sha256: PLAN_DIGEST.to_vec(),
            admitted_device_facts_sha256: DEVICE_FACTS.to_vec(),
            usb_topology: None,
            binding: AuthorityBinding {
                authority_namespace: "arkdeck".into(),
                binding_id: "TGT-1".into(),
                binding_revision: 2,
                stable_identity_digest: vec![0x33; 32],
            },
            controller_session_id: "SESSION-1".into(),
            permit_lifetime_ms: PERMIT_LIFETIME_MS,
        },
        ControllerPairingSecret::new(PairingEpoch(1), b"session-secret".to_vec()),
        || 1_000_100,
    )
}

fn admission_event(step_id: &str, sequence: u64) -> JobEvent {
    JobEvent {
        job_id: "JOB-1".into(),
        sequence,
        kind: JobEventKind::StepAdmissionRequested,
        at_epoch_ms: 1_000_050,
        job_state: "running".into(),
        admission: Some(StepAdmissionSnapshot {
            job_id: "JOB-1".into(),
            plan_id: "PLAN-1".into(),
            plan_sha256: PLAN_DIGEST.to_vec(),
            step_id: step_id.into(),
            attempt_id: "ATTEMPT-1".into(),
            public_step_sha256: vec![0x44; 32],
            private_action_sha256: vec![0x55; 32],
            effect_set_sha256: vec![0x66; 32],
            admitted_device_facts_sha256: DEVICE_FACTS.to_vec(),
            observed_mode: "loader".into(),
            observed_at_epoch_ms: 1_000_000,
            snapshot_lifetime_ms: 60_000,
            request_id: format!("ADM-{step_id}"),
            ..StepAdmissionSnapshot::default()
        }),
        ..JobEvent::default()
    }
}

fn receipt_event(step_id: &str, sequence: u64) -> JobEvent {
    JobEvent {
        job_id: "JOB-1".into(),
        sequence,
        kind: JobEventKind::ActionReceipt,
        at_epoch_ms: 1_000_060,
        job_state: "running".into(),
        receipt: Some(ActionReceiptSummary {
            job_id: "JOB-1".into(),
            plan_id: "PLAN-1".into(),
            step_id: step_id.into(),
            action_id: "A-1".into(),
            attempt_id: "ATTEMPT-1".into(),
            permit_id: format!("PERMIT-JOB-1-{step_id}-ATTEMPT-1"),
            disposition: "semanticSuccess".into(),
            verification_outcome: "verified".into(),
            verification_strength: "fullHash".into(),
            verified_range_length: 4096,
            ..ActionReceiptSummary::default()
        }),
        ..JobEvent::default()
    }
}

fn classified(sequence: u64, facts: &[(&str, &str)]) -> JobEvent {
    JobEvent {
        job_id: "JOB-1".into(),
        sequence,
        kind: JobEventKind::OutcomeClassified,
        at_epoch_ms: 1_000_070,
        facts: facts
            .iter()
            .map(|(key, value)| KeyValue {
                key: (*key).into(),
                value: (*value).into(),
            })
            .collect(),
        ..JobEvent::default()
    }
}

fn control_event(sequence: u64) -> JobEvent {
    JobEvent {
        job_id: "JOB-1".into(),
        sequence,
        kind: JobEventKind::ManagedControlRequested,
        at_epoch_ms: 1_000_050,
        job_state: "running".into(),
        control_request: Some(ManagedControlRequest {
            job_id: "JOB-1".into(),
            step_id: "enter-loader-mode".into(),
            request_id: "CTL-1".into(),
            action: ManagedControlAction::EnterUpdater,
            permit_id: "PERMIT-1".into(),
            deadline_epoch_ms: 1_100_000,
            ..ManagedControlRequest::default()
        }),
        ..JobEvent::default()
    }
}

fn loader_observation() -> Observation {
    Observation {
        accepted: true,
        facts: BTreeMap::from([
            ("mode".to_owned(), "Loader".to_owned()),
            ("stableIdentitySHA256".to_owned(), "a".repeat(64)),
            ("usbTopology".to_owned(), "17956864".to_owned()),
        ]),
        evidence_sha256: vec![0x07; 32],
        observed_disconnect: true,
        observed_unique_loader_rebind: true,
        ..Observation::default()
    }
}

/// Drives `daemon` with `performer`, without waiting between quiet polls.
fn drive(
    daemon: &mut dyn SessionDaemon,
    performer: &mut dyn ControlPerformer,
) -> (Result<SessionOutcome, SessionError>, Vec<String>) {
    let mut authority = authority();
    let mut session = FlashSession::paced(daemon, &mut authority, performer, |_| {});
    let outcome = session.run_existing("JOB-1");
    (outcome, session.declined_admissions().to_vec())
}

fn step_ids(receipts: &[ActionReceiptSummary]) -> Vec<&str> {
    receipts
        .iter()
        .map(|receipt| receipt.step_id.as_str())
        .collect()
}

// MARK: the loop

#[test]
fn a_matching_admission_is_answered_with_a_signed_permit() {
    let mut daemon = ScriptedDaemon::with(vec![
        admission_event("flash-partitions", 1),
        receipt_event("flash-partitions", 2),
        classified(3, &[("outcome", "succeeded")]),
    ]);
    let (outcome, _) = drive(&mut daemon, &mut accepting());
    assert_eq!(daemon.permits.len(), 1);
    let submitted = &daemon.permits[0];
    assert!(
        submitted.refusal.is_empty(),
        "a matching admission is signed"
    );
    assert!(!submitted.permit_cbor.is_empty());
    assert_eq!(submitted.pairing_epoch, 1);
    assert_eq!(submitted.request_id, "ADM-flash-partitions");
    assert_eq!(submitted.job_id, "JOB-1");
    let SessionOutcome::Completed(receipts) = outcome.unwrap() else {
        panic!("expected completion");
    };
    assert_eq!(receipts.len(), 1);
    assert_eq!(receipts[0].disposition, "semanticSuccess");
}

#[test]
fn the_correlated_job_is_driven_to_its_own_completion() {
    let mut daemon = ScriptedDaemon::with(vec![receipt_event("flash-partitions", 1)]);
    let (outcome, _) = drive(&mut daemon, &mut accepting());
    let SessionOutcome::Completed(receipts) = outcome.unwrap() else {
        panic!("expected the correlated job's completion");
    };
    assert_eq!(step_ids(&receipts), ["flash-partitions"]);
    // Every poll names the job and reads after the last sequence seen.
    assert_eq!(daemon.polls, [0, 1]);
}

#[test]
fn passive_terminal_observation_cannot_answer_or_mutate_the_job() {
    let mut daemon = ScriptedDaemon::with(vec![
        admission_event("flash-partitions", 1),
        receipt_event("flash-partitions", 2),
        classified(3, &[("outcome", "succeeded")]),
    ]);
    let Some(SessionOutcome::Completed(receipts)) = observe_terminal(&mut daemon, "JOB-1").unwrap()
    else {
        panic!("expected passive completion");
    };
    assert_eq!(step_ids(&receipts), ["flash-partitions"]);
    assert!(daemon.permits.is_empty());
    assert!(daemon.controls.is_empty());
    assert!(daemon.cancels.is_empty());
    assert_eq!(daemon.polls, [0]);
}

#[test]
fn passive_observation_consumes_a_reconciled_terminal_and_a_restarted_receipt() {
    let mut daemon = ScriptedDaemon::with(vec![
        classified(
            1,
            &[
                ("outcome", "outcomeUnknown"),
                ("reason", "daemon restarted after dispatch"),
            ],
        ),
        receipt_event("postflight-readback", 2),
        classified(3, &[("outcome", "succeeded")]),
    ]);
    let Some(SessionOutcome::Completed(receipts)) = observe_terminal(&mut daemon, "JOB-1").unwrap()
    else {
        panic!("the later durable classification must supersede outcomeUnknown");
    };
    assert_eq!(step_ids(&receipts), ["postflight-readback"]);
    assert!(daemon.permits.is_empty() && daemon.controls.is_empty() && daemon.cancels.is_empty());
    // Another job's classification is not this one's, and no classification
    // at all is `None`.
    let mut foreign = ScriptedDaemon::with(vec![JobEvent {
        job_id: "JOB-2".into(),
        ..classified(1, &[("outcome", "succeeded")])
    }]);
    assert_eq!(observe_terminal(&mut foreign, "JOB-1").unwrap(), None);
    let mut unclassified = ScriptedDaemon::with(vec![receipt_event("x", 1)]);
    assert_eq!(observe_terminal(&mut unclassified, "JOB-1").unwrap(), None);
}

/// The real daemon exposed exactly this gap after DEVICE_RESET: a receipt,
/// one empty poll, then the postflight admission. The empty poll is not
/// completion.
#[test]
fn an_empty_poll_between_a_receipt_and_the_next_admission_is_not_completion() {
    struct Gapped {
        poll: usize,
        permits: Vec<String>,
    }
    impl SessionDaemon for Gapped {
        fn job_events(&mut self, _job: &str, _after: u64) -> Result<Vec<JobEvent>, String> {
            self.poll += 1;
            Ok(match self.poll {
                1 => vec![receipt_event("reboot", 1)],
                2 => Vec::new(),
                3 => {
                    let mut admission = admission_event("postflight", 2);
                    let snapshot = admission.admission.as_mut().unwrap();
                    snapshot.attempt_id = "ATTEMPT-2".into();
                    snapshot.observed_mode = "hdc-normal".into();
                    snapshot.request_id = "ADM-postflight".into();
                    vec![admission]
                }
                4 => vec![receipt_event("postflight", 3)],
                _ => vec![classified(4, &[("outcome", "succeeded")])],
            })
        }
        fn submit_permit(
            &mut self,
            submission: &SubmitStepPermitRequest,
        ) -> Result<SubmissionOutcome, String> {
            self.permits.push(submission.request_id.clone());
            Ok(SubmissionOutcome {
                accepted: true,
                ..SubmissionOutcome::default()
            })
        }
        fn submit_control_receipt(
            &mut self,
            _receipt: &SubmitManagedControlReceiptRequest,
        ) -> Result<SubmissionOutcome, String> {
            unreachable!("no control request is scripted")
        }
        fn cancel(&mut self, _job: &str, _sequence: u64) -> Result<(), String> {
            unreachable!("nothing is cancelled")
        }
    }
    let mut daemon = Gapped {
        poll: 0,
        permits: Vec::new(),
    };
    let mut pauses = 0;
    let mut authority = authority();
    let mut performer = accepting();
    let mut session = FlashSession::paced(&mut daemon, &mut authority, &mut performer, |pause| {
        assert_eq!(pause, POLL_INTERVAL);
        pauses += 1;
    });
    let SessionOutcome::Completed(receipts) = session.run_existing("JOB-1").unwrap() else {
        panic!("expected completion after the explicit terminal event");
    };
    assert_eq!(step_ids(&receipts), ["reboot", "postflight"]);
    drop(session);
    assert_eq!(daemon.permits, ["ADM-postflight"]);
    assert_eq!(pauses, 1, "only the quiet poll waited");
}

#[test]
fn a_refused_admission_is_reported_rather_than_withheld() {
    let mut refused = admission_event("flash-partitions", 1);
    refused.admission.as_mut().unwrap().plan_sha256 = vec![0xee; 32];
    let mut daemon = ScriptedDaemon::with(vec![refused]);
    let (outcome, declined) = drive(&mut daemon, &mut accepting());
    assert!(matches!(outcome, Ok(SessionOutcome::Completed(_))));
    let submitted = &daemon.permits[0];
    assert_eq!(
        submitted.refusal,
        "the admission's plan digest is not the plan this authority approved"
    );
    assert!(
        submitted.permit_cbor.is_empty(),
        "a refusal carries no permit"
    );
    assert_eq!(
        declined,
        ["flash-partitions: the admission's plan digest is not the plan this authority approved"]
    );
}

#[test]
fn a_control_request_is_performed_and_its_observation_relayed() {
    let mut daemon = ScriptedDaemon::with(vec![control_event(1)]);
    let (outcome, _) = drive(&mut daemon, &mut Performer(Ok(loader_observation())));
    assert!(matches!(outcome, Ok(SessionOutcome::Completed(_))));
    let receipt = &daemon.controls[0];
    assert!(receipt.accepted);
    assert_eq!(receipt.job_id, "JOB-1");
    assert_eq!(receipt.request_id, "CTL-1");
    assert_eq!(receipt.action, ManagedControlAction::EnterUpdater);
    assert_eq!(
        receipt
            .facts
            .iter()
            .map(|fact| fact.key.as_str())
            .collect::<Vec<_>>(),
        ["mode", "stableIdentitySHA256", "usbTopology"]
    );
}

/// An accepted observation the daemon took extends the authority's Loader
/// lineage, so the Loader admission that follows is signed.
#[test]
fn an_accepted_control_observation_admits_the_loader_that_follows() {
    let mut loader = admission_event("flash-partitions", 2);
    {
        let snapshot = loader.admission.as_mut().unwrap();
        snapshot.observed_mode = "rockusb-loader".into();
        snapshot.topology_sha256 =
            hex_to_bytes(&crate::loader::topology_digest("17956864").unwrap());
        snapshot.descriptor_sha256 = vec![0x77; 32];
        snapshot.serial_sha256 = vec![0x88; 32];
        snapshot.serial_evidence_kind = "descriptor".into();
        snapshot.identity_strength = "serialAndTopology".into();
        snapshot.transport_session_sha256 = vec![0x99; 32];
        snapshot.admitted_device_facts_sha256 = crate::authority::device_facts_digest(snapshot);
    }
    let mut daemon = ScriptedDaemon {
        after_control: vec![loader.clone()],
        ..ScriptedDaemon::with(vec![control_event(1)])
    };
    let (outcome, declined) = drive(&mut daemon, &mut Performer(Ok(loader_observation())));
    assert!(matches!(outcome, Ok(SessionOutcome::Completed(_))));
    assert!(declined.is_empty(), "{declined:?}");
    assert!(daemon.permits[0].refusal.is_empty());
    // Without the observation the same admission is not the confirmed device.
    let mut unobserved = ScriptedDaemon::with(vec![loader]);
    let (_, declined) = drive(&mut unobserved, &mut accepting());
    assert_eq!(
        declined,
        [
            "flash-partitions: the admission's device facts are not the binding this authority \
          confirmed; the device under the daemon is not the device that was authorized"
        ]
    );
}

#[test]
fn a_control_action_that_failed_is_not_reported_as_nothing_having_happened() {
    let mut daemon = ScriptedDaemon::with(vec![control_event(1)]);
    let (outcome, _) = drive(&mut daemon, &mut Performer(Err("Boom()".into())));
    assert!(matches!(outcome, Ok(SessionOutcome::Completed(_))));
    let receipt = &daemon.controls[0];
    assert!(!receipt.accepted);
    assert_eq!(
        receipt.failure_reason,
        "control action did not complete: Boom()"
    );
    assert!(receipt.facts.is_empty());
    assert!(receipt.evidence_sha256.is_empty());
}

// MARK: rejections are answers, not noise

#[test]
fn a_rejected_permit_submission_is_a_named_stop() {
    let mut daemon = ScriptedDaemon::with(vec![admission_event("flash-partitions", 1)]);
    daemon.permit_rejections.insert(
        "ADM-flash-partitions".into(),
        (
            "PERMIT_REJECTED".into(),
            "integrity tag does not verify".into(),
        ),
    );
    let (outcome, declined) = drive(&mut daemon, &mut accepting());
    let error = outcome.unwrap_err();
    assert_eq!(
        error,
        SessionError::PermitRejected {
            step_id: "flash-partitions".into(),
            code: "PERMIT_REJECTED".into(),
            message: "integrity tag does not verify".into(),
        }
    );
    assert_eq!(
        error.to_string(),
        "arkforged rejected the permit for flash-partitions: PERMIT_REJECTED integrity tag does \
         not verify"
    );
    assert_eq!(
        declined,
        ["flash-partitions: permit rejected: PERMIT_REJECTED integrity tag does not verify"]
    );
}

#[test]
fn a_snapshot_expired_rejection_is_recorded_but_not_fatal() {
    let mut daemon = ScriptedDaemon::with(vec![admission_event("flash-partitions", 1)]);
    daemon.permit_rejections.insert(
        "ADM-flash-partitions".into(),
        (
            "SNAPSHOT_EXPIRED".into(),
            "the admission snapshot aged out".into(),
        ),
    );
    let (outcome, declined) = drive(&mut daemon, &mut accepting());
    assert!(matches!(outcome, Ok(SessionOutcome::Completed(_))));
    assert_eq!(declined.len(), 1);
    assert!(declined[0].contains("SNAPSHOT_EXPIRED"), "{}", declined[0]);
}

/// A rejected receipt stops the drive, after Swift's cancel: one that names
/// no journal sequence, which the daemon refuses, so the job waits for its
/// request's deadline as it did under Swift.
#[test]
fn a_rejected_control_receipt_cancels_the_job_and_stops() {
    let mut daemon = ScriptedDaemon::with(vec![control_event(1)]);
    daemon.control_rejection = Some((
        "CONTROL_EVIDENCE_MISMATCH".into(),
        "evidence is not the facts digest".into(),
    ));
    let (outcome, _) = drive(&mut daemon, &mut Performer(Ok(loader_observation())));
    let error = outcome.unwrap_err();
    assert_eq!(
        error,
        SessionError::ControlReceiptRejected {
            request_id: "CTL-1".into(),
            code: "CONTROL_EVIDENCE_MISMATCH".into(),
            message: "evidence is not the facts digest".into(),
        }
    );
    assert_eq!(
        error.to_string(),
        "arkforged rejected the control receipt for CTL-1: CONTROL_EVIDENCE_MISMATCH evidence \
         is not the facts digest. The job was cancelled rather than left waiting for a receipt \
         it refuses"
    );
    assert_eq!(daemon.cancels, [("JOB-1".to_owned(), 0)]);
}

/// A receipt the port refuses to build is never sent: the drive stops with
/// the port's words.
#[test]
fn a_receipt_the_port_refuses_is_not_sent() {
    let mut daemon = ScriptedDaemon::with(vec![control_event(1)]);
    let mut leaking = loader_observation();
    leaking
        .facts
        .insert("connectKey".into(), "127.0.0.1:5555".into());
    let (outcome, _) = drive(&mut daemon, &mut Performer(Ok(leaking)));
    assert_eq!(
        outcome.unwrap_err(),
        SessionError::Receipt(ReceiptRefusal::ForbiddenFact("connectKey".into()))
    );
    assert!(daemon.controls.is_empty());
}

#[test]
fn a_terminal_unknown_carries_the_daemons_reason() {
    let mut daemon = ScriptedDaemon::with(vec![classified(
        1,
        &[
            ("outcome", "outcomeUnknown"),
            (
                "reason",
                "managed control enter-updater request CTL-1 expired unanswered",
            ),
        ],
    )]);
    let (outcome, _) = drive(&mut daemon, &mut accepting());
    assert_eq!(
        outcome.unwrap(),
        SessionOutcome::OutcomeUnknown {
            reason: "the daemon classified this job's outcome as outcomeUnknown: managed \
                     control enter-updater request CTL-1 expired unanswered"
                .into(),
            receipts: Vec::new(),
        }
    );
}

#[test]
fn a_confirmed_failure_cannot_fall_through_to_completion() {
    let mut daemon = ScriptedDaemon::with(vec![classified(
        1,
        &[
            ("outcome", "confirmedFailed"),
            ("reason", "postflight readback disproved the target image"),
        ],
    )]);
    let (outcome, _) = drive(&mut daemon, &mut accepting());
    assert_eq!(
        outcome.unwrap(),
        SessionOutcome::ConfirmedFailed {
            reason: "the daemon classified this job as confirmedFailed: postflight readback \
                     disproved the target image"
                .into(),
            receipts: Vec::new(),
        }
    );
}

#[test]
fn an_unknown_terminal_wire_value_fails_closed() {
    let mut daemon =
        ScriptedDaemon::with(vec![classified(1, &[("outcome", "futureDaemonTerminal")])]);
    let (outcome, _) = drive(&mut daemon, &mut accepting());
    assert_eq!(
        outcome.unwrap(),
        SessionOutcome::OutcomeUnknown {
            reason: "arkforged emitted unsupported terminal outcome futureDaemonTerminal".into(),
            receipts: Vec::new(),
        }
    );
}

/// Swift's whole terminal table, each wire value as it maps.
#[test]
fn the_terminal_table_is_swifts() {
    let cases: [(&[(&str, &str)], SessionOutcome); 6] = [
        (
            &[
                ("outcome", "recoveryAssessable"),
                ("step", "STEP-4"),
                ("why", "reset"),
            ],
            SessionOutcome::OutcomeUnknown {
                reason: "the daemon classified this job's outcome as recoveryAssessable: \
                         step=STEP-4 why=reset"
                    .into(),
                receipts: Vec::new(),
            },
        ),
        (
            &[("outcome", "confirmedFailed")],
            SessionOutcome::ConfirmedFailed {
                reason: "the daemon classified this job as confirmedFailed".into(),
                receipts: Vec::new(),
            },
        ),
        (
            &[("outcome", "outcomeUnknown")],
            SessionOutcome::OutcomeUnknown {
                reason: "the daemon classified this job's outcome as outcomeUnknown".into(),
                receipts: Vec::new(),
            },
        ),
        (
            &[("outcome", "cancelledSafe")],
            SessionOutcome::CancelledSafe(Vec::new()),
        ),
        (
            &[("reason", "no outcome here")],
            SessionOutcome::OutcomeUnknown {
                reason: "arkforged emitted outcomeClassified without an outcome fact".into(),
                receipts: Vec::new(),
            },
        ),
        (
            &[("outcome", "succeeded"), ("outcome", "confirmedFailed")],
            SessionOutcome::Completed(Vec::new()),
        ),
    ];
    for (facts, expected) in cases {
        assert_eq!(
            terminal_outcome(&classified(1, facts), Vec::new()),
            expected
        );
    }
}

/// Silence is never completion: past the quiet bound the outcome is unknown,
/// naming the permit still owed evidence when one is.
#[test]
fn a_silent_daemon_leaves_the_outcome_unknown_past_the_quiet_bound() {
    struct Silent(Vec<JobEvent>);
    impl SessionDaemon for Silent {
        fn job_events(&mut self, _job: &str, _after: u64) -> Result<Vec<JobEvent>, String> {
            Ok(std::mem::take(&mut self.0))
        }
        fn submit_permit(
            &mut self,
            _submission: &SubmitStepPermitRequest,
        ) -> Result<SubmissionOutcome, String> {
            Ok(SubmissionOutcome {
                accepted: true,
                ..SubmissionOutcome::default()
            })
        }
        fn submit_control_receipt(
            &mut self,
            _receipt: &SubmitManagedControlReceiptRequest,
        ) -> Result<SubmissionOutcome, String> {
            unreachable!()
        }
        fn cancel(&mut self, _job: &str, _sequence: u64) -> Result<(), String> {
            unreachable!()
        }
    }
    for (events, owed) in [
        (Vec::new(), ""),
        (
            vec![admission_event("flash-partitions", 1)],
            " while a signed permit still owed evidence",
        ),
    ] {
        let mut daemon = Silent(events);
        let mut authority = authority();
        let mut performer = accepting();
        let mut pauses = 0u64;
        let outcome =
            FlashSession::paced(&mut daemon, &mut authority, &mut performer, |_| pauses += 1)
                .run_existing("JOB-1")
                .unwrap();
        assert_eq!(
            outcome,
            SessionOutcome::OutcomeUnknown {
                reason: format!("arkforged produced no explicit terminal outcome for 2100s{owed}"),
                receipts: Vec::new(),
            }
        );
        assert_eq!(pauses, QUIET_POLL_LIMIT);
    }
}

/// A daemon that cannot answer ends the drive with its own error.
#[test]
fn a_daemon_error_stops_the_drive_with_its_words() {
    struct Broken;
    impl SessionDaemon for Broken {
        fn job_events(&mut self, _job: &str, _after: u64) -> Result<Vec<JobEvent>, String> {
            Err("IPC_IO_FAILED: connection reset".into())
        }
        fn submit_permit(
            &mut self,
            _submission: &SubmitStepPermitRequest,
        ) -> Result<SubmissionOutcome, String> {
            unreachable!()
        }
        fn submit_control_receipt(
            &mut self,
            _receipt: &SubmitManagedControlReceiptRequest,
        ) -> Result<SubmissionOutcome, String> {
            unreachable!()
        }
        fn cancel(&mut self, _job: &str, _sequence: u64) -> Result<(), String> {
            unreachable!()
        }
    }
    let (outcome, _) = drive(&mut Broken, &mut accepting());
    let error = outcome.unwrap_err();
    assert_eq!(error.to_string(), "IPC_IO_FAILED: connection reset");
    assert_eq!(
        observe_terminal(&mut Broken, "JOB-1"),
        Err("IPC_IO_FAILED: connection reset".into())
    );
}

// MARK: receipts

#[test]
fn the_receipt_shape_is_carried_through_unchanged() {
    let mut daemon = ScriptedDaemon::with(vec![receipt_event("verify-flash-readback", 1)]);
    let mut authority = authority();
    let mut performer = accepting();
    let mut session = FlashSession::paced(&mut daemon, &mut authority, &mut performer, |_| {});
    session.run_existing("JOB-1").unwrap();
    let receipt = &session.published_receipts()[0];
    assert_eq!(receipt.verification_outcome, "verified");
    assert_eq!(receipt.verification_strength, "fullHash");
    assert_eq!(receipt.verified_range_length, 4096);
    assert!(receipt.typed_skip_reason.is_empty());
}

/// Events of another job, and any at or below the cursor, are not this
/// session's to answer: a re-poll never counts a receipt twice.
#[test]
fn another_jobs_events_and_answered_ones_are_skipped() {
    let mut foreign = admission_event("flash-partitions", 2);
    foreign.job_id = "JOB-2".into();
    let mut daemon = ScriptedDaemon::with(vec![
        receipt_event("flash-partitions", 1),
        foreign,
        receipt_event("verify-flash-readback", 3),
    ]);
    let (outcome, _) = drive(&mut daemon, &mut accepting());
    let SessionOutcome::Completed(receipts) = outcome.unwrap() else {
        panic!("expected completion");
    };
    assert_eq!(
        step_ids(&receipts),
        ["flash-partitions", "verify-flash-readback"]
    );
    assert!(daemon.permits.is_empty());
}

fn hex_to_bytes(hex: &str) -> Vec<u8> {
    (0..hex.len() / 2)
        .map(|index| u8::from_str_radix(&hex[index * 2..index * 2 + 2], 16).unwrap())
        .collect()
}

/// Within one poll every admission is answered before any control request,
/// each in event order, as Swift answers them.
#[test]
fn admissions_are_answered_before_controls_within_a_poll() {
    let mut daemon = ScriptedDaemon::with(vec![
        control_event(1),
        admission_event("flash-partitions", 2),
        admission_event("verify-flash-readback", 3),
    ]);
    let (outcome, _) = drive(&mut daemon, &mut Performer(Ok(loader_observation())));
    assert!(matches!(outcome, Ok(SessionOutcome::Completed(_))));
    assert_eq!(
        daemon.answers,
        [
            "permit ADM-flash-partitions",
            "permit ADM-verify-flash-readback",
            "control CTL-1"
        ]
    );
}

/// Only consecutive silence counts toward the bound: a daemon that speaks
/// between quiet polls, however many there are in all, is still running.
#[test]
fn quiet_polls_count_only_while_consecutive() {
    struct Intermittent {
        poll: u64,
    }
    impl SessionDaemon for Intermittent {
        fn job_events(&mut self, _job: &str, _after: u64) -> Result<Vec<JobEvent>, String> {
            self.poll += 1;
            let sequence = self.poll / 2;
            Ok(if self.poll > 2 * (QUIET_POLL_LIMIT + 50) {
                vec![classified(sequence, &[("outcome", "succeeded")])]
            } else if self.poll.is_multiple_of(2) {
                vec![receipt_event("progress", sequence)]
            } else {
                Vec::new()
            })
        }
        fn submit_permit(
            &mut self,
            _submission: &SubmitStepPermitRequest,
        ) -> Result<SubmissionOutcome, String> {
            unreachable!()
        }
        fn submit_control_receipt(
            &mut self,
            _receipt: &SubmitManagedControlReceiptRequest,
        ) -> Result<SubmissionOutcome, String> {
            unreachable!()
        }
        fn cancel(&mut self, _job: &str, _sequence: u64) -> Result<(), String> {
            unreachable!()
        }
    }
    let (outcome, _) = drive(&mut Intermittent { poll: 0 }, &mut accepting());
    let SessionOutcome::Completed(receipts) = outcome.unwrap() else {
        panic!("a daemon that keeps speaking is not silent");
    };
    assert_eq!(receipts.len() as u64, QUIET_POLL_LIMIT + 50);
}
