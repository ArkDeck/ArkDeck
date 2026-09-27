//! Fake external ports exercise the real materialization, cache, correlation
//! and session policy. These receipts are fixtures, never hardware evidence.
use super::*;
use crate::managed_control::{ManagedControlRequest, Observation};
use arkforge_authority_api::PairingEpoch;
use arkforge_client::{DeviceObservationView, MaterializeInput};
use arkforge_ipc::messages::{
    Assessment, ExecutablePlan, JobEvent, JobEventKind, KeyValue, MaterializePlanResponse,
    SubmissionOutcome, SubmitManagedControlReceiptRequest, SubmitStepPermitRequest,
};

#[derive(Default)]
struct Script {
    calls: Vec<String>,
    fault: String,
    imported: bool,
    preview: bool,
    start_failure: bool,
    poll_failure: bool,
    outcome: String,
}

struct Port {
    script: Arc<Mutex<Script>>,
    public: bool,
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

impl PlanSource for Port {
    fn inspect(&mut self, _: &str) -> Result<(), String> {
        let mut script = self.script.lock().unwrap();
        script.calls.push(format!("inspect:{}", self.public));
        if script.imported {
            Ok(())
        } else {
            Err("not imported".into())
        }
    }
    fn import(&mut self, _: &LaneArtifact) -> Result<(), String> {
        assert!(!self.public);
        let mut script = self.script.lock().unwrap();
        script.calls.push("import".into());
        script.imported = true;
        Ok(())
    }
    fn discover(&mut self) -> Result<Vec<DeviceObservationView>, String> {
        let mut script = self.script.lock().unwrap();
        script.calls.push(format!("discover:{}", self.public));
        let mut observation = DeviceObservationView {
            observation_id: "OBS-1".into(),
            mode: "rockusb-loader".into(),
            topology_sha256: crate::topology_digest("17956864").unwrap(),
            descriptor_sha256: "dd".repeat(32),
            identity_strength: "serialAndTopology".into(),
            ..DeviceObservationView::default()
        };
        if !self.public && script.fault == "observation" {
            observation.descriptor_sha256 = "ee".repeat(32);
        }
        Ok(vec![observation])
    }
    fn materialize(
        &mut self,
        input: &MaterializeInput<'_>,
    ) -> Result<MaterializePlanResponse, String> {
        let mut script = self.script.lock().unwrap();
        script.calls.push(format!(
            "materialize:{}:{}",
            self.public, input.authority_support_state
        ));
        if script.preview {
            assert_eq!(input.profile_id, "org.openharmony.dayu200@1.0.0");
            assert_eq!(
                hex(input.stable_identity_sha256),
                arkdeck_contract::sha256_hex(b"17956864")
            );
            assert_eq!(input.binding_id, "PREVIEW-555555555555");
            assert_eq!(input.binding_revision, 1);
            assert_eq!(input.execution_purpose, "primaryFlash");
        } else {
            assert_eq!(input.stable_identity_sha256, &[0xaa; 32]);
            assert_eq!(input.binding_id, "TGT-1");
            assert_eq!(input.binding_revision, 4);
        }
        let assessment = Assessment {
            mechanics_maturity_key_sha256: "bb".repeat(32),
            mechanics_maturity_state: "hardwareCampaign".into(),
            authority_support_key_sha256: hex(input.authority_support_key_sha256),
            authority_support_state: input.authority_support_state.into(),
            ..Assessment::default()
        };
        if self.public && script.fault != "public-plan" {
            return Ok(MaterializePlanResponse::Assessment(assessment));
        }
        if input.authority_support_state == "hardwareGated" && script.fault != "pending-plan" {
            let mut assessment = assessment;
            match script.fault.as_str() {
                "pending-seal" => assessment.authority_support_key_sha256 = "cc".repeat(32),
                "mechanics-key" => assessment.mechanics_maturity_key_sha256 = "cc".repeat(32),
                "mechanics-gated" => {
                    assessment.mechanics_maturity_state = "hardwareGated".into();
                    assessment.availability = "unavailable".into();
                    assessment.unavailable_reason = "maturity is hardwareGated".into();
                    assessment.unknowns = vec![KeyValue {
                        key: "RK-M02".into(),
                        value: "hardwareGated".into(),
                    }];
                }
                _ => {}
            }
            return Ok(MaterializePlanResponse::Assessment(assessment));
        }
        let mut plan = ExecutablePlan {
            plan_id: "PLAN-1".into(),
            plan_sha256: "11".repeat(32),
            execution_purpose: input.execution_purpose.into(),
            mechanics_maturity_key_sha256: assessment.mechanics_maturity_key_sha256,
            mechanics_maturity_state: assessment.mechanics_maturity_state,
            mechanics_maturity_campaign: "fixture-campaign".into(),
            authority_support_key_sha256: hex(input.authority_support_key_sha256),
            authority_support_state: input.authority_support_state.into(),
            authority_support_campaign: input.authority_support_detail.into(),
            ..ExecutablePlan::default()
        };
        match script.fault.as_str() {
            "final-mechanics-key" => plan.mechanics_maturity_key_sha256 = "cc".repeat(32),
            "final-mechanics-state" => plan.mechanics_maturity_state = "productionVerified".into(),
            "final-mechanics-campaign" => plan.mechanics_maturity_campaign = "different".into(),
            "final-authority-key" => plan.authority_support_key_sha256 = "cc".repeat(32),
            "final-authority-state" => plan.authority_support_state = "productionVerified".into(),
            "final-authority-campaign" => plan.authority_support_campaign = "different".into(),
            "purpose" => plan.execution_purpose = "different".into(),
            "digest" => plan.plan_sha256 = "malformed".into(),
            _ => {}
        }
        Ok(MaterializePlanResponse::Plan(plan))
    }
}

impl AssessmentSource for Port {
    fn inspect(&mut self, artifact: &str) -> Result<(), String> {
        PlanSource::inspect(self, artifact)
    }
    fn discover(&mut self) -> Result<Vec<DeviceObservationView>, String> {
        PlanSource::discover(self)
    }
    fn assess(
        &mut self,
        _: &str,
        _: &str,
        _: &str,
    ) -> Result<MaterializePlanResponse, crate::AssessmentFailure> {
        let mut script = self.script.lock().unwrap();
        script.calls.push("materialize:true:".into());
        if script.fault == "public-plan" {
            Ok(MaterializePlanResponse::Plan(ExecutablePlan::default()))
        } else {
            Ok(MaterializePlanResponse::Assessment(Assessment {
                mechanics_maturity_key_sha256: "bb".repeat(32),
                mechanics_maturity_state: "hardwareCampaign".into(),
                ..Assessment::default()
            }))
        }
    }
}

impl ExecutionClient for Port {
    fn start(&mut self, _: &str, _: &str, _: &str, _: &str) -> Result<String, String> {
        let mut script = self.script.lock().unwrap();
        script.calls.push("start".into());
        if script.start_failure {
            Err("lost reply".into())
        } else {
            Ok("DAEMON-1".into())
        }
    }
}

impl SessionDaemon for Port {
    fn job_events(&mut self, job_id: &str, _: u64) -> Result<Vec<JobEvent>, String> {
        assert_eq!(job_id, "DAEMON-1");
        let mut script = self.script.lock().unwrap();
        script.calls.push("poll".into());
        if script.poll_failure {
            return Err("lost controller".into());
        }
        Ok(vec![
            JobEvent {
                job_id: job_id.into(),
                sequence: 1,
                kind: JobEventKind::ActionReceipt,
                receipt: Some(ActionReceiptSummary {
                    job_id: job_id.into(),
                    plan_id: "PLAN-1".into(),
                    step_id: "DAEMON-STEP".into(),
                    disposition: "semanticSuccess".into(),
                    ..ActionReceiptSummary::default()
                }),
                ..JobEvent::default()
            },
            JobEvent {
                job_id: job_id.into(),
                sequence: 2,
                kind: JobEventKind::OutcomeClassified,
                facts: vec![KeyValue {
                    key: "outcome".into(),
                    value: if script.outcome.is_empty() {
                        "succeeded".into()
                    } else {
                        script.outcome.clone()
                    },
                }],
                ..JobEvent::default()
            },
        ])
    }
    fn submit_permit(&mut self, _: &SubmitStepPermitRequest) -> Result<SubmissionOutcome, String> {
        panic!("fixture terminal has no admission")
    }
    fn submit_control_receipt(
        &mut self,
        _: &SubmitManagedControlReceiptRequest,
    ) -> Result<SubmissionOutcome, String> {
        panic!("fixture terminal has no control request")
    }
    fn cancel(&mut self, _: &str, _: u64) -> Result<(), String> {
        panic!("passive read cannot cancel")
    }
}

struct NeverPerform;
impl ControlPerformer for NeverPerform {
    fn perform(&mut self, _: &ManagedControlRequest) -> Result<Observation, String> {
        panic!("fixture terminal needs no device action")
    }
}

struct Connections(Arc<Mutex<Script>>);
impl super::PlanConnections for Connections {
    fn controller(&self) -> Result<Box<dyn PlanSource>, String> {
        Ok(Box::new(Port {
            script: Arc::clone(&self.0),
            public: false,
        }))
    }
    fn public(&self) -> Result<Box<dyn AssessmentSource>, String> {
        Ok(Box::new(Port {
            script: Arc::clone(&self.0),
            public: true,
        }))
    }
}
impl LaneConnections for Connections {
    fn execution(&self) -> Result<Box<dyn ExecutionClient>, String> {
        Ok(Box::new(Port {
            script: Arc::clone(&self.0),
            public: false,
        }))
    }
    fn performer(&self, _: &str, _: &DeviceBinding) -> Box<dyn ControlPerformer> {
        Box::new(NeverPerform)
    }
}

fn fixture(campaign: &str) -> (LaneHost, Arc<Mutex<Script>>, LaneArtifact, DeviceBinding) {
    let script = Arc::new(Mutex::new(Script::default()));
    let lane = LaneHost::new(
        Box::new(Connections(Arc::clone(&script))),
        "cc".repeat(32),
        Configuration::new(&"22".repeat(32), &"33".repeat(32), campaign),
        ControllerPairingSecret::new(PairingEpoch(1), vec![0x44; 32]),
    );
    let artifact = LaneArtifact {
        path: "/fixture/archive".into(),
        sha256: "55".repeat(32),
        profile_id: "org.openharmony.dayu200@1.0.0".into(),
    };
    let binding = DeviceBinding {
        connect_key: "hdc-alias".into(),
        stable_identity_sha256: "aa".repeat(32),
        target_id: "TGT-1".into(),
        binding_revision: 4,
        usb_topology: "17956864".into(),
    };
    (lane, script, artifact, binding)
}

#[test]
fn preparation_seals_two_assessments_and_starts_only_once_without_driving() {
    let (lane, script, artifact, binding) = fixture("fixture-campaign");
    assert!(lane.prewarm("JOB-1", &artifact).unwrap().imported);
    assert!(lane.prewarm("JOB-1", &artifact).unwrap().imported);
    let execution = lane
        .prepare("JOB-1", &artifact, &binding, "primaryFlash")
        .unwrap();
    assert_eq!(
        lane.prepare("JOB-1", &artifact, &binding, "primaryFlash")
            .unwrap(),
        execution
    );
    assert_eq!(
        script.lock().unwrap().calls,
        [
            "inspect:false",
            "import",
            "inspect:false",
            "inspect:true",
            "discover:true",
            "materialize:true:",
            "discover:false",
            "materialize:false:hardwareGated",
            "materialize:false:hardwareCampaign",
            "start"
        ]
    );
    assert_eq!(execution.daemon_job_id, "DAEMON-1");
    assert_eq!(execution.observation_mode, "rockusb-loader");
    assert!(
        lane.prepare("JOB-1", &artifact, &binding, "recovery")
            .is_err()
    );
}

#[test]
fn concurrent_prepare_and_perform_share_one_daemon_execution() {
    let (lane, script, artifact, binding) = fixture("fixture-campaign");
    let ready = std::sync::Barrier::new(2);
    let executions = std::thread::scope(|scope| {
        let invoke = || {
            ready.wait();
            lane.prepare("JOB-1", &artifact, &binding, "primaryFlash")
                .unwrap()
        };
        let first = scope.spawn(invoke);
        let second = scope.spawn(invoke);
        (first.join().unwrap(), second.join().unwrap())
    });
    assert_eq!(executions.0, executions.1);
    std::thread::scope(|scope| {
        let invoke = || {
            ready.wait();
            lane.perform("flash-partitions", &executions.0, &artifact, &binding)
                .unwrap()
        };
        let first = scope.spawn(invoke);
        let second = scope.spawn(invoke);
        assert_eq!(first.join().unwrap(), second.join().unwrap());
    });
    let calls = &script.lock().unwrap().calls;
    assert_eq!(calls.iter().filter(|call| *call == "start").count(), 1);
    assert_eq!(calls.iter().filter(|call| *call == "poll").count(), 1);
}

#[test]
fn every_assessment_or_seal_mismatch_refuses_before_start() {
    for fault in [
        "public-plan",
        "observation",
        "pending-plan",
        "pending-seal",
        "mechanics-key",
        "mechanics-gated",
        "final-mechanics-key",
        "final-mechanics-state",
        "final-mechanics-campaign",
        "final-authority-key",
        "final-authority-state",
        "final-authority-campaign",
        "purpose",
        "digest",
    ] {
        let (lane, script, artifact, binding) = fixture("fixture-campaign");
        script.lock().unwrap().fault = fault.into();
        assert!(
            matches!(
                lane.prepare("JOB-1", &artifact, &binding, "primaryFlash"),
                Err(LaneFailure::ConfirmedNotExecuted(_))
            ),
            "{fault}"
        );
        assert!(
            !script
                .lock()
                .unwrap()
                .calls
                .iter()
                .any(|call| call == "start" || call == "poll"),
            "{fault}"
        );
    }
    let (lane, script, artifact, binding) = fixture("");
    assert!(
        lane.prepare("JOB-1", &artifact, &binding, "primaryFlash")
            .is_err()
    );
    assert!(
        !script
            .lock()
            .unwrap()
            .calls
            .iter()
            .any(|call| call == "start")
    );
}

#[test]
fn a_lost_start_reply_is_effect_free_and_never_starts_a_replacement() {
    let (lane, script, artifact, binding) = fixture("fixture-campaign");
    script.lock().unwrap().start_failure = true;
    assert!(matches!(
        lane.prepare("JOB-1", &artifact, &binding, "primaryFlash"),
        Err(LaneFailure::ConfirmedNotExecuted(_))
    ));
    let calls = script.lock().unwrap().calls.clone();
    assert!(
        lane.prepare("JOB-1", &artifact, &binding, "primaryFlash")
            .is_err()
    );
    assert_eq!(script.lock().unwrap().calls, calls);
}

#[test]
fn completed_receipts_project_only_the_two_published_steps_without_redispatch() {
    let (lane, script, artifact, binding) = fixture("fixture-campaign");
    let execution = lane
        .prepare("JOB-1", &artifact, &binding, "primaryFlash")
        .unwrap();
    let receipt = lane
        .perform("flash-partitions", &execution, &artifact, &binding)
        .unwrap();
    assert_eq!(
        lane.perform("verify-flash-readback", &execution, &artifact, &binding)
            .unwrap(),
        receipt
    );
    assert_eq!(
        lane.perform("DAEMON-STEP", &execution, &artifact, &binding)
            .unwrap(),
        receipt
    );
    assert!(
        lane.perform("unrelated-step", &execution, &artifact, &binding)
            .is_err()
    );
    assert_eq!(
        script
            .lock()
            .unwrap()
            .calls
            .iter()
            .filter(|call| *call == "poll")
            .count(),
        1
    );
    assert_eq!(lane.completed_plan_receipt("JOB-1"), Some(receipt));
}

#[test]
fn unknown_or_failed_terminal_is_cached_without_replay_or_completion_receipt() {
    for outcome in [
        "outcomeUnknown",
        "confirmedFailed",
        "cancelledSafe",
        "lost-transport",
    ] {
        let (lane, script, artifact, binding) = fixture("fixture-campaign");
        let execution = lane
            .prepare("JOB-1", &artifact, &binding, "primaryFlash")
            .unwrap();
        script.lock().unwrap().outcome = outcome.into();
        script.lock().unwrap().poll_failure = outcome == "lost-transport";
        let failure = lane
            .perform("flash-partitions", &execution, &artifact, &binding)
            .unwrap_err();
        if outcome == "outcomeUnknown" || outcome == "lost-transport" {
            assert!(matches!(failure, LaneFailure::OutcomeUnknown(_)));
        }
        let calls = script.lock().unwrap().calls.clone();
        assert_eq!(
            lane.perform("flash-partitions", &execution, &artifact, &binding),
            Err(failure)
        );
        assert_eq!(script.lock().unwrap().calls, calls);
        assert!(lane.completed_plan_receipt("JOB-1").is_none());
    }
}

#[test]
fn persisted_correlation_is_checked_before_polling_and_terminal_observation_is_passive() {
    let (lane, script, artifact, binding) = fixture("fixture-campaign");
    let execution = lane
        .prepare("JOB-1", &artifact, &binding, "primaryFlash")
        .unwrap();
    let mut other = binding.clone();
    other.binding_revision += 1;
    let calls = script.lock().unwrap().calls.clone();
    assert!(
        lane.perform("flash-partitions", &execution, &artifact, &other)
            .is_err()
    );
    assert_eq!(script.lock().unwrap().calls, calls);
    assert!(matches!(
        lane.observe_terminal(&execution).unwrap(),
        Some(Terminal::Completed(_))
    ));
    assert_eq!(&script.lock().unwrap().calls[calls.len()..], ["poll"]);
    assert!(lane.completed_plan_receipt("JOB-1").is_none());
}

#[test]
fn preview_materializes_read_only_and_preserves_structured_refusals() {
    use crate::{LanePlanPreview, LanePreview, LanePreviewHost};
    for (fault, campaign, state) in [
        ("", "fixture-campaign", "available"),
        ("", "", "planNotExecutable"),
        ("public-plan", "fixture-campaign", "planNotExecutable"),
        ("observation", "fixture-campaign", "planNotExecutable"),
        ("pending-plan", "fixture-campaign", "planNotExecutable"),
        ("pending-seal", "fixture-campaign", "planNotExecutable"),
        ("mechanics-key", "fixture-campaign", "planNotExecutable"),
        ("mechanics-gated", "fixture-campaign", "planNotExecutable"),
        (
            "final-mechanics-key",
            "fixture-campaign",
            "planNotExecutable",
        ),
        (
            "final-mechanics-state",
            "fixture-campaign",
            "planNotExecutable",
        ),
        (
            "final-mechanics-campaign",
            "fixture-campaign",
            "planNotExecutable",
        ),
        (
            "final-authority-key",
            "fixture-campaign",
            "planNotExecutable",
        ),
        (
            "final-authority-state",
            "fixture-campaign",
            "planNotExecutable",
        ),
        (
            "final-authority-campaign",
            "fixture-campaign",
            "planNotExecutable",
        ),
    ] {
        let script = Arc::new(Mutex::new(Script {
            imported: true,
            preview: true,
            fault: fault.into(),
            ..Script::default()
        }));
        let preview = LanePreviewHost::new(
            Box::new(Connections(script.clone())),
            Configuration::new(&"22".repeat(32), &"33".repeat(32), campaign),
            "org.openharmony.dayu200@1.0.0".into(),
        );
        let result = preview.preview(&"55".repeat(32), "17956864");
        match result {
            LanePreview::Available {
                plan_id,
                plan_sha256,
                observation_mode,
            } => {
                assert_eq!(state, "available", "{fault}");
                assert_eq!(plan_id, "PLAN-1");
                assert_eq!(plan_sha256, "11".repeat(32));
                assert_eq!(observation_mode, "rockusb-loader");
                assert_eq!(
                    script.lock().unwrap().calls,
                    [
                        "inspect:false",
                        "inspect:true",
                        "discover:true",
                        "materialize:true:",
                        "discover:false",
                        "materialize:false:hardwareGated",
                        "materialize:false:hardwareCampaign",
                    ]
                );
            }
            LanePreview::PlanNotExecutable {
                availability,
                reason,
                unknowns,
            } => {
                assert_eq!(state, "planNotExecutable", "{fault}");
                assert!(!reason.is_empty());
                assert!(!availability.is_empty());
                assert!(!unknowns.is_empty());
                if fault == "mechanics-gated" {
                    assert_eq!(availability, "unavailable");
                    assert_eq!(reason, "maturity is hardwareGated");
                    assert_eq!(
                        unknowns.get("RK-M02").map(String::as_str),
                        Some("hardwareGated")
                    );
                }
                if fault.starts_with("final-") {
                    assert_eq!(unknowns.len(), 6);
                }
                if campaign.is_empty() {
                    assert!(unknowns.contains_key("RK-A01"));
                }
            }
            other => panic!("unexpected preview {fault}: {other:?}"),
        }
        let calls = &script.lock().unwrap().calls;
        assert!(
            !calls
                .iter()
                .any(|call| matches!(call.as_str(), "import" | "start" | "poll" | "permit"))
        );
    }
}

#[test]
fn preview_store_miss_never_imports_or_opens_an_assessment() {
    use crate::{LanePlanPreview, LanePreview, LanePreviewHost};
    let script = Arc::new(Mutex::new(Script::default()));
    let preview = LanePreviewHost::new(
        Box::new(Connections(script.clone())),
        Configuration::new(&"22".repeat(32), &"33".repeat(32), ""),
        "org.openharmony.dayu200@1.0.0".into(),
    );
    assert_eq!(
        preview.preview(&"55".repeat(32), "17956864"),
        LanePreview::BundleNotInLaneStore
    );
    assert_eq!(script.lock().unwrap().calls, ["inspect:false"]);
}
