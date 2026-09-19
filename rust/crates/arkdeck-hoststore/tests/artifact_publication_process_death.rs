#![cfg(target_os = "macos")]
//! A Job product's publication killed by an actual SIGKILL at each of its
//! steps (XPA-AC-7): the Artifact index is consistent afterwards, naming the
//! product with its sealed, verified bytes or not naming it at all; never a
//! half-record. A child process runs a real analyzer Job through the Rust Job
//! runner and stops at the chosen step through the Artifact owner's fault
//! seam; the parent kills it there and reopens every owner.
//!
//! These tests spawn child processes, so they have their own test binary: a
//! child spawned while another test thread closes and reopens an owner lock
//! briefly holds that thread's closed flock descriptor.
use serde_json::json;
use std::fs;
use std::os::unix::fs::{DirBuilderExt, MetadataExt, PermissionsExt};
use std::os::unix::process::ExitStatusExt;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};

const NOW: &str = "2026-09-12T00:00:00Z";
const SOURCE: &str = "job-oracle-source";
/// The run oracle's source whose first line makes its analyzer answer.
const SOURCE_ARTIFACT: &str = "ART-de6b658824f09ec9eab7d91e4a056b4b";
const QUOTA: u64 = 64 * 1024 * 1024;

fn fixtures() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/fixtures")
}

fn private_directory(path: &Path) {
    fs::DirBuilder::new().mode(0o700).create(path).unwrap();
}

struct Fixture {
    root: PathBuf,
}

impl Fixture {
    fn new() -> Self {
        let root = std::env::temp_dir().canonicalize().unwrap().join(format!(
            "rust-publication-kill-{:032x}",
            u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap())
        ));
        private_directory(&root);
        for name in ["artifacts", "jobs-state"] {
            private_directory(&root.join(name));
        }
        // The run oracle's sources, a capture Job's crash logs, and its
        // analyzer, which answers from a source's first line.
        private_directory(&root.join("artifacts").join(SOURCE));
        let source = fixtures().join("job-run-analyzer/artifacts").join(SOURCE);
        for entry in fs::read_dir(&source).unwrap() {
            let name = entry.unwrap().file_name();
            let path = root.join("artifacts").join(SOURCE).join(&name);
            fs::copy(source.join(&name), &path).unwrap();
            let mode = if name == "index.json" { 0o600 } else { 0o400 };
            fs::set_permissions(&path, fs::Permissions::from_mode(mode)).unwrap();
        }
        let analyzer = root.join("analyzer");
        fs::copy(fixtures().join("job-run-analyzer/analyzer"), &analyzer).unwrap();
        fs::set_permissions(&analyzer, fs::Permissions::from_mode(0o700)).unwrap();
        Self { root }
    }

    fn artifacts(&self) -> PathBuf {
        self.root.join("artifacts")
    }

    /// An analyzer Job over the source lease, admitted, not yet run.
    fn admit(&self) -> String {
        let jobs = jobs_at(&self.root);
        let artifacts = arkdeck_hoststore::ArtifactReadStore::open(&self.artifacts()).unwrap();
        let profile = profile_at(&self.root);
        let request = serde_json::to_vec(&json!({
            "documentType": "runtime-operation-request", "schemaVersion": "1.0.0",
            "requestId": "req-publication-kill", "idempotencyKey": "idem-publication-kill",
            "target": {"targetId": "TGT-ORACLE"},
            "operation": {"id": "analyzer.extract-crash-signature", "version": 1},
            "inputs": {"sourceArtifactRef": format!("lease-v1:{SOURCE}:{SOURCE_ARTIFACT}")},
        }))
        .unwrap();
        arkdeck_hoststore::JobAdmitter {
            authority: None,
            planner: arkdeck_hoststore::JobPlanner {
                imports: None,
                artifacts: Some(&artifacts),
                analyzer: Some(&profile),
                state_root: &self.root,
                hdc: None,
            },
            jobs: &jobs,
            now: || Some(NOW.into()),
        }
        .submit(&request)
        .unwrap()["jobId"]
            .as_str()
            .unwrap()
            .to_owned()
    }
}

fn jobs_at(root: &Path) -> arkdeck_hoststore::JobStore {
    arkdeck_hoststore::JobStore::open_owner(&root.join("jobs-state")).unwrap()
}

fn profile_at(root: &Path) -> arkdeck_hoststore::AnalyzerProfile {
    arkdeck_hoststore::AnalyzerProfile::crash_signature(&root.join("analyzer")).unwrap()
}

impl Drop for Fixture {
    fn drop(&mut self) {
        // Sealed payloads keep their directories removable; nothing else stays.
        let _ = fs::remove_dir_all(&self.root);
    }
}

#[test]
#[ignore = "subprocess fixture invoked by a_publication_killed_at_any_step_leaves_no_half_record"]
fn publication_kill_helper() {
    let root = PathBuf::from(std::env::var_os("ARKDECK_PUBLICATION_KILL_ROOT").unwrap());
    let window = std::env::var("ARKDECK_PUBLICATION_KILL_WINDOW").unwrap();
    let job = std::env::var("ARKDECK_PUBLICATION_KILL_JOB").unwrap();
    let marker = root.join("ready");
    let artifacts = arkdeck_hoststore::ArtifactReadStore::open_with_fault(
        &root.join("artifacts"),
        Arc::new(move |point| {
            if format!("{point:?}") == window {
                fs::write(&marker, b"ready")?;
                loop {
                    std::thread::park();
                }
            }
            Ok(())
        }),
    )
    .unwrap();
    let jobs = jobs_at(&root);
    let profile = profile_at(&root);
    let answer = arkdeck_hoststore::JobRunner {
        mutation: None,
        imports: None,
        jobs: &jobs,
        artifacts: &artifacts,
        analyzer: Some(&profile),
        quota: QUOTA,
        home: "/isolated-test",
        now: || Some(NOW.into()),
        precise_now: || Some("2026-09-12T00:00:00.000Z".into()),
        sessions: None,
        cancellation: None,
        after_commit: None,
        hdc: None,
    }
    .handle(json!({"jobId": job}).as_object().unwrap());
    panic!("the kill step was not reached: {answer:?}");
}

#[test]
fn a_publication_killed_at_any_step_leaves_no_half_record() {
    for window in ["AfterPayload", "AfterSeal", "AfterIndex"] {
        let fixture = Fixture::new();
        let job = fixture.admit();
        let mut child = std::process::Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "publication_kill_helper",
                "--ignored",
                "--nocapture",
            ])
            .env("ARKDECK_PUBLICATION_KILL_ROOT", &fixture.root)
            .env("ARKDECK_PUBLICATION_KILL_WINDOW", window)
            .env("ARKDECK_PUBLICATION_KILL_JOB", &job)
            .stdout(std::process::Stdio::null())
            .spawn()
            .unwrap();
        // The helper's startup, analyzer run and durable writes are real work
        // that a loaded host can stretch past any tight budget, so the wait
        // ends on its marker or its exit; the bound only keeps a hung helper
        // from hanging the test.
        let deadline = Instant::now() + Duration::from_secs(120);
        while !fixture.root.join("ready").is_file()
            && Instant::now() < deadline
            && child.try_wait().unwrap().is_none()
        {
            std::thread::sleep(Duration::from_millis(10));
        }
        let reached = fixture.root.join("ready").is_file();
        let _ = child.kill();
        let status = child.wait().unwrap();
        assert!(reached, "child failed before {window}: {status}");
        assert_eq!(
            status.signal(),
            Some(9),
            "expected actual SIGKILL at {window}"
        );

        // Every owner reopens over what the killed process left.
        let jobs = jobs_at(&fixture.root);
        let artifacts = arkdeck_hoststore::ArtifactReadStore::open(&fixture.artifacts()).unwrap();
        let directory = fixture.artifacts().join(&job);
        let entries: Vec<String> = fs::read_dir(&directory)
            .unwrap()
            .map(|entry| entry.unwrap().file_name().into_string().unwrap())
            .collect();
        let payloads: Vec<&String> = entries
            .iter()
            .filter(|name| name.starts_with("ART-"))
            .collect();
        assert_eq!(payloads.len(), 1, "{window}: {entries:?}");
        assert!(
            entries
                .iter()
                .all(|name| name.starts_with("ART-") || name == "index.json"),
            "{window}: no partial file is left: {entries:?}"
        );
        let mode = fs::metadata(directory.join(payloads[0])).unwrap().mode() & 0o777;
        // The index verifies wherever the kill landed: every row it names has
        // its exact, sealed bytes.
        let listed = artifacts.list(&job).unwrap();
        let rows = listed.page(0, 1000).unwrap().items;
        let indexed_bytes: u64 = rows
            .iter()
            .map(|row| row["byteCount"].as_u64().unwrap())
            .sum();
        match window {
            "AfterPayload" => {
                assert_eq!(mode, 0o600, "{window}");
                assert!(
                    rows.is_empty(),
                    "{window}: an unsealed payload is never named"
                );
            }
            "AfterSeal" => {
                assert_eq!(mode, 0o400, "{window}");
                assert!(rows.is_empty(), "{window}");
            }
            _ => {
                assert_eq!(mode, 0o400, "{window}");
                assert_eq!(rows.len(), 1, "{window}");
                assert_eq!(rows[0]["artifactID"], json!(payloads[0]));
                assert_eq!(rows[0]["status"], json!({"published": {}}));
            }
        }
        // The quota counts exactly what the indexes name.
        let quota = arkdeck_hoststore::ArtifactUsage::open(&fixture.artifacts(), QUOTA)
            .unwrap()
            .quota()
            .unwrap();
        let source_index: serde_json::Value = serde_json::from_slice(
            &fs::read(fixture.artifacts().join(SOURCE).join("index.json")).unwrap(),
        )
        .unwrap();
        let source_bytes: u64 = source_index["artifacts"]
            .as_array()
            .unwrap()
            .iter()
            .map(|row| row["byteCount"].as_u64().unwrap())
            .sum();
        assert_eq!(
            quota["usedBytes"],
            json!(source_bytes + indexed_bytes),
            "{window}: {quota}"
        );
        // The Job the process was running is not terminal, so the retention
        // sweep keeps everything it left.
        assert_eq!(
            arkdeck_hoststore::collect_expired_artifacts(&jobs, &artifacts, "2100-01-01T00:00:00Z")
                .unwrap()
                .iter()
                .filter(|artifact| payloads.iter().any(|payload| payload == artifact))
                .count(),
            0,
            "{window}"
        );
    }
}
