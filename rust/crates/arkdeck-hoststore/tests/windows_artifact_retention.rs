//! The start-up Artifact retention sweep on Windows (TASK-XPA-005) over real
//! Job owners on NTFS, as `artifact_retention.rs` runs it on macOS: the Jobs
//! the census cannot prove settled keep their Artifacts, and so do the Jobs
//! still owing a cleanup; a settled Job's and an unowned directory's lapsed
//! Artifacts go.
//!
//! The macOS test admits analyzer Jobs over the analyzer oracle's source
//! lease; the analyzer lane is not built on Windows (ArkTrace's
//! trace_streamer), so here the Jobs are `observe.device@1` Jobs admitted in
//! process over the recorded Target and an HDC composition whose dispatcher
//! fails the test if called, and cancelled before they run, as the Windows
//! daemon cancels one. Beside them lies the recorded Swift `observe.device@1`
//! store (`rust/tests/fixtures/observe-device`) with its Artifacts as the
//! macOS Runtime published them, lapsing on 2026-09-21: the terminal Jobs
//! whose Sessions were published lose them. Two recorded Jobs keep theirs,
//! as the census cannot prove them settled: the Job its unknown outcome
//! parked (the lapsed row planted beside it) and the failed Job whose Session
//! publication failed (`sourceIntegrityFailed`), never finalized.
#![cfg(windows)]

use arkdeck_contract::sha256_hex;
use arkdeck_hoststore::{
    ArtifactReadStore, HdcComposition, JobAdmitter, JobCanceller, JobPlanner, JobRecord, JobStore,
    SessionPublisher, SessionStore, StorageClaims, SystemStorageProbe, TargetStore,
};
use arkdeck_platform::HostDirectory;
use arkdeck_provider_hdc::{DispatchFailure, HdcDispatch, ProcessPlan, Receipt};
use serde_json::{Value, json};
use std::collections::BTreeSet;
use std::fs;
use std::path::{Path, PathBuf};

const NOW: &str = "2026-09-14T00:00:00Z";
const LAPSED: &str = "2026-09-15T00:00:00Z";
const SWEEP: &str = "2026-09-22T00:00:00Z";
/// The recorded Job its unknown outcome parked.
const PARKED: &str = "job-8adf7b22600ff6ee77e61d7c92b2f790";
/// The recorded failed Job whose Session publication failed.
const UNPUBLISHED: &str = "job-1721f8df101bec4bab91e4619d3f66fa";

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

/// A dispatcher nothing here may reach.
struct NoDispatch;
impl HdcDispatch for NoDispatch {
    fn dispatch(&self, plan: &ProcessPlan) -> Result<Receipt, DispatchFailure> {
        panic!("dispatched {:?}", plan.arguments)
    }
}

/// A fresh owner-only root below the temporary directory, in the canonical
/// spelling the Session owner compares; removed afterwards.
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
        let root = temporary.join(format!("ad-winretention-{nonce:032x}"));
        HostDirectory::open_or_create_private(&root).unwrap();
        for name in [
            "artifacts",
            "jobs-state",
            "session-owner",
            "Sessions",
            "targets-state",
        ] {
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

    /// The recorded Jobs, admitted and advanced to their recorded version,
    /// each Journal beside its record, and their Artifacts (index
    /// owner-only, payloads sealed). Answers the recorded Jobs.
    fn with_recorded_jobs(&self, jobs: &JobStore) -> Vec<String> {
        let index = document(fixture("store/index.json"));
        let mut rows = index["rows"].as_array().unwrap().clone();
        rows.sort_by_key(|row| row["admissionSequence"].as_i64().unwrap());
        let mut recorded = Vec::new();
        for row in &rows {
            let id = row["jobId"].as_str().unwrap();
            let directory = fixture("store/jobs").join(id);
            let record =
                JobRecord::decode(&fs::read(directory.join("job-record.json")).unwrap()).unwrap();
            jobs.admit(&record, row["requestHash"].as_str().unwrap())
                .unwrap();
            for _ in 1..row["version"].as_i64().unwrap() {
                jobs.persist(&record, row["updatedAtUTC"].as_str().unwrap())
                    .unwrap();
            }
            fs::copy(
                directory.join("journal.jsonl"),
                self.root
                    .join("jobs-state/jobs")
                    .join(id)
                    .join("journal.jsonl"),
            )
            .unwrap();
            recorded.push(id.to_owned());
        }
        let artifacts = HostDirectory::open(&self.artifacts()).unwrap();
        for job in fs::read_dir(fixture("artifacts")).unwrap() {
            let job = job.unwrap().path();
            let owned = artifacts
                .create_private_child(job.file_name().unwrap().to_str().unwrap())
                .unwrap();
            for file in fs::read_dir(&job).unwrap() {
                let file = file.unwrap().path();
                let name = file.file_name().unwrap().to_str().unwrap().to_owned();
                owned
                    .create_document(&name, &fs::read(&file).unwrap())
                    .unwrap();
                if name != "index.json" {
                    owned.seal_document(&name).unwrap();
                }
            }
        }
        recorded
    }

    /// A published row lapsed at `LAPSED` in `job`'s index, and its sealed
    /// payload.
    fn plant(&self, job: &str) -> String {
        let artifacts = HostDirectory::open(&self.artifacts()).unwrap();
        let directory = match artifacts.child(job) {
            Ok(directory) => directory,
            Err(_) => artifacts.create_private_child(job).unwrap(),
        };
        let bytes = format!("evidence of {job}").into_bytes();
        let artifact = format!("ART-{}", &sha256_hex(job.as_bytes())[..32]);
        directory.create_document(&artifact, &bytes).unwrap();
        directory.seal_document(&artifact).unwrap();
        let row = json!({
            "artifactID": artifact, "jobID": job, "sessionID": format!("session-{job}"),
            "stepID": "capture", "name": "hilog.txt", "mediaType": "text/plain",
            "byteCount": bytes.len(), "sha256": sha256_hex(&bytes), "createdAtUTC": NOW,
            "providerID": "hdc", "sourceOperation": "capture.diagnostics@1",
            "bindingSnapshot": {"targetID": "TGT-ORACLE"}, "privacy": "standard",
            "retention": {"retentionClass": "default", "pinned": false, "deadlineUTC": LAPSED},
            "status": {"published": {}}, "redactionApplied": false,
        });
        directory
            .create_document(
                "index.json",
                json!({"schemaVersion": "1.0.0", "artifacts": [row]})
                    .to_string()
                    .as_bytes(),
            )
            .unwrap();
        artifact
    }

    fn rows(&self, job: &str) -> Vec<String> {
        let bytes = fs::read(self.artifacts().join(job).join("index.json")).unwrap();
        serde_json::from_slice::<Value>(&bytes).unwrap()["artifacts"]
            .as_array()
            .unwrap()
            .iter()
            .map(|row| row["artifactID"].as_str().unwrap().to_owned())
            .collect()
    }

    fn ledger(&self, records: Value) {
        let artifacts = HostDirectory::open(&self.artifacts()).unwrap();
        let _ = fs::remove_file(self.artifacts().join("cleanup-debt.json"));
        artifacts
            .create_document("cleanup-debt.json", records.to_string().as_bytes())
            .unwrap();
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

struct Owners {
    jobs: JobStore,
    artifacts: ArtifactReadStore,
    targets: TargetStore,
    sessions: SessionStore,
}

impl Owners {
    fn open(fixture: &Fixture) -> Self {
        Self {
            jobs: JobStore::open_owner(&fixture.root.join("jobs-state")).unwrap(),
            artifacts: ArtifactReadStore::open(&fixture.artifacts()).unwrap(),
            targets: TargetStore::open(&fixture.root.join("targets-state")).unwrap(),
            sessions: SessionStore::open(
                &fixture.root.join("session-owner"),
                &fixture.root.join("Sessions"),
            )
            .unwrap(),
        }
    }

    /// An `observe.device@1` Job admitted over the recorded Target, queued
    /// and not yet run.
    fn admit(&self, fixture: &Fixture, key: &str) -> String {
        let provenance = document(fixture_path("provenance.json"));
        let hdc = HdcComposition {
            targets: &self.targets,
            dispatch: &NoDispatch,
            receive_root: None,
            tool_sha256: provenance["hdcSHA256"].as_str().unwrap(),
            now,
            code_sign_helper: None,
        };
        let mut request = document(fixture_path(
            "store/jobs/job-0f77f8c52864d676372962eccb17389c/job-record.json",
        ))["originalSubmissionRequest"]
            .clone();
        request["idempotencyKey"] = json!(format!("idem-{key}"));
        request["requestId"] = json!(format!("req-{key}"));
        JobAdmitter {
            planner: JobPlanner {
                imports: None,
                artifacts: Some(&self.artifacts),
                analyzer: None,
                state_root: &fixture.root,
                hdc: Some(&hdc),
                workspace: None,
            },
            jobs: &self.jobs,
            now,
            authority: None,
        }
        .submit(&serde_json::to_vec(&request).unwrap())
        .unwrap()["jobId"]
            .as_str()
            .unwrap()
            .to_owned()
    }

    /// The Job cancelled before it ran: terminal, finalized and settled.
    fn cancel(&self, job: &str) {
        let claims = StorageClaims::default();
        let publisher = SessionPublisher {
            sessions: &self.sessions,
            claims: &claims,
            probe: &SystemStorageProbe,
        };
        JobCanceller {
            jobs: &self.jobs,
            now,
            sessions: Some(&publisher),
        }
        .handle(json!({"jobId": job}).as_object().unwrap())
        .unwrap();
    }

    fn sweep(&self) -> Result<BTreeSet<String>, String> {
        arkdeck_hoststore::collect_expired_artifacts(&self.jobs, &self.artifacts, SWEEP)
            .map(|reclaimed| reclaimed.into_iter().collect())
    }
}

fn fixture_path(name: &str) -> PathBuf {
    fixture(name)
}

#[test]
fn only_what_the_census_proves_settled_is_reclaimed_on_windows() {
    let fixture = Fixture::new();
    let owners = Owners::open(&fixture);
    let recorded = fixture.with_recorded_jobs(&owners.jobs);
    let active = owners.admit(&fixture, "active");
    let settled = owners.admit(&fixture, "settled");
    owners.cancel(&settled);
    let owing = owners.admit(&fixture, "owing");
    owners.cancel(&owing);
    let torn = owners.admit(&fixture, "torn");
    owners.cancel(&torn);
    // A partial last line: the journal no longer proves the Job settled.
    let journal = fixture
        .root
        .join("jobs-state/jobs")
        .join(&torn)
        .join("journal.jsonl");
    let mut bytes = fs::read(&journal).unwrap();
    bytes.extend_from_slice(b"{\"partial\"");
    fs::write(&journal, bytes).unwrap();
    // A Job directory no row explains.
    HostDirectory::open_or_create_private(&fixture.root.join("jobs-state/jobs/job-unexplained"))
        .unwrap();
    fixture.ledger(json!([{
        "jobID": owing, "stepID": "cleanup-uninstall", "remotePath": "/data/local/tmp/x",
        "reason": "the device refused", "recordedAtUTC": NOW,
    }]));
    let planted: Vec<(String, String)> = [
        active.as_str(),
        settled.as_str(),
        owing.as_str(),
        torn.as_str(),
        "job-unexplained",
        "job-legacy",
        PARKED,
    ]
    .iter()
    .map(|job| (job.to_string(), fixture.plant(job)))
    .collect();
    let artifact = |job: &str| planted.iter().find(|(id, _)| id == job).unwrap().1.clone();
    // The recorded terminal Jobs that published Artifacts, and what they
    // published.
    let published: Vec<(String, Vec<String>)> = recorded
        .iter()
        .filter(|job| {
            ![PARKED, UNPUBLISHED].contains(&job.as_str()) && fixture.artifacts().join(job).is_dir()
        })
        .map(|job| (job.clone(), fixture.rows(job)))
        .collect();
    assert_eq!(published.len(), 2, "{published:?}");
    let unpublished = fixture.rows(UNPUBLISHED);
    assert_eq!(unpublished.len(), 1);

    // The settled Job's and the unowned legacy directory's rows lapse, and
    // so do the recorded terminal Jobs'; the parked Job keeps its own.
    let mut expected = BTreeSet::from([artifact(&settled), artifact("job-legacy")]);
    for (_, rows) in &published {
        expected.extend(rows.iter().cloned());
    }
    assert_eq!(owners.sweep().unwrap(), expected);
    for job in [&settled, &"job-legacy".to_owned()] {
        assert!(fixture.rows(job).is_empty(), "{job}");
        assert!(!fixture.artifacts().join(job).join(artifact(job)).exists());
    }
    for (job, _) in &published {
        assert!(fixture.rows(job).is_empty(), "{job}");
    }
    assert_eq!(fixture.rows(UNPUBLISHED), unpublished);
    for job in [
        &active,
        &owing,
        &torn,
        &"job-unexplained".to_owned(),
        &PARKED.to_owned(),
    ] {
        assert_eq!(fixture.rows(job), [artifact(job)], "{job}");
        assert!(fixture.artifacts().join(job).join(artifact(job)).exists());
    }

    // Once the active Job settles and the cleanup is settled, their rows go.
    // The torn and unexplained Jobs and the parked one stay.
    owners.cancel(&active);
    fixture.ledger(json!([{
        "jobID": owing, "stepID": "cleanup-uninstall", "remotePath": "/data/local/tmp/x",
        "reason": "the device refused", "recordedAtUTC": NOW, "settledAtUTC": SWEEP,
    }]));
    assert_eq!(
        owners.sweep().unwrap(),
        BTreeSet::from([artifact(&active), artifact(&owing)])
    );
    for job in [&torn, &"job-unexplained".to_owned(), &PARKED.to_owned()] {
        assert_eq!(fixture.rows(job), [artifact(job)], "{job}");
    }
    assert_eq!(fixture.rows(UNPUBLISHED), unpublished);
}

#[test]
fn an_unreadable_cleanup_ledger_reclaims_nothing_on_windows() {
    let fixture = Fixture::new();
    let owners = Owners::open(&fixture);
    let settled = owners.admit(&fixture, "settled");
    owners.cancel(&settled);
    let artifact = fixture.plant(&settled);
    fixture.ledger(json!({"not": "a ledger"}));
    let refused = owners.sweep().unwrap_err();
    assert!(refused.contains("cleanup debt ledger"), "{refused}");
    assert_eq!(fixture.rows(&settled), [artifact]);
}
