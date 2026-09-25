//! Replays the Swift HiLog summary Job oracle (`rust/tests/fixtures/
//! job-run-hilog`, produced by `JobRunAnalyzerOracleContractTests/
//! testSwiftRunsTheSharedHilogSummaryJobs`) against the Rust planner,
//! admitter, runner and readers: `analyzer.summarize-hilog@1` planned where
//! the analyzer is composed, where the host's analyzer is not the daemon and
//! where none is; then the same admissions, every run in order over one store
//! with the oracle analyzer, which answers by the first line of its source,
//! and every Job's status, details, result and evidence. Every answer and the
//! store the runs leave (the Job index and files, every Artifact index and
//! payload) must be Swift's, byte for byte. The runs spawn children, so this
//! binary is theirs.
#![cfg(target_os = "macos")]

use arkdeck_hoststore::{
    AnalyzerComposition, AnalyzerProfile, AnalyzerProfiles, ArtifactReadStore, JobAdmitter,
    JobPlanner, JobResultReader, JobRunner, JobStore,
};
use arkdeck_platform::{HostSqlite, SqliteValue as Sql};
use serde_json::{Map, Value, json};
use std::collections::BTreeMap;
use std::fs::{self, File, OpenOptions};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

const ROOT: &str = "/private/tmp/arkdeck-job-plan-oracle";
const LOCK: &str = "/private/tmp/arkdeck-job-plan-oracle.lock";

fn fixture() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/fixtures/job-run-hilog")
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

/// The sources as Swift published them before any Job, and the analyzer.
fn rebuild() -> PathBuf {
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
    for file in fs::read_dir(fixture().join("artifacts/job-oracle-source")).unwrap() {
        let file = file.unwrap().path();
        let name = file.file_name().unwrap();
        let destination = root.join("artifacts/job-oracle-source").join(name);
        fs::copy(&file, &destination).unwrap();
        chmod(
            &destination,
            if name == "index.json" { 0o600 } else { 0o400 },
        );
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

/// Every file one level below each directory under `base`, dotfiles only
/// when `dotfiles` holds.
fn files(base: &Path, dotfiles: bool) -> BTreeMap<String, Vec<u8>> {
    let mut files = BTreeMap::new();
    for directory in fs::read_dir(base).unwrap() {
        let directory = directory.unwrap().path();
        for file in fs::read_dir(&directory).unwrap() {
            let file = file.unwrap().path();
            let name = file.file_name().unwrap().to_str().unwrap();
            if !dotfiles && name.starts_with('.') {
                continue;
            }
            files.insert(
                format!(
                    "{}/{name}",
                    directory.file_name().unwrap().to_str().unwrap()
                ),
                fs::read(&file).unwrap(),
            );
        }
    }
    files
}

fn same_files(rust: &BTreeMap<String, Vec<u8>>, swift: &BTreeMap<String, Vec<u8>>) {
    assert_eq!(
        rust.keys().collect::<Vec<_>>(),
        swift.keys().collect::<Vec<_>>()
    );
    for (path, bytes) in swift {
        assert_eq!(
            String::from_utf8_lossy(&rust[path]),
            String::from_utf8_lossy(bytes),
            "{path}"
        );
    }
}

fn recorded(name: &str) -> Value {
    serde_json::from_slice(&fs::read(fixture().join(name)).unwrap()).unwrap()
}

fn answer<T>(outcome: Result<Value, T>, error: impl Fn(T) -> Value) -> Value {
    match outcome {
        Ok(result) => json!({"ok": true, "result": result}),
        Err(refusal) => json!({"ok": false, "error": error(refusal)}),
    }
}

#[test]
fn rust_plans_runs_and_reads_hilog_summaries_as_swift_did() {
    let _lock = exclusive();
    let root = rebuild();
    let provenance = recorded("provenance.json");
    let artifacts = ArtifactReadStore::open(&root.join("artifacts")).unwrap();
    let jobs = JobStore::open_owner(&root.join("jobs-state")).unwrap();
    let hilog = AnalyzerProfile::hilog_summary(&root.join("analyzer")).unwrap();
    let composed = AnalyzerProfiles::new(vec![hilog], BTreeMap::new());
    // The host's analyzer is another executable than this daemon's own.
    let other_daemon = AnalyzerProfiles::for_daemon_analyzer(
        AnalyzerProfile::crash_signature(&root.join("analyzer")).unwrap(),
        Some(&"0".repeat(64)),
    );
    let unconfigured = AnalyzerProfiles::default();
    let planner = |analyzer: &'static str| JobPlanner {
        imports: None,
        artifacts: Some(&artifacts),
        analyzer: Some(match analyzer {
            "composed" => &composed as &dyn AnalyzerComposition,
            "otherDaemon" => &other_daemon,
            _ => &unconfigured,
        }),
        state_root: &root,
        hdc: None,
        workspace: None,
    };
    let refusal = |code: &str, message: String, details: Map<String, Value>| {
        let mut error = json!({"code": code, "message": message});
        if !details.is_empty() {
            error["details"] = Value::Object(details);
        }
        error
    };
    let mut differences = Vec::new();
    for plan in recorded("plans.json").as_array().unwrap() {
        let composition = plan["composition"].as_str().unwrap();
        let mut actual = answer(
            planner(match composition {
                "composed" => "composed",
                "otherDaemon" => "otherDaemon",
                _ => "unconfigured",
            })
            .handle(plan["params"].as_object().unwrap()),
            |refused| {
                refusal(
                    refused.code,
                    refused.message,
                    Map::from_iter([
                        ("newDispatchCount".into(), json!(0)),
                        ("phase".into(), json!("preAdmission")),
                    ]),
                )
            },
        );
        if let Some(result) = actual.get_mut("result").and_then(Value::as_object_mut) {
            // The step set's digest is Rust presentation provenance (#2121),
            // not in Swift's answer: Swift's `stepSetDigest` of the one step.
            assert_eq!(
                result.remove("stepSetDigestSHA256"),
                Some(json!(arkdeck_contract::sha256_hex(
                    b"summarize-hilog|runDeterministicAnalyzer|hostOnly|immediate|none"
                )))
            );
        }
        if actual != plan["response"] {
            differences.push(format!(
                "plan {composition}:\n  swift {}\n  rust  {actual}",
                plan["response"]
            ));
        }
    }
    let cases = recorded("cases.json");
    // The admissions Swift made, through the Rust admitter.
    for case in cases.as_array().unwrap() {
        let accepted = JobAdmitter {
            planner: planner("composed"),
            jobs: &jobs,
            now: fixed_now,
            authority: None,
        }
        .handle(case["submit"].as_object().unwrap());
        // A refusal before the admission point proves zero dispatch; Swift
        // attaches empty details to any later failure.
        let actual = answer(accepted, |refused| {
            json!({"code": refused.code, "message": refused.message,
            "details": if refused.proven {
                json!({"newDispatchCount": 0, "phase": "preAdmission"})
            } else {
                json!({})
            }})
        });
        if actual != case["accepted"] {
            differences.push(format!(
                "{} admission:\n  swift {}\n  rust  {actual}",
                case["name"], case["accepted"]
            ));
        }
    }
    let runner = JobRunner {
        imports: None,
        mutation: None,
        jobs: &jobs,
        artifacts: &artifacts,
        analyzer: Some(&composed),
        quota: provenance["quotaBytes"].as_u64().unwrap(),
        home: provenance["home"].as_str().unwrap(),
        now: fixed_now,
        precise_now: fixed_precise_now,
        sessions: None,
        cancellation: None,
        after_commit: None,
        hdc: None,
        workspace: None,
    };
    for case in cases.as_array().unwrap() {
        let actual = answer(
            runner.handle(case["params"].as_object().unwrap()),
            |refused| refusal(refused.code, refused.message, refused.details),
        );
        if actual != case["response"] {
            differences.push(format!(
                "{} run:\n  swift {}\n  rust  {actual}",
                case["name"], case["response"]
            ));
        }
    }
    // Each Job's status, details, result and evidence, as Swift read them.
    let reader = JobResultReader {
        jobs: &jobs,
        artifacts: &artifacts,
    };
    for (job, answers) in recorded("reads.json").as_object().unwrap() {
        for (method, recorded) in answers.as_object().unwrap() {
            let params = Map::from_iter([("jobId".into(), json!(job))]);
            let outcome = if matches!(method.as_str(), "job.result" | "job.evidence") {
                reader.handle(method, &params)
            } else {
                jobs.handle_resource(method, &params)
            };
            let actual = answer(outcome, |error| {
                let mut body = json!({"code": error.code, "message": error.message});
                if let Some(details) = error.details {
                    body["details"] = Value::Object(details);
                }
                body
            });
            if &actual != recorded {
                differences.push(format!(
                    "{job} {method}:\n  swift {recorded}\n  rust  {actual}"
                ));
            }
        }
    }
    assert!(differences.is_empty(), "{}", differences.join("\n"));
    drop(jobs);
    assert_eq!(
        index(&root.join("jobs-state")),
        recorded("store/index.json")
    );
    same_files(
        &files(&root.join("jobs-state/jobs"), true),
        &files(&fixture().join("store/jobs"), true),
    );
    let published = files(&root.join("artifacts"), false);
    same_files(&published, &files(&fixture().join("artifacts"), false));
    for path in published
        .keys()
        .filter(|path| !path.ends_with("index.json"))
    {
        let mode = fs::metadata(root.join("artifacts").join(path))
            .unwrap()
            .permissions()
            .mode();
        assert_eq!(mode & 0o777, 0o400, "{path}");
    }
    // The Job a signal parked is reconciled as Swift reconciles a parked
    // analyzer Job: its source is the one its intent named, so the analyzer
    // is confirmed not to have produced an answer; the Job fails by that
    // name and nothing runs again.
    let parked = cases
        .as_array()
        .unwrap()
        .iter()
        .find(|case| case["name"] == "signalled")
        .unwrap()["params"]
        .clone();
    let jobs = JobStore::open_owner(&root.join("jobs-state")).unwrap();
    let reconciler = arkdeck_hoststore::JobReconciler {
        jobs: &jobs,
        artifacts: &artifacts,
        imports: None,
        now: fixed_now,
        sessions: None,
        hdc: None,
        capabilities: None,
        runner: None,
    };
    for _ in 0..2 {
        let reconciled = reconciler.handle(parked.as_object().unwrap()).unwrap();
        assert_eq!(reconciled["outcome"], "failed", "{reconciled}");
        assert_eq!(reconciled["outcomeUnknown"], false, "{reconciled}");
        assert_eq!(
            reconciled["failure"]["code"], "executionConfirmedNotPerformed",
            "{reconciled}"
        );
        assert_eq!(
            reconciled["failure"]["recovery"], "submitNewTypedRequestAfterRuntimeProof",
            "{reconciled}"
        );
    }
    drop(jobs);
    fs::remove_dir_all(&root).unwrap();
}
