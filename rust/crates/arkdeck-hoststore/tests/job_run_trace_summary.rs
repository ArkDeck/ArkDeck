//! Replays the Swift trace-summary Job oracle (`rust/tests/fixtures/
//! job-run-trace-summary`, produced by `JobRunAnalyzerOracleContractTests/
//! testSwiftRunsTheSharedTraceSummaryJobs`) against the Rust planner,
//! admitter, runner and readers: `analyzer.summarize-trace@1` planned where a
//! reviewed ArkTrace distribution is composed and where none is; then the
//! same admissions and every run in order over one store with the checked-in
//! ArkTrace stand-in, launched at its canonical bundle path while the bundle,
//! its pinned files, its pinned tree and the source are held; the last three
//! Jobs each while one of those no longer holds — a file added to the pinned
//! tree, the pinned `Info.plist` changed, the bundle writable by others — as
//! the plan made then; and every Job's status, details, result and evidence.
//! Every answer, the arguments each child was given and the store the runs
//! leave (the Job index and files, every Artifact index and payload) must be
//! Swift's, byte for byte. The runs spawn children, so this binary is theirs.
#![cfg(target_os = "macos")]

use arkdeck_hoststore::{
    AnalyzerComposition, AnalyzerProfile, AnalyzerProfiles, ArkTraceContract, ArkTraceProfileError,
    ArtifactReadStore, JobAdmitter, JobPlanner, JobResultReader, JobRunner, JobStore, PinnedFile,
    PinnedTree,
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
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/fixtures/job-run-trace-summary")
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

fn recorded(name: &str) -> Value {
    serde_json::from_slice(&fs::read(fixture().join(name)).unwrap()).unwrap()
}

fn text(value: &Value) -> String {
    value.as_str().unwrap().to_owned()
}

/// The distribution, the stand-in's answers and the sources as Swift wrote
/// them before any Job, and the profile Swift composed for that
/// distribution.
fn rebuild() -> (PathBuf, AnalyzerProfile) {
    let root = PathBuf::from(ROOT);
    let _ = fs::remove_dir_all(&root);
    for directory in [
        "",
        "ArkTrace.app",
        "ArkTrace.app/Contents",
        "ArkTrace.app/Contents/MacOS",
        "ArkTrace.app/Contents/Resources",
        "arktrace",
        "arktrace/answers",
        "artifacts",
        "artifacts/job-oracle-source",
        "jobs-state",
    ] {
        let directory = root.join(directory);
        fs::create_dir(&directory).unwrap();
        chmod(&directory, 0o700);
    }
    let profile = recorded("profile.json");
    let executable = root.join("ArkTrace.app/Contents/MacOS/arktrace");
    fs::copy(fixture().join("arktrace"), &executable).unwrap();
    chmod(&executable, 0o700);
    let parser = PathBuf::from(text(&profile["pinnedFiles"][0]["path"]));
    fs::write(&parser, text(&profile["parser"])).unwrap();
    chmod(&parser, 0o700);
    let info_plist = PathBuf::from(text(&profile["pinnedFiles"][1]["path"]));
    fs::write(&info_plist, text(&profile["infoPlist"])).unwrap();
    chmod(&info_plist, 0o600);
    for answer in fs::read_dir(fixture().join("answers")).unwrap() {
        let answer = answer.unwrap().path();
        let destination = root
            .join("arktrace/answers")
            .join(answer.file_name().unwrap());
        fs::copy(&answer, &destination).unwrap();
        chmod(&destination, 0o600);
    }
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
    let contract = &profile["contract"];
    let profile = AnalyzerProfile {
        analyzer_ref: text(&profile["analyzerRef"]),
        analyzer_version: text(&profile["analyzerVersion"]),
        executable_path: PathBuf::from(text(&profile["executablePath"])),
        executable_sha256: text(&profile["executableSHA256"]),
        fixed_arguments: profile["fixedArguments"]
            .as_array()
            .unwrap()
            .iter()
            .map(text)
            .collect(),
        timeout_seconds: profile["timeoutSeconds"].as_i64().unwrap(),
        output_byte_budget: profile["outputByteBudget"].as_u64().unwrap() as usize,
        canonical_namespace_root: Some(text(&profile["canonicalNamespaceRoot"])),
        pinned_files: profile["pinnedFiles"]
            .as_array()
            .unwrap()
            .iter()
            .map(|pin| PinnedFile {
                path: text(&pin["path"]),
                sha256: text(&pin["sha256"]),
                byte_count: pin["byteCount"].as_u64().unwrap(),
                require_executable: pin["requireExecutable"].as_bool().unwrap(),
            })
            .collect(),
        pinned_trees: profile["pinnedTrees"]
            .as_array()
            .unwrap()
            .iter()
            .map(|pin| PinnedTree {
                path: text(&pin["path"]),
                sha256: text(&pin["sha256"]),
            })
            .collect(),
        arktrace_summary: Some(ArkTraceContract {
            tool_version: text(&contract["toolVersion"]),
            parser_version: text(&contract["parserVersion"]),
            parser_upstream_revision: text(&contract["parserUpstreamRevision"]),
            parser_sha256: text(&contract["parserSHA256"]),
            parser_build_recipe_version: text(&contract["parserBuildRecipeVersion"]),
            parser_adapter_version: text(&contract["parserAdapterVersion"]),
            schema_adapter_version: text(&contract["schemaAdapterVersion"]),
            index_schema_version: contract["indexSchemaVersion"].as_i64().unwrap(),
        }),
        arktrace_analysis: None,
    };
    (root, profile)
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

fn answer<T>(outcome: Result<Value, T>, error: impl Fn(T) -> Value) -> Value {
    match outcome {
        Ok(result) => json!({"ok": true, "result": result}),
        Err(refusal) => json!({"ok": false, "error": error(refusal)}),
    }
}

/// Each child's arguments, the source's inode alias as the oracle keeps it.
fn normalized_calls(root: &Path) -> String {
    let calls = fs::read_to_string(root.join("arktrace/calls.log")).unwrap();
    let mut normalized = String::new();
    let mut rest = calls.as_str();
    while let Some(start) = rest.find("/.vol/") {
        normalized.push_str(&rest[..start]);
        let alias = &rest[start + "/.vol/".len()..];
        let digits = |text: &str| text.bytes().take_while(u8::is_ascii_digit).count();
        let device = digits(alias);
        assert!(device > 0 && alias.as_bytes()[device] == b'/', "{calls}");
        let inode = digits(&alias[device + 1..]);
        assert!(inode > 0, "{calls}");
        normalized.push_str("/.vol/<device>/<inode>");
        rest = &alias[device + 1 + inode..];
    }
    normalized.push_str(rest);
    normalized
}

#[test]
fn rust_plans_runs_and_reads_trace_summaries_as_swift_did() {
    let _lock = exclusive();
    let (root, profile) = rebuild();
    let provenance = recorded("provenance.json");
    let artifacts = ArtifactReadStore::open(&root.join("artifacts")).unwrap();
    let jobs = JobStore::open_owner(&root.join("jobs-state")).unwrap();
    let bundle = PathBuf::from(profile.canonical_namespace_root.clone().unwrap());
    let info_plist = PathBuf::from(&profile.pinned_files[1].path);
    let extra = PathBuf::from(&profile.pinned_trees[0].path).join("extra.txt");
    let composed = AnalyzerProfiles::new(vec![profile], BTreeMap::new());
    // The daemon without `ARKDECK_ARKTRACE_DESCRIPTOR`.
    let unconfigured = AnalyzerProfiles::default().without_arktrace();
    assert_eq!(
        unconfigured.unavailable_reason("trace-summary@1"),
        Some(ArkTraceProfileError::NotFound.reason())
    );
    let planner = |analyzer: &str| JobPlanner {
        imports: None,
        artifacts: Some(&artifacts),
        analyzer: Some(if analyzer == "unconfigured" {
            &unconfigured as &dyn AnalyzerComposition
        } else {
            &composed
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
    let plan = |recorded: &Value| {
        let composition = recorded["composition"].as_str().unwrap();
        let mut actual = answer(
            planner(composition).handle(recorded["params"].as_object().unwrap()),
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
                    b"summarize-trace|runDeterministicAnalyzer|hostOnly|immediate|none"
                )))
            );
        }
        (actual != recorded["response"]).then(|| {
            format!(
                "plan {composition}:\n  swift {}\n  rust  {actual}",
                recorded["response"]
            )
        })
    };
    let plans = recorded("plans.json");
    let plans = plans.as_array().unwrap();
    assert_eq!(plans.len(), 5);
    let mut differences: Vec<String> = plans[..2].iter().filter_map(plan).collect();
    let profile_document = recorded("profile.json");
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
        // After every admission, the distribution stops holding for one run:
        // the plan made then answers as Swift's did, and the change is undone
        // after the run.
        let mode = case["mode"].as_str().unwrap();
        match mode {
            "tree" => {
                fs::write(&extra, text(&profile_document["extraResource"])).unwrap();
                chmod(&extra, 0o600);
            }
            "plist" => fs::write(&info_plist, text(&profile_document["driftedInfoPlist"])).unwrap(),
            "bundle" => chmod(&bundle, 0o777),
            _ => {}
        }
        if ["tree", "plist", "bundle"].contains(&mode) {
            let recorded = plans
                .iter()
                .find(|plan| plan["composition"] == case["name"])
                .unwrap();
            differences.extend(plan(recorded));
        }
        let actual = answer(
            runner.handle(case["params"].as_object().unwrap()),
            |refused| refusal(refused.code, refused.message, refused.details),
        );
        match mode {
            "tree" => fs::remove_file(&extra).unwrap(),
            "plist" => fs::write(&info_plist, text(&profile_document["infoPlist"])).unwrap(),
            "bundle" => chmod(&bundle, 0o700),
            _ => {}
        }
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
    assert_eq!(
        normalized_calls(&root),
        fs::read_to_string(fixture().join("calls.log")).unwrap()
    );
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
    // The published summary is the stand-in's answer, byte for byte.
    let answered = fs::read(fixture().join("answers/answered.stdout")).unwrap();
    assert!(published.values().any(|bytes| *bytes == answered));
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
    }
    drop(jobs);
    fs::remove_dir_all(&root).unwrap();
}
