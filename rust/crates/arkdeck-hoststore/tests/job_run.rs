//! Replays the Swift `job.run` oracle (`rust/tests/fixtures/job-run-analyzer`,
//! produced by `JobRunAnalyzerOracleContractTests`) against the Rust runner:
//! the same sources, the same admissions through the Rust admitter, then every
//! run in order over one store with the oracle analyzer, which answers by the
//! first line of its source. Each Job is admitted and run under the analyzer
//! budget Swift gave it: the provenance's production budget, or the short one
//! the timeout case's entries name. Every answer, every read and the store the
//! runs leave (the Job index and files, every Artifact index and payload) must
//! be Swift's, byte for byte. The runs spawn children, so this binary is theirs.
#![cfg(target_os = "macos")]

use arkdeck_hoststore::{
    AnalyzerProfile, ArtifactReadStore, JobAdmitter, JobPlanner, JobResultReader, JobRunner,
    JobStore,
};
use arkdeck_platform::{HostSqlite, SqliteValue as Sql};
use serde_json::{Map, Value, json};
use std::collections::BTreeMap;
use std::fs::{self, File, OpenOptions};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

const ROOT: &str = "/private/tmp/arkdeck-job-plan-oracle";
const LOCK: &str = "/private/tmp/arkdeck-job-plan-oracle.lock";
const SOURCES: [&str; 2] = ["job-oracle-source", "job-oracle-source-removed"];

fn fixture() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/fixtures/job-run-analyzer")
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

/// The sources as Swift published them before any run: every recorded
/// source payload, and the one a case later removes rebuilt from its mode.
fn rebuild(cases: &[Value]) -> PathBuf {
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
        let bytes = format!(
            "{}\nFault log list:\n******\n",
            case["mode"].as_str().unwrap()
        );
        let (job, artifact) = removed.split_once('/').unwrap();
        let index: Value = serde_json::from_slice(
            &fs::read(root.join("artifacts").join(job).join("index.json")).unwrap(),
        )
        .unwrap();
        let row = index["artifacts"]
            .as_array()
            .unwrap()
            .iter()
            .find(|row| row["artifactID"] == artifact)
            .unwrap();
        assert_eq!(
            row["sha256"],
            arkdeck_contract::sha256_hex(bytes.as_bytes())
        );
        let path = root.join("artifacts").join(removed);
        fs::write(&path, bytes).unwrap();
        chmod(&path, 0o400);
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

#[test]
fn rust_runs_reproduce_the_swift_oracle() {
    let _lock = exclusive();
    let cases: Vec<Value> =
        serde_json::from_slice(&fs::read(fixture().join("cases.json")).unwrap()).unwrap();
    let provenance: Value =
        serde_json::from_slice(&fs::read(fixture().join("provenance.json")).unwrap()).unwrap();
    let root = rebuild(&cases);
    let artifacts = ArtifactReadStore::open(&root.join("artifacts")).unwrap();
    // One analyzer profile per budget Swift composed: the production budget,
    // and the short one only the timeout case's entries name.
    let production = provenance["timeoutSeconds"].as_i64().unwrap();
    let budget = |case: &Value| case["timeoutSeconds"].as_i64().unwrap_or(production);
    let profiles: BTreeMap<i64, AnalyzerProfile> = cases
        .iter()
        .map(budget)
        .chain([production])
        .map(|seconds| {
            let mut profile = AnalyzerProfile::crash_signature(&root.join("analyzer")).unwrap();
            profile.timeout_seconds = seconds;
            (seconds, profile)
        })
        .collect();
    let jobs = JobStore::open_owner(&root.join("jobs-state")).unwrap();
    // The admissions the Swift oracle made, through the Rust admitter.
    for case in cases.iter().filter(|case| case["submit"].is_object()) {
        let accepted = JobAdmitter {
            planner: JobPlanner {
                imports: None,
                artifacts: Some(&artifacts),
                analyzer: Some(&profiles[&budget(case)]),
                state_root: &root,
                hdc: None,
            },
            jobs: &jobs,
            now: fixed_now,
            authority: None,
        }
        .handle(case["submit"].as_object().unwrap())
        .unwrap();
        assert_eq!(
            accepted["jobId"], case["params"]["jobId"],
            "{}",
            case["name"]
        );
    }
    let runners: BTreeMap<i64, JobRunner<'_>> = profiles
        .iter()
        .map(|(seconds, profile)| {
            let runner = JobRunner {
                imports: None,
                jobs: &jobs,
                artifacts: &artifacts,
                analyzer: Some(profile),
                quota: provenance["quotaBytes"].as_u64().unwrap(),
                home: provenance["home"].as_str().unwrap(),
                now: fixed_now,
                precise_now: fixed_precise_now,
                sessions: None,
                cancellation: None,
                after_commit: None,
                hdc: None,
            };
            (*seconds, runner)
        })
        .collect();
    let mut differences = Vec::new();
    for case in &cases {
        if let Some(removed) = case["removesSourcePayload"].as_str() {
            fs::remove_file(root.join("artifacts").join(removed)).unwrap();
        }
        let actual = match runners[&budget(case)].handle(case["params"].as_object().unwrap()) {
            Ok(result) => json!({"ok": true, "result": result}),
            Err(refusal) => json!({"ok": false, "error": {"code": refusal.code,
                "message": refusal.message, "details": Value::Object(refusal.details)}}),
        };
        if actual != case["response"] {
            differences.push(format!(
                "{}:\n  swift {}\n  rust  {actual}",
                case["name"], case["response"]
            ));
        }
    }
    assert!(differences.is_empty(), "{}", differences.join("\n"));
    // The Rust readers answer every read Swift recorded exactly as Swift did:
    // each Rust-run Job's status, details, result and evidence, every Job read
    // of an absent Job, and the result and evidence reads of open options.
    {
        let reader = JobResultReader {
            jobs: &jobs,
            artifacts: &artifacts,
        };
        let answer = |method: &str, params: &Map<String, Value>| -> Value {
            let outcome = if matches!(method, "job.result" | "job.evidence") {
                reader.handle(method, params)
            } else {
                jobs.handle_resource(method, params)
            };
            match outcome {
                Ok(result) => json!({"ok": true, "result": result}),
                Err(error) => {
                    let mut body = json!({"code": error.code, "message": error.message});
                    if let Some(details) = error.details {
                        body["details"] = Value::Object(details);
                    }
                    json!({"ok": false, "error": body})
                }
            }
        };
        let reads: Value =
            serde_json::from_slice(&fs::read(fixture().join("reads.json")).unwrap()).unwrap();
        let mut differences = Vec::new();
        for (job, answers) in reads.as_object().unwrap() {
            for (method, recorded) in answers.as_object().unwrap() {
                let actual = answer(method, &Map::from_iter([("jobId".into(), json!(job))]));
                if &actual != recorded {
                    differences.push(format!(
                        "{job} {method}:\n  swift {recorded}\n  rust  {actual}"
                    ));
                }
            }
        }
        let refused: Vec<Value> =
            serde_json::from_slice(&fs::read(fixture().join("refused-reads.json")).unwrap())
                .unwrap();
        for read in &refused {
            let actual = answer(
                read["method"].as_str().unwrap(),
                read["params"].as_object().unwrap(),
            );
            if actual != read["response"] {
                differences.push(format!(
                    "{} {}:\n  swift {}\n  rust  {actual}",
                    read["method"], read["params"], read["response"]
                ));
            }
        }
        assert!(differences.is_empty(), "{}", differences.join("\n"));
    }
    drop(jobs);
    let recorded: Value =
        serde_json::from_slice(&fs::read(fixture().join("store/index.json")).unwrap()).unwrap();
    assert_eq!(index(&root.join("jobs-state")), recorded);
    same_files(
        &files(&root.join("jobs-state/jobs"), true),
        &files(&fixture().join("store/jobs"), true),
    );
    let published = files(&root.join("artifacts"), false);
    same_files(&published, &files(&fixture().join("artifacts"), false));
    // Published payloads are sealed owner read-only, as Swift seals them.
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
    fs::remove_dir_all(&root).unwrap();
}
