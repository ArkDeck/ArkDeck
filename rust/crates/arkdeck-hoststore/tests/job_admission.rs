//! Replays the Swift `job.submit` oracle (`rust/tests/fixtures/job-submit-analyzer`,
//! produced by `JobSubmitAnalyzerOracleContractTests`) against the Rust
//! admitter, in order over one Job store, then compares the store it leaves:
//! every admitted Job's files and the admission index. The plan digest covers
//! the source Artifact's absolute path, so the recorded store is rebuilt at the
//! oracles' fixed root, under the lock their Swift producers also take.
#![cfg(target_os = "macos")]

#[path = "support/catalog_lineage.rs"]
mod lineage;

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
                imports: None,
                artifacts: Some(&artifacts),
                analyzer: (case["engine"] != "unconfigured").then_some(&profile),
                state_root: &root,
                hdc: None,
                workspace: None,
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

/// A fixed c6 reviewed plan remains immutable in a current e4 view. The
/// original complete positive sequence belongs to its historical c6 view;
/// this current-view test proves refusal without translating old authority.
#[test]
fn current_catalog_refuses_both_original_reviewed_plan_requests_without_admission() {
    assert_eq!(arkdeck_contract::CATALOG_DIGEST, lineage::CURRENT);
    let _lock = exclusive();
    let source = lineage::Lineage::frozen().unwrap();
    source
        .assert_current_sources(
            &Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../Catalog/operations"),
        )
        .unwrap();
    source
        .operation("analyzer.extract-crash-signature@1")
        .unwrap();
    let bytes = fs::read(fixture().join("cases.json")).unwrap();
    assert_eq!(
        arkdeck_contract::sha256_hex(&bytes),
        "83282cb310eba2bee48fd0118c5fa61b927ee5c3601da2b764a5a9cc7743d076"
    );
    let cases: Vec<Value> = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(cases.len(), 18);
    let original = |name: &str| {
        let matches: Vec<_> = cases.iter().filter(|case| case["name"] == name).collect();
        assert_eq!(matches.len(), 1);
        matches[0]
    };
    let root = rebuild();
    let artifacts = ArtifactReadStore::open(&root.join("artifacts")).unwrap();
    let profile = AnalyzerProfile::crash_signature(&root.join("analyzer")).unwrap();
    let executable_sha = arkdeck_contract::sha256_hex(&fs::read(root.join("analyzer")).unwrap());
    let jobs = JobStore::open_owner(&root.join("jobs-state")).unwrap();
    let admitter = JobAdmitter {
        planner: JobPlanner {
            imports: None,
            artifacts: Some(&artifacts),
            analyzer: Some(&profile),
            state_root: &root,
            hdc: None,
            workspace: None,
        },
        jobs: &jobs,
        now: fixed_now,
        authority: None,
    };
    // Create one fresh current Job without running it, so both the duplicate
    // and new-admission refusal branches are checked against real owner state.
    let setup = original("admitted");
    let result = admitter
        .handle(setup["params"].as_object().unwrap())
        .unwrap();
    assert_eq!(json!({"ok": true, "result": result}), setup["response"]);
    let baseline_index = index(&root.join("jobs-state"));
    let baseline_files = job_files(&root.join("jobs-state/jobs"));
    assert_eq!(baseline_index["rows"].as_array().unwrap().len(), 1);
    for (name, message) in [
        (
            "duplicateWithReviewedPlan",
            "the existing Job differs from the immutable reviewed plan",
        ),
        (
            "admittedWithReviewedPlan",
            "the fresh materialized plan differs from the immutable reviewed plan",
        ),
    ] {
        let case = original(name);
        assert_eq!(case["response"]["ok"], true);
        let params = case["params"].as_object().unwrap();
        let request: Value = serde_json::from_str(params["requestJson"].as_str().unwrap()).unwrap();
        let old_digest = request["reviewedPlanDigest"].as_str().unwrap();
        assert_eq!(
            old_digest,
            "5f31f98fb1b612ea7d0a2f37f003cd5d9d0dffefaa9919661abecc746a5a36a9"
        );
        let plan = source
            .crash_signature_plan(
                &request,
                &executable_sha,
                "/private/tmp/arkdeck-job-plan-oracle/artifacts/job-oracle-source/ART-cf645cc2f23c16cf9965b179bcb35b5e",
            )
            .unwrap();
        let new_digest = source.current_digest(&plan, old_digest).unwrap();
        assert_ne!(new_digest, old_digest);
        let fresh = admitter
            .planner
            .plan(params["requestJson"].as_str().unwrap().as_bytes())
            .unwrap();
        assert_eq!(fresh["catalogDigest"], lineage::CURRENT);
        assert_eq!(fresh["materializedPlanDigest"], new_digest);
        let refusal = admitter.handle(params).unwrap_err();
        assert!(refusal.proven);
        assert_eq!(
            json!({"ok": false, "error": {"code": refusal.code, "message": refusal.message,
                "details": {"phase": "preAdmission", "newDispatchCount": 0}}}),
            json!({"ok": false, "error": {"code": "reviewedPlanMismatch", "message": message,
                "details": {"phase": "preAdmission", "newDispatchCount": 0}}}),
            "{name}"
        );
        assert_eq!(index(&root.join("jobs-state")), baseline_index);
        assert_eq!(job_files(&root.join("jobs-state/jobs")), baseline_files);
    }
    // No run/dispatch or mutation authority is composed by this test.
    drop(jobs);
}
