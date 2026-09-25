//! The fakes the Swift Flash run oracle (`FlashRunOracleContractTests`,
//! `rust/tests/fixtures/flash-run`) scripts, as the Rust replay composes them:
//! the ArkForge lane, the Rockchip host and the facts port, each answering as
//! the exchange's
//! recorded `script` says and logging what it was asked in the oracle's own
//! words. No device, `arkforged`, HDC or installed service is reached; what
//! they answer is fixture data, never device evidence.
use arkdeck_hoststore::RockchipFacts;
use arkdeck_provider_arkforge::{
    ActionReceipt, DeviceBinding, Execution, FlashLane, HostAction, HostReceipt, LaneArtifact,
    LaneFailure, PrewarmReceipt, RockchipHost, Terminal, canonical_facts_digest,
};
use serde_json::Value;
use std::collections::{BTreeMap, HashMap};
use std::sync::{Arc, Mutex, PoisonError};

/// The lane's toolchain, which every StepPermit binds.
pub const TOOLCHAIN: &str = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";
/// The configured `arkforged` the facts port names.
const ARKFORGED: &str = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
const CONNECT_KEY: &str = "150100424a544e4600";
const ALIAS_KEY: &str = "post-flash-hdc-address";

/// What the fakes answer while one exchange runs.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Script {
    pub prewarm: String,
    pub prepare: String,
    pub perform: String,
    pub terminal: String,
    pub diagnostics: String,
    pub cross_mode: String,
    pub alias_topology: Option<String>,
    pub binding_revision: i64,
}

impl Script {
    /// The script an exchange recorded.
    pub fn recorded(value: &Value) -> Self {
        let text = |key: &str| value[key].as_str().unwrap().to_owned();
        Self {
            prewarm: text("prewarm"),
            prepare: text("prepare"),
            perform: text("perform"),
            terminal: text("terminal"),
            diagnostics: text("diagnostics"),
            cross_mode: text("crossMode"),
            alias_topology: value["aliasTopology"].as_str().map(str::to_owned),
            binding_revision: value["bindingRevision"].as_i64().unwrap(),
        }
    }
}

impl Default for Script {
    fn default() -> Self {
        Self {
            prewarm: "storeHit".into(),
            prepare: "ok".into(),
            perform: "ok".into(),
            terminal: "none".into(),
            diagnostics: "hilog".into(),
            cross_mode: "satisfied".into(),
            alias_topology: Some("42".into()),
            binding_revision: 1,
        }
    }
}

#[derive(Default)]
struct Shared {
    script: Script,
    lane_calls: Vec<String>,
    dispatch_calls: Vec<String>,
    executions: u64,
}

/// The script the fakes read and the calls they received, shared across the
/// daemon's restarts as the oracle shares them.
#[derive(Clone, Default)]
pub struct Fakes(Arc<Mutex<Shared>>);

impl Fakes {
    fn shared(&self) -> std::sync::MutexGuard<'_, Shared> {
        self.0.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// The fakes answer `script` from now on, with no call received yet.
    pub fn begin(&self, script: Script) {
        let mut shared = self.shared();
        shared.script = script;
        shared.lane_calls.clear();
        shared.dispatch_calls.clear();
    }

    pub fn current(&self) -> Script {
        self.shared().script.clone()
    }

    fn lane(&self, call: String) {
        self.shared().lane_calls.push(call);
    }

    pub fn dispatched(&self, call: String) {
        self.shared().dispatch_calls.push(call);
    }

    /// The lane's calls and the dispatcher's, since the exchange began.
    pub fn calls(&self) -> (Vec<String>, Vec<String>) {
        let shared = self.shared();
        (shared.lane_calls.clone(), shared.dispatch_calls.clone())
    }

    /// The daemon names its jobs uniquely across its own restarts.
    fn next_execution(&self) -> u64 {
        let mut shared = self.shared();
        shared.executions += 1;
        shared.executions
    }

    /// The facts port's answer: a covered, post-flash-routed DAYU200, as the
    /// exchange's script shapes it.
    pub fn facts(&self, target_id: &str) -> Result<RockchipFacts, String> {
        let script = self.current();
        let mut server = BTreeMap::from([
            ("rockusbBackend".to_owned(), "native".to_owned()),
            (
                "arkForgeToolchainID".to_owned(),
                "arkforged-native-rockusb".to_owned(),
            ),
            ("dayu200CrossModeBinding".to_owned(), script.cross_mode),
        ]);
        if let Some(topology) = script.alias_topology {
            server.insert(
                "dayu200HDCNormalAliasSHA256".into(),
                arkdeck_contract::sha256_hex(ALIAS_KEY.as_bytes()),
            );
            server.insert("dayu200HDCNormalAliasUSBTopology".into(), topology);
        }
        Ok(RockchipFacts {
            target_id: target_id.to_owned(),
            binding_revision: script.binding_revision,
            identity_sha256: arkdeck_contract::sha256_hex(CONNECT_KEY.as_bytes()),
            tool_sha256: ARKFORGED.into(),
            execution_connect_key: ALIAS_KEY.into(),
            device_mode: "hdc".into(),
            build_fingerprint: None,
            profile_id: "dayu200".into(),
            server_facts: server,
        })
    }
}

/// The ArkForge lane as the oracle scripts it. Its cache of completed plans
/// is its own, as the production lane's is: a restart loses it.
pub struct FakeLane {
    fakes: Fakes,
    completed: Mutex<HashMap<String, ActionReceipt>>,
}

impl FakeLane {
    pub fn new(fakes: &Fakes) -> Self {
        Self {
            fakes: fakes.clone(),
            completed: Mutex::new(HashMap::new()),
        }
    }

    fn remember(&self, job_id: &str, receipt: &ActionReceipt) {
        self.completed
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .insert(job_id.to_owned(), receipt.clone());
    }
}

/// The terminal managed-control postflight of one completed plan, as the
/// production lane exposes it; a non-canonical one carries a zero digest.
pub fn receipt(execution: &Execution, canonical: bool) -> ActionReceipt {
    let facts = vec![
        ("const.product.model".to_owned(), "DAYU200".to_owned()),
        (
            "const.ohos.fullname".to_owned(),
            "OpenHarmony-7.0.0.36".to_owned(),
        ),
        ("usbTopology".to_owned(), execution.usb_topology.clone()),
    ];
    let ordinal = execution
        .daemon_job_id
        .strip_prefix("JOB-FLASH-")
        .unwrap_or_default();
    ActionReceipt {
        job_id: execution.daemon_job_id.clone(),
        plan_id: execution.plan_id.clone(),
        step_id: "STEP-023".into(),
        action_id: String::new(),
        attempt_id: String::new(),
        permit_id: format!("PERMIT-FLASH-{ordinal}"),
        disposition: "semanticSuccess".into(),
        evidence_sha256: if canonical {
            canonical_facts_digest(&facts).unwrap()
        } else {
            vec![0; 32]
        },
        verification_outcome: String::new(),
        verification_strength: String::new(),
        verified_range_start: 0,
        verified_range_length: 0,
        typed_skip_reason: String::new(),
        failure_classification: String::new(),
        facts,
    }
}

impl FlashLane for FakeLane {
    fn toolchain_sha256(&self) -> &str {
        TOOLCHAIN
    }

    fn prewarm(
        &self,
        job_id: &str,
        artifact: &LaneArtifact,
    ) -> Result<PrewarmReceipt, LaneFailure> {
        self.fakes.lane(format!(
            "prewarm {job_id} sha256={} profile={}",
            artifact.sha256, artifact.profile_id
        ));
        let script = self.fakes.current().prewarm;
        let (imported, duration_milliseconds) = match script.as_str() {
            "refused" => {
                return Err(LaneFailure::Other(
                    "fixture ArkForge content store unavailable".into(),
                ));
            }
            "imported" => (true, 11),
            _ => (false, 7),
        };
        // A drifted receipt answers for another archive.
        let artifact_sha256 = if script == "drifted" {
            "0".repeat(64)
        } else {
            artifact.sha256.clone()
        };
        Ok(PrewarmReceipt {
            artifact_sha256,
            profile_id: artifact.profile_id.clone(),
            imported,
            duration_milliseconds,
        })
    }

    fn finish_prewarm(&self, job_id: &str) {
        self.fakes.lane(format!("finishPrewarm {job_id}"));
    }

    fn prepare(
        &self,
        job_id: &str,
        artifact: &LaneArtifact,
        binding: &DeviceBinding,
        purpose: &str,
    ) -> Result<Execution, LaneFailure> {
        self.fakes.lane(format!(
            "prepare {job_id} purpose={purpose} target={} revision={} identity={} \
             connectKey={} topology={} sha256={} profile={}",
            binding.target_id,
            binding.binding_revision,
            binding.stable_identity_sha256,
            binding.connect_key,
            binding.usb_topology,
            artifact.sha256,
            artifact.profile_id
        ));
        let script = self.fakes.current().prepare;
        match script.as_str() {
            "failed" => {
                return Err(LaneFailure::Failed(
                    "fixture arkforged refused to materialize the plan".into(),
                ));
            }
            "confirmedNotExecuted" => {
                return Err(LaneFailure::ConfirmedNotExecuted(
                    "fixture arkforged created no daemon job".into(),
                ));
            }
            _ => {}
        }
        let ordinal = self.fakes.next_execution();
        Ok(Execution {
            arkdeck_job_id: job_id.to_owned(),
            daemon_job_id: format!("JOB-FLASH-{ordinal}"),
            plan_id: format!("PLAN-FLASH-{ordinal}"),
            plan_sha256: "7".repeat(64),
            execution_purpose: purpose.to_owned(),
            artifact_sha256: artifact.sha256.clone(),
            artifact_profile_id: artifact.profile_id.clone(),
            target_id: binding.target_id.clone(),
            binding_revision: binding.binding_revision,
            stable_identity_sha256: binding.stable_identity_sha256.clone(),
            usb_topology: binding.usb_topology.clone(),
            observation_mode: "loader".into(),
            // An uncorrelated daemon job is bound to another toolchain.
            toolchain_sha256: if script == "uncorrelated" {
                "d".repeat(64)
            } else {
                TOOLCHAIN.into()
            },
        })
    }

    fn perform(
        &self,
        step_id: &str,
        execution: &Execution,
        _artifact: &LaneArtifact,
        _binding: &DeviceBinding,
    ) -> Result<ActionReceipt, LaneFailure> {
        self.fakes.lane(format!(
            "perform {step_id} {} daemonJob={} plan={} purpose={}",
            execution.arkdeck_job_id,
            execution.daemon_job_id,
            execution.plan_id,
            execution.execution_purpose
        ));
        match self.fakes.current().perform.as_str() {
            "failed" => Err(LaneFailure::Failed(
                "fixture arkforged confirmed the plan failed".into(),
            )),
            "confirmedNotExecuted" => Err(LaneFailure::ConfirmedNotExecuted(
                "fixture arkforged confirmed nothing was written".into(),
            )),
            "outcomeUnknown" => Err(LaneFailure::OutcomeUnknown(
                "fixture lost the controller after the daemon accepted the exact job".into(),
            )),
            "lost" => Err(LaneFailure::Other(
                "fixture controller connection reset".into(),
            )),
            "nonCanonical" => Ok(receipt(execution, false)),
            _ => {
                let completed = receipt(execution, true);
                self.remember(&execution.arkdeck_job_id, &completed);
                Ok(completed)
            }
        }
    }

    fn observe_terminal(&self, execution: &Execution) -> Result<Option<Terminal>, String> {
        self.fakes.lane(format!(
            "observe {} daemonJob={}",
            execution.arkdeck_job_id, execution.daemon_job_id
        ));
        Ok(match self.fakes.current().terminal.as_str() {
            "completed" => {
                let completed = receipt(execution, true);
                self.remember(&execution.arkdeck_job_id, &completed);
                Some(Terminal::Completed(vec![completed]))
            }
            "cancelledSafe" => Some(Terminal::CancelledSafe),
            "confirmedFailed" => Some(Terminal::ConfirmedFailed(
                "fixture daemon confirmed the plan failed".into(),
            )),
            "outcomeUnknown" => Some(Terminal::OutcomeUnknown(
                "fixture daemon still cannot prove the outcome".into(),
            )),
            "unreachable" => return Err("fixture daemon socket unreachable".into()),
            _ => None,
        })
    }

    fn completed_plan_receipt(&self, job_id: &str) -> Option<ActionReceipt> {
        self.fakes.lane(format!("completedPlanReceipt {job_id}"));
        self.completed
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get(job_id)
            .cloned()
    }
}

/// What the fake capture of the post-flash HiLog answers: one line names a
/// path in the configured home, which the Artifact store redacts.
pub const HILOG: &str = "09-25 00:00:00.000  1234  1234 I A00001/fixture: post-flash boot complete\n\
09-25 00:00:00.001  1234  1234 I A00001/fixture: opened /private/tmp/arkdeck-flash-run-oracle/home/.config/app\n";

/// The Rockchip per-action host as the oracle scripts it: the one
/// host-managed action a delegated Flash runs itself is the post-flash HiLog
/// capture.
pub struct FakeHost(pub Fakes);

impl RockchipHost for FakeHost {
    fn dispatch(&self, action: &HostAction) -> Result<HostReceipt, LaneFailure> {
        self.0.dispatched(format!(
            "{} {} identifier={} target={} revision={} connectKey={} identity={} tool={} \
             action={} budget={}",
            action.step_id,
            action.job_id,
            action.identifier,
            action.target_id,
            action.binding_revision,
            action.connect_key,
            action.expected_identity_sha256,
            action.provider_executable_sha256,
            action.action_sha256,
            action
                .output_byte_budget
                .map_or_else(|| "none".to_owned(), |budget| budget.to_string())
        ));
        if action.step_id != "capture-post-flash-diagnostics" {
            return Err(LaneFailure::Failed(
                "the Flash oracle dispatches only the post-flash diagnostics capture".into(),
            ));
        }
        if self.0.current().diagnostics != "hilog" {
            return Err(LaneFailure::Failed(
                "post-flash HiLog capture returned no bytes".into(),
            ));
        }
        let stdout = HILOG.as_bytes().to_vec();
        Ok(HostReceipt {
            exit_status: Some(0),
            summary: BTreeMap::from([
                ("byteCount".to_owned(), stdout.len().to_string()),
                ("debugRuntime".to_owned(), "ready".to_owned()),
                ("verification".to_owned(), "full".to_owned()),
            ]),
            stdout,
            stderr: Vec::new(),
            stdout_truncated: false,
            duration_seconds: 0.25,
            record_id: Some(format!(
                "rockchip-record-{}-{}",
                action.job_id, action.step_id
            )),
        })
    }
}
