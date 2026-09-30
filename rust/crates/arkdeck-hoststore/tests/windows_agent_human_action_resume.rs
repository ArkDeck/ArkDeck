//! HAR crash-resume on Windows (TASK-XPA-006, as far as it goes without the
//! Windows HDC tuple): the Rust agent execution owner adopting a device and
//! resuming the physical-assistance actions Swift's physical-assistance
//! oracle (`rust/tests/fixtures/agent-human-action`) asked for, across crashes
//! of the process that owned them, as `agent_human_action_raise.rs` exercises
//! it on macOS over the shell fake HDC:
//!
//! * an execution that names no Target adopts the one connected, proved
//!   device and owns exactly one Job, which the Rust runner completes; a
//!   budget expiring during the identity readback or at the Target commit,
//!   and a USB identity that changes during adoption, commit no Target and no
//!   Job;
//! * the process crashes (`std::process::exit`) between the Target commit and
//!   the execution's own commit: a new process, with every owner reopened and
//!   no in-memory receipt, keeps the original budget and adopts nothing
//!   twice;
//! * `physicalConnection`, `deviceTrustPrompt` and `ambiguousIdentity`
//!   actions, raised and then resumed only by their durable references
//!   (`human-action.resume`, `agent.resume`): the original intent is kept,
//!   concurrent resumes own one Job, a changed selection is an idempotency
//!   conflict, an expired action or an untrusted clock is refused with no
//!   HDC call, and the action ends `resolvedByFreshProbe`;
//! * the process crashes after the resume resolved the action and before
//!   the Job was admitted: a new process answers the resume as it stands and
//!   the next run continues to one Job (or is refused once the original
//!   budget has passed).
//!
//! The fake HDC is the oracle's table (`hdc-answers.sh`) answered in process,
//! by mode, every call logged as the fake logs it; the owners are laid down
//! owner-only on NTFS. No `hdc` runs and no Windows HDC tuple is registered
//! or needed: the owners are fed a dispatch directly. The Windows daemon
//! composes none, so over the wire an execution that must observe a device
//! is refused before admission (`windows_reconcile_agent_process.rs` reads
//! the recorded executions there).
#![cfg(windows)]

use arkdeck_contract::sha256_hex;
use arkdeck_hoststore::{
    AgentEngine, AgentExecutionStore, ArtifactReadStore, JobAdmitter, JobPlanner, JobStore,
    Observing, Sources, StorageProbe, StorageSnapshot, TargetObservations, TargetStore,
};
use arkdeck_platform::HostDirectory;
use arkdeck_provider_hdc::{DispatchFailure, HdcDispatch, ProcessPlan, Receipt, UsbRelation};
use serde_json::{Map, Value, json};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

const KEY: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const OTHER: &str = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
/// The root a crash child lays its owners down in, named by its parent.
const ROOT: &str = "ARKDECK_HAR_ROOT";

fn fixture() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/fixtures/agent-human-action")
}

fn document(path: &Path) -> Value {
    serde_json::from_slice(&fs::read(path).unwrap()).unwrap()
}

fn fixed_now() -> Option<String> {
    Some("2026-09-14T00:00:00Z".into())
}

fn fixed_precise_now() -> Option<String> {
    Some("2026-09-14T00:00:00.000Z".into())
}

/// The oracle's fake HDC (`hdc-answers.sh`) in process: the device list in
/// the state the mode names, and the reads an adoption and an
/// `observe.device@1` Job make. Every call is recorded as the fake logs it:
/// each argument followed by U+001F, then a newline. Clones share it.
#[derive(Clone)]
struct FakeHdc {
    state: Arc<Mutex<(String, Vec<u8>)>>,
    digest: String,
}

impl FakeHdc {
    fn new(mode: &str) -> Self {
        let provenance = document(&fixture().join("provenance.json"));
        Self {
            state: Arc::new(Mutex::new((mode.to_owned(), Vec::new()))),
            digest: provenance["hdcSHA256"].as_str().unwrap().to_owned(),
        }
    }
    /// The mode the next calls answer in, as the oracle writes `hdc-mode`.
    fn set_mode(&self, mode: &str) -> std::io::Result<()> {
        self.state.lock().unwrap().0 = mode.trim_end().to_owned();
        Ok(())
    }
    /// Every call the fake has received, as its log holds them.
    fn read_log(&self) -> std::io::Result<Vec<u8>> {
        Ok(self.state.lock().unwrap().1.clone())
    }
}

impl HdcDispatch for FakeHdc {
    fn dispatch(&self, plan: &ProcessPlan) -> Result<Receipt, DispatchFailure> {
        let mut state = self.state.lock().unwrap();
        for argument in &plan.arguments {
            state.1.extend_from_slice(argument.as_bytes());
            state.1.push(0x1f);
        }
        state.1.push(b'\n');
        let arguments = plan.arguments.join(" ");
        let row = |key: &str, status: &str| format!("{key}\t\tUSB\t{status}\tlocalhost\n");
        let answer = match (arguments.as_str(), state.0.as_str()) {
            ("list targets -v", "offline") => Some(row(KEY, "Offline")),
            ("list targets -v", "unauthorized") => Some(row(KEY, "Unauthorized")),
            ("list targets -v", "twoDevices") => {
                Some(row(KEY, "Connected") + &row(OTHER, "Connected"))
            }
            ("list targets -v", "otherDevice") => Some(row(OTHER, "Connected")),
            ("list targets -v", _) => Some(row(KEY, "Connected")),
            ("-v", _) => Some("Ver: 3.2.0d\n".to_owned()),
            ("checkserver", _) => {
                Some("Client version:Ver: 3.2.0d, server version:Ver: 3.2.0d\n".to_owned())
            }
            (other, _) if other == format!("-t {KEY} shell param get const.product.name") => {
                Some("OpenHarmony Reference Device\n".to_owned())
            }
            (other, _) if other == format!("-t {KEY} shell param get const.ohos.fullname") => {
                Some("OpenHarmony-4.1-release\n".to_owned())
            }
            _ => None,
        };
        Ok(match answer {
            Some(stdout) => Receipt {
                exit_status: 0,
                stdout: stdout.into_bytes(),
                stderr: Vec::new(),
                truncated: false,
                duration: Duration::ZERO,
            },
            None => Receipt {
                exit_status: 23,
                stdout: Vec::new(),
                stderr: b"unregistered fixture output\n".to_vec(),
                truncated: false,
                duration: Duration::ZERO,
            },
        })
    }
}

/// The oracle's probe: this machine's volume with room for every claim.
struct OracleProbe(u64);

impl OracleProbe {
    fn new(provenance: &Value) -> Self {
        Self(provenance["availableBytes"].as_u64().unwrap())
    }
}

impl StorageProbe for OracleProbe {
    fn snapshot(&self, root: &HostDirectory) -> std::io::Result<StorageSnapshot> {
        Ok(StorageSnapshot {
            volume_identity: root.export_facts()?.volume_identity,
            available_bytes: self.0,
            read_only: false,
        })
    }
}

/// A fresh root below the temporary directory, in the spelling the file
/// system resolves (the host store opens a directory only by it).
fn fresh_root() -> PathBuf {
    let nonce = u64::from_ne_bytes(arkdeck_platform::random_bytes::<8>().unwrap());
    let temporary = std::env::temp_dir().canonicalize().unwrap();
    let temporary = match temporary
        .to_str()
        .and_then(|text| text.strip_prefix(r"\\?\"))
    {
        Some(plain) => PathBuf::from(plain),
        None => temporary,
    };
    temporary.join(format!("ad-winagent-resume-{nonce:016x}"))
}

/// A private state root holding the oracle's Target document, and the empty
/// owners beside it, owner-only on NTFS: at the root a crash child's parent
/// named, or a fresh one.
struct State(PathBuf);

impl State {
    fn new(fixture: &Path) -> Self {
        let root = std::env::var_os(ROOT).map_or_else(fresh_root, PathBuf::from);
        HostDirectory::open_or_create_private(&root).unwrap();
        for directory in [
            "targets-state",
            "artifacts",
            "jobs-state",
            "agent-executions",
            "human-action-snapshots",
        ] {
            HostDirectory::open_or_create_private(&root.join(directory)).unwrap();
        }
        HostDirectory::open(&root.join("targets-state"))
            .unwrap()
            .create_document(
                "targets.json",
                &fs::read(fixture.join("targets-state/targets.json")).unwrap(),
            )
            .unwrap();
        Self(root)
    }
}

impl Drop for State {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn relations(value: &Value) -> Vec<UsbRelation> {
    value
        .as_array()
        .unwrap()
        .iter()
        .map(|relation| UsbRelation::from_value(relation).unwrap())
        .collect()
}

fn execution_file(id: &str) -> String {
    format!("execution-{}.json", sha256_hex(id.as_bytes()))
}

thread_local! {
    static ADOPTION_EXPIRED: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
    static RESUME_CLOCK_ROLLBACK: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
    static RESUME_CRASH_COUNTDOWN: std::cell::Cell<u8> = const { std::cell::Cell::new(0) };
    static ADOPTION_CRASH_PENDING: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
}
fn adoption_now() -> Option<String> {
    let countdown = RESUME_CRASH_COUNTDOWN.get();
    if countdown == 1 {
        std::process::exit(79);
    }
    if countdown > 1 {
        RESUME_CRASH_COUNTDOWN.set(countdown - 1);
    }
    if ADOPTION_CRASH_PENDING.get() {
        std::process::exit(79);
    }
    if RESUME_CLOCK_ROLLBACK.get() {
        return Some("2026-09-13T23:59:59.000Z".into());
    }
    Some(
        if ADOPTION_EXPIRED.get() {
            "2026-09-14T00:06:00.000Z"
        } else {
            "2026-09-14T00:00:00.000Z"
        }
        .into(),
    )
}

/// Exercise the production run path, without a caller-selected Target.
/// A budget may expire during the final identity readback or Target commit.
fn adopting_run(
    expire_before_commit: bool,
    expire_after_commit: bool,
    identity_drift: bool,
    crash_after_commit: bool,
) {
    use arkdeck_hoststore::HdcComposition;
    use std::cell::Cell;
    ADOPTION_EXPIRED.set(false);
    let fixture = fixture();
    let cases: Value =
        serde_json::from_slice(&fs::read(fixture.join("cases.json")).unwrap()).unwrap();
    let exchanges = cases["exchanges"].as_array().unwrap();
    let request = exchanges
        .iter()
        .find(|v| v["name"] == "connect.run")
        .unwrap()["params"]
        .as_object()
        .unwrap()
        .clone();
    let plugged = relations(
        &exchanges
            .iter()
            .find(|v| v["name"] == "connect.resume")
            .unwrap()["usbRelations"],
    );
    let fake = FakeHdc::new("normal");
    fake.set_mode("normal\n").unwrap();
    let state = State::new(&fixture);
    let root = &state.0;
    let target_path = root.join("targets-state/targets.json");
    let initial = fs::read(&target_path).unwrap();
    let targets = TargetStore::open(&root.join("targets-state")).unwrap();
    let artifacts = ArtifactReadStore::open(&root.join("artifacts")).unwrap();
    let jobs = JobStore::open_owner(&root.join("jobs-state")).unwrap();
    let agents = AgentExecutionStore::open(&root.join("agent-executions")).unwrap();
    let digest = fake.digest.clone();
    let dispatch = fake.clone();
    let hdc = HdcComposition {
        targets: &targets,
        dispatch: &dispatch,
        receive_root: None,
        tool_sha256: &digest,
        now: fixed_now,
        code_sign_helper: None,
    };
    let admitter = JobAdmitter {
        planner: JobPlanner {
            imports: None,
            artifacts: Some(&artifacts),
            analyzer: None,
            state_root: root,
            hdc: Some(&hdc),
            workspace: None,
        },
        jobs: &jobs,
        now: fixed_now,
        authority: None,
    };
    let reads = Cell::new(0);
    let usb = || {
        reads.set(reads.get() + 1);
        if expire_before_commit && reads.get() == 5 {
            ADOPTION_EXPIRED.set(true);
        }
        if identity_drift && reads.get() == 5 {
            return Ok(Vec::new());
        }
        Ok::<_, String>(plugged.clone())
    };
    let clock_calls = Cell::new(0);
    let clock = || {
        clock_calls.set(clock_calls.get() + 1);
        // Two snapshot timestamps precede the Target store timestamp.
        if expire_after_commit && clock_calls.get() == 3 {
            ADOPTION_EXPIRED.set(true);
        }
        if crash_after_commit && clock_calls.get() == 3 {
            // This source clock supplies the Target commit timestamp. The
            // agent's next budget clock runs after adopt has durably returned,
            // before resolve_snapshot can publish execution.target.
            ADOPTION_CRASH_PENDING.set(true);
        }
        "2026-09-14T00:00:00Z".to_owned()
    };
    let observer = TargetObservations::default();
    let engine = AgentEngine {
        targets: &targets,
        jobs: &jobs,
        admitter: &admitter,
        now: adoption_now,
        observations: Some(Observing {
            owner: &observer,
            sources: Sources {
                dispatch: &dispatch,
                relations: &usb,
                targets: &targets,
                now: &clock,
            },
        }),
    };
    let answer = agents.advance("agent.run", &request, &engine);
    if identity_drift {
        let error = match answer {
            Err(error) => error,
            Ok(_) => panic!("drifting identity accepted"),
        };
        // Swift wraps TargetObservationFailure as the agent handler's internal
        // refusal. No target or Job may be committed behind that refusal.
        assert_eq!(error.code, "internalError");
        assert_eq!(fs::read(target_path).unwrap(), initial);
        let status = agents
            .advance(
                "agent.status",
                &Map::from_iter([("executionId".into(), json!("har-connect"))]),
                &engine,
            )
            .unwrap();
        assert!(status.value["jobId"].is_null());
        assert!(status.value["targetId"].is_null());
    } else if expire_before_commit || expire_after_commit {
        let error = match answer {
            Err(error) => error,
            Ok(_) => panic!("expired run accepted"),
        };
        assert_eq!(error.code, "orchestrationBudgetExpired");
        assert_eq!(error.details.unwrap()["executionId"], "har-connect");
        let status = agents
            .advance(
                "agent.status",
                &Map::from_iter([("executionId".into(), json!("har-connect"))]),
                &engine,
            )
            .unwrap();
        assert_eq!(status.value["state"], "budgetExpired");
        assert!(status.value["jobId"].is_null());
        assert!(status.start.is_none());
        if expire_before_commit {
            assert_eq!(fs::read(target_path).unwrap(), initial);
        }
        let rerun = agents.advance("agent.run", &request, &engine);
        assert!(
            rerun.is_err(),
            "expired execution must not resume by rerunning"
        );
    } else {
        let answer = answer.unwrap();
        let start = answer
            .start
            .expect("newly owned Job must be returned for dispatch");
        assert_eq!(answer.value["state"], "jobOwned");
        assert!(answer.value["humanAction"].is_null());
        let durable: Value = serde_json::from_slice(&fs::read(target_path).unwrap()).unwrap();
        assert_eq!(answer.value["targetId"], durable["targets"][0]["targetID"]);
        let after_calls = fake.read_log().unwrap();
        let rerun = agents.advance("agent.run", &request, &engine).unwrap();
        assert_eq!(rerun.value["jobId"], start.job);
        assert!(rerun.start.is_none());
        assert_eq!(fake.read_log().unwrap(), after_calls);
        drop(agents);
        let reopened = AgentExecutionStore::open(&root.join("agent-executions")).unwrap();
        let rerun = reopened.advance("agent.run", &request, &engine).unwrap();
        assert_eq!(rerun.value["jobId"], start.job);
        assert!(
            rerun.start.is_none(),
            "reopening owner does not replay an owned Job"
        );
        // The daemon dispatches only the original returned start identity.
        // Complete its read-only Observe Job through the actual Rust runner.
        use arkdeck_hoststore::{JobRunner, SessionPublisher, SessionStore, StorageClaims};
        let provenance = document(&fixture.join("provenance.json"));
        for name in ["session-owner", "Sessions"] {
            HostDirectory::open_or_create_private(&root.join(name)).unwrap();
        }
        let sessions =
            SessionStore::open(&root.join("session-owner"), &root.join("Sessions")).unwrap();
        let claims = StorageClaims::default();
        let probe = OracleProbe::new(&provenance);
        let publisher = SessionPublisher {
            sessions: &sessions,
            claims: &claims,
            probe: &probe,
        };
        JobRunner {
            imports: None,
            mutation: None,
            jobs: &jobs,
            artifacts: &artifacts,
            analyzer: None,
            quota: provenance["quotaBytes"].as_u64().unwrap(),
            home: provenance["home"].as_str().unwrap(),
            now: fixed_now,
            precise_now: fixed_precise_now,
            sessions: Some(&publisher),
            cancellation: None,
            after_commit: None,
            hdc: Some(&hdc),
            workspace: None,
        }
        .handle(&Map::from_iter([("jobId".into(), json!(start.job))]))
        .unwrap();
        reopened.finish(&start, &jobs);
        let completed = reopened
            .advance(
                "agent.status",
                &Map::from_iter([("executionId".into(), json!("har-connect"))]),
                &engine,
            )
            .unwrap();
        assert_eq!(completed.value["state"], "completed");
        assert_eq!(completed.value["jobState"], "succeeded");
    }
    ADOPTION_EXPIRED.set(false);
}

#[test]
fn connected_proved_candidate_is_adopted_once_and_owns_one_job() {
    adopting_run(false, false, false, false);
}
#[test]
fn budget_expiring_during_identity_readback_prevents_target_commit_and_job() {
    adopting_run(true, false, false, false);
}
#[test]
fn budget_expiring_at_target_commit_prevents_job_creation() {
    adopting_run(false, true, false, false);
}

#[test]
fn changed_usb_identity_during_adoption_never_commits_target_or_job() {
    adopting_run(false, false, true, false);
}

#[test]
#[ignore = "subprocess crash fixture; launched only by the restart test"]
fn adoption_commit_gap_crash_child() {
    adopting_run(false, false, false, true);
    panic!("crash boundary was not reached");
}

#[test]
fn crash_between_target_and_execution_commit_reopens_all_owners_and_keeps_original_budget() {
    use arkdeck_hoststore::HdcComposition;
    for expired in [false, true] {
        let root = fresh_root();
        let mut child = std::process::Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "adoption_commit_gap_crash_child",
                "--ignored",
                "--nocapture",
            ])
            .env(ROOT, &root)
            .spawn()
            .unwrap();
        assert_eq!(child.wait().unwrap().code(), Some(79));
        let state = State(root);
        let root = &state.0;
        let target_path = root.join("targets-state/targets.json");
        let target_before: Value =
            serde_json::from_slice(&fs::read(&target_path).unwrap()).unwrap();
        assert_eq!(target_before["targets"].as_array().unwrap().len(), 1);
        let record_path = fs::read_dir(root.join("agent-executions"))
            .unwrap()
            .map(|entry| entry.unwrap().path())
            .find(|path| {
                path.file_name()
                    .unwrap()
                    .to_str()
                    .unwrap()
                    .starts_with("execution-")
            })
            .unwrap();
        let before: Value = serde_json::from_slice(&fs::read(&record_path).unwrap()).unwrap();
        assert_eq!(before["state"], "orchestrating");
        assert!(before.get("target").is_none());
        assert!(before.get("jobID").is_none());
        assert_eq!(before["deadline"], "2026-09-14T00:05:00.000Z");
        let fixture = fixture();
        let cases: Value =
            serde_json::from_slice(&fs::read(fixture.join("cases.json")).unwrap()).unwrap();
        let exchanges = cases["exchanges"].as_array().unwrap();
        let request = exchanges
            .iter()
            .find(|v| v["name"] == "connect.run")
            .unwrap()["params"]
            .as_object()
            .unwrap();
        let plugged = relations(
            &exchanges
                .iter()
                .find(|v| v["name"] == "connect.resume")
                .unwrap()["usbRelations"],
        );
        let fake = FakeHdc::new("normal");
        fake.set_mode("normal\n").unwrap();
        // New owners and a new observation source: no in-memory receipt from
        // the exited process is available to make this retry pass.
        let targets = TargetStore::open(&root.join("targets-state")).unwrap();
        let artifacts = ArtifactReadStore::open(&root.join("artifacts")).unwrap();
        let jobs = JobStore::open_owner(&root.join("jobs-state")).unwrap();
        let agents = AgentExecutionStore::open(&root.join("agent-executions")).unwrap();
        let observer = TargetObservations::default();
        let digest = fake.digest.clone();
        let dispatch = fake.clone();
        let hdc = HdcComposition {
            targets: &targets,
            dispatch: &dispatch,
            receive_root: None,
            tool_sha256: &digest,
            now: fixed_now,
            code_sign_helper: None,
        };
        let admitter = JobAdmitter {
            planner: JobPlanner {
                imports: None,
                artifacts: Some(&artifacts),
                analyzer: None,
                state_root: root,
                hdc: Some(&hdc),
                workspace: None,
            },
            jobs: &jobs,
            now: fixed_now,
            authority: None,
        };
        let usb = || Ok::<_, String>(plugged.clone());
        let clock = || "2026-09-14T00:00:00Z".to_owned();
        let engine = AgentEngine {
            targets: &targets,
            jobs: &jobs,
            admitter: &admitter,
            now: adoption_now,
            observations: Some(Observing {
                owner: &observer,
                sources: Sources {
                    dispatch: &dispatch,
                    relations: &usb,
                    targets: &targets,
                    now: &clock,
                },
            }),
        };
        ADOPTION_EXPIRED.set(expired);
        let outcome = agents.advance("agent.run", request, &engine);
        if expired {
            let error = outcome.err().expect("original deadline must refuse retry");
            assert_eq!(error.code, "orchestrationBudgetExpired");
            assert!(fake.read_log().unwrap().is_empty());
        } else {
            let answer = outcome.unwrap();
            let job = answer.start.expect("one newly admitted Job").job;
            assert_eq!(
                answer.value["targetId"],
                target_before["targets"][0]["targetID"]
            );
            let calls = fake.read_log().unwrap();
            let retry = agents.advance("agent.run", request, &engine).unwrap();
            assert_eq!(retry.value["jobId"], job);
            assert!(retry.start.is_none());
            assert_eq!(fake.read_log().unwrap(), calls);
        }
        let after: Value = serde_json::from_slice(&fs::read(&record_path).unwrap()).unwrap();
        assert_eq!(after["createdAt"], before["createdAt"]);
        assert_eq!(after["deadline"], before["deadline"]);
        let target_after: Value = serde_json::from_slice(&fs::read(target_path).unwrap()).unwrap();
        assert_eq!(target_after, target_before);
        let inventory = jobs.handle_resource("job.list", &Map::new()).unwrap();
        assert_eq!(
            inventory["items"].as_array().unwrap().len(),
            if expired { 0 } else { 1 }
        );
        ADOPTION_EXPIRED.set(false);
    }
}

#[test]
fn physical_resume_keeps_original_intent_and_unique_job() {
    use arkdeck_hoststore::HdcComposition;
    use std::cell::Cell;
    for scenario in [
        "connect",
        "trust-restart",
        "select-restart",
        "select-drift",
        "select",
        "expired",
        "rollback",
        "adoption-expired",
    ] {
        ADOPTION_EXPIRED.set(false);
        let fixture = fixture();
        let cases: Value =
            serde_json::from_slice(&fs::read(fixture.join("cases.json")).unwrap()).unwrap();
        let exchanges = cases["exchanges"].as_array().unwrap();
        let request = exchanges
            .iter()
            .find(|v| v["name"] == "connect.run")
            .unwrap()["params"]
            .as_object()
            .unwrap()
            .clone();
        let plugged = relations(
            &exchanges
                .iter()
                .find(|v| {
                    v["name"]
                        == if scenario.starts_with("select") {
                            "ambiguous.run"
                        } else {
                            "connect.resume"
                        }
                })
                .unwrap()["usbRelations"],
        );
        let fake = FakeHdc::new("normal");
        fake.set_mode("normal\n").unwrap();
        let state = State::new(&fixture);
        let root = &state.0;
        let target_path = root.join("targets-state/targets.json");
        let _initial = fs::read(&target_path).unwrap();
        let targets = TargetStore::open(&root.join("targets-state")).unwrap();
        let artifacts = ArtifactReadStore::open(&root.join("artifacts")).unwrap();
        let jobs = JobStore::open_owner(&root.join("jobs-state")).unwrap();
        let agents = AgentExecutionStore::open(&root.join("agent-executions")).unwrap();
        let digest = fake.digest.clone();
        let dispatch = fake.clone();
        let hdc = HdcComposition {
            targets: &targets,
            dispatch: &dispatch,
            receive_root: None,
            tool_sha256: &digest,
            now: fixed_now,
            code_sign_helper: None,
        };
        let admitter = JobAdmitter {
            planner: JobPlanner {
                imports: None,
                artifacts: Some(&artifacts),
                analyzer: None,
                state_root: root,
                hdc: Some(&hdc),
                workspace: None,
            },
            jobs: &jobs,
            now: fixed_now,
            authority: None,
        };
        let reads = Cell::new(0);
        let usb = || {
            reads.set(reads.get() + 1);
            if scenario == "adoption-expired" && reads.get() == 5 {
                ADOPTION_EXPIRED.set(true);
            }
            Ok::<_, String>(plugged.clone())
        };
        let clock_calls = Cell::new(0);
        let clock = || {
            clock_calls.set(clock_calls.get() + 1);
            if std::env::var_os("ARKDECK_RESUME_CRASH_CHILD").is_some() && clock_calls.get() == 4 {
                RESUME_CRASH_COUNTDOWN.set(2);
            }
            "2026-09-14T00:00:00Z".to_owned()
        };
        let observer = TargetObservations::default();
        let engine = AgentEngine {
            targets: &targets,
            jobs: &jobs,
            admitter: &admitter,
            now: adoption_now,
            observations: Some(Observing {
                owner: &observer,
                sources: Sources {
                    dispatch: &dispatch,
                    relations: &usb,
                    targets: &targets,
                    now: &clock,
                },
            }),
        };

        fake.set_mode(if scenario == "trust-restart" {
            "unauthorized\n"
        } else if scenario.starts_with("select") {
            "twoDevices\n"
        } else {
            "offline\n"
        })
        .unwrap();
        let waiting = agents
            .advance("agent.run", &request, &engine)
            .unwrap()
            .value;
        assert_eq!(waiting["state"], "waitingForHuman");
        let reference = waiting["humanAction"]["resumeReference"].clone();
        let action = waiting["humanAction"]["actionId"].clone();
        let mut params = json!({"resumeReference":reference,"humanAction":action});
        if scenario.starts_with("select") {
            params["selection"] = waiting["humanAction"]["selectionSchema"]["enum"][0].clone();
        }
        for bad in [
            json!({"resumeReference":reference,"selection":"raw-device"}),
            json!({"resumeReference":reference,"targetId":"other"}),
            json!({"resumeReference":reference,"humanAction":"har-wrong"}),
        ] {
            let method = if bad.get("humanAction").is_some() {
                "human-action.resume"
            } else {
                "agent.resume"
            };
            assert!(
                agents
                    .advance(method, bad.as_object().unwrap(), &engine)
                    .is_err()
            );
        }
        if scenario == "expired" || scenario == "rollback" {
            ADOPTION_EXPIRED.set(scenario == "expired");
            RESUME_CLOCK_ROLLBACK.set(scenario == "rollback");
            let before = fake.read_log().unwrap();
            let error = agents
                .advance("human-action.resume", params.as_object().unwrap(), &engine)
                .err()
                .unwrap();
            assert_eq!(
                error.code,
                if scenario == "expired" {
                    "humanActionExpired"
                } else {
                    "orchestrationClockUntrusted"
                }
            );
            assert_eq!(fake.read_log().unwrap(), before);
            ADOPTION_EXPIRED.set(false);
            RESUME_CLOCK_ROLLBACK.set(false);
            continue;
        }
        fake.set_mode(if scenario == "select" {
            "twoDevices\n"
        } else {
            "normal\n"
        })
        .unwrap();
        let restarted_observer = TargetObservations::default();
        let restarted_engine = AgentEngine {
            observations: Some(Observing {
                owner: &restarted_observer,
                sources: Sources {
                    dispatch: &dispatch,
                    relations: &usb,
                    targets: &targets,
                    now: &clock,
                },
            }),
            ..engine
        };
        let engine = if scenario.ends_with("restart") {
            &restarted_engine
        } else {
            &engine
        };
        if scenario.ends_with("restart") || scenario == "select-drift" {
            let refreshed = agents
                .advance("human-action.resume", params.as_object().unwrap(), engine)
                .unwrap();
            assert!(refreshed.start.is_none());
            assert_eq!(refreshed.value["state"], "waitingForHuman");
            assert_eq!(
                refreshed.value["humanAction"]["category"],
                "ambiguousIdentity"
            );
            assert_ne!(refreshed.value["humanAction"]["resumeReference"], reference);
            assert!(
                agents
                    .advance("human-action.resume", params.as_object().unwrap(), engine)
                    .is_err()
            );
            params = json!({"resumeReference":refreshed.value["humanAction"]["resumeReference"], "humanAction":refreshed.value["humanAction"]["actionId"], "selection":refreshed.value["humanAction"]["selectionSchema"]["enum"][0]});
        }
        if scenario == "adoption-expired" {
            let error = agents
                .advance("human-action.resume", params.as_object().unwrap(), engine)
                .err()
                .unwrap();
            assert_eq!(error.code, "orchestrationBudgetExpired");
            assert_eq!(fs::read(&target_path).unwrap(), _initial);
            ADOPTION_EXPIRED.set(false);
            continue;
        }
        let resumed = if scenario == "connect"
            && std::env::var_os("ARKDECK_RESUME_CRASH_CHILD").is_none()
        {
            std::thread::scope(|scope| {
                let mut handles = Vec::new();
                for _ in 0..4 {
                    let (
                        agents,
                        targets,
                        jobs,
                        artifacts,
                        dispatch,
                        digest,
                        plugged,
                        observer,
                        params,
                    ) = (
                        &agents, &targets, &jobs, &artifacts, &dispatch, &digest, &plugged,
                        &observer, &params,
                    );
                    handles.push(scope.spawn(move || {
                        let usb = || Ok::<_, String>(plugged.clone());
                        let hdc = HdcComposition {
                            targets,
                            dispatch,
                            receive_root: None,
                            tool_sha256: digest,
                            now: fixed_now,
                            code_sign_helper: None,
                        };
                        let admitter = JobAdmitter {
                            planner: JobPlanner {
                                imports: None,
                                artifacts: Some(artifacts),
                                analyzer: None,
                                state_root: root,
                                hdc: Some(&hdc),
                                workspace: None,
                            },
                            jobs,
                            now: fixed_now,
                            authority: None,
                        };
                        let engine = AgentEngine {
                            targets,
                            jobs,
                            admitter: &admitter,
                            now: fixed_precise_now,
                            observations: Some(Observing {
                                owner: observer,
                                sources: Sources {
                                    dispatch,
                                    relations: &usb,
                                    targets,
                                    now: &|| fixed_now().unwrap(),
                                },
                            }),
                        };
                        agents
                            .advance("human-action.resume", params.as_object().unwrap(), &engine)
                            .unwrap()
                    }));
                }
                let answers: Vec<_> = handles.into_iter().map(|h| h.join().unwrap()).collect();
                assert_eq!(answers.iter().filter(|a| a.start.is_some()).count(), 1);
                assert!(
                    answers
                        .iter()
                        .all(|a| a.value["jobId"] == answers[0].value["jobId"])
                );
                answers.into_iter().find(|a| a.start.is_some()).unwrap()
            })
        } else {
            agents
                .advance("human-action.resume", params.as_object().unwrap(), engine)
                .unwrap()
        };
        assert_eq!(resumed.value["state"], "jobOwned", "{scenario}");
        assert!(resumed.start.is_some());
        if scenario == "select" {
            let mut changed = params.clone();
            changed["selection"] = waiting["humanAction"]["selectionSchema"]["enum"][1].clone();
            assert_eq!(
                agents
                    .advance("human-action.resume", changed.as_object().unwrap(), engine)
                    .err()
                    .unwrap()
                    .code,
                "idempotencyConflict"
            );
        }
        let before = fake.read_log().unwrap();
        let repeated = agents
            .advance("human-action.resume", params.as_object().unwrap(), engine)
            .unwrap();
        assert!(repeated.start.is_none());
        assert_eq!(repeated.value["jobId"], resumed.value["jobId"]);
        assert_eq!(fake.read_log().unwrap(), before);
        let rerun = agents.advance("agent.run", &request, engine).unwrap();
        assert_eq!(rerun.value["jobId"], resumed.value["jobId"]);
        let record: Value = serde_json::from_slice(
            &fs::read(
                root.join("agent-executions")
                    .join(execution_file("har-connect")),
            )
            .unwrap(),
        )
        .unwrap();
        assert_eq!(
            record["actions"].as_array().unwrap().last().unwrap()["status"],
            "resolvedByFreshProbe"
        );
        assert_eq!(record["createdAt"], "2026-09-14T00:00:00.000Z");
    }
}

#[test]
fn resolved_resume_commit_gap_preserves_status_then_run_continuation() {
    use arkdeck_hoststore::HdcComposition;
    for expired in [false, true] {
        let root = fresh_root();
        let mut child = std::process::Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "physical_resume_keeps_original_intent_and_unique_job",
                "--nocapture",
            ])
            .env("ARKDECK_RESUME_CRASH_CHILD", "1")
            .env(ROOT, &root)
            .spawn()
            .unwrap();
        assert_eq!(child.wait().unwrap().code(), Some(79));
        let state = State(root);
        let root = &state.0;
        let target_path = root.join("targets-state/targets.json");
        let target_before: Value =
            serde_json::from_slice(&fs::read(&target_path).unwrap()).unwrap();
        assert_eq!(target_before["targets"].as_array().unwrap().len(), 1);
        let record_path = fs::read_dir(root.join("agent-executions"))
            .unwrap()
            .map(|entry| entry.unwrap().path())
            .find(|path| {
                path.file_name()
                    .unwrap()
                    .to_str()
                    .unwrap()
                    .starts_with("execution-")
            })
            .unwrap();
        let before: Value = serde_json::from_slice(&fs::read(&record_path).unwrap()).unwrap();
        assert_eq!(before["state"], "orchestrating");
        assert!(before.get("target").is_some());
        assert_eq!(before["actions"][0]["status"], "resolvedByFreshProbe");
        assert!(before.get("jobID").is_none());
        assert_eq!(before["deadline"], "2026-09-14T00:05:00.000Z");
        let fixture = fixture();
        let cases: Value =
            serde_json::from_slice(&fs::read(fixture.join("cases.json")).unwrap()).unwrap();
        let exchanges = cases["exchanges"].as_array().unwrap();
        let request = exchanges
            .iter()
            .find(|v| v["name"] == "connect.run")
            .unwrap()["params"]
            .as_object()
            .unwrap();
        let plugged = relations(
            &exchanges
                .iter()
                .find(|v| v["name"] == "connect.resume")
                .unwrap()["usbRelations"],
        );
        let fake = FakeHdc::new("normal");
        fake.set_mode("normal\n").unwrap();
        // New owners and a new observation source: no in-memory receipt from
        // the exited process is available to make this retry pass.
        let targets = TargetStore::open(&root.join("targets-state")).unwrap();
        let artifacts = ArtifactReadStore::open(&root.join("artifacts")).unwrap();
        let jobs = JobStore::open_owner(&root.join("jobs-state")).unwrap();
        let agents = AgentExecutionStore::open(&root.join("agent-executions")).unwrap();
        let observer = TargetObservations::default();
        let digest = fake.digest.clone();
        let dispatch = fake.clone();
        let hdc = HdcComposition {
            targets: &targets,
            dispatch: &dispatch,
            receive_root: None,
            tool_sha256: &digest,
            now: fixed_now,
            code_sign_helper: None,
        };
        let admitter = JobAdmitter {
            planner: JobPlanner {
                imports: None,
                artifacts: Some(&artifacts),
                analyzer: None,
                state_root: root,
                hdc: Some(&hdc),
                workspace: None,
            },
            jobs: &jobs,
            now: fixed_now,
            authority: None,
        };
        let usb = || Ok::<_, String>(plugged.clone());
        let clock = || "2026-09-14T00:00:00Z".to_owned();
        let engine = AgentEngine {
            targets: &targets,
            jobs: &jobs,
            admitter: &admitter,
            now: adoption_now,
            observations: Some(Observing {
                owner: &observer,
                sources: Sources {
                    dispatch: &dispatch,
                    relations: &usb,
                    targets: &targets,
                    now: &clock,
                },
            }),
        };
        let resume = json!({"resumeReference":before["actions"][0]["resumeReference"]});
        let repeated = agents
            .advance("agent.resume", resume.as_object().unwrap(), &engine)
            .unwrap();
        assert_eq!(repeated.value["state"], "orchestrating");
        assert!(repeated.start.is_none());
        assert!(fake.read_log().unwrap().is_empty());
        ADOPTION_EXPIRED.set(expired);
        let outcome = agents.advance("agent.run", request, &engine);
        if expired {
            let error = outcome.err().expect("original deadline must refuse retry");
            assert_eq!(error.code, "orchestrationBudgetExpired");
            assert!(fake.read_log().unwrap().is_empty());
        } else {
            let answer = outcome.unwrap();
            let job = answer.start.expect("one newly admitted Job").job;
            assert_eq!(
                answer.value["targetId"],
                target_before["targets"][0]["targetID"]
            );
            let calls = fake.read_log().unwrap();
            let retry = agents.advance("agent.run", request, &engine).unwrap();
            assert_eq!(retry.value["jobId"], job);
            assert!(retry.start.is_none());
            assert_eq!(fake.read_log().unwrap(), calls);
        }
        let after: Value = serde_json::from_slice(&fs::read(&record_path).unwrap()).unwrap();
        assert_eq!(after["createdAt"], before["createdAt"]);
        assert_eq!(after["deadline"], before["deadline"]);
        let target_after: Value = serde_json::from_slice(&fs::read(target_path).unwrap()).unwrap();
        assert_eq!(target_after, target_before);
        let inventory = jobs.handle_resource("job.list", &Map::new()).unwrap();
        assert_eq!(
            inventory["items"].as_array().unwrap().len(),
            if expired { 0 } else { 1 }
        );
        ADOPTION_EXPIRED.set(false);
    }
}
