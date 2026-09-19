//! The isolated owner's startup Artifact retention sweep over real Job
//! owners: the Jobs its census cannot prove settled keep their Artifacts, and
//! so do the Jobs still owing a cleanup and every Artifact an active Job
//! leases; a settled Job's and an unowned directory's lapsed Artifacts go.
//! Jobs are admitted and cancelled through the Rust owners over the analyzer
//! oracle's source Artifact; everything else is host fixture data.
#![cfg(target_os = "macos")]
use arkdeck_contract::sha256_hex;
use serde_json::{Value, json};
use std::collections::BTreeSet;
use std::fs;
use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
use std::path::{Path, PathBuf};

const NOW: &str = "2026-09-12T00:00:00Z";
const LAPSED: &str = "2026-09-13T00:00:00Z";
const SWEEP: &str = "2026-09-22T00:00:00Z";
const SOURCE: &str = "job-oracle-source";
const SOURCE_ARTIFACT: &str = "ART-cf645cc2f23c16cf9965b179bcb35b5e";

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
            "rust-artifact-retention-{:032x}",
            u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap())
        ));
        private_directory(&root);
        for name in ["artifacts", "jobs-state", "session-owner", "Sessions"] {
            private_directory(&root.join(name));
        }
        // The analyzer oracle's source: a capture Job's crash log, lapsing on
        // 2026-09-21, which every Job here leases.
        private_directory(&root.join("artifacts").join(SOURCE));
        let source = fixtures()
            .join("job-submit-analyzer/artifacts")
            .join(SOURCE);
        for (name, mode) in [("index.json", 0o600), (SOURCE_ARTIFACT, 0o400)] {
            let path = root.join("artifacts").join(SOURCE).join(name);
            fs::copy(source.join(name), &path).unwrap();
            fs::set_permissions(&path, fs::Permissions::from_mode(mode)).unwrap();
        }
        let analyzer = root.join("analyzer");
        fs::copy(fixtures().join("job-submit-analyzer/analyzer"), &analyzer).unwrap();
        fs::set_permissions(&analyzer, fs::Permissions::from_mode(0o700)).unwrap();
        Self { root }
    }

    fn artifacts(&self) -> PathBuf {
        self.root.join("artifacts")
    }

    /// A published row lapsed at `LAPSED` in `job`'s index, and its payload.
    fn plant(&self, job: &str) -> String {
        let directory = self.artifacts().join(job);
        if !directory.exists() {
            private_directory(&directory);
        }
        let bytes = format!("evidence of {job}").into_bytes();
        let artifact = format!("ART-{}", &sha256_hex(job.as_bytes())[..32]);
        let payload = directory.join(&artifact);
        fs::write(&payload, &bytes).unwrap();
        fs::set_permissions(&payload, fs::Permissions::from_mode(0o400)).unwrap();
        let row = json!({
            "artifactID": artifact, "jobID": job, "sessionID": format!("session-{job}"),
            "stepID": "capture", "name": "hilog.txt", "mediaType": "text/plain",
            "byteCount": bytes.len(), "sha256": sha256_hex(&bytes), "createdAtUTC": NOW,
            "providerID": "hdc", "sourceOperation": "capture.diagnostics@1",
            "bindingSnapshot": {"targetID": "TGT-ORACLE"}, "privacy": "standard",
            "retention": {"retentionClass": "default", "pinned": false, "deadlineUTC": LAPSED},
            "status": {"published": {}}, "redactionApplied": false,
        });
        let index = directory.join("index.json");
        fs::write(
            &index,
            json!({"schemaVersion": "1.0.0", "artifacts": [row]}).to_string(),
        )
        .unwrap();
        fs::set_permissions(&index, fs::Permissions::from_mode(0o600)).unwrap();
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
        let path = self.artifacts().join("cleanup-debt.json");
        fs::write(&path, records.to_string()).unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

struct Owners {
    jobs: arkdeck_hoststore::JobStore,
    artifacts: arkdeck_hoststore::ArtifactReadStore,
    profile: arkdeck_hoststore::AnalyzerProfile,
    sessions: arkdeck_hoststore::SessionStore,
}

impl Owners {
    fn open(fixture: &Fixture) -> Self {
        Self {
            jobs: arkdeck_hoststore::JobStore::open_owner(&fixture.root.join("jobs-state"))
                .unwrap(),
            artifacts: arkdeck_hoststore::ArtifactReadStore::open(&fixture.artifacts()).unwrap(),
            profile: arkdeck_hoststore::AnalyzerProfile::crash_signature(
                &fixture.root.join("analyzer"),
            )
            .unwrap(),
            sessions: arkdeck_hoststore::SessionStore::open(
                &fixture.root.join("session-owner"),
                &fixture.root.join("Sessions"),
            )
            .unwrap(),
        }
    }

    /// An analyzer Job admitted over the source lease, not yet run.
    fn admit(&self, fixture: &Fixture, key: &str) -> String {
        let request = serde_json::to_vec(&json!({
            "documentType": "runtime-operation-request", "schemaVersion": "1.0.0",
            "requestId": format!("req-{key}"), "idempotencyKey": format!("idem-{key}"),
            "target": {"targetId": "TGT-ORACLE"},
            "operation": {"id": "analyzer.extract-crash-signature", "version": 1},
            "inputs": {"sourceArtifactRef": format!("lease-v1:{SOURCE}:{SOURCE_ARTIFACT}")},
        }))
        .unwrap();
        arkdeck_hoststore::JobAdmitter {
            authority: None,
            planner: arkdeck_hoststore::JobPlanner {
                imports: None,
                artifacts: Some(&self.artifacts),
                analyzer: Some(&self.profile),
                state_root: &fixture.root,
                hdc: None,
            },
            jobs: &self.jobs,
            now: || Some(NOW.into()),
        }
        .submit(&request)
        .unwrap()["jobId"]
            .as_str()
            .unwrap()
            .to_owned()
    }

    /// The Job cancelled before it ran: terminal, finalized and settled.
    fn cancel(&self, job: &str) {
        let claims = arkdeck_hoststore::StorageClaims::default();
        let probe = arkdeck_hoststore::SystemStorageProbe;
        let publisher = arkdeck_hoststore::SessionPublisher {
            sessions: &self.sessions,
            claims: &claims,
            probe: &probe,
        };
        arkdeck_hoststore::JobCanceller {
            jobs: &self.jobs,
            now: || Some(NOW.into()),
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

#[test]
fn only_what_the_census_proves_settled_and_nothing_an_active_job_leases_is_reclaimed() {
    let fixture = Fixture::new();
    let owners = Owners::open(&fixture);
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
    fs::set_permissions(&journal, fs::Permissions::from_mode(0o600)).unwrap();
    fs::write(&journal, bytes).unwrap();
    // A Job directory no row explains.
    private_directory(&fixture.root.join("jobs-state/jobs/job-unexplained"));
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
    ]
    .iter()
    .map(|job| (job.to_string(), fixture.plant(job)))
    .collect();
    let artifact = |job: &str| planted.iter().find(|(id, _)| id == job).unwrap().1.clone();

    // The settled Job's and the unowned legacy directory's rows lapse; the
    // source lapses too, but the active Job leases it.
    assert_eq!(
        owners.sweep().unwrap(),
        BTreeSet::from([artifact(&settled), artifact("job-legacy")])
    );
    for job in [&settled, &"job-legacy".to_owned()] {
        assert!(fixture.rows(job).is_empty(), "{job}");
        assert!(!fixture.artifacts().join(job).join(artifact(job)).exists());
    }
    for job in [&active, &owing, &torn, &"job-unexplained".to_owned()] {
        assert_eq!(fixture.rows(job), [artifact(job)], "{job}");
        assert!(fixture.artifacts().join(job).join(artifact(job)).exists());
    }
    assert_eq!(fixture.rows(SOURCE), [SOURCE_ARTIFACT]);

    // Once the active Job settles and the cleanup is settled, their rows go.
    // The torn and unexplained Jobs stay, and the torn Job, which the census
    // cannot prove settled, still leases the source.
    owners.cancel(&active);
    fixture.ledger(json!([{
        "jobID": owing, "stepID": "cleanup-uninstall", "remotePath": "/data/local/tmp/x",
        "reason": "the device refused", "recordedAtUTC": NOW, "settledAtUTC": SWEEP,
    }]));
    assert_eq!(
        owners.sweep().unwrap(),
        BTreeSet::from([artifact(&active), artifact(&owing)])
    );
    for job in [&torn, &"job-unexplained".to_owned()] {
        assert_eq!(fixture.rows(job), [artifact(job)], "{job}");
    }
    assert_eq!(fixture.rows(SOURCE), [SOURCE_ARTIFACT]);
}

#[test]
fn an_unreadable_cleanup_ledger_reclaims_nothing() {
    let fixture = Fixture::new();
    let owners = Owners::open(&fixture);
    let settled = owners.admit(&fixture, "settled");
    owners.cancel(&settled);
    let artifact = fixture.plant(&settled);
    fixture.ledger(json!({"not": "a ledger"}));
    let refused = owners.sweep().unwrap_err();
    assert!(refused.contains("cleanup debt ledger"), "{refused}");
    assert_eq!(fixture.rows(&settled), [artifact]);
    assert_eq!(fixture.rows(SOURCE), [SOURCE_ARTIFACT]);
}
