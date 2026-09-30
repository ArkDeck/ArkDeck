//! The Swift restart and reconcile oracle
//! (`rust/tests/fixtures/job-reconcile-analyzer`) on Windows: the Job store
//! Swift's second daemon start left (`secondRestart`) — two analyzer Jobs a
//! signal death parked, the second's source payload since removed, one run to
//! success and one only admitted — laid down on NTFS with the Artifacts it
//! reads, then every recorded `job.reconcile` request in order through the
//! Rust reconciler composed with the Session publication writer, as the
//! standalone Swift daemon is, and every recorded read.
//!
//! The runs that produced the store spawn the analyzer, a lane not built on
//! Windows (its profiles pin ArkTrace's trace_streamer), so the store is laid
//! down as Swift recorded it rather than produced here; the macOS replay
//! (`job_reconcile.rs`) runs the whole oracle. Reconciling an analyzer Job
//! runs nothing: it reads the Job's journal and its source Artifact. Every
//! answer and read must be Swift's but a refusal's wording (T2), which names
//! this host's paths, and the published Manifest's digest, whose
//! `platformProfile` names the platform it was published on.
//!
//! The succeeded Job's Session is laid down as Swift's first daemon
//! published it (the catalog at generation 1), so the parked Job's reconcile
//! registers its own at generation 2, as Swift's did.
#![cfg(windows)]

use arkdeck_contract::WireError;
use arkdeck_contract::sha256_hex;
use arkdeck_hoststore::{
    ArtifactReadStore, JobReconciler, JobRecord, JobResultReader, JobStore, SessionPublisher,
    SessionStore, StorageClaims, SystemStorageProbe,
};
use arkdeck_platform::HostDirectory;
use serde_json::{Map, Value, json};
use std::fs;
use std::path::{Path, PathBuf};

fn fixture(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/fixtures/job-reconcile-analyzer")
        .join(name)
}

fn document(path: PathBuf) -> Value {
    serde_json::from_slice(&fs::read(path).unwrap()).unwrap()
}

fn fixed_now() -> Option<String> {
    Some("2026-09-14T00:00:00Z".into())
}

/// A fresh owner-only root below the temporary directory, in the canonical
/// spelling without `\\?\` as the Session owner compares roots.
struct Root(PathBuf);
impl Root {
    fn new() -> Self {
        let nonce = u64::from_ne_bytes(arkdeck_platform::random_bytes::<8>().unwrap());
        let temporary = std::env::temp_dir().canonicalize().unwrap();
        let temporary = match temporary
            .to_str()
            .and_then(|text| text.strip_prefix(r"\\?\"))
        {
            Some(plain) => PathBuf::from(plain),
            None => temporary,
        };
        let path = temporary.join(format!("ad-winreconcile-{nonce:016x}"));
        HostDirectory::open_or_create_private(&path).unwrap();
        for owner in ["artifacts", "jobs-state", "session-owner", "Sessions"] {
            HostDirectory::open_or_create_private(&path.join(owner)).unwrap();
        }
        Self(path)
    }
    /// The Job store as Swift's second start left it: each row admitted and
    /// persisted to its recorded version, its files beside its record.
    fn with_store(&self) {
        let state = self.0.join("jobs-state");
        let store = JobStore::open_owner(&state).unwrap();
        let recorded = fixture("secondRestart");
        let index = document(recorded.join("index.json"));
        let mut rows = index["rows"].as_array().unwrap().clone();
        rows.sort_by_key(|row| row["admissionSequence"].as_i64().unwrap());
        for row in &rows {
            let id = row["jobId"].as_str().unwrap();
            let directory = recorded.join("jobs").join(id);
            let record =
                JobRecord::decode(&fs::read(directory.join("job-record.json")).unwrap()).unwrap();
            store
                .admit(&record, row["requestHash"].as_str().unwrap())
                .unwrap();
            for _ in 1..row["version"].as_i64().unwrap() {
                store
                    .persist(&record, row["updatedAtUTC"].as_str().unwrap())
                    .unwrap();
            }
            for file in fs::read_dir(&directory).unwrap() {
                let file = file.unwrap().path();
                let name = file.file_name().unwrap();
                if name != "job-record.json" {
                    fs::copy(&file, state.join("jobs").join(id).join(name)).unwrap();
                }
            }
        }
    }
    /// The Sessions root as Swift's first daemon left it: the succeeded Job's
    /// Session and a catalog holding it alone, at generation 1.
    fn with_first_session(&self) {
        let recorded = fixture("sessions");
        let catalog = document(recorded.join(".arkdeck-retention-catalog.json"));
        let first = &catalog["entries"][0];
        let first_session = first["sessionId"].as_str().unwrap();
        let sessions = HostDirectory::open(&self.0.join("Sessions")).unwrap();
        let catalog = json!({
            "entries": [first],
            "generation": 1,
            "schemaVersion": catalog["schemaVersion"],
        });
        sessions
            .create_document(
                ".arkdeck-retention-catalog.json",
                &serde_json::to_vec(&catalog).unwrap(),
            )
            .unwrap();
        sessions
            .create_document(
                ".arkdeck-retention-catalog.lock",
                &fs::read(recorded.join(".arkdeck-retention-catalog.lock")).unwrap(),
            )
            .unwrap();
        let month = sessions.create_private_child("2026").unwrap();
        let month = month.create_private_child("09").unwrap();
        copy_tree(
            &recorded.join("2026/09").join(first_session),
            &month.create_private_child(first_session).unwrap(),
        );
    }
    /// The Artifacts the oracle's Jobs read and published, as the macOS
    /// Runtime published them (index owner-only, payloads sealed), the
    /// removed source payload absent.
    fn with_artifacts(&self) {
        let artifacts = HostDirectory::open(&self.0.join("artifacts")).unwrap();
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
    }
}
/// A recorded directory's files and directories, below an owned one.
fn copy_tree(from: &Path, to: &HostDirectory) {
    for entry in fs::read_dir(from).unwrap() {
        let entry = entry.unwrap().path();
        let name = entry.file_name().unwrap().to_str().unwrap();
        if entry.is_dir() {
            copy_tree(&entry, &to.create_private_child(name).unwrap());
        } else {
            to.create_document(name, &fs::read(&entry).unwrap())
                .unwrap();
        }
    }
}

/// The digest of a recorded Swift Manifest as it reads published on
/// Windows: its `platformProfile` names this platform.
fn windows_manifest_sha256(swift: &str) -> String {
    let path = fixture("sessions/2026/09");
    for session in fs::read_dir(path).unwrap() {
        let manifest = fs::read(session.unwrap().path().join("manifest.json")).unwrap();
        if sha256_hex(&manifest) == swift {
            let manifest = String::from_utf8(manifest)
                .unwrap()
                .replace("PLATFORM-MACOS@0.2.0", "PLATFORM-WINDOWS@0.2.0");
            return sha256_hex(manifest.as_bytes());
        }
    }
    panic!("no recorded Manifest has digest {swift}")
}

impl Drop for Root {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

/// A control answer as the oracle records it, a refusal's wording aside.
fn answer(outcome: Result<Value, WireError>) -> Value {
    match outcome {
        Ok(result) => json!({"ok": true, "result": result}),
        Err(error) => {
            let mut refusal = json!({"code": error.code});
            if let Some(details) = error.details {
                refusal["details"] = Value::Object(details);
            }
            json!({"ok": false, "error": refusal})
        }
    }
}

/// A recorded answer as this host must give it: a refusal's wording aside,
/// and a Session this reconciler published (after the laid-down one, at
/// generation 1) naming its Manifest's Windows digest.
fn recorded(answer: &Value) -> Value {
    let mut answer = answer.clone();
    if let Some(error) = answer.get_mut("error").and_then(Value::as_object_mut) {
        error.remove("message");
    }
    for publication in [
        "/result/sessionPublication",
        "/result/job/sessionPublication",
    ] {
        if let Some(publication) = answer
            .pointer_mut(publication)
            .and_then(Value::as_object_mut)
            && publication.get("catalogGeneration") != Some(&json!("1"))
            && let Some(Value::String(swift)) = publication.get("manifestSha256")
        {
            let windows = windows_manifest_sha256(swift);
            publication.insert("manifestSha256".into(), json!(windows));
        }
    }
    answer
}

#[test]
fn rust_reconciles_the_swift_jobs_on_windows() {
    let root = Root::new();
    root.with_store();
    root.with_artifacts();
    root.with_first_session();
    let jobs = JobStore::open_owner(&root.0.join("jobs-state")).unwrap();
    let artifacts = ArtifactReadStore::open(&root.0.join("artifacts")).unwrap();
    let sessions =
        SessionStore::open(&root.0.join("session-owner"), &root.0.join("Sessions")).unwrap();
    let claims = StorageClaims::default();
    let publisher = SessionPublisher {
        sessions: &sessions,
        claims: &claims,
        probe: &SystemStorageProbe,
    };
    let reconciler = JobReconciler {
        jobs: &jobs,
        artifacts: &artifacts,
        imports: None,
        now: fixed_now,
        sessions: Some(&publisher),
        hdc: None,
        capabilities: None,
        runner: None,
    };
    let mut differences = Vec::new();
    for case in document(fixture("cases.json")).as_array().unwrap() {
        let actual = answer(reconciler.handle(case["params"].as_object().unwrap()));
        let expected = recorded(&case["response"]);
        if actual != expected {
            differences.push(format!(
                "{}:\n  swift {expected}\n  rust  {actual}",
                case["name"]
            ));
        }
    }
    // How each Job, its result and its evidence then read.
    let reader = JobResultReader {
        jobs: &jobs,
        artifacts: &artifacts,
    };
    let reads = document(fixture("reads.json"));
    for (job, answers) in reads.as_object().unwrap() {
        for (method, expected) in answers.as_object().unwrap() {
            let params = Map::from_iter([("jobId".into(), json!(job))]);
            let actual = answer(
                if matches!(method.as_str(), "job.result" | "job.evidence") {
                    reader.handle(method, &params)
                } else {
                    jobs.handle_resource(method, &params)
                },
            );
            let expected = recorded(expected);
            if actual != expected {
                differences.push(format!(
                    "{job} {method}:\n  swift {expected}\n  rust  {actual}"
                ));
            }
        }
    }
    assert!(differences.is_empty(), "{}", differences.join("\n"));
}
