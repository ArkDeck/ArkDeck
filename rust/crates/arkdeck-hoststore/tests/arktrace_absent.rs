//! Replays the Swift oracle of the ArkTrace analyzers on a host without
//! ArkTrace (`rust/tests/fixtures/arktrace-absent`, produced by
//! `ArkTraceAbsentOracleContractTests`): the daemon's composition with the
//! crash-ledger analyzer an installed daemon's `ARKDECK_ANALYZER_PATH` names
//! and no `ARKDECK_ARKTRACE_DESCRIPTOR`, and the plan of a complete
//! `analyzer.summarize-trace@1` and `analyzer.analyze-trace@1` request over a
//! raw Trace Artifact, planned and submitted: each refused before admission
//! as Swift refuses it, nothing admitted and the source untouched. The operations' descriptors
//! are the daemon's (`operation_availability_control`).
#![cfg(target_os = "macos")]

use arkdeck_hoststore::{
    AnalyzerComposition, AnalyzerProfile, AnalyzerProfiles, ArtifactReadStore, JobAdmitter,
    JobPlanner, JobStore,
};
use serde_json::{Value, json};
use std::fs::{self, File, OpenOptions};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

const ROOT: &str = "/private/tmp/arkdeck-job-plan-oracle";
const LOCK: &str = "/private/tmp/arkdeck-job-plan-oracle.lock";

fn fixture() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/fixtures/arktrace-absent")
}

fn chmod(path: &Path, mode: u32) {
    fs::set_permissions(path, fs::Permissions::from_mode(mode)).unwrap();
}

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

#[test]
fn rust_refuses_the_arktrace_analyzers_without_arktrace_as_swift_does() {
    let _lock = exclusive();
    let root = PathBuf::from(ROOT);
    let _ = fs::remove_dir_all(&root);
    for directory in [
        root.clone(),
        root.join("artifacts"),
        root.join("jobs-state"),
        root.join("artifacts/job-oracle-source"),
    ] {
        fs::create_dir(&directory).unwrap();
        chmod(&directory, 0o700);
    }
    fs::copy(fixture().join("analyzer"), root.join("analyzer")).unwrap();
    chmod(&root.join("analyzer"), 0o700);
    let source = fixture().join("artifacts/job-oracle-source");
    for file in fs::read_dir(&source).unwrap() {
        let file = file.unwrap().path();
        let name = file.file_name().unwrap();
        let destination = root.join("artifacts/job-oracle-source").join(name);
        fs::copy(&file, &destination).unwrap();
        chmod(
            &destination,
            if name == "index.json" { 0o600 } else { 0o400 },
        );
    }

    let artifacts = ArtifactReadStore::open(&root.join("artifacts")).unwrap();
    let jobs = JobStore::open_owner(&root.join("jobs-state")).unwrap();
    // The daemon's composition (`hilog_summary_analyzer::composed`) for an
    // analyzer that is not the daemon, without an ArkTrace descriptor.
    let composition = AnalyzerProfiles::for_daemon_analyzer(
        AnalyzerProfile::crash_signature(&root.join("analyzer")).unwrap(),
        Some(&"0".repeat(64)),
    )
    .without_arktrace();
    let planner = JobPlanner {
        imports: None,
        artifacts: Some(&artifacts),
        analyzer: Some(&composition as &dyn AnalyzerComposition),
        state_root: &root,
        hdc: None,
        workspace: None,
    };
    let cases: Value =
        serde_json::from_slice(&fs::read(fixture().join("cases.json")).unwrap()).unwrap();
    let admitter = JobAdmitter {
        planner: JobPlanner {
            imports: None,
            artifacts: Some(&artifacts),
            analyzer: Some(&composition as &dyn AnalyzerComposition),
            state_root: &root,
            hdc: None,
            workspace: None,
        },
        jobs: &jobs,
        now: || Some("2026-09-14T00:00:00Z".into()),
        authority: None,
    };
    let mut answered = 0;
    for exchange in cases["exchanges"].as_array().unwrap() {
        let params = exchange["params"].as_object().unwrap();
        let actual = match exchange["method"].as_str().unwrap() {
            "job.plan" => match planner.handle(params) {
                Ok(result) => json!({"ok": true, "result": result}),
                Err(refused) => json!({"ok": false, "error": {
                    "code": refused.code, "message": refused.message,
                    "details": {"newDispatchCount": 0, "phase": "preAdmission"}}}),
            },
            "job.submit" => match admitter.handle(params) {
                Ok(result) => json!({"ok": true, "result": result}),
                Err(refused) => {
                    assert!(refused.proven, "{}", exchange["name"]);
                    json!({"ok": false, "error": {
                        "code": refused.code, "message": refused.message,
                        "details": {"newDispatchCount": 0, "phase": "preAdmission"}}})
                }
            },
            _ => continue,
        };
        assert_eq!(actual, exchange["answer"], "{}", exchange["name"]);
        answered += 1;
    }
    assert_eq!(answered, 4);
    // Nothing was admitted, and the source is as Swift left it.
    let listed = jobs
        .handle_resource("job.list", &serde_json::Map::new())
        .unwrap();
    assert_eq!(listed["items"], json!([]), "{listed}");
    for file in fs::read_dir(&source).unwrap() {
        let file = file.unwrap().path();
        let name = file.file_name().unwrap();
        assert_eq!(
            fs::read(root.join("artifacts/job-oracle-source").join(name)).unwrap(),
            fs::read(&file).unwrap(),
            "{}",
            name.to_string_lossy()
        );
    }
    drop(jobs);
    fs::remove_dir_all(&root).unwrap();
}
