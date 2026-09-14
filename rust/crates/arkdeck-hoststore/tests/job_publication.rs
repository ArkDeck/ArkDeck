//! Replays the Swift Session publication oracle
//! (`rust/tests/fixtures/job-publication-analyzer`, produced by
//! `JobRunAnalyzerOracleContractTests.testSwiftPublishesTheSharedAnalyzerSessions`)
//! against the Rust runner composed with the publication writer, as the
//! standalone Swift daemon is: the same sources and admissions, then every run
//! in order over one store, a Sessions root and a storage owner, with a probe
//! that reports the volume full where the oracle's did. Every answer, every
//! read and everything the runs leave (the Job index and files, every Artifact,
//! every file of the Sessions root and the storage owner, and every entry's
//! kind and mode) must be Swift's byte for byte, once each Job record's
//! volume, device, inode and claim generation are read as labels. The runs
//! spawn children, so this binary is theirs.
#![cfg(target_os = "macos")]

use arkdeck_hoststore::{
    AnalyzerProfile, ArtifactReadStore, JobAdmitter, JobPlanner, JobRunner, JobStore,
    SessionPublisher, SessionStore, StorageClaims, StorageProbe, StorageSnapshot,
};
use arkdeck_platform::{HostDirectory, HostSqlite, SqliteValue as Sql};
use serde_json::{Map, Value, json};
use std::collections::BTreeMap;
use std::fs::{self, File, OpenOptions};
use std::io;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};

const ROOT: &str = "/private/tmp/arkdeck-job-plan-oracle";
const LOCK: &str = "/private/tmp/arkdeck-job-plan-oracle.lock";
const SOURCES: [&str; 2] = ["job-oracle-source", "job-oracle-source-removed"];
const MACHINE_FACTS: [&str; 4] = ["device", "inode", "volumeIdentity", "admissionGeneration"];

fn fixture() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/fixtures/job-publication-analyzer")
}

fn chmod(path: &Path, mode: u32) {
    fs::set_permissions(path, fs::Permissions::from_mode(mode)).unwrap();
}

fn fixed_now() -> Option<String> {
    Some("2026-09-14T00:00:00Z".into())
}

fn fixed_precise_now() -> Option<String> {
    Some("2026-09-14T00:00:00.000Z".into())
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

/// The oracle's probe: this machine's volume with room for every claim,
/// unless a case reports it full.
struct OracleProbe(AtomicBool, u64);

impl StorageProbe for OracleProbe {
    fn snapshot(&self, root: &HostDirectory) -> io::Result<StorageSnapshot> {
        Ok(StorageSnapshot {
            volume_identity: root.export_facts()?.volume_identity,
            available_bytes: if self.0.load(Ordering::SeqCst) {
                0
            } else {
                self.1
            },
            read_only: false,
        })
    }
}

/// The sources as Swift published them before any run, the one a case later
/// removes rebuilt from its mode, and the empty owner and Sessions roots.
fn rebuild(cases: &[Value]) -> PathBuf {
    let root = PathBuf::from(ROOT);
    let _ = fs::remove_dir_all(&root);
    for directory in [
        root.clone(),
        root.join("artifacts"),
        root.join("jobs-state"),
        root.join("Sessions"),
        root.join("session-owner"),
    ] {
        fs::create_dir(&directory).unwrap();
        chmod(&directory, 0o700);
    }
    fs::copy(fixture().join("analyzer"), root.join("analyzer")).unwrap();
    chmod(&root.join("analyzer"), 0o700);
    for job in SOURCES {
        let destination = root.join("artifacts").join(job);
        fs::create_dir(&destination).unwrap();
        chmod(&destination, 0o700);
        for file in fs::read_dir(fixture().join("artifacts").join(job)).unwrap() {
            let file = file.unwrap().path();
            let name = file.file_name().unwrap();
            fs::copy(&file, destination.join(name)).unwrap();
            chmod(
                &destination.join(name),
                if name == "index.json" { 0o600 } else { 0o400 },
            );
        }
    }
    for case in cases {
        let Some(removed) = case["removesSourcePayload"].as_str() else {
            continue;
        };
        let path = root.join("artifacts").join(removed);
        fs::write(
            &path,
            format!(
                "{}\nFault log list:\n******\n",
                case["mode"].as_str().unwrap()
            ),
        )
        .unwrap();
        chmod(&path, 0o400);
    }
    root
}

/// A Job record's publication marker names this machine's volume, device,
/// inode and claim generation; each reads as a fixed label, and a refused
/// marker's blank or zero value stays as it is.
fn machine_independent(bytes: &[u8]) -> Vec<u8> {
    let mut text = String::from_utf8(bytes.to_vec()).unwrap();
    for key in MACHINE_FACTS {
        let needle = format!("\"{key}\"");
        let label = format!("<{key}>");
        let mut out = String::new();
        let mut rest = text.as_str();
        while let Some(at) = rest.find(&needle) {
            let (head, tail) = rest.split_at(at + needle.len());
            out.push_str(head);
            rest = tail;
            let Some(value) = tail
                .trim_start_matches(' ')
                .strip_prefix(':')
                .map(|after| after.trim_start_matches(' '))
                .and_then(|after| after.strip_prefix('"'))
            else {
                continue;
            };
            let Some(end) = value.find('"') else {
                continue;
            };
            out.push_str(&tail[..tail.len() - value.len()]);
            let current = &value[..end];
            out.push_str(if current.is_empty() || current == "0" {
                current
            } else {
                &label
            });
            rest = &value[end..];
        }
        out.push_str(rest);
        text = out;
    }
    text.into_bytes()
}

/// The facts the Swift oracle records of the Job index, each record's
/// digest taken over its machine-independent reading.
fn index(path: &Path) -> Value {
    let mut db = HostSqlite::open(&path.join("runtime-jobs.sqlite3"), true, false).unwrap();
    let cell = |value: &Sql| match value {
        Sql::Null => Value::Null,
        Sql::Integer(n) => json!(n),
        Sql::Text(text) => json!(text),
        Sql::Blob(bytes) => json!(arkdeck_contract::sha256_hex(&machine_independent(bytes))),
    };
    let mut query = |sql: &str| db.query(sql, &[], 64 << 20).unwrap();
    let schema: Vec<Value> =
        query("SELECT name, type, tbl_name, sql FROM sqlite_schema ORDER BY name")
            .iter()
            .map(|row| {
                json!({"name": cell(&row[0]), "type": cell(&row[1]), "tableName": cell(&row[2]),
                "sql": cell(&row[3])})
            })
            .collect();
    let rows: Vec<Value> = query(
        "SELECT job_id, idempotency_key, request_hash, state, admission_sequence, created_at_utc, created_at_order_key, updated_at_utc, version, initial_record_json FROM runtime_job ORDER BY admission_sequence",
    )
    .iter()
    .map(|row| {
        json!({"jobId": cell(&row[0]), "idempotencyKey": cell(&row[1]),
            "requestHash": cell(&row[2]), "state": cell(&row[3]),
            "admissionSequence": cell(&row[4]), "createdAtUTC": cell(&row[5]),
            "createdAtOrderKey": cell(&row[6]), "updatedAtUTC": cell(&row[7]),
            "version": cell(&row[8]), "recordSHA256": cell(&row[9])})
    })
    .collect();
    let version = cell(&query("PRAGMA user_version")[0][0]);
    let mode = cell(&query("PRAGMA journal_mode")[0][0]);
    json!({"userVersion": version, "journalMode": mode, "schema": schema, "rows": rows})
}

/// Every entry below `base` as `prefix/<relative path>`: each file's bytes
/// (a Job record's read machine-independently) and each entry's kind and mode.
fn walk(
    base: &Path,
    prefix: &str,
    files: &mut BTreeMap<String, Vec<u8>>,
    tree: &mut Vec<(String, &'static str, String)>,
) {
    let mut entries = Vec::new();
    let mut pending = vec![PathBuf::new()];
    while let Some(relative) = pending.pop() {
        for entry in fs::read_dir(base.join(&relative)).unwrap() {
            let entry = entry.unwrap();
            let path = relative.join(entry.file_name());
            if entry.file_type().unwrap().is_dir() {
                pending.push(path.clone());
            }
            entries.push(path);
        }
    }
    entries.sort();
    for relative in entries {
        let path = base.join(&relative);
        let metadata = fs::symlink_metadata(&path).unwrap();
        let name = format!("{prefix}/{}", relative.display());
        let kind = if metadata.is_dir() {
            "directory"
        } else {
            "file"
        };
        tree.push((
            name.clone(),
            kind,
            format!("{:o}", metadata.permissions().mode() & 0o777),
        ));
        if metadata.is_file() {
            let bytes = fs::read(&path).unwrap();
            files.insert(
                name,
                if relative.file_name().unwrap() == "job-record.json" {
                    machine_independent(&bytes)
                } else {
                    bytes
                },
            );
        }
    }
}

/// Every Artifact index and payload, the verification cache aside.
fn artifacts(base: &Path) -> BTreeMap<String, Vec<u8>> {
    let mut files = BTreeMap::new();
    for directory in fs::read_dir(base).unwrap() {
        let directory = directory.unwrap().path();
        let job = directory.file_name().unwrap().to_str().unwrap().to_owned();
        if job.starts_with('.') {
            continue;
        }
        for file in fs::read_dir(&directory).unwrap() {
            let file = file.unwrap().path();
            let name = file.file_name().unwrap().to_str().unwrap().to_owned();
            if !name.starts_with('.') {
                files.insert(format!("artifacts/{job}/{name}"), fs::read(&file).unwrap());
            }
        }
    }
    files
}

#[test]
fn rust_publishes_the_swift_sessions() {
    let _lock = exclusive();
    let cases: Vec<Value> =
        serde_json::from_slice(&fs::read(fixture().join("cases.json")).unwrap()).unwrap();
    let provenance: Value =
        serde_json::from_slice(&fs::read(fixture().join("provenance.json")).unwrap()).unwrap();
    let root = rebuild(&cases);
    let artifact_store = ArtifactReadStore::open(&root.join("artifacts")).unwrap();
    let mut profile = AnalyzerProfile::crash_signature(&root.join("analyzer")).unwrap();
    profile.timeout_seconds = provenance["timeoutSeconds"].as_i64().unwrap();
    let jobs = JobStore::open_owner(&root.join("jobs-state")).unwrap();
    let sessions = SessionStore::open(&root.join("session-owner"), &root.join("Sessions")).unwrap();
    for case in &cases {
        let accepted = JobAdmitter {
            planner: JobPlanner {
                artifacts: Some(&artifact_store),
                analyzer: Some(&profile),
                state_root: &root,
            },
            jobs: &jobs,
            now: fixed_now,
        }
        .handle(case["submit"].as_object().unwrap())
        .unwrap();
        assert_eq!(
            accepted["jobId"], case["params"]["jobId"],
            "{}",
            case["name"]
        );
    }
    let probe = OracleProbe(
        AtomicBool::new(false),
        provenance["availableBytes"].as_u64().unwrap(),
    );
    let claims = StorageClaims::default();
    let publisher = SessionPublisher {
        sessions: &sessions,
        claims: &claims,
        probe: &probe,
    };
    let runner = JobRunner {
        jobs: &jobs,
        artifacts: &artifact_store,
        analyzer: Some(&profile),
        quota: provenance["quotaBytes"].as_u64().unwrap(),
        home: provenance["home"].as_str().unwrap(),
        now: fixed_now,
        precise_now: fixed_precise_now,
        sessions: Some(&publisher),
    };
    let mut differences = Vec::new();
    for case in &cases {
        let job = case["params"]["jobId"].as_str().unwrap();
        if let Some(removed) = case["removesSourcePayload"].as_str() {
            fs::remove_file(root.join("artifacts").join(removed)).unwrap();
        }
        if case["presetsSession"] == true {
            // Something else already holds this Job's Session path.
            let mut path = root.join("Sessions");
            for part in ["2026", "09", &format!("session-{job}")] {
                path.push(part);
                if !path.exists() {
                    fs::create_dir(&path).unwrap();
                    chmod(&path, 0o700);
                }
            }
        }
        probe
            .0
            .store(case["exhaustsStorage"] == true, Ordering::SeqCst);
        let actual = match runner.handle(case["params"].as_object().unwrap()) {
            Ok(result) => json!({"ok": true, "result": result}),
            Err(refusal) => json!({"ok": false, "error": {"code": refusal.code,
                "message": refusal.message, "details": Value::Object(refusal.details)}}),
        };
        probe.0.store(false, Ordering::SeqCst);
        if actual != case["response"] {
            differences.push(format!(
                "{}:\n  swift {}\n  rust  {actual}",
                case["name"], case["response"]
            ));
        }
    }
    assert!(differences.is_empty(), "{}", differences.join("\n"));
    // How the Rust reader then reads each Job's status and details.
    let reads: Value =
        serde_json::from_slice(&fs::read(fixture().join("reads.json")).unwrap()).unwrap();
    for (job, answers) in reads.as_object().unwrap() {
        for (method, recorded) in answers.as_object().unwrap() {
            let actual = match jobs
                .handle_resource(method, &Map::from_iter([("jobId".into(), json!(job))]))
            {
                Ok(result) => json!({"ok": true, "result": result}),
                Err(error) => json!({"ok": false, "error": {"code": error.code,
                    "message": error.message}}),
            };
            assert_eq!(&actual, recorded, "{job} {method}");
        }
    }
    drop(jobs);
    let recorded: Value =
        serde_json::from_slice(&fs::read(fixture().join("store/index.json")).unwrap()).unwrap();
    assert_eq!(index(&root.join("jobs-state")), recorded);

    let (mut files, mut tree) = (BTreeMap::new(), Vec::new());
    for (base, prefix) in [
        (root.join("jobs-state/jobs"), "store/jobs"),
        (root.join("Sessions"), "sessions"),
        (root.join("session-owner"), "session-owner"),
    ] {
        walk(&base, prefix, &mut files, &mut tree);
    }
    files.extend(artifacts(&root.join("artifacts")));
    let expected: Vec<Value> =
        serde_json::from_slice(&fs::read(fixture().join("tree.json")).unwrap()).unwrap();
    let actual: Vec<Value> = tree
        .iter()
        .map(|(path, kind, mode)| json!({"path": path, "kind": kind, "mode": mode}))
        .collect();
    assert_eq!(actual, expected);
    let mut recorded = BTreeMap::new();
    for (path, _) in provenance["files"].as_object().unwrap() {
        if ["store/jobs/", "sessions/", "session-owner/", "artifacts/"]
            .iter()
            .any(|prefix| path.starts_with(prefix))
        {
            recorded.insert(path.clone(), fs::read(fixture().join(path)).unwrap());
        }
    }
    assert_eq!(
        files.keys().collect::<Vec<_>>(),
        recorded.keys().collect::<Vec<_>>()
    );
    for (path, bytes) in &recorded {
        assert_eq!(
            String::from_utf8_lossy(&files[path]),
            String::from_utf8_lossy(bytes),
            "{path}"
        );
    }
    fs::remove_dir_all(&root).unwrap();
}
