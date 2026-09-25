//! Host acceptance of the Rust ArkTrace loader over a reviewed, signed and
//! notarized distribution: `ProductionDistributionTrust` (the Security
//! framework's own checks of the App and its helper), `ProductionDoctorProbe`
//! running the real CLI's self-test at its canonical path, and a private
//! snapshot generation. A reviewed distribution is a host's, so this runs
//! only when `ARKDECK_REVIEWED_ARKTRACE_DESCRIPTOR` names one; with
//! `ARKDECK_REVIEWED_ARKTRACE_SWIFT` naming what
//! `ArkTraceReviewedDistributionOracleContractTests` recorded at the same
//! root, the two loads must be the same, byte for byte.
#![cfg(target_os = "macos")]

use arkdeck_hoststore::{
    AnalyzerComposition, AnalyzerProfile, AnalyzerProfiles, ArkTraceProfileLoader,
    ArtifactReadStore, JobAdmitter, JobPlanner, JobResultReader, JobRunner, JobStore,
    ProductionDistributionTrust, ProductionDoctorProbe,
};
use serde_json::{Map, Value, json};
use std::collections::BTreeMap;
use std::fs::{self, File, OpenOptions};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

const ROOT: &str = "/private/tmp/arkdeck-arktrace-reviewed";
const LOCK: &str = "/private/tmp/arkdeck-arktrace-oracle.lock";

fn contract(value: &Option<arkdeck_hoststore::ArkTraceContract>) -> Value {
    value.as_ref().map_or(Value::Null, |contract| {
        json!({
            "toolVersion": contract.tool_version,
            "parserVersion": contract.parser_version,
            "parserUpstreamRevision": contract.parser_upstream_revision,
            "parserSHA256": contract.parser_sha256,
            "parserBuildRecipeVersion": contract.parser_build_recipe_version,
            "parserAdapterVersion": contract.parser_adapter_version,
            "schemaAdapterVersion": contract.schema_adapter_version,
            "indexSchemaVersion": contract.index_schema_version,
        })
    })
}

fn projection(profile: &AnalyzerProfile) -> Value {
    json!({
        "analyzerRef": profile.analyzer_ref,
        "analyzerVersion": profile.analyzer_version,
        "executablePath": profile.executable_path.to_str().unwrap(),
        "executableSHA256": profile.executable_sha256,
        "canonicalNamespaceRoot": profile.canonical_namespace_root,
        "fixedArguments": profile.fixed_arguments,
        "timeoutSeconds": profile.timeout_seconds,
        "outputByteBudget": profile.output_byte_budget,
        "pinnedFiles": profile.pinned_files.iter().map(|pin| json!({
            "path": pin.path, "sha256": pin.sha256, "byteCount": pin.byte_count,
            "requireExecutable": pin.require_executable})).collect::<Vec<_>>(),
        "pinnedTrees": profile.pinned_trees.iter().map(|tree| json!({
            "path": tree.path, "sha256": tree.sha256})).collect::<Vec<_>>(),
        "preflightAvailable": true,
        "arkTraceSummaryContract": contract(&profile.arktrace_summary),
        "arkTraceAnalysisContract": contract(&profile.arktrace_analysis),
    })
}

/// Serializes every user of the fixed root, Swift producers included, and
/// leaves it empty and owner-only.
fn exclusive_root() -> File {
    let lock = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .open(LOCK)
        .unwrap();
    lock.lock().unwrap();
    let _ = fs::remove_dir_all(ROOT);
    fs::create_dir(ROOT).unwrap();
    fs::set_permissions(ROOT, fs::Permissions::from_mode(0o700)).unwrap();
    lock
}

#[test]
fn a_reviewed_distribution_passes_production_trust_and_its_own_doctor() {
    let Ok(descriptor) = std::env::var("ARKDECK_REVIEWED_ARKTRACE_DESCRIPTOR") else {
        eprintln!("set ARKDECK_REVIEWED_ARKTRACE_DESCRIPTOR for the reviewed signed App gate");
        return;
    };
    let _lock = exclusive_root();
    let doctor = ProductionDoctorProbe::new(Path::new(&format!("{ROOT}/home")));
    let snapshots = format!("{ROOT}/snapshots");
    let loader = ArkTraceProfileLoader {
        doctor: &doctor,
        trust: &ProductionDistributionTrust,
        snapshot_root: Some(snapshots.clone()),
        hooks: None,
    };
    let profiles = loader.load_profiles(&descriptor).unwrap();
    let [summary, analysis] = profiles.as_slice() else {
        panic!("two profiles");
    };
    assert_eq!(summary.analyzer_ref, "trace-summary@1");
    assert_eq!(summary.analyzer_version, "0.1.0+1");
    assert!(summary.executable_path.starts_with(format!("{snapshots}/")));
    assert!(
        summary.pinned_files.len() > 20,
        "{}",
        summary.pinned_files.len()
    );
    assert!(
        summary
            .pinned_files
            .iter()
            .all(|pin| pin.path.starts_with(&format!("{snapshots}/")))
    );
    assert!(
        summary
            .pinned_files
            .iter()
            .any(|pin| pin.path.ends_with("CodeResources"))
    );
    assert!(
        summary
            .pinned_files
            .iter()
            .any(|pin| pin.path.ends_with("notarization-receipt.json"))
    );
    assert_eq!(analysis.executable_path, summary.executable_path);
    assert_eq!(analysis.pinned_files, summary.pinned_files);
    assert_eq!(analysis.pinned_trees, summary.pinned_trees);
    let composition = AnalyzerProfiles::new(profiles.clone(), Default::default());
    assert!(composition.profile("trace-summary@1").unwrap().holds());
    assert!(composition.profile("trace-analysis@1").unwrap().holds());
    if let Ok(recorded) = std::env::var("ARKDECK_REVIEWED_ARKTRACE_SWIFT") {
        let swift: Value = serde_json::from_slice(&fs::read(recorded).unwrap()).unwrap();
        assert_eq!(
            json!({"profiles": profiles.iter().map(projection).collect::<Vec<_>>()}),
            swift
        );
    }
    fs::remove_dir_all(ROOT).unwrap();
}

fn fixed_now() -> Option<String> {
    Some("2026-09-14T00:00:00Z".into())
}

fn fixed_precise_now() -> Option<String> {
    Some("2026-09-14T00:00:00.000Z".into())
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

/// Host acceptance of `analyzer.summarize-trace@1` with the reviewed
/// distribution: when `ARKDECK_REVIEWED_ARKTRACE_JOB_SWIFT` names what
/// `ArkTraceReviewedDistributionOracleContractTests/
/// testSwiftSummarizesTheFixtureTraceWithTheReviewedDistribution` recorded,
/// the Rust daemon's own load of the distribution, then the plan, admission,
/// run and reads of the same request over the repository's `zlib.htrace`,
/// the real CLI launched at its canonical snapshot path, must answer as
/// Swift's did and leave the same Job and Artifact files, byte for byte.
#[test]
fn a_reviewed_distribution_summarizes_the_fixture_trace_as_swift_did() {
    let (Ok(descriptor), Ok(recorded)) = (
        std::env::var("ARKDECK_REVIEWED_ARKTRACE_DESCRIPTOR"),
        std::env::var("ARKDECK_REVIEWED_ARKTRACE_JOB_SWIFT"),
    ) else {
        eprintln!(
            "set ARKDECK_REVIEWED_ARKTRACE_DESCRIPTOR and ARKDECK_REVIEWED_ARKTRACE_JOB_SWIFT"
        );
        return;
    };
    let recorded = PathBuf::from(recorded);
    let read = |name: &str| -> Value {
        serde_json::from_slice(&fs::read(recorded.join(name)).unwrap()).unwrap()
    };
    let _lock = exclusive_root();
    let root = PathBuf::from(ROOT);
    let doctor = ProductionDoctorProbe::new(&root.join("home"));
    let loader = ArkTraceProfileLoader {
        doctor: &doctor,
        trust: &ProductionDistributionTrust,
        snapshot_root: Some(format!("{ROOT}/snapshots")),
        hooks: None,
    };
    let profiles = loader.load_profiles(&descriptor).unwrap();
    assert_eq!(
        json!(profiles.iter().map(projection).collect::<Vec<_>>()),
        read("profiles.json")
    );
    // The source Swift published, as it published it.
    for directory in ["artifacts", "artifacts/job-reviewed-source", "jobs-state"] {
        fs::create_dir(root.join(directory)).unwrap();
        fs::set_permissions(root.join(directory), fs::Permissions::from_mode(0o700)).unwrap();
    }
    for file in fs::read_dir(recorded.join("artifacts/job-reviewed-source")).unwrap() {
        let file = file.unwrap().path();
        let name = file.file_name().unwrap();
        let destination = root.join("artifacts/job-reviewed-source").join(name);
        fs::copy(&file, &destination).unwrap();
        fs::set_permissions(
            &destination,
            fs::Permissions::from_mode(if name == "index.json" { 0o600 } else { 0o400 }),
        )
        .unwrap();
    }
    let artifacts = ArtifactReadStore::open(&root.join("artifacts")).unwrap();
    let jobs = JobStore::open_owner(&root.join("jobs-state")).unwrap();
    let composed = AnalyzerProfiles::new(profiles, BTreeMap::new());
    let planner = JobPlanner {
        imports: None,
        artifacts: Some(&artifacts),
        analyzer: Some(&composed as &dyn AnalyzerComposition),
        state_root: &root,
        hdc: None,
        workspace: None,
    };
    let answers = read("answers.json");
    let params = read("requests.json")["job.plan"].clone();
    let params = params.as_object().unwrap();
    let mut actual = Map::new();
    let mut planned = answer(planner.handle(params), |refused| {
        json!({"code": refused.code, "message": refused.message,
            "details": {"newDispatchCount": 0, "phase": "preAdmission"}})
    });
    // The step set's digest is Rust presentation provenance (#2121).
    assert_eq!(
        planned["result"]
            .as_object_mut()
            .unwrap()
            .remove("stepSetDigestSHA256"),
        Some(json!(arkdeck_contract::sha256_hex(
            b"summarize-trace|runDeterministicAnalyzer|hostOnly|immediate|none"
        )))
    );
    actual.insert("job.plan".into(), planned);
    let accepted = JobAdmitter {
        planner,
        jobs: &jobs,
        now: fixed_now,
        authority: None,
    }
    .handle(params);
    let accepted = answer(
        accepted,
        |refused| json!({"code": refused.code, "message": refused.message}),
    );
    let job = accepted["result"]["jobId"].as_str().unwrap().to_owned();
    actual.insert("job.submit".into(), accepted);
    let job_params = Map::from_iter([("jobId".into(), json!(job))]);
    let runner = JobRunner {
        imports: None,
        mutation: None,
        jobs: &jobs,
        artifacts: &artifacts,
        analyzer: Some(&composed),
        quota: 64 * 1024 * 1024,
        home: &format!("{ROOT}/home"),
        now: fixed_now,
        precise_now: fixed_precise_now,
        sessions: None,
        cancellation: None,
        after_commit: None,
        hdc: None,
        workspace: None,
    };
    actual.insert(
        "job.run".into(),
        answer(
            runner.handle(&job_params),
            |refused| json!({"code": refused.code, "message": refused.message}),
        ),
    );
    let reader = JobResultReader {
        jobs: &jobs,
        artifacts: &artifacts,
    };
    for method in ["job.status", "job.show", "job.result", "job.evidence"] {
        let outcome = if matches!(method, "job.result" | "job.evidence") {
            reader.handle(method, &job_params)
        } else {
            jobs.handle_resource(method, &job_params)
        };
        actual.insert(
            method.into(),
            answer(
                outcome,
                |error| json!({"code": error.code, "message": error.message}),
            ),
        );
    }
    let mut differences = Vec::new();
    for (method, swift) in answers.as_object().unwrap() {
        if actual.get(method) != Some(swift) {
            differences.push(format!(
                "{method}:\n  swift {swift}\n  rust  {}",
                actual.get(method).unwrap_or(&Value::Null)
            ));
        }
    }
    assert!(differences.is_empty(), "{}", differences.join("\n"));
    drop(jobs);
    same_files(
        &files(&root.join("jobs-state/jobs"), true),
        &files(&recorded.join("store/jobs"), true),
    );
    same_files(
        &files(&root.join("artifacts"), false),
        &files(&recorded.join("artifacts"), false),
    );
    fs::remove_dir_all(&root).unwrap();
}
