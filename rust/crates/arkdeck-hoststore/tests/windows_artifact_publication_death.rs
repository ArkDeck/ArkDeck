//! A Job product's publication on Windows killed at each of its steps
//! (XPA-AC-7), as `artifact_publication_process_death.rs` kills it on macOS:
//! the Artifact index is consistent afterwards, naming the product with its
//! sealed bytes or not naming it at all; never a half-record. A child process
//! runs an `observe.device@1` Job through the Rust Job runner (the macOS test
//! runs an analyzer Job; the analyzer lane is not built on Windows) and
//! stops at the chosen step through the Artifact owner's fault seam; the
//! parent terminates it there (`TerminateProcess`) and reopens every owner.
//!
//! The Job's HDC calls are answered in process from `ArkDeckFakeHDCFixture`'s
//! `observe.device@1` table (`rust/tests/fixtures/observe-device`); no device
//! or `hdc` is involved. The child tells the parent it reached its step on
//! its standard output, which the parent reads; nothing waits on a clock.
//!
//! These tests spawn child processes, so they have their own test binary.
#![cfg(windows)]

use arkdeck_hoststore::{
    ArtifactPublicationFault, ArtifactReadStore, ArtifactUsage, HdcComposition, JobAdmitter,
    JobPlanner, JobRunner, JobStore, TargetStore,
};
use arkdeck_platform::HostDirectory;
use arkdeck_provider_hdc::{DispatchFailure, HdcDispatch, ProcessPlan, Receipt};
use serde_json::{Value, json};
use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::Arc;
use std::time::Duration;

const NOW: &str = "2026-09-14T00:00:00Z";
const QUOTA: u64 = 64 * 1024 * 1024;
const KEY: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const READY: &str = "publication step reached";

fn fixture(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/fixtures/observe-device")
        .join(name)
}

fn document(path: PathBuf) -> Value {
    serde_json::from_slice(&fs::read(path).unwrap()).unwrap()
}

fn now() -> Option<String> {
    Some(NOW.into())
}

/// `ArkDeckFakeHDCFixture`'s `observe.device@1` answers, in its normal mode.
struct FakeHdc;

impl HdcDispatch for FakeHdc {
    fn dispatch(&self, plan: &ProcessPlan) -> Result<Receipt, DispatchFailure> {
        let joined = plan.arguments.join(" ");
        let stdout = if joined == "-v" {
            "Ver: 3.2.0d\n".to_owned()
        } else if joined == "checkserver" {
            "Client version:Ver: 3.2.0d, server version:Ver: 3.2.0d\n".to_owned()
        } else if joined == "list targets -v" {
            format!("{KEY}\t\tUSB\tConnected\tlocalhost\n")
        } else if joined == format!("-t {KEY} shell param get const.product.name") {
            "OpenHarmony Reference Device\n".to_owned()
        } else if joined == format!("-t {KEY} shell param get const.ohos.fullname") {
            "OpenHarmony-4.1-release\n".to_owned()
        } else {
            return Ok(Receipt {
                exit_status: 23,
                stdout: Vec::new(),
                stderr: b"unregistered fixture output\n".to_vec(),
                truncated: false,
                duration: Duration::ZERO,
            });
        };
        Ok(Receipt {
            exit_status: 0,
            stdout: stdout.into_bytes(),
            stderr: Vec::new(),
            truncated: false,
            duration: Duration::ZERO,
        })
    }
}

/// A fresh owner-only root, in the spelling the file system resolves.
struct Fixture {
    root: PathBuf,
}

impl Fixture {
    fn new() -> Self {
        let nonce = u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap());
        let temporary = std::env::temp_dir().canonicalize().unwrap();
        let temporary = match temporary
            .to_str()
            .and_then(|text| text.strip_prefix(r"\\?\"))
        {
            Some(plain) => PathBuf::from(plain),
            None => temporary,
        };
        let root = temporary.join(format!("ad-winpublication-kill-{nonce:032x}"));
        HostDirectory::open_or_create_private(&root).unwrap();
        for name in ["artifacts", "jobs-state", "targets-state"] {
            HostDirectory::open_or_create_private(&root.join(name)).unwrap();
        }
        HostDirectory::open(&root.join("targets-state"))
            .unwrap()
            .create_document(
                "targets.json",
                &fs::read(fixture("targets-state/targets.json")).unwrap(),
            )
            .unwrap();
        Self { root }
    }

    fn artifacts(&self) -> PathBuf {
        self.root.join("artifacts")
    }

    /// An `observe.device@1` Job over the recorded Target, admitted, not yet
    /// run.
    fn admit(&self) -> String {
        let jobs = jobs_at(&self.root);
        let artifacts = ArtifactReadStore::open(&self.artifacts()).unwrap();
        let targets = TargetStore::open(&self.root.join("targets-state")).unwrap();
        let provenance = document(fixture("provenance.json"));
        let hdc = HdcComposition {
            targets: &targets,
            dispatch: &FakeHdc,
            receive_root: None,
            tool_sha256: provenance["hdcSHA256"].as_str().unwrap(),
            now,
            code_sign_helper: None,
        };
        let mut request = document(fixture(
            "store/jobs/job-0f77f8c52864d676372962eccb17389c/job-record.json",
        ))["originalSubmissionRequest"]
            .clone();
        request["idempotencyKey"] = json!("idem-publication-kill");
        request["requestId"] = json!("req-publication-kill");
        JobAdmitter {
            authority: None,
            planner: JobPlanner {
                imports: None,
                artifacts: Some(&artifacts),
                analyzer: None,
                state_root: &self.root,
                hdc: Some(&hdc),
                workspace: None,
            },
            jobs: &jobs,
            now,
        }
        .submit(&serde_json::to_vec(&request).unwrap())
        .unwrap()["jobId"]
            .as_str()
            .unwrap()
            .to_owned()
    }
}

fn jobs_at(root: &Path) -> JobStore {
    JobStore::open_owner(&root.join("jobs-state")).unwrap()
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

/// Whether the file at `path` is sealed: nothing may open it for writing.
fn sealed(path: &Path) -> bool {
    fs::OpenOptions::new().write(true).open(path).is_err()
}

#[test]
#[ignore = "subprocess fixture invoked by a_publication_killed_at_any_step_leaves_no_half_record_on_windows"]
fn publication_kill_helper() {
    let root = PathBuf::from(std::env::var_os("ARKDECK_PUBLICATION_KILL_ROOT").unwrap());
    let window = std::env::var("ARKDECK_PUBLICATION_KILL_WINDOW").unwrap();
    let job = std::env::var("ARKDECK_PUBLICATION_KILL_JOB").unwrap();
    let artifacts = ArtifactReadStore::open_with_fault(
        &root.join("artifacts"),
        Arc::new(move |point: ArtifactPublicationFault| {
            if format!("{point:?}") == window {
                let mut out = std::io::stdout().lock();
                writeln!(out, "{READY}")?;
                out.flush()?;
                loop {
                    std::thread::park();
                }
            }
            Ok(())
        }),
    )
    .unwrap();
    let jobs = jobs_at(&root);
    let targets = TargetStore::open(&root.join("targets-state")).unwrap();
    let provenance = document(fixture("provenance.json"));
    let hdc = HdcComposition {
        targets: &targets,
        dispatch: &FakeHdc,
        receive_root: None,
        tool_sha256: provenance["hdcSHA256"].as_str().unwrap(),
        now,
        code_sign_helper: None,
    };
    let answer = JobRunner {
        mutation: None,
        imports: None,
        jobs: &jobs,
        artifacts: &artifacts,
        analyzer: None,
        quota: QUOTA,
        home: r"C:\isolated-test",
        now,
        precise_now: || Some("2026-09-14T00:00:00.000Z".into()),
        sessions: None,
        cancellation: None,
        after_commit: None,
        hdc: Some(&hdc),
        workspace: None,
    }
    .handle(json!({"jobId": job}).as_object().unwrap());
    panic!("the kill step was not reached: {answer:?}");
}

#[test]
fn a_publication_killed_at_any_step_leaves_no_half_record_on_windows() {
    for window in ["AfterPayload", "AfterSeal", "AfterIndex"] {
        let fixture = Fixture::new();
        let job = fixture.admit();
        let mut child = Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "publication_kill_helper",
                "--ignored",
                "--nocapture",
            ])
            .env("ARKDECK_PUBLICATION_KILL_ROOT", &fixture.root)
            .env("ARKDECK_PUBLICATION_KILL_WINDOW", window)
            .env("ARKDECK_PUBLICATION_KILL_JOB", &job)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        // The child names its step once it is parked there, or ends.
        let reached = BufReader::new(child.stdout.take().unwrap())
            .lines()
            .map_while(Result::ok)
            .any(|line| line == READY);
        child.kill().unwrap();
        let status = child.wait().unwrap();
        assert!(reached, "child failed before {window}: {status}");
        assert!(!status.success(), "{window}: {status}");

        let jobs = jobs_at(&fixture.root);
        let artifacts = ArtifactReadStore::open(&fixture.artifacts()).unwrap();
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
        let is_sealed = sealed(&directory.join(payloads[0]));
        let listed = artifacts.list(&job).unwrap();
        let rows = listed.page(0, 1000).unwrap().items;
        let indexed_bytes: u64 = rows
            .iter()
            .map(|row| row["byteCount"].as_u64().unwrap())
            .sum();
        match window {
            "AfterPayload" => {
                assert!(!is_sealed, "{window}");
                assert!(
                    rows.is_empty(),
                    "{window}: an unsealed payload is never named"
                );
            }
            "AfterSeal" => {
                assert!(is_sealed, "{window}");
                assert!(rows.is_empty(), "{window}");
            }
            _ => {
                assert!(is_sealed, "{window}");
                assert_eq!(rows.len(), 1, "{window}");
                assert_eq!(rows[0]["artifactID"], json!(payloads[0]));
                assert_eq!(rows[0]["status"], json!({"published": {}}));
            }
        }
        // The quota counts exactly what the indexes name.
        let quota = ArtifactUsage::open(&fixture.artifacts(), QUOTA)
            .unwrap()
            .quota()
            .unwrap();
        assert_eq!(
            quota["usedBytes"],
            json!(indexed_bytes),
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
        // A start over what the killed run left recovers the Job without a
        // refusal or a quarantine, and changes no Artifact.
        let before: Vec<(String, Vec<u8>)> = entries
            .iter()
            .map(|name| (name.clone(), fs::read(directory.join(name)).unwrap()))
            .collect();
        let recovered = arkdeck_hoststore::recover_active_jobs(&jobs, None, now).unwrap();
        assert!(
            recovered.quarantined.is_empty() && recovered.refused.is_empty(),
            "{window}"
        );
        assert_eq!(recovered.statuses.len(), 1, "{window}");
        for (name, bytes) in before {
            assert_eq!(
                fs::read(directory.join(&name)).unwrap(),
                bytes,
                "{window}: {name}"
            );
        }
    }
}
