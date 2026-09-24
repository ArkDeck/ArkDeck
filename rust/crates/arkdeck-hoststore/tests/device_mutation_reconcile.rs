//! Replays the Swift oracle of the reconcile and resume of parked device
//! mutations (`rust/tests/fixtures/device-mutation-reconcile`, recorded by
//! `DeviceMutationReconcileOracleContractTests`) through the Rust admitter,
//! runner, recovery, reconciler, cleanup debt continuation and readers over
//! the shared fake HDC, composed as the standalone daemon composes them,
//! scenario by scenario and step by step:
//! - `portRule`: a create whose `fport` dies after writing the rule parks;
//!   reconcile reads it back and confirms it completed; a start carries the
//!   confirmed boundary; `job.run` resumes the Job there — the journal's
//!   confirmed steps skipped, the rule read back once more — and settles its
//!   use, so the next create is admitted and runs;
//! - `debugHap`: an install killed before it installs is read back absent,
//!   confirmed not executed, and the Job's failure finalization removes its
//!   staging under the use it consumed; a Job parked on its read-only HiLog
//!   capture is confirmed not executed and every declared compensation runs;
//!   an install killed after it installs is read back present, and the
//!   resumed Job starts, observes, stops, uninstalls and cleans up under its
//!   use, consuming no second one;
//! - `nativeLibrary`: a publish killed after it published is read back as
//!   the new library and the resumed Job restarts, verifies and cleans up;
//!   one killed before is read back as the old library, which a publish never
//!   proves not executed, so the Job stays parked, `job.run` refuses it and
//!   its lineage refuses the next request;
//! - `screenSequence`: a receive killed is read-only and confirmed not
//!   executed; a capture parked on its missing archive is where this Runtime
//!   declares a difference: Swift's materialization does not know its kind,
//!   so its reconcile fails and leaves the Journal `reconciling` and the
//!   record resident ahead of its file, while the Rust reconcile reads the
//!   capture back (`ls -ld` of its archive and frames directory), finds its
//!   frames without their archive and keeps it parked, resending nothing —
//!   the frames those answers alone name are marked as declared differences
//!   below, and the Rust-only scenarios after them conclude a capture or a
//!   cleanup the probes do settle;
//! - `captureFileLegs`: a component tree capture killed before writing reads
//!   back absent, one killed after reads back present and is resumed through
//!   its receive and cleanup, and a refused cleanup's debt is continued.
//!
//! Every answer, every snapshot the oracle took (Job index and files,
//! capability store, the fake's calls so far) and everything the replay
//! leaves must be Swift's byte for byte, once each Job record's volume,
//! device, inode and claim generation are read as labels.
//!
//! Three scenarios start from a daemon that died mid-run, which a child of
//! this test binary reproduces by exiting where Swift's oracle copied its
//! root: `tapBeforeConsume` and `tapAfterConsume` (an `input.tap@1` that
//! dies before its capability is consumed, or once the use and its evidence
//! are durable and before the gesture's intent), resumed from `running` by
//! `job.run` — the first consuming its use, the second continuing under the
//! one it holds — and `hapFinalizing` (a debug HAP whose start fails and
//! whose daemon dies as its failure finalization begins), whose finalization
//! `job.run` continues. The runs spawn the fake, so this binary is theirs.
#![cfg(target_os = "macos")]

mod support;

use arkdeck_provider_hdc::{DispatchFailure, HdcDispatch, ProcessPlan, Receipt};
use serde_json::{Map, Value, json};
use std::fs;
use std::path::PathBuf;
use std::sync::OnceLock;
use support::debug_hap;
use support::reconcile::Daemon;

const FIXTURE: &str = "device-mutation-reconcile";

/// One recorded exchange answered by the Rust owner that serves it: a start,
/// a run with the device state it clears first, or any other request.
fn answer(daemon: &mut Daemon, exchange: &Value) -> Value {
    match exchange["method"].as_str().unwrap() {
        "recoverActiveJobs" => json!(daemon.restart().statuses),
        method => {
            if method == "job.run" {
                for state in exchange["cleared"].as_array().into_iter().flatten() {
                    let _ = fs::remove_file(daemon.root.join(state.as_str().unwrap()));
                }
            }
            daemon.answer(&daemon.timed(), exchange)
        }
    }
}

/// Every exchange of the scenario from `first` on, answered in order, each
/// recorded snapshot compared where the oracle took it; the differences.
fn replay_from(daemon: &mut Daemon, scenario: &str, first: usize) -> Vec<String> {
    let cases = support::document(&daemon.fixture, "cases.json");
    let steps: Vec<&str> = cases["steps"]
        .as_array()
        .unwrap()
        .iter()
        .map(|step| step.as_str().unwrap())
        .filter(|step| *step != "crash")
        .collect();
    let mut snapshots = steps.iter().peekable();
    let mut differences = Vec::new();
    for exchange in &cases["exchanges"].as_array().unwrap()[first..] {
        let name = exchange["name"].as_str().unwrap();
        let actual = answer(daemon, exchange);
        if actual != exchange["answer"] {
            differences.push(format!(
                "{scenario} {name}:\n  swift {}\n  rust  {actual}",
                exchange["answer"]
            ));
        }
        // The oracle recorded the store after every step that writes one.
        if snapshots.peek() == Some(&&name) {
            daemon.assert_snapshot(&format!("steps/{name}"));
            snapshots.next();
        }
    }
    assert!(
        snapshots.next().is_none(),
        "{scenario}: every recorded step was replayed"
    );
    differences
}

fn replay(scenario: &str) {
    let _lock = debug_hap::exclusive();
    let mut daemon = Daemon::open(&format!("{FIXTURE}/{scenario}"));
    let differences = replay_from(&mut daemon, scenario, 0);
    assert!(differences.is_empty(), "{}", differences.join("\n"));
    daemon.assert_leftovers();
}

#[test]
fn a_port_rule_confirmed_by_its_readback_is_resumed_as_swift_resumes_it() {
    replay("portRule");
}

#[test]
fn a_debug_hap_is_reconciled_finalized_and_resumed_as_swift_does() {
    replay("debugHap");
}

#[test]
fn a_native_deployment_is_resumed_or_kept_parked_as_swift_decides() {
    replay("nativeLibrary");
}

/// The recorded screen sequence scenario, with the declared difference its
/// parked capture makes. Every exchange and snapshot up to the second start,
/// the receive's reconcile and the reads of that Job are Swift's; for the
/// capture's two reconciles and what they change, [`sequence_declared`]
/// states what the Rust daemon answers instead, and the store is checked
/// against Swift's with the reconcile's decisions in place of its failure.
#[test]
fn a_screen_sequence_is_reconciled_by_its_readbacks_where_swift_cannot() {
    let _lock = debug_hap::exclusive();
    let mut daemon = Daemon::open(&format!("{FIXTURE}/screenSequence"));
    let cases = support::document(&daemon.fixture, "cases.json");
    let job = cases["jobs"]["missingArchive"].as_str().unwrap().to_owned();
    let mut steps = cases["steps"].as_array().unwrap().iter().peekable();
    let (mut parked, mut reconciles) = (Value::Null, 0);
    for exchange in cases["exchanges"].as_array().unwrap() {
        let name = exchange["name"].as_str().unwrap();
        let actual = answer(&mut daemon, exchange);
        match sequence_declared(name, &exchange["answer"], &parked, &job, reconciles) {
            Some(expected) => assert_eq!(actual, expected, "{name} (declared difference)"),
            None => assert_eq!(actual, exchange["answer"], "{name}"),
        }
        // The status the second start answered for the parked capture, which
        // each Rust reconcile of it answers again.
        if name == "secondRestart" {
            parked = actual
                .as_array()
                .unwrap()
                .iter()
                .find(|status| status["jobId"] == job.as_str())
                .unwrap()
                .clone();
        }
        if name.starts_with("reconcileMissingArchive") {
            reconciles += 1;
        }
        if steps.peek().is_some_and(|step| *step == name) {
            if name.starts_with("reconcileMissingArchive") {
                assert_parked_capture(&daemon, &format!("steps/{name}"), &job, reconciles);
            } else {
                daemon.assert_snapshot(&format!("steps/{name}"));
            }
            steps.next();
        }
    }
    assert!(steps.next().is_none(), "every recorded step was replayed");
    // What the replay leaves is Swift's but for the parked capture's record,
    // journal and index row, and the fake's calls, checked as declared.
    daemon.close();
    assert_parked_capture_files(&daemon, None, &job, reconciles);
    assert_eq!(
        daemon.calls(),
        format!(
            "{}{}",
            fs::read_to_string(daemon.fixture.join("hdc-invocations.log")).unwrap(),
            capture_probes(&job).repeat(reconciles)
        ),
        "the fake's calls: Swift's, then the capture's probes of each reconcile"
    );
    assert_eq!(
        fs::read(daemon.root.join("targets-state/targets.json")).unwrap(),
        fs::read(daemon.fixture.join("targets-state/targets.json")).unwrap(),
        "the Target document"
    );
    let directory = daemon.default_root.join("jobs").join(&job);
    let recorded = |name: &str| format!("store/jobs/{job}/{name}");
    let (record, journal) = (recorded("job-record.json"), recorded("journal.jsonl"));
    let rows = support::index(&daemon.default_root);
    support::assert_leftovers_with(
        &daemon.fixture,
        &daemon.root,
        &daemon.default_root,
        // Checked above by `assert_parked_capture_files`.
        |path, bytes| {
            if path == record {
                fs::read(directory.join("job-record.json")).unwrap()
            } else if path == journal {
                fs::read(directory.join("journal.jsonl")).unwrap()
            } else {
                bytes
            }
        },
        |index| {
            let actual = rows["rows"]
                .as_array()
                .unwrap()
                .iter()
                .find(|row| row["jobId"] == job.as_str())
                .unwrap();
            for row in index["rows"].as_array_mut().unwrap() {
                if row["jobId"] == job.as_str() {
                    assert_eq!(
                        actual["version"].as_i64().unwrap(),
                        row["version"].as_i64().unwrap() + i64::try_from(reconciles).unwrap(),
                        "one record write per reconcile"
                    );
                    row["version"] = actual["version"].clone();
                    row["recordSHA256"] = actual["recordSHA256"].clone();
                }
            }
        },
    );
}

// --- declared differences: a parked screen sequence -------------------------

/// Why the Rust reconcile keeps the recorded parked capture parked: the
/// capture ran in part (its frames directory is on the device, its archive
/// is not), which neither completes nor proves it not executed.
fn partial_capture_reason(job: &str) -> String {
    format!(
        "frames directory /data/local/tmp/arkdeck-{job}-capture-screen-sequence-owned-frames \
         remains without its archive \
         /data/local/tmp/arkdeck-{job}-capture-screen-sequence-owned.tar; original not resent"
    )
}

/// The fake's record of the probes one reconcile of a parked capture sends:
/// `ls -ld` of its archive, then of its frames directory.
fn capture_probes(job: &str) -> String {
    let key = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    [
        "capture-screen-sequence-owned.tar",
        "capture-screen-sequence-owned-frames",
    ]
    .iter()
    .map(|owned| {
        ["-t", key, "shell", "ls", "-ld"]
            .iter()
            .map(|part| format!("{part}\u{1f}"))
            .collect::<String>()
            + &format!("/data/local/tmp/arkdeck-{job}-{owned}\u{1f}\n")
    })
    .collect()
}

/// The timeline a reconcile of the parked capture begins with, which Swift
/// journals and keeps resident too before its reconcile fails.
fn began() -> Vec<Value> {
    [
        "waitingForRecovery->reconciling",
        "reason: begin exact typed provider reconciliation",
        "reconcile started capture-screen-sequence",
    ]
    .map(Value::from)
    .to_vec()
}

/// The timeline an inconclusive reconcile of the parked capture ends with —
/// which Swift, whose reconcile fails, never writes.
fn inconclusive(job: &str) -> Vec<Value> {
    let reason = partial_capture_reason(job);
    vec![
        Value::from("reconciling->waitingForRecovery"),
        Value::from(format!(
            "reason: persist exact typed reconcile decision: {reason}"
        )),
        Value::from(format!("reconcile inconclusive: {reason}")),
    ]
}

/// The recorded exchanges whose Swift answer comes from Swift's defect —
/// its materialization does not know `hdc.captureScreenSequence`, so both
/// reconciles fail `internalError` and the engine keeps the Job resident
/// `reconciling` — and what the Rust daemon answers for each instead: the
/// reconcile concludes, inconclusively, so the Job is `waitingForRecovery`
/// again (as the second start answered it) and never runnable; a read of it
/// names that state, and its timeline carries each reconcile's decision.
/// `None` is an exchange the Rust daemon answers as Swift did.
fn sequence_declared(
    name: &str,
    swift: &Value,
    parked: &Value,
    job: &str,
    reconciles: usize,
) -> Option<Value> {
    let mut rust = swift.clone();
    match name {
        "reconcileMissingArchive" | "reconcileMissingArchiveAgain" => {
            assert_eq!(swift["error"]["code"], "internalError");
            assert_eq!(
                swift["error"]["message"],
                "persisted typed provider action kind hdc.captureScreenSequence is unknown"
            );
            return Some(json!({"ok": true, "result": parked}));
        }
        "missingArchive.resume" => {
            rust["error"]["message"] =
                json!(format!("job {job} is waitingForRecovery, not runnable"));
        }
        "missingArchive.job.status" => rust["result"]["state"] = json!("waitingForRecovery"),
        "missingArchive.job.result" => {
            rust["error"]["details"]["state"] = json!("waitingForRecovery");
        }
        "missingArchive.job.show" => {
            rust["result"]["job"]["state"] = json!("waitingForRecovery");
            // Swift's resident record holds the first reconcile's start.
            let entries = rust["result"]["timeline"]["entries"]
                .as_array_mut()
                .unwrap();
            assert_eq!(entries[entries.len() - 3..], began());
            for attempt in 0..reconciles {
                if attempt > 0 {
                    entries.extend(began());
                }
                entries.extend(inconclusive(job));
            }
        }
        _ => return None,
    }
    assert_ne!(&rust, swift, "{name} is declared to differ");
    Some(rust)
}

/// The store at a recorded reconcile of the parked capture: Swift's snapshot
/// but for the parked Job, whose files the reconciles changed as declared,
/// and the capability store Swift's exactly — the use stays `outcomeUnknown`,
/// the lineage blocked.
fn assert_parked_capture(daemon: &Daemon, prefix: &str, job: &str, reconciles: usize) {
    let (actual, recorded) =
        support::assert_store_except(&daemon.fixture, prefix, &daemon.default_root, job);
    assert_eq!(
        actual["version"].as_i64().unwrap(),
        recorded["version"].as_i64().unwrap() + i64::try_from(reconciles).unwrap(),
        "{prefix}: one record write per reconcile"
    );
    daemon.assert_capabilities(prefix);
    assert_parked_capture_files(daemon, Some(prefix), job, reconciles);
    let calls =
        fs::read_to_string(daemon.fixture.join(prefix).join("hdc-invocations.log")).unwrap();
    assert_eq!(
        daemon.calls(),
        format!("{calls}{}", capture_probes(job).repeat(reconciles)),
        "{prefix}: Swift's calls, then the probes; nothing resent"
    );
}

/// The parked capture's journal and record after `reconciles` reconciles,
/// against Swift's at the snapshot `prefix` (or at the end): Swift's journal
/// — which stops at the first reconcile's start — continued by each
/// inconclusive decision (and the second reconcile's start); Swift's last
/// durable record with each reconcile's timeline, still parked on the same
/// intent.
fn assert_parked_capture_files(
    daemon: &Daemon,
    prefix: Option<&str>,
    job: &str,
    reconciles: usize,
) {
    let recorded = match prefix {
        Some(prefix) => daemon.fixture.join(prefix).join("jobs").join(job),
        None => daemon.fixture.join("store/jobs").join(job),
    };
    let actual = daemon.default_root.join("jobs").join(job);
    let swift_journal = fs::read_to_string(recorded.join("journal.jsonl")).unwrap();
    let rust_journal = fs::read_to_string(actual.join("journal.jsonl")).unwrap();
    let appended = rust_journal
        .strip_prefix(&swift_journal)
        .unwrap_or_else(|| panic!("{job}: Swift's journal is not where the Rust one begins"));
    let events: Vec<Value> = appended
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect();
    let mut expected = Vec::new();
    for attempt in 0..reconciles {
        if attempt > 0 {
            expected.extend(["stateTransition", "reconcileStarted"]);
        }
        expected.extend(["reconcileOutcome", "stateTransition"]);
    }
    assert_eq!(
        events
            .iter()
            .map(|event| event["kind"].as_str().unwrap())
            .collect::<Vec<_>>(),
        expected,
        "{job}: the journal after Swift's"
    );
    for outcome in events
        .iter()
        .filter(|event| event["kind"] == "reconcileOutcome")
    {
        assert_eq!(outcome["payload"]["outcomeCertainty"], "outcomeUnknown");
        assert_eq!(outcome["payload"]["nextState"], "waitingForRecovery");
        assert_eq!(
            outcome["payload"]["evidence"],
            json!([partial_capture_reason(job)])
        );
    }
    // No step outcome for the parked intent: nothing was concluded or sent.
    assert!(events.iter().all(|event| event["kind"] != "stepOutcome"));
    let read = |path: &std::path::Path| -> Value {
        serde_json::from_slice(&fs::read(path.join("job-record.json")).unwrap()).unwrap()
    };
    let (mut swift, mut rust) = (read(&recorded), read(&actual));
    let mut timeline = swift["timeline"].as_array().unwrap().clone();
    for _ in 0..reconciles {
        timeline.extend(began());
        timeline.extend(inconclusive(job));
    }
    assert_eq!(rust["timeline"], Value::from(timeline), "{job}: timeline");
    assert_eq!(rust["state"], "waitingForRecovery");
    assert_eq!(rust["outcomeUnknown"], true);
    swift.as_object_mut().unwrap().remove("timeline");
    rust.as_object_mut().unwrap().remove("timeline");
    assert_eq!(rust, swift, "{job}: the record but its timeline");
}

#[test]
fn a_capture_file_leg_is_read_back_resumed_and_its_debt_continued_as_swift_does() {
    replay("captureFileLegs");
}

/// A resumed Job continues only the use the capability store still holds
/// unsettled for it (a stricter check than Swift's, which reads the Job's
/// record alone): with that use settled behind its back, `job.run` of the
/// Job at its confirmed safe boundary is refused with the zero-dispatch
/// proof, and nothing is dispatched or written.
#[test]
fn a_resumed_job_continues_only_the_unsettled_use_it_holds() {
    let _lock = debug_hap::exclusive();
    let mut daemon = Daemon::open(&format!("{FIXTURE}/portRule"));
    let cases = support::document(&daemon.fixture, "cases.json");
    for exchange in cases["exchanges"].as_array().unwrap() {
        let actual = answer(&mut daemon, exchange);
        assert_eq!(actual, exchange["answer"], "{}", exchange["name"]);
        if exchange["name"] == "reconcile" {
            break;
        }
    }
    let job = cases["jobs"]["create"].as_str().unwrap();
    let directory = daemon.default_root.join("jobs").join(job);
    let record: Value =
        serde_json::from_slice(&fs::read(directory.join("job-record.json")).unwrap()).unwrap();
    assert_eq!(record["state"], "resumeAtConfirmedSafeBoundary");
    daemon
        .stores()
        .capabilities
        .record_outcome(
            record["admissionEvidence"]["reference"].as_str().unwrap(),
            record["request"]["idempotencyKey"].as_str().unwrap(),
            job,
            arkdeck_hoststore::CapabilityUseOutcome::Confirmed,
            "succeeded",
            &support::fixed_now().unwrap(),
        )
        .unwrap();
    let files = |name: &str| fs::read(directory.join(name)).unwrap();
    let before = (
        files("job-record.json"),
        files("journal.jsonl"),
        daemon.calls(),
    );
    let params = Map::from_iter([("jobId".into(), json!(job))]);
    assert_eq!(
        daemon.run(&daemon.dispatch, &params, None),
        json!({"ok": false, "error": {"code": "rejected",
            "message": format!(
                "job {job}'s capability use is not an unsettled use the store holds for it; \
                 the Rust Runtime does not continue it and nothing was dispatched"
            ),
            "details": {"jobId": job, "newDispatchCount": 0, "phase": "preAdmission"}}})
    );
    assert_eq!(
        (
            files("job-record.json"),
            files("journal.jsonl"),
            daemon.calls()
        ),
        before
    );
}

// --- Rust only: a parked screen sequence the probes settle -----------------
//
// No Swift oracle can record these (Swift never concludes a parked screen
// sequence): fresh Jobs over the screen sequence scenario's root and fake,
// each parked where a dispatcher loses one invocation's outcome, before or
// after the fake ran it, then started again and reconciled.

/// The fake's dispatch, but that the first invocation `lost` names never
/// reports its outcome: the fake runs it first if `after`, else never.
struct Losing<'a> {
    inner: &'a (dyn HdcDispatch + Sync),
    lost: fn(&[String]) -> bool,
    after: bool,
    done: std::sync::atomic::AtomicBool,
}

impl<'a> Losing<'a> {
    fn new(inner: &'a (dyn HdcDispatch + Sync), lost: fn(&[String]) -> bool, after: bool) -> Self {
        Self {
            inner,
            lost,
            after,
            done: std::sync::atomic::AtomicBool::new(false),
        }
    }
}

impl HdcDispatch for Losing<'_> {
    fn mutation_identity_current(&self) -> bool {
        self.inner.mutation_identity_current()
    }

    fn dispatch(&self, plan: &ProcessPlan) -> Result<Receipt, DispatchFailure> {
        use std::sync::atomic::Ordering;
        if !self.done.load(Ordering::SeqCst) && (self.lost)(&plan.arguments) {
            self.done.store(true, Ordering::SeqCst);
            if self.after {
                let _ = self.inner.dispatch(plan);
            }
            return Err(DispatchFailure::Unobservable(
                "the child's outcome was lost".into(),
            ));
        }
        self.inner.dispatch(plan)
    }
}

/// The shell command an HDC invocation sends (`-t <key> shell <command> …`).
fn command(arguments: &[String]) -> &str {
    arguments.get(3).map_or("", String::as_str)
}

/// A fresh `capture.screen-sequence@1` Job over the recorded request, under
/// its own idempotency key: its identity.
fn submit_sequence(daemon: &Daemon, key: &str) -> String {
    let cases = support::document(&daemon.fixture, "cases.json");
    let recorded = &cases["exchanges"][0];
    assert_eq!(recorded["name"], "receiveKilled.submit");
    let mut request: Value =
        serde_json::from_str(recorded["params"]["requestJson"].as_str().unwrap()).unwrap();
    request["idempotencyKey"] = json!(format!("idem-rust-{key}"));
    request["requestId"] = json!(format!("req-rust-{key}"));
    let submitted = daemon.answer(
        &daemon.timed(),
        &json!({"name": key, "method": "job.submit",
            "params": {"requestJson": request.to_string()}}),
    );
    assert_eq!(submitted["ok"], true, "{submitted}");
    submitted["result"]["jobId"].as_str().unwrap().to_owned()
}

fn read(daemon: &Daemon, method: &str, job: &str) -> Value {
    daemon.answer(
        &daemon.timed(),
        &json!({"name": method, "method": method, "params": {"jobId": job}}),
    )
}

fn params(job: &str) -> Map<String, Value> {
    Map::from_iter([("jobId".into(), json!(job))])
}

/// Whether the Target's automatic capability lineage admits a new mutation.
fn lineage_open(daemon: &Daemon) -> bool {
    let listed = daemon.answer(
        &daemon.timed(),
        &json!({"name": "list", "method": "capability.list", "params": {}}),
    );
    listed["result"][0]["lineageAllowsNewExecution"] == true
}

/// The fake's calls after the first `mark`, each as one line of its words.
fn calls_after(daemon: &Daemon, mark: usize) -> Vec<String> {
    daemon
        .calls()
        .lines()
        .skip(mark)
        .map(|line| line.trim_end_matches('\u{1f}').replace('\u{1f}', " "))
        .collect()
}

/// A fresh Job run until the dispatcher loses the outcome it names, which
/// parks it; the daemon then started again. Its identity, and how many calls
/// the fake had received by then.
fn park_sequence(
    daemon: &mut Daemon,
    key: &str,
    lost: fn(&[String]) -> bool,
    after: bool,
) -> (String, usize) {
    let job = submit_sequence(daemon, key);
    {
        let timed = daemon.timed();
        let losing = Losing::new(&timed, lost, after);
        let ran = daemon.run(&losing, &params(&job), None);
        assert_eq!(ran["result"]["state"], "waitingForRecovery", "{ran}");
        assert_eq!(ran["result"]["outcomeUnknown"], true);
    }
    daemon.restart();
    assert!(
        !lineage_open(daemon),
        "an unknown outcome blocks the lineage"
    );
    let mark = daemon.calls().lines().count();
    (job, mark)
}

/// The recorded fake answers `ls -ld` for a directory only, all the recorded
/// scenario probed; a device lists a regular file too, which the probe of a
/// capture's archive reads. Scenarios that leave an archive on the device
/// answer it as a device does.
fn list_files_too(daemon: &Daemon) {
    let path = daemon.root.join("hdc-answers.sh");
    let answers = fs::read_to_string(&path).unwrap();
    let directory = r#"    printf '%s 2 shell shell 3452 2026-09-14 00:00 %s\n' drwxrwxrwx "$6"
"#;
    let file = r#"  elif [ -f "$(device "$6")" ]; then
    printf '%s 1 shell shell %s 2026-09-14 00:00 %s\n' -rw-rw-rw- \
      "$(($(wc -c < "$(device "$6")")))" "$6"
"#;
    assert_eq!(answers.matches(directory).count(), 1, "the fake's ls -ld");
    fs::write(
        &path,
        answers.replace(directory, &format!("{directory}{file}")),
    )
    .unwrap();
}

fn frames(job: &str) -> String {
    format!("/data/local/tmp/arkdeck-{job}-capture-screen-sequence-owned-frames")
}

fn archive(job: &str) -> String {
    format!("/data/local/tmp/arkdeck-{job}-capture-screen-sequence-owned.tar")
}

fn probe(path: &str) -> String {
    format!("-t aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa shell ls -ld {path}")
}

/// A capture whose `tar` wrote the archive but whose outcome was lost is
/// read back complete (its archive there): it waits at its confirmed safe
/// boundary, still holding its use, and `job.run` resumes it — nothing of
/// the capture sent again — to receive, clean up and finish, which settles
/// the use.
#[test]
fn a_screen_sequence_capture_read_back_complete_is_resumed_to_its_end() {
    let _lock = debug_hap::exclusive();
    let mut daemon = Daemon::open(&format!("{FIXTURE}/screenSequence"));
    list_files_too(&daemon);
    let (job, mark) = park_sequence(
        &mut daemon,
        "captureLostAfterTar",
        |arguments| command(arguments) == "tar",
        true,
    );
    let reconciled = daemon.reconcile(Some(&daemon.timed()), &params(&job));
    assert_eq!(
        reconciled["result"]["state"], "resumeAtConfirmedSafeBoundary",
        "{reconciled}"
    );
    assert_eq!(reconciled["result"]["outcomeUnknown"], false);
    assert_eq!(
        calls_after(&daemon, mark),
        [probe(&archive(&job)), probe(&frames(&job))]
    );
    // A confirmed completion records no outcome: the use waits for the run.
    assert!(!lineage_open(&daemon));
    let resumed = daemon.run(&daemon.timed(), &params(&job), None);
    assert_eq!(resumed["result"]["state"], "succeeded", "{resumed}");
    let landing = format!("/private/tmp/arkdeck-hdc-oracle/receive/{}", {
        let archive = archive(&job);
        archive.rsplit('/').next().unwrap().to_owned()
    });
    let key = "-t aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa shell";
    assert_eq!(
        calls_after(&daemon, mark + 2),
        [
            format!(
                "-t aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa file recv {} {landing}",
                archive(&job)
            ),
            format!(
                "{key} rm -f {0}/0001.jpeg {0}/0002.jpeg {0}/0003.jpeg",
                frames(&job)
            ),
            format!("{key} rm -f {}", archive(&job)),
            format!("{key} rmdir {}", frames(&job)),
            probe(&frames(&job)),
        ],
        "the resume receives and cleans up, and sends nothing of the capture again"
    );
    let result = read(&daemon, "job.result", &job);
    let names: Vec<&str> = result["result"]["artifacts"]
        .as_array()
        .unwrap()
        .iter()
        .map(|artifact| artifact["name"].as_str().unwrap())
        .collect();
    assert!(names.contains(&"frames.tar"), "{result}");
    assert!(names.contains(&"sequence.json"), "{result}");
    assert!(lineage_open(&daemon), "the resumed run settled its use");
    let device = daemon.root.join("device-tmp");
    assert!(
        !device
            .join(frames(&job).trim_start_matches("/data/local/tmp/"))
            .exists()
    );
    assert!(
        !device
            .join(archive(&job).trim_start_matches("/data/local/tmp/"))
            .exists()
    );
}

/// A capture lost before anything reached the device is read back as
/// nothing there: confirmed not executed, the Job fails, its use resolved
/// `safeToReflash`, and the lineage admits the next request.
#[test]
fn a_screen_sequence_capture_that_left_nothing_is_confirmed_not_executed() {
    let _lock = debug_hap::exclusive();
    let mut daemon = Daemon::open(&format!("{FIXTURE}/screenSequence"));
    let (job, mark) = park_sequence(
        &mut daemon,
        "captureLostBeforeMkdir",
        |arguments| command(arguments) == "mkdir",
        false,
    );
    let reconciled = daemon.reconcile(Some(&daemon.timed()), &params(&job));
    assert_eq!(reconciled["result"]["state"], "failed", "{reconciled}");
    assert_eq!(
        reconciled["result"]["failure"]["code"],
        "executionConfirmedNotPerformed"
    );
    assert_eq!(
        calls_after(&daemon, mark),
        [probe(&archive(&job)), probe(&frames(&job))],
        "two probes, nothing resent"
    );
    assert!(lineage_open(&daemon), "the use resolved safeToReflash");
    let run = daemon.run(&daemon.timed(), &params(&job), None);
    assert_eq!(run["error"]["code"], "resourceConflict", "{run}");
    assert_eq!(calls_after(&daemon, mark).len(), 2);
}

/// A cleanup lost after its `rmdir` is read back done (the frames directory
/// gone) and resumed to its end; one lost before its first `rm` is read back
/// not done (the directory there) and fails, never sent again.
#[test]
fn a_screen_sequence_cleanup_is_concluded_by_its_frames_directory() {
    let _lock = debug_hap::exclusive();
    let mut daemon = Daemon::open(&format!("{FIXTURE}/screenSequence"));
    let (done, mark) = park_sequence(
        &mut daemon,
        "cleanupLostAfterRmdir",
        |arguments| command(arguments) == "rmdir",
        true,
    );
    let reconciled = daemon.reconcile(Some(&daemon.timed()), &params(&done));
    assert_eq!(
        reconciled["result"]["state"], "resumeAtConfirmedSafeBoundary",
        "{reconciled}"
    );
    assert_eq!(calls_after(&daemon, mark), [probe(&frames(&done))]);
    let resumed = daemon.run(&daemon.timed(), &params(&done), None);
    assert_eq!(resumed["result"]["state"], "succeeded", "{resumed}");
    assert_eq!(
        calls_after(&daemon, mark).len(),
        1,
        "the resume sends nothing: every device step is confirmed"
    );
    // What the capture measured before the cleanup parked is kept.
    let shown = read(&daemon, "job.show", &done);
    assert_eq!(
        shown["result"]["screenSequence"],
        json!({"capturedFrameCount": 3, "frameDurationsSeconds": [0.5, 0.5, 0.5],
            "requestedFrameCount": 3})
    );
    assert!(lineage_open(&daemon));

    let (left, mark) = park_sequence(
        &mut daemon,
        "cleanupLostBeforeRm",
        |arguments| command(arguments) == "rm",
        false,
    );
    let reconciled = daemon.reconcile(Some(&daemon.timed()), &params(&left));
    assert_eq!(reconciled["result"]["state"], "failed", "{reconciled}");
    assert_eq!(
        reconciled["result"]["failure"]["code"],
        "executionConfirmedNotPerformed"
    );
    assert_eq!(calls_after(&daemon, mark), [probe(&frames(&left))]);
    assert!(lineage_open(&daemon), "the use resolved safeToReflash");
    let device = daemon.root.join("device-tmp");
    assert!(
        device
            .join(frames(&left).trim_start_matches("/data/local/tmp/"))
            .join("0001.jpeg")
            .exists(),
        "a cleanup never sent left the frames"
    );
}

// --- Rust only: a JPEG still's receive and cleanup -------------------------
//
// Swift rebuilds a persisted receive or cleanup of a still with its default
// PNG suffix, so a JPEG still's is refused ("remote path does not match its
// owned components"): its reconcile fails and its cleanup debt can never be
// continued. The Rust materialization reads the still's own suffix (a
// declared difference), shown here over the capture file legs scenario's
// root and fake, taught to write a JPEG still as a device does.

/// The capture file legs scenario's fake, answering `snapshot_display` as
/// the file legs oracle's fake does.
fn stills_too(daemon: &Daemon) {
    let path = daemon.root.join("hdc-answers.sh");
    let answers = fs::read_to_string(&path).unwrap();
    let fallback = "*)\n  printf 'unregistered fixture output\\n' >&2\n";
    let still = r#""-t $key shell snapshot_display -t "*)
  printf '\377\330\377\340JFIF still' > "$(device "$8")"
  printf 'process: display 0, file type: %s, width: 720, height: 1280\n' "$6" ;;
"#;
    assert_eq!(answers.matches(fallback).count(), 1, "the fake's fallback");
    fs::write(
        &path,
        answers.replace(fallback, &format!("{still}{fallback}")),
    )
    .unwrap();
}

/// A fresh `capture.diagnostics@1` Job taking one JPEG still, under its own
/// idempotency key: its identity.
fn submit_still(daemon: &Daemon, key: &str) -> String {
    let cases = support::document(&daemon.fixture, "cases.json");
    let recorded = &cases["exchanges"][0];
    assert_eq!(recorded["name"], "treeKilledBefore.submit");
    let mut request: Value =
        serde_json::from_str(recorded["params"]["requestJson"].as_str().unwrap()).unwrap();
    request["idempotencyKey"] = json!(format!("idem-rust-{key}"));
    request["requestId"] = json!(format!("req-rust-{key}"));
    request["inputs"] = json!({"captureHilog": false, "durationSeconds": 5,
        "screenshotImageType": "jpeg", "uiDump": false, "uiScreenshot": true});
    let submitted = daemon.answer(
        &daemon.timed(),
        &json!({"name": key, "method": "job.submit",
            "params": {"requestJson": request.to_string()}}),
    );
    assert_eq!(submitted["ok"], true, "{submitted}");
    submitted["result"]["jobId"].as_str().unwrap().to_owned()
}

/// A JPEG still Job run until the dispatcher loses the outcome it names,
/// which parks it; the daemon then started again. Its identity, and how
/// many calls the fake had received by then.
fn park_still(
    daemon: &mut Daemon,
    key: &str,
    lost: fn(&[String]) -> bool,
    after: bool,
) -> (String, usize) {
    let job = submit_still(daemon, key);
    {
        let timed = daemon.timed();
        let losing = Losing::new(&timed, lost, after);
        let ran = daemon.run(&losing, &params(&job), None);
        assert_eq!(ran["result"]["state"], "waitingForRecovery", "{ran}");
    }
    daemon.restart();
    let mark = daemon.calls().lines().count();
    (job, mark)
}

fn still(job: &str) -> String {
    format!("/data/local/tmp/arkdeck-{job}-capture-screenshot-owned.jpeg")
}

/// A JPEG still's refused cleanup owes a debt that `cleanupDebt.continue`
/// reads back (the still there) and retries once, settling it; a receive of
/// one whose outcome was lost is reconciled not executed, as any read is; a
/// cleanup of one whose outcome was lost after it removed the still is read
/// back done and resumed to its end. Swift refuses every one of these.
#[test]
fn a_jpeg_still_is_reconciled_and_its_cleanup_debt_continued() {
    let _lock = debug_hap::exclusive();
    let mut daemon = Daemon::open(&format!("{FIXTURE}/captureFileLegs"));
    stills_too(&daemon);

    let owing = submit_still(&daemon, "stillCleanupRefused");
    daemon.mode("cleanupRefused");
    let ran = daemon.run(&daemon.timed(), &params(&owing), None);
    daemon.mode("normal");
    assert_eq!(ran["result"]["state"], "succeeded", "{ran}");
    let listed = daemon.answer(
        &daemon.timed(),
        &json!({"name": "debts", "method": "cleanupDebt.list", "params": {}}),
    );
    let debts = listed["result"].as_array().unwrap();
    assert_eq!(debts.len(), 1, "{listed}");
    assert_eq!(debts[0]["identity"], still(&owing).as_str());
    let mark = daemon.calls().lines().count();
    let continued = daemon.continue_debt(
        &daemon.timed(),
        &Map::from_iter([
            ("jobId".into(), json!(owing)),
            ("remotePath".into(), json!(still(&owing))),
        ]),
    );
    assert_eq!(
        continued,
        json!({"ok": true, "result": {"jobId": owing, "identity": still(&owing),
            "state": "settled", "detail": "exact typed cleanup completed"}})
    );
    assert_eq!(
        calls_after(&daemon, mark),
        [
            probe(&still(&owing)),
            format!(
                "-t aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa shell rm -f {}",
                still(&owing)
            ),
        ],
        "the still read back, then its cleanup retried once"
    );
    let listed = daemon.answer(
        &daemon.timed(),
        &json!({"name": "debts", "method": "cleanupDebt.list", "params": {}}),
    );
    assert_eq!(listed["result"], json!([]));

    let (receiving, mark) = park_still(
        &mut daemon,
        "stillReceiveLost",
        |arguments| command(arguments) == "recv",
        true,
    );
    let reconciled = daemon.reconcile(Some(&daemon.timed()), &params(&receiving));
    assert_eq!(reconciled["result"]["state"], "failed", "{reconciled}");
    assert_eq!(
        reconciled["result"]["failure"]["code"],
        "executionConfirmedNotPerformed"
    );
    assert!(
        calls_after(&daemon, mark).is_empty(),
        "a read is concluded without a dispatch"
    );

    let (cleaning, mark) = park_still(
        &mut daemon,
        "stillCleanupLostAfterRm",
        |arguments| command(arguments) == "rm",
        true,
    );
    let reconciled = daemon.reconcile(Some(&daemon.timed()), &params(&cleaning));
    assert_eq!(
        reconciled["result"]["state"], "resumeAtConfirmedSafeBoundary",
        "{reconciled}"
    );
    assert_eq!(calls_after(&daemon, mark), [probe(&still(&cleaning))]);
    let resumed = daemon.run(&daemon.timed(), &params(&cleaning), None);
    assert_eq!(resumed["result"]["state"], "succeeded", "{resumed}");
    assert_eq!(calls_after(&daemon, mark).len(), 1, "nothing sent again");
}

// --- the scenarios whose daemon died mid-run -------------------------------

/// Each crashed scenario: the mode its Job ran in, and the exit code of the
/// child that dies at its window.
const CRASHES: [(&str, &str, i32); 3] = [
    ("tapBeforeConsume", "normal", 91),
    ("tapAfterConsume", "normal", 92),
    ("hapFinalizing", "startFailed", 93),
];
const CHILD: &str = "ARKDECK_DEVICE_MUTATION_CRASH_CHILD";

fn crash(scenario: &str) -> (&'static str, &'static str, i32) {
    *CRASHES
        .iter()
        .find(|(name, _, _)| *name == scenario)
        .unwrap()
}

/// The fake's dispatcher, which dies where Swift's `beforeConsume` window
/// copied the root: at the tool identity check that opens the consume, once
/// the last evidence step's outcome is durable.
struct Dying<'a> {
    inner: &'a (dyn HdcDispatch + Sync),
    before_consume: bool,
    journal: PathBuf,
}

impl HdcDispatch for Dying<'_> {
    fn mutation_identity_current(&self) -> bool {
        if self.before_consume
            && fs::read_to_string(&self.journal)
                .is_ok_and(|journal| journal.contains("\"outcome-read-evidence-firmware\""))
        {
            std::process::exit(crash("tapBeforeConsume").2);
        }
        self.inner.mutation_identity_current()
    }

    fn dispatch(&self, plan: &ProcessPlan) -> Result<Receipt, DispatchFailure> {
        self.inner.dispatch(plan)
    }
}

/// The Job record a dying clock watches, and the window it dies at.
static WATCHED: OnceLock<(PathBuf, &'static str)> = OnceLock::new();

/// The oracle's clock, until the Job record on disk has reached the window:
/// the next read is where the run dies. `tapAfterConsume` dies once the
/// record holds the consumed capability's evidence (the gesture intent's
/// envelope comes next); `hapFinalizing` once the record is `finalizing`
/// with its failure, where Swift's `failureFinalizing` checkpoint sits.
fn dying_clock() -> Option<String> {
    if let Some((record, scenario)) = WATCHED.get()
        && let Ok(text) = fs::read_to_string(record)
    {
        let reached = match *scenario {
            "tapAfterConsume" => text.contains("\"runtimeCapability\""),
            _ => serde_json::from_str::<Value>(&text)
                .is_ok_and(|record| record["state"] == "finalizing"),
        };
        if reached {
            std::process::exit(crash(scenario).2);
        }
    }
    support::fixed_now()
}

/// The Rust daemon's run of a crashed scenario's Job, dying at its window.
/// Run only as the child of the test below.
#[test]
fn device_mutation_crash_child() {
    let Ok(scenario) = std::env::var(CHILD) else {
        return;
    };
    let (scenario, mode, _) = crash(&scenario);
    let daemon = Daemon::open(&format!("{FIXTURE}/{scenario}"));
    let cases = support::document(&daemon.fixture, "cases.json");
    let submit = &cases["exchanges"][0];
    assert_eq!(
        daemon.answer(&daemon.dispatch, submit),
        submit["answer"],
        "{scenario}: {}",
        submit["name"]
    );
    let job = cases["jobs"]
        .as_object()
        .unwrap()
        .values()
        .find(|job| submit["answer"]["result"]["jobId"] == **job)
        .unwrap()
        .as_str()
        .unwrap()
        .to_owned();
    let jobs = daemon.default_root.join("jobs").join(&job);
    let dying = Dying {
        inner: &daemon.dispatch,
        before_consume: scenario == "tapBeforeConsume",
        journal: jobs.join("journal.jsonl"),
    };
    let now: fn() -> Option<String> = if scenario == "tapBeforeConsume" {
        support::fixed_now
    } else {
        WATCHED
            .set((jobs.join("job-record.json"), scenario))
            .unwrap();
        dying_clock
    };
    daemon.mode(mode);
    let params = Map::from_iter([("jobId".into(), json!(job))]);
    let ran = daemon.run_on(&dying, &params, None, now);
    panic!("{scenario}: the run ended without reaching its window: {ran}");
}

/// A crashed scenario: the child dies at the window, the store it left must
/// be Swift's at its death, and every exchange after the submission is
/// answered as Swift answered it — the start first, then the run that
/// resumes or continues the Job.
fn replay_crash(scenario: &str) {
    let _lock = debug_hap::exclusive();
    let (_, _, code) = crash(scenario);
    let output = std::process::Command::new(std::env::current_exe().unwrap())
        .args(["--exact", "device_mutation_crash_child", "--nocapture"])
        .env(CHILD, scenario)
        .output()
        .unwrap();
    assert_eq!(
        output.status.code(),
        Some(code),
        "{scenario}: {}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    let mut daemon = Daemon::attach(&format!("{FIXTURE}/{scenario}"));
    daemon.mode("normal");
    daemon.assert_snapshot("steps/crash");
    let differences = replay_from(&mut daemon, scenario, 1);
    assert!(differences.is_empty(), "{}", differences.join("\n"));
    daemon.assert_leftovers();
}

#[test]
fn a_tap_that_died_before_its_consume_is_resumed_and_consumes_its_use_once() {
    replay_crash("tapBeforeConsume");
}

#[test]
fn a_tap_that_died_after_its_consume_is_resumed_under_the_use_it_holds() {
    replay_crash("tapAfterConsume");
}

#[test]
fn a_debug_hap_failure_finalization_a_restart_left_is_continued_by_its_run() {
    replay_crash("hapFinalizing");
}
