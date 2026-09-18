//! Replays the Swift `job.submit` oracle (`rust/tests/fixtures/job-submit-analyzer`,
//! produced by `JobSubmitAnalyzerOracleContractTests`) against the Rust
//! admitter, in order over one Job store, then compares the store it leaves:
//! every admitted Job's files and the admission index. The plan digest covers
//! the source Artifact's absolute path, so the recorded store is rebuilt at the
//! oracles' fixed root, under the lock their Swift producers also take.
#![cfg(target_os = "macos")]

use arkdeck_hoststore::{AnalyzerProfile, ArtifactReadStore, JobAdmitter, JobPlanner, JobStore};
use arkdeck_platform::{HostSqlite, SqliteValue as Sql};
use serde_json::{Map, Value, json};
use std::collections::BTreeMap;
use std::fs::{self, File, OpenOptions};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

const ROOT: &str = "/private/tmp/arkdeck-job-plan-oracle";
const LOCK: &str = "/private/tmp/arkdeck-job-plan-oracle.lock";

fn fixture() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/fixtures/job-submit-analyzer")
}

fn chmod(path: &Path, mode: u32) {
    fs::set_permissions(path, fs::Permissions::from_mode(mode)).unwrap();
}

/// The oracle's clock.
fn fixed_now() -> Option<String> {
    Some("2026-09-14T00:00:00Z".into())
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

/// The recorded Artifact store and analyzer at the fixed root, with the modes
/// Swift publication leaves, beside an empty private Job state directory.
fn rebuild() -> PathBuf {
    let root = PathBuf::from(ROOT);
    let _ = fs::remove_dir_all(&root);
    for directory in [
        root.clone(),
        root.join("artifacts"),
        root.join("jobs-state"),
    ] {
        fs::create_dir(&directory).unwrap();
        chmod(&directory, 0o700);
    }
    fs::copy(fixture().join("analyzer"), root.join("analyzer")).unwrap();
    chmod(&root.join("analyzer"), 0o700);
    for job in fs::read_dir(fixture().join("artifacts")).unwrap() {
        let job = job.unwrap().path();
        let destination = root.join("artifacts").join(job.file_name().unwrap());
        fs::create_dir(&destination).unwrap();
        chmod(&destination, 0o700);
        for file in fs::read_dir(&job).unwrap() {
            let file = file.unwrap().path();
            let name = file.file_name().unwrap();
            fs::copy(&file, destination.join(name)).unwrap();
            chmod(
                &destination.join(name),
                if name == "index.json" { 0o600 } else { 0o400 },
            );
        }
    }
    root
}

/// The facts the Swift oracle records, read through a read-only connection.
fn index(path: &Path) -> Value {
    let mut db = HostSqlite::open(&path.join("runtime-jobs.sqlite3"), true, false).unwrap();
    let cell = |value: &Sql| match value {
        Sql::Null => Value::Null,
        Sql::Integer(n) => json!(n),
        Sql::Text(text) => json!(text),
        Sql::Blob(bytes) => json!(arkdeck_contract::sha256_hex(bytes)),
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

/// Every file under `jobs/`, by path below it.
fn job_files(jobs: &Path) -> BTreeMap<String, Vec<u8>> {
    let mut files = BTreeMap::new();
    for job in fs::read_dir(jobs).unwrap() {
        let job = job.unwrap().path();
        for file in fs::read_dir(&job).unwrap() {
            let file = file.unwrap().path();
            let name = format!(
                "{}/{}",
                job.file_name().unwrap().to_str().unwrap(),
                file.file_name().unwrap().to_str().unwrap()
            );
            files.insert(name, fs::read(&file).unwrap());
        }
    }
    files
}

#[test]
fn rust_admissions_reproduce_the_swift_oracle() {
    let _lock = exclusive();
    let root = rebuild();
    let cases: Vec<Value> =
        serde_json::from_slice(&fs::read(fixture().join("cases.json")).unwrap()).unwrap();
    let artifacts = ArtifactReadStore::open(&root.join("artifacts")).unwrap();
    let profile = AnalyzerProfile::crash_signature(&root.join("analyzer")).unwrap();
    let jobs = JobStore::open_owner(&root.join("jobs-state")).unwrap();
    let zero = json!({"phase": "preAdmission", "newDispatchCount": 0});
    let mut admitted = 0;
    let mut differences = Vec::new();
    for case in &cases {
        let name = case["name"].as_str().unwrap();
        let params = match &case["params"] {
            Value::Object(params) => params.clone(),
            _ => Map::from_iter([(
                "requestJson".into(),
                json!(" ".repeat(case["requestJsonSpaces"].as_u64().unwrap() as usize)),
            )]),
        };
        let outcome = JobAdmitter {
            planner: JobPlanner {
                artifacts: Some(&artifacts),
                analyzer: (case["engine"] != "unconfigured").then_some(&profile),
                state_root: &root,
                hdc: None,
            },
            jobs: &jobs,
            now: fixed_now,
            authority: None,
        }
        .handle(&params);
        let actual = match outcome {
            Ok(result) => {
                admitted += usize::from(result["deduplicated"] == false);
                json!({"ok": true, "result": result})
            }
            Err(refusal) => json!({"ok": false, "error": {"code": refusal.code,
                "message": refusal.message,
                "details": if refusal.proven { zero.clone() } else { json!({}) }}}),
        };
        if actual != case["response"] {
            differences.push(format!(
                "{name}:\n  swift {}\n  rust  {actual}",
                case["response"]
            ));
        }
    }
    assert!(differences.is_empty(), "{}", differences.join("\n"));
    assert_eq!(admitted, 4, "the oracle admits four Jobs");
    // The Rust reader projects each Rust-admitted Job exactly as Swift reads
    // its own, the one carrying a thread included.
    let reads: Value =
        serde_json::from_slice(&fs::read(fixture().join("reads.json")).unwrap()).unwrap();
    assert_eq!(reads.as_object().unwrap().len(), 4);
    for (job, answers) in reads.as_object().unwrap() {
        for method in ["job.status", "job.show"] {
            let params = Map::from_iter([("jobId".into(), json!(job))]);
            let result = jobs.handle_resource(method, &params).unwrap();
            assert_eq!(answers[method]["ok"], true, "{job} {method}");
            assert_eq!(result, answers[method]["result"], "{job} {method}");
        }
    }
    drop(jobs);
    let recorded: Value =
        serde_json::from_slice(&fs::read(fixture().join("store/index.json")).unwrap()).unwrap();
    assert_eq!(index(&root.join("jobs-state")), recorded);
    let swift = job_files(&fixture().join("store/jobs"));
    let rust = job_files(&root.join("jobs-state/jobs"));
    assert_eq!(
        rust.keys().collect::<Vec<_>>(),
        swift.keys().collect::<Vec<_>>()
    );
    for (path, bytes) in &swift {
        assert_eq!(
            String::from_utf8_lossy(&rust[path]),
            String::from_utf8_lossy(bytes),
            "{path}"
        );
    }
    fs::remove_dir_all(&root).unwrap();
}
