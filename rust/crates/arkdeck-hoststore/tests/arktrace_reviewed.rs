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
    ProductionDistributionTrust, ProductionDoctorProbe,
};
use serde_json::{Value, json};
use std::fs::{self, OpenOptions};
use std::os::unix::fs::PermissionsExt;
use std::path::Path;

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

#[test]
fn a_reviewed_distribution_passes_production_trust_and_its_own_doctor() {
    let Ok(descriptor) = std::env::var("ARKDECK_REVIEWED_ARKTRACE_DESCRIPTOR") else {
        eprintln!("set ARKDECK_REVIEWED_ARKTRACE_DESCRIPTOR for the reviewed signed App gate");
        return;
    };
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
