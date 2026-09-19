//! Replays the Swift `observe.device@1` oracle (`rust/tests/fixtures/observe-device`,
//! produced by `ObserveDeviceOracleContractTests`) against the Rust planner,
//! admitter, runner and result reader over the shared fake HDC: the adopted
//! Target as Swift wrote it, then every recorded request in order, each run
//! while the fake answers in the mode the oracle names. Every answer's code,
//! details and result must be Swift's; a refusal's message is Swift's own
//! wording and is reported, not compared (T2). Each call the fake received
//! and everything the Jobs leave (the Job index and files, every Artifact,
//! every file of the Sessions root and the storage owner, every entry's kind
//! and mode) must be Swift's byte for byte, once each Job record's volume,
//! device, inode and claim generation are read as labels, as is the revision
//! of an `artifact.list` page. The runs spawn the fake, so this binary is
//! theirs.
#![cfg(target_os = "macos")]

mod support;

use arkdeck_contract::sha256_hex;
use arkdeck_hoststore::{
    ArtifactReadStore, HdcComposition, JobAdmitter, JobPlanner, JobResultReader, JobRunner,
    JobStore, SessionPublisher, SessionStore, StorageClaims, TargetStore,
};
use arkdeck_platform::VerifiedTool;
use arkdeck_provider_hdc::ProcessDispatch;
use serde_json::{Map, Value, json};
use std::fs::{self, File, OpenOptions};
use std::path::{Path, PathBuf};
use support::{OracleProbe, chmod, fixed_now, fixed_precise_now};

/// `HDCOracleFake`'s fixed root and lock, which the fake's driver names.
const ROOT: &str = "/private/tmp/arkdeck-hdc-oracle";
const LOCK: &str = "/private/tmp/arkdeck-hdc-oracle.lock";

/// Serializes every user of the fixed root, Swift producers included.
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

/// The root as `HDCOracleFake.install` left it, with the Target document the
/// Swift oracle's adoption wrote.
fn rebuild(fixture: &Path) -> PathBuf {
    let root = PathBuf::from(ROOT);
    let _ = fs::remove_dir_all(&root);
    for directory in [
        root.clone(),
        root.join("targets-state"),
        root.join("artifacts"),
        root.join("jobs-state"),
        root.join("Sessions"),
        root.join("session-owner"),
    ] {
        fs::create_dir(&directory).unwrap();
        chmod(&directory, 0o700);
    }
    fs::copy(fixture.join("hdc"), root.join("hdc")).unwrap();
    chmod(&root.join("hdc"), 0o700);
    fs::copy(fixture.join("hdc-answers.sh"), root.join("hdc-answers.sh")).unwrap();
    fs::write(root.join("hdc-invocations.log"), b"").unwrap();
    fs::copy(
        fixture.join("targets-state/targets.json"),
        root.join("targets-state/targets.json"),
    )
    .unwrap();
    // Owner-only, as the Target owner requires and Swift wrote it; a checkout
    // leaves the fixture group-readable.
    chmod(&root.join("targets-state/targets.json"), 0o600);
    root
}

fn refused(code: &str, message: String, details: Option<Map<String, Value>>) -> Value {
    let mut error = json!({"code": code, "message": message});
    if let Some(details) = details {
        error["details"] = Value::Object(details);
    }
    json!({"ok": false, "error": error})
}

fn proven() -> Map<String, Value> {
    Map::from_iter([
        ("phase".into(), json!("preAdmission")),
        ("newDispatchCount".into(), json!(0)),
    ])
}

/// The answer without a refusal's message, which is Swift's wording (T2).
fn semantic(answer: &Value) -> Value {
    let mut answer = answer.clone();
    if let Some(error) = answer.get_mut("error").and_then(Value::as_object_mut) {
        error.remove("message");
    }
    answer
}

#[test]
fn rust_observes_the_swift_fake_device() {
    let _lock = exclusive();
    let fixture = support::fixture("observe-device");
    let cases = support::document(&fixture, "cases.json");
    let provenance = support::document(&fixture, "provenance.json");
    let root = rebuild(&fixture);
    let digest = sha256_hex(&fs::read(root.join("hdc")).unwrap());
    assert_eq!(provenance["hdcSHA256"], digest.as_str());
    let targets = TargetStore::open(&root.join("targets-state")).unwrap();
    let artifacts = ArtifactReadStore::open(&root.join("artifacts")).unwrap();
    let jobs = JobStore::open_owner(&root.join("jobs-state")).unwrap();
    let sessions = SessionStore::open(&root.join("session-owner"), &root.join("Sessions")).unwrap();
    let dispatch =
        ProcessDispatch::new(VerifiedTool::open(root.join("hdc"), &digest).unwrap(), None);
    let hdc = HdcComposition {
        targets: &targets,
        dispatch: &dispatch,
        tool_sha256: &digest,
        now: fixed_now,
    };
    let probe = OracleProbe::new(&provenance);
    let claims = StorageClaims::default();
    let publisher = SessionPublisher {
        sessions: &sessions,
        claims: &claims,
        probe: &probe,
    };
    let planner = || JobPlanner {
        imports: None,
        artifacts: Some(&artifacts),
        analyzer: None,
        state_root: &root,
        hdc: Some(&hdc),
    };
    let runner = JobRunner {
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
    };
    let reader = JobResultReader {
        jobs: &jobs,
        artifacts: &artifacts,
    };
    let (mut differences, mut wording) = (Vec::new(), Vec::new());
    for exchange in cases["exchanges"].as_array().unwrap() {
        let (name, method) = (&exchange["name"], exchange["method"].as_str().unwrap());
        let params = exchange["params"].as_object().unwrap();
        let actual = match method {
            "job.plan" => match planner().handle(params) {
                Ok(result) => json!({"ok": true, "result": result}),
                Err(refusal) => refused(refusal.code, refusal.message, Some(proven())),
            },
            "job.submit" => match (JobAdmitter {
                planner: planner(),
                jobs: &jobs,
                now: fixed_now,
                authority: None,
            })
            .handle(params)
            {
                Ok(result) => json!({"ok": true, "result": result}),
                Err(refusal) => refused(
                    refusal.code,
                    refusal.message,
                    Some(if refusal.proven { proven() } else { Map::new() }),
                ),
            },
            "job.run" => {
                if let Some(mode) = exchange["mode"].as_str() {
                    fs::write(root.join("hdc-mode"), format!("{mode}\n")).unwrap();
                }
                match runner.handle(params) {
                    Ok(result) => json!({"ok": true, "result": result}),
                    Err(refusal) => refused(refusal.code, refusal.message, Some(refusal.details)),
                }
            }
            "job.result" | "job.evidence" => match reader.handle(method, params) {
                Ok(result) => json!({"ok": true, "result": result}),
                Err(error) => refused(&error.code, error.message, error.details),
            },
            "artifact.list" => {
                match artifacts.handle_list(params, &jobs.snapshot_directory(), |job| {
                    jobs.read_snapshot(job).map(|_| ())
                }) {
                    // The pager's revision is its own; the oracle labels it.
                    Ok(mut result) => {
                        result["snapshotRevision"] = json!("<snapshotRevision>");
                        json!({"ok": true, "result": result})
                    }
                    Err(error) => refused(&error.code, error.message, error.details),
                }
            }
            other => panic!("{name}: the oracle sent {other}"),
        };
        let recorded = &exchange["answer"];
        if semantic(&actual) != semantic(recorded) {
            differences.push(format!("{name}:\n  swift {recorded}\n  rust  {actual}"));
        } else if actual != *recorded {
            wording.push(format!(
                "{name}: swift {:?}, rust {:?}",
                recorded["error"]["message"], actual["error"]["message"]
            ));
        }
    }
    for note in &wording {
        eprintln!("refusal wording (T2): {note}");
    }
    assert!(differences.is_empty(), "{}", differences.join("\n"));
    assert_eq!(
        String::from_utf8(fs::read(root.join("hdc-invocations.log")).unwrap()).unwrap(),
        String::from_utf8(fs::read(fixture.join("hdc-invocations.log")).unwrap()).unwrap(),
        "the fake's calls"
    );
    assert_eq!(
        fs::read(root.join("targets-state/targets.json")).unwrap(),
        fs::read(fixture.join("targets-state/targets.json")).unwrap(),
        "the Target document"
    );
    drop(jobs);
    support::assert_leftovers(&fixture, &root);
}
