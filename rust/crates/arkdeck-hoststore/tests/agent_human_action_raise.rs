//! The Rust agent execution owner raising Swift's physical-assistance
//! actions over the shared fake HDC: the part of Swift's physical-assistance
//! oracle (`rust/tests/fixtures/agent-human-action`) that needs no adoption,
//! no resume and no Job, replayed in its recorded order. A run that names no
//! target observes the fake's devices through the Target observation owner,
//! between two reads of the USB relations the exchange plugged, and raises
//! what a person must do (connect, trust or pick a device), or is refused
//! when a connected device's physical identity is unproved. The combined
//! human-action owner lists and shows those actions. Every answer is Swift's
//! once the identities the owners mint read as the oracle's labels; the fake
//! receives the oracle's four device lists; the execution records are
//! Swift's up to the observation identities and generations that Swift's
//! skipped resume advanced; and the Target document is untouched.
#![cfg(target_os = "macos")]

mod support;

use arkdeck_contract::{WireError, canonical_json, sha256_hex};
use arkdeck_hoststore::{
    AgentEngine, AgentExecutionStore, ArtifactReadStore, HumanActionResources, JobAdmitter,
    JobPlanner, JobStore, Observing, Sources, TargetObservations, TargetStore,
};
use arkdeck_platform::VerifiedTool;
use arkdeck_provider_hdc::{ProcessDispatch, UsbRelation};
use serde_json::{Map, Value, json};
use std::cell::RefCell;
use std::collections::BTreeMap;
use std::fs::{self, File, OpenOptions};
use std::path::{Path, PathBuf};
use support::{chmod, fixed_now, fixed_precise_now};

/// `HDCOracleFake`'s fixed root and lock, which the fake's driver names.
const ROOT: &str = "/private/tmp/arkdeck-hdc-oracle";
const LOCK: &str = "/private/tmp/arkdeck-hdc-oracle.lock";

/// The oracle's exchanges these owners serve without an adoption, a resume
/// or a Job.
const SERVED: [&str; 19] = [
    "connect.run",
    "connect.rerun",
    "connect.status",
    "connect.list",
    "connect.show",
    "connect.waiting",
    "trust.run",
    "trust.abandonStale",
    "trust.abandon",
    "trust.expired",
    "trust.rerun",
    "ambiguous.run",
    "unproven.run",
    "refuse.listHalfFilter",
    "refuse.listKind",
    "refuse.listPageSize",
    "refuse.listCursor",
    "refuse.showUnknown",
    "refuse.showInvalid",
];

/// The kinds of identity the owners mint, which the oracle labels.
const KINDS: [&str; 4] = ["har", "resume", "candidate", "obs"];

/// Serializes every user of the fake's fixed root, Swift producers included.
fn exclusive() -> File {
    let lock = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .open(LOCK)
        .unwrap();
    lock.lock().unwrap();
    lock
}

/// The fake's root as `HDCOracleFake.install` leaves it.
fn install_fake(fixture: &Path) -> PathBuf {
    let root = PathBuf::from(ROOT);
    let _ = fs::remove_dir_all(&root);
    fs::create_dir(&root).unwrap();
    chmod(&root, 0o700);
    fs::copy(fixture.join("hdc"), root.join("hdc")).unwrap();
    chmod(&root.join("hdc"), 0o700);
    fs::copy(fixture.join("hdc-answers.sh"), root.join("hdc-answers.sh")).unwrap();
    fs::write(root.join("hdc-invocations.log"), b"").unwrap();
    root
}

/// A private state root holding the oracle's Target document, and the empty
/// owners beside it.
struct State(PathBuf);

impl State {
    fn new(fixture: &Path) -> Self {
        let root = std::env::temp_dir()
            .canonicalize()
            .unwrap()
            .join(format!("agent-human-action-raise-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        for directory in [
            "",
            "targets-state",
            "artifacts",
            "jobs-state",
            "agent-executions",
            "human-action-snapshots",
        ] {
            let path = root.join(directory);
            fs::create_dir_all(&path).unwrap();
            chmod(&path, 0o700);
        }
        let targets = root.join("targets-state/targets.json");
        fs::copy(fixture.join("targets-state/targets.json"), &targets).unwrap();
        chmod(&targets, 0o600);
        Self(root)
    }
}

impl Drop for State {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

/// Whether `text` is a lowercase UUID, as Swift spells one.
fn is_uuid(text: &str) -> bool {
    text.len() == 36
        && text.bytes().enumerate().all(|(index, byte)| {
            if [8, 13, 18, 23].contains(&index) {
                byte == b'-'
            } else {
                byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte)
            }
        })
}

/// The oracle's labels for the identities the owners mint: `<har-1>` for the
/// first `har-` identity to appear, and so on for each kind.
#[derive(Default)]
struct Labels {
    labels: BTreeMap<String, String>,
    counts: BTreeMap<&'static str, usize>,
}

impl Labels {
    fn label(&mut self, text: &str) -> String {
        let mut out = String::new();
        let mut at = 0;
        'scan: while at < text.len() {
            for kind in KINDS {
                let start = at + kind.len() + 1;
                if text[at..].starts_with(kind)
                    && text[at + kind.len()..].starts_with('-')
                    && text.get(start..start + 36).is_some_and(is_uuid)
                {
                    let identity = &text[at..start + 36];
                    let label = match self.labels.get(identity) {
                        Some(label) => label.clone(),
                        None => {
                            let count = self.counts.entry(kind).or_default();
                            *count += 1;
                            let label = format!("<{kind}-{count}>");
                            self.labels.insert(identity.to_owned(), label.clone());
                            label
                        }
                    };
                    out.push_str(&label);
                    at = start + 36;
                    continue 'scan;
                }
            }
            let character = text[at..].chars().next().unwrap();
            out.push(character);
            at += character.len_utf8();
        }
        out
    }

    fn identity(&self, text: &str) -> String {
        let mut text = text.to_owned();
        for (identity, label) in &self.labels {
            text = text.replace(label.as_str(), identity);
        }
        text
    }
}

/// An owner's answer as the daemon frames it.
fn framed(answer: Result<Value, WireError>) -> Value {
    match answer {
        Ok(result) => json!({"ok": true, "result": result}),
        Err(error) => {
            let mut failure = Map::from_iter([
                ("code".into(), json!(error.code)),
                ("message".into(), json!(error.message)),
            ]);
            if let Some(details) = error.details {
                failure.insert("details".into(), Value::Object(details));
            }
            json!({"ok": false, "error": failure})
        }
    }
}

/// An observation's identity and generation, read alike: Swift's skipped
/// resume observed twice more, so both moved on there.
fn unnumbered(observation: &mut Value) {
    if let Some(observation) = observation.as_object_mut() {
        observation.insert("observationID".into(), json!("<obs>"));
        observation.insert("generation".into(), json!("<generation>"));
    }
}

/// A record's canonical text with its identities labelled and each
/// observation it names unnumbered.
fn comparable(labels: &mut Labels, bytes: &[u8]) -> Value {
    let mut record: Value =
        serde_json::from_str(&labels.label(std::str::from_utf8(bytes).unwrap())).unwrap();
    for action in record["actions"].as_array_mut().unwrap() {
        if let Some(observation) = action.get_mut("observation") {
            unnumbered(observation);
        }
        for selection in action["selections"].as_array_mut().unwrap() {
            unnumbered(&mut selection["observation"]);
        }
    }
    record
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

#[test]
fn rust_raises_and_reads_the_physical_assistance_swift_asked_for() {
    let _lock = exclusive();
    let fixture = support::fixture("agent-human-action");
    let cases: Value =
        serde_json::from_slice(&fs::read(fixture.join("cases.json")).unwrap()).unwrap();
    let hdc = install_fake(&fixture);
    let state = State::new(&fixture);
    let root = &state.0;
    let targets = TargetStore::open(&root.join("targets-state")).unwrap();
    let artifacts = ArtifactReadStore::open(&root.join("artifacts")).unwrap();
    let jobs = JobStore::open_owner(&root.join("jobs-state")).unwrap();
    let agents = AgentExecutionStore::open(&root.join("agent-executions")).unwrap();
    let resources = HumanActionResources::open(&root.join("human-action-snapshots")).unwrap();
    let admitter = JobAdmitter {
        planner: JobPlanner {
            imports: None,
            artifacts: Some(&artifacts),
            analyzer: None,
            state_root: root,
            hdc: None,
        },
        jobs: &jobs,
        now: fixed_now,
        authority: None,
    };
    let digest = sha256_hex(&fs::read(hdc.join("hdc")).unwrap());
    let dispatch =
        ProcessDispatch::new(VerifiedTool::open(hdc.join("hdc"), &digest).unwrap(), None);
    // What the oracle's harness plugged, until an exchange plugs again.
    let plugged: RefCell<Vec<UsbRelation>> = RefCell::new(Vec::new());
    let usb = || Ok::<_, String>(plugged.borrow().clone());
    let observer = TargetObservations::default();
    let clock = || "2026-09-14T00:00:00Z".to_owned();
    let engine = AgentEngine {
        targets: &targets,
        jobs: &jobs,
        admitter: &admitter,
        now: fixed_precise_now,
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
    let mut labels = Labels::default();
    let mut replayed = 0;
    for exchange in cases["exchanges"].as_array().unwrap() {
        let name = exchange["name"].as_str().unwrap();
        if !SERVED.contains(&name) {
            continue;
        }
        if let Some(mode) = exchange["mode"].as_str() {
            fs::write(hdc.join("hdc-mode"), format!("{mode}\n")).unwrap();
        }
        if let Some(plug) = exchange.get("usbRelations") {
            *plugged.borrow_mut() = relations(plug);
        }
        let method = exchange["method"].as_str().unwrap();
        let params: Value =
            serde_json::from_str(&labels.identity(&exchange["params"].to_string())).unwrap();
        let params = params.as_object().unwrap();
        let answer = if method.starts_with("human-action.") {
            // As the daemon composes it without a managed HDC server: no
            // control action holds an approval.
            resources.answer(method, params, &agents, None)
        } else {
            agents
                .advance(method, params, &engine)
                .map(|answer| answer.value)
        };
        let text = String::from_utf8(canonical_json(&framed(answer)).unwrap()).unwrap();
        let mut answer: Value = serde_json::from_str(&labels.label(&text)).unwrap();
        if let Some(revision) = answer.pointer_mut("/result/snapshotRevision") {
            *revision = json!("<snapshotRevision>");
        }
        assert_eq!(answer, exchange["answer"], "{name}");
        replayed += 1;
    }
    assert_eq!(replayed, SERVED.len());

    // The fake listed the devices once for each run that observed them.
    let recorded = fs::read_to_string(fixture.join("hdc-invocations.log")).unwrap();
    let recorded: Vec<&str> = recorded.lines().collect();
    let expected: String = [0, 10, 11, 12]
        .iter()
        .map(|line| format!("{}\n", recorded[*line]))
        .collect();
    assert_eq!(
        fs::read_to_string(hdc.join("hdc-invocations.log")).unwrap(),
        expected
    );
    // Nothing was adopted.
    assert_eq!(
        fs::read(root.join("targets-state/targets.json")).unwrap(),
        fs::read(fixture.join("targets-state/targets.json")).unwrap()
    );
    for execution in ["har-unproven", "har-trust", "har-ambiguous"] {
        let file = execution_file(execution);
        assert_eq!(
            comparable(
                &mut labels,
                &fs::read(root.join("agent-executions").join(&file)).unwrap()
            ),
            comparable(
                &mut Labels::default(),
                &fs::read(fixture.join("agent-executions").join(&file)).unwrap()
            ),
            "{execution}"
        );
    }
    // Swift resumed this one next; here it still waits, run twice.
    let connect: Value = serde_json::from_slice(
        &fs::read(
            root.join("agent-executions")
                .join(execution_file("har-connect")),
        )
        .unwrap(),
    )
    .unwrap();
    assert_eq!(connect["state"], "waitingForHuman");
    assert_eq!(connect["generation"], 4);
    assert_eq!(connect["actions"].as_array().unwrap().len(), 1);
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
    let _lock = exclusive();
    ADOPTION_EXPIRED.set(false);
    let fixture = support::fixture("agent-human-action");
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
    let fake = install_fake(&fixture);
    fs::write(fake.join("hdc-mode"), "normal\n").unwrap();
    let state = State::new(&fixture);
    let root = &state.0;
    let target_path = root.join("targets-state/targets.json");
    let initial = fs::read(&target_path).unwrap();
    let targets = TargetStore::open(&root.join("targets-state")).unwrap();
    let artifacts = ArtifactReadStore::open(&root.join("artifacts")).unwrap();
    let jobs = JobStore::open_owner(&root.join("jobs-state")).unwrap();
    let agents = AgentExecutionStore::open(&root.join("agent-executions")).unwrap();
    let digest = sha256_hex(&fs::read(fake.join("hdc")).unwrap());
    let dispatch =
        ProcessDispatch::new(VerifiedTool::open(fake.join("hdc"), &digest).unwrap(), None);
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
        let after_calls = fs::read(fake.join("hdc-invocations.log")).unwrap();
        let rerun = agents.advance("agent.run", &request, &engine).unwrap();
        assert_eq!(rerun.value["jobId"], start.job);
        assert!(rerun.start.is_none());
        assert_eq!(
            fs::read(fake.join("hdc-invocations.log")).unwrap(),
            after_calls
        );
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
        use support::OracleProbe;
        let provenance = support::document(&fixture, "provenance.json");
        for name in ["session-owner", "Sessions"] {
            fs::create_dir(root.join(name)).unwrap();
            chmod(&root.join(name), 0o700);
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
        let mut child = std::process::Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "adoption_commit_gap_crash_child",
                "--ignored",
                "--nocapture",
            ])
            .spawn()
            .unwrap();
        let root = std::env::temp_dir()
            .canonicalize()
            .unwrap()
            .join(format!("agent-human-action-raise-{}", child.id()));
        assert_eq!(child.wait().unwrap().code(), Some(79));
        let _lock = exclusive();
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
        let fixture = support::fixture("agent-human-action");
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
        let fake = install_fake(&fixture);
        fs::write(fake.join("hdc-mode"), "normal\n").unwrap();
        // New owners and a new observation source: no in-memory receipt from
        // the exited process is available to make this retry pass.
        let targets = TargetStore::open(&root.join("targets-state")).unwrap();
        let artifacts = ArtifactReadStore::open(&root.join("artifacts")).unwrap();
        let jobs = JobStore::open_owner(&root.join("jobs-state")).unwrap();
        let agents = AgentExecutionStore::open(&root.join("agent-executions")).unwrap();
        let observer = TargetObservations::default();
        let digest = sha256_hex(&fs::read(fake.join("hdc")).unwrap());
        let dispatch =
            ProcessDispatch::new(VerifiedTool::open(fake.join("hdc"), &digest).unwrap(), None);
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
            assert!(
                fs::read(fake.join("hdc-invocations.log"))
                    .unwrap()
                    .is_empty()
            );
        } else {
            let answer = outcome.unwrap();
            let job = answer.start.expect("one newly admitted Job").job;
            assert_eq!(
                answer.value["targetId"],
                target_before["targets"][0]["targetID"]
            );
            let calls = fs::read(fake.join("hdc-invocations.log")).unwrap();
            let retry = agents.advance("agent.run", request, &engine).unwrap();
            assert_eq!(retry.value["jobId"], job);
            assert!(retry.start.is_none());
            assert_eq!(fs::read(fake.join("hdc-invocations.log")).unwrap(), calls);
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
        let _lock = exclusive();
        ADOPTION_EXPIRED.set(false);
        let fixture = support::fixture("agent-human-action");
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
        let fake = install_fake(&fixture);
        fs::write(fake.join("hdc-mode"), "normal\n").unwrap();
        let state = State::new(&fixture);
        let root = &state.0;
        let target_path = root.join("targets-state/targets.json");
        let _initial = fs::read(&target_path).unwrap();
        let targets = TargetStore::open(&root.join("targets-state")).unwrap();
        let artifacts = ArtifactReadStore::open(&root.join("artifacts")).unwrap();
        let jobs = JobStore::open_owner(&root.join("jobs-state")).unwrap();
        let agents = AgentExecutionStore::open(&root.join("agent-executions")).unwrap();
        let digest = sha256_hex(&fs::read(fake.join("hdc")).unwrap());
        let dispatch =
            ProcessDispatch::new(VerifiedTool::open(fake.join("hdc"), &digest).unwrap(), None);
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

        fs::write(
            fake.join("hdc-mode"),
            if scenario == "trust-restart" {
                "unauthorized\n"
            } else if scenario.starts_with("select") {
                "twoDevices\n"
            } else {
                "offline\n"
            },
        )
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
            let before = fs::read(fake.join("hdc-invocations.log")).unwrap();
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
            assert_eq!(fs::read(fake.join("hdc-invocations.log")).unwrap(), before);
            ADOPTION_EXPIRED.set(false);
            RESUME_CLOCK_ROLLBACK.set(false);
            continue;
        }
        fs::write(
            fake.join("hdc-mode"),
            if scenario == "select" {
                "twoDevices\n"
            } else {
                "normal\n"
            },
        )
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
        let before = fs::read(fake.join("hdc-invocations.log")).unwrap();
        let repeated = agents
            .advance("human-action.resume", params.as_object().unwrap(), engine)
            .unwrap();
        assert!(repeated.start.is_none());
        assert_eq!(repeated.value["jobId"], resumed.value["jobId"]);
        assert_eq!(fs::read(fake.join("hdc-invocations.log")).unwrap(), before);
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
        let mut child = std::process::Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "physical_resume_keeps_original_intent_and_unique_job",
                "--nocapture",
            ])
            .env("ARKDECK_RESUME_CRASH_CHILD", "1")
            .spawn()
            .unwrap();
        let root = std::env::temp_dir()
            .canonicalize()
            .unwrap()
            .join(format!("agent-human-action-raise-{}", child.id()));
        assert_eq!(child.wait().unwrap().code(), Some(79));
        let _lock = exclusive();
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
        let fixture = support::fixture("agent-human-action");
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
        let fake = install_fake(&fixture);
        fs::write(fake.join("hdc-mode"), "normal\n").unwrap();
        // New owners and a new observation source: no in-memory receipt from
        // the exited process is available to make this retry pass.
        let targets = TargetStore::open(&root.join("targets-state")).unwrap();
        let artifacts = ArtifactReadStore::open(&root.join("artifacts")).unwrap();
        let jobs = JobStore::open_owner(&root.join("jobs-state")).unwrap();
        let agents = AgentExecutionStore::open(&root.join("agent-executions")).unwrap();
        let observer = TargetObservations::default();
        let digest = sha256_hex(&fs::read(fake.join("hdc")).unwrap());
        let dispatch =
            ProcessDispatch::new(VerifiedTool::open(fake.join("hdc"), &digest).unwrap(), None);
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
        assert!(
            fs::read(fake.join("hdc-invocations.log"))
                .unwrap()
                .is_empty()
        );
        ADOPTION_EXPIRED.set(expired);
        let outcome = agents.advance("agent.run", request, &engine);
        if expired {
            let error = outcome.err().expect("original deadline must refuse retry");
            assert_eq!(error.code, "orchestrationBudgetExpired");
            assert!(
                fs::read(fake.join("hdc-invocations.log"))
                    .unwrap()
                    .is_empty()
            );
        } else {
            let answer = outcome.unwrap();
            let job = answer.start.expect("one newly admitted Job").job;
            assert_eq!(
                answer.value["targetId"],
                target_before["targets"][0]["targetID"]
            );
            let calls = fs::read(fake.join("hdc-invocations.log")).unwrap();
            let retry = agents.advance("agent.run", request, &engine).unwrap();
            assert_eq!(retry.value["jobId"], job);
            assert!(retry.start.is_none());
            assert_eq!(fs::read(fake.join("hdc-invocations.log")).unwrap(), calls);
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
