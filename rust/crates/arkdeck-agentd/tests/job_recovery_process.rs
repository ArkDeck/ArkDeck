//! The isolated Rust daemon recovers its Jobs when it starts, before it
//! serves (Swift `recoverActiveJobs()`), and answers `job.reconcile` through
//! its Job owner: an analyzer Job parked by a signal death is still parked
//! after a restart and carries its recovery marker, a reconcile then fails it
//! as confirmed not executed, and its analyzer is never started again. The
//! source is the reconcile oracle's; host-only: no HDC, no Swift daemon, no
//! device.
#![cfg(target_os = "macos")]

use arkdeck_hoststore::{
    AnalyzerProfile, ArtifactReadStore, JobAdmitter, JobPlanner, JobRunner, JobStore,
};
use serde_json::{Map, Value, json};
use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

fn fixture(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/fixtures")
        .join(name)
}

fn private_directory(path: &Path) {
    fs::DirBuilder::new().mode(0o700).create(path).unwrap();
}

/// The isolated daemon over `root`, serving once its start has recovered.
struct Daemon(Child);

impl Daemon {
    fn start(root: &Path) -> Self {
        let mut command = Command::new(env!("CARGO_BIN_EXE_arkdeck-agentd"));
        for (key, _) in std::env::vars_os() {
            if key.to_string_lossy().starts_with("ARKDECK_") {
                command.env_remove(key);
            }
        }
        let mut child = command
            .env("ARKDECK_DEVELOPMENT_STATE_ROOT", root)
            .env("ARKDECK_ENDPOINT", root.join("control.sock"))
            .env("ARKDECK_ANALYZER_PATH", root.join("analyzer"))
            .stdout(Stdio::null())
            .stderr(Stdio::inherit())
            .spawn()
            .unwrap();
        let deadline = Instant::now() + Duration::from_secs(10);
        while UnixStream::connect(root.join("control.sock")).is_err() {
            assert!(child.try_wait().unwrap().is_none(), "daemon exited");
            assert!(Instant::now() < deadline, "daemon startup timeout");
            std::thread::sleep(Duration::from_millis(10));
        }
        Self(child)
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

/// One control frame, answered.
fn request(root: &Path, method: &str, params: Value) -> Value {
    let mut stream = UnixStream::connect(root.join("control.sock")).unwrap();
    stream
        .set_read_timeout(Some(Duration::from_secs(60)))
        .unwrap();
    let mut frame = serde_json::to_vec(&json!({
        "protocolVersion": arkdeck_contract::PROTOCOL_VERSION,
        "contractIdentity": arkdeck_contract::CONTRACT_IDENTITY,
        "id": "job-recovery-process", "method": method, "params": params}))
    .unwrap();
    frame.push(b'\n');
    stream.write_all(&frame).unwrap();
    let mut line = String::new();
    BufReader::new(stream).read_line(&mut line).unwrap();
    serde_json::from_str(&line).unwrap()
}

#[test]
fn the_isolated_daemon_recovers_a_parked_job_at_start_and_reconciles_it() {
    let root = PathBuf::from(format!(
        "/private/tmp/arkdeck-job-recovery-process-{:032x}",
        u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap())
    ));
    private_directory(&root);
    // Every start of this analyzer is counted, and each dies by a signal.
    let dispatches = root.join("dispatches");
    let analyzer = root.join("analyzer");
    fs::write(
        &analyzer,
        format!(
            "#!/bin/sh\n[ \"$#\" -eq 2 ] && [ \"$1\" = --analyze-crash-ledger ] || exit 64\n\
             printf x >> '{}'\nkill -KILL \"$$\"\n",
            dispatches.display()
        ),
    )
    .unwrap();
    fs::set_permissions(&analyzer, fs::Permissions::from_mode(0o700)).unwrap();
    let artifacts = root.join("artifacts");
    private_directory(&artifacts);
    let source = fixture("job-reconcile-analyzer/artifacts/job-oracle-source");
    private_directory(&artifacts.join("job-oracle-source"));
    for file in fs::read_dir(&source).unwrap() {
        let file = file.unwrap().path();
        let name = file.file_name().unwrap();
        let copied = artifacts.join("job-oracle-source").join(name);
        fs::copy(&file, &copied).unwrap();
        let mode = if name == "index.json" { 0o600 } else { 0o400 };
        fs::set_permissions(&copied, fs::Permissions::from_mode(mode)).unwrap();
    }
    private_directory(&root.join("jobs-state"));

    // A Job admitted and run before this daemon's start, parked by the
    // signal death of its analyzer.
    let job = {
        let jobs = JobStore::open_owner(&root.join("jobs-state")).unwrap();
        let store = ArtifactReadStore::open(&artifacts).unwrap();
        let profile = AnalyzerProfile::crash_signature(&analyzer).unwrap();
        let recorded = fs::read(fixture("job-reconcile-analyzer/jobs.json")).unwrap();
        let recorded: Value = serde_json::from_slice(&recorded).unwrap();
        let accepted = JobAdmitter {
            planner: JobPlanner {
                imports: None,
                artifacts: Some(&store),
                analyzer: Some(&profile),
                state_root: &root,
                hdc: None,
            },
            jobs: &jobs,
            now: arkdeck_hoststore::runtime_now,
            authority: None,
        }
        .handle(recorded[0]["submit"].as_object().unwrap())
        .unwrap();
        let job = accepted["jobId"].as_str().unwrap().to_owned();
        let parked = JobRunner {
            imports: None,
            mutation: None,
            jobs: &jobs,
            artifacts: &store,
            analyzer: Some(&profile),
            quota: 8 << 30,
            home: "/nonexistent",
            now: arkdeck_hoststore::runtime_now,
            precise_now: arkdeck_hoststore::runtime_precise_now,
            sessions: None,
            cancellation: None,
            after_commit: None,
            hdc: None,
        }
        .handle(&Map::from_iter([("jobId".into(), json!(job))]))
        .unwrap();
        assert_eq!(parked["state"], "waitingForRecovery");
        job
    };
    assert_eq!(fs::read(&dispatches).unwrap(), b"x");

    let daemon = Daemon::start(&root);
    let params = json!({"jobId": job});
    let shown = request(&root, "job.show", params.clone());
    assert_eq!(shown["ok"], true, "{shown}");
    assert_eq!(shown["result"]["job"]["state"], "waitingForRecovery");
    assert_eq!(shown["result"]["job"]["outcomeUnknown"], true);
    assert_eq!(
        shown["result"]["timeline"]["entries"]
            .as_array()
            .unwrap()
            .last()
            .unwrap(),
        "recovered: outstanding intents or unknown outcomes; no redispatch"
    );

    let reconciled = request(&root, "job.reconcile", params.clone());
    // The Job is reconciled and its Session published; the answer is its
    // status, as Swift answers it, and the published result schema admits it
    // (widened from the frames of the reconcile oracles).
    assert_eq!(reconciled["ok"], true, "{reconciled}");
    assert!(reconciled.get("error").is_none(), "{reconciled}");
    let status = request(&root, "job.status", params.clone());
    assert_eq!(status["ok"], true, "{status}");
    assert_eq!(status["result"], reconciled["result"]);
    assert_eq!(status["result"]["state"], "failed");
    assert_eq!(status["result"]["outcomeUnknown"], false);
    assert_eq!(
        status["result"]["failure"]["code"],
        "executionConfirmedNotPerformed"
    );
    assert_eq!(status["result"]["sessionPublication"]["state"], "published");
    drop(daemon);

    // A start over a terminal Job reopens nothing; the analyzer never ran
    // again.
    let daemon = Daemon::start(&root);
    assert_eq!(
        request(&root, "job.status", params)["result"],
        status["result"]
    );
    assert_eq!(fs::read(&dispatches).unwrap(), b"x");
    drop(daemon);
    fs::remove_dir_all(&root).unwrap();
}
