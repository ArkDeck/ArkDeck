use super::*;
use serde_json::{Value, json};

const RECORDED_MANIFEST: &[u8] =
    include_bytes!("../../../tests/fixtures/windows-arktrace-distribution/manifest.json");

fn recorded() -> Value {
    serde_json::from_slice(RECORDED_MANIFEST).unwrap()
}
fn accepts(value: &Value) -> bool {
    Manifest::read(&serde_json::to_vec(value).unwrap()).is_ok()
}

#[test]
fn the_windows_manifest_binds_the_recipe_and_index_without_apple_fields() {
    let manifest = Manifest::read(RECORDED_MANIFEST).unwrap();
    assert_eq!(manifest.contract().index_schema_version, 4);
    assert_eq!(manifest.files().len(), 110);
    assert!(accepts(&recorded()));
    for (pointer, edit) in [
        ("/formatVersion", json!(true)),
        ("/formatVersion", json!(1.0)),
        ("/schema", json!("arktrace.cli-distribution/1")),
        ("/product/architecture", json!("arm64")),
        ("/product/extra", json!(1)),
        ("/provenance/indexSchemaVersion", json!(3)),
        ("/signing/policy", json!("development-pinned")),
        ("/signing/publisher", Value::Null),
        ("/signing/publisher", json!(" leading space")),
        ("/traceStreamer/unsignedBinarySHA256", json!("0".repeat(64))),
        ("/traceStreamer/buildRecipeVersion", json!("0".repeat(64))),
        ("/integrity/fileCount", json!(111)),
        ("/integrity/treeSHA256", json!("0".repeat(64))),
        ("/attribution/licenseFileCount", json!(17)),
        ("/attribution/rustDependencyCount", json!(36)),
        ("/attribution/rustLicenseFileCount", json!(74)),
        (
            "/upgradePolicy/rollback",
            json!("overwrite-active-directory"),
        ),
    ] {
        let mut value = recorded();
        if pointer.ends_with("/extra") {
            value["product"]["extra"] = edit;
        } else {
            *value.pointer_mut(pointer).unwrap() = edit;
        }
        assert!(!accepts(&value), "accepted drift at {pointer}");
    }
    let duplicate = String::from_utf8(RECORDED_MANIFEST.to_vec())
        .unwrap()
        .replacen('{', "{\"formatVersion\":1,", 1);
    assert!(Manifest::read(duplicate.as_bytes()).is_err());
}

#[test]
fn same_hashes_never_legalize_path_aliases_or_an_incomplete_license_closure() {
    for path in [
        "../a", "a//b", "a/./b", "C:/a", "a\\b", "con.txt", "COM9.exe", "a:", "a.", "a/b ", "资源",
    ] {
        assert!(!wire::safe_relative(path), "{path}");
    }
    for edit in [
        "resources/licenses/LICENSES/undeclared.txt",
        "resources/Helpers/ARKTRACE-HOST-PROCESS.exe",
    ] {
        let mut value = recorded();
        value["integrity"]["files"][0]["path"] = json!(edit);
        let mut files: Vec<FilePin> =
            serde_json::from_value(value["integrity"]["files"].clone()).unwrap();
        files.sort_by(|a, b| a.path.cmp(&b.path));
        value["integrity"]["files"] = json!(
            files
                .iter()
                .map(|f| json!({"path":f.path,"sha256":f.sha256,"byteCount":f.byte_count}))
                .collect::<Vec<_>>()
        );
        value["integrity"]["treeSHA256"] = json!(wire::tree_digest(&files));
        assert!(!accepts(&value));
    }
}

#[test]
fn reviewed_descriptors_reject_duplicate_keys_coercions_and_foreign_fields() {
    let good =
        json!({"formatVersion":1,"distributionRoot":r"C:\Trace","manifestSHA256":"a".repeat(64)});
    assert!(Descriptor::read(&serde_json::to_vec(&good).unwrap()).is_ok());
    for (field, edit) in [
        ("formatVersion", json!(true)),
        ("formatVersion", json!(1.0)),
        ("manifestSHA256", json!("A".repeat(64))),
        ("extra", json!(1)),
    ] {
        let mut changed = good.clone();
        changed[field] = edit;
        assert!(Descriptor::read(&serde_json::to_vec(&changed).unwrap()).is_err());
    }
    assert!(Descriptor::read(br#"{"formatVersion":1,"formatVersion":1,"distributionRoot":"C:\\Trace","manifestSHA256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}"#).is_err());
    assert!(plain(Path::new(r"relative\descriptor.json")).is_err());
    assert!(plain(Path::new(r"\\server\share\descriptor.json")).is_err());
}

#[test]
fn resealed_rust_license_hashes_cannot_replace_the_frozen_dependency_inventory() {
    let mut value = recorded();
    let mut files: Vec<FilePin> =
        serde_json::from_value(value["integrity"]["files"].clone()).unwrap();
    let file = files
        .iter_mut()
        .find(|f| f.path.starts_with("resources/licenses/rust/licenses/"))
        .unwrap();
    file.sha256 = "0".repeat(64);
    value["integrity"]["treeSHA256"] = json!(wire::tree_digest(&files));
    value["integrity"]["files"] = serde_json::to_value(
        files
            .iter()
            .map(|f| json!({"path":f.path,"sha256":f.sha256,"byteCount":f.byte_count}))
            .collect::<Vec<_>>(),
    )
    .unwrap();
    assert!(!accepts(&value));
    let directories = wire::directories().unwrap();
    assert_eq!(directories.len(), 46);
    assert!(!directories.contains("resources/licenses/rust/licenses/extra"));
}

fn inspection_profile() -> AnalyzerProfile {
    let manifest = Manifest::read(RECORDED_MANIFEST).unwrap();
    AnalyzerProfile {
        analyzer_ref: SUMMARY_REF.into(),
        analyzer_version: "0.1.0+1".into(),
        executable_path: PathBuf::from(r"C:\not-executed\arktrace.exe"),
        executable_sha256: manifest.tool_sha256().into(),
        fixed_arguments: Vec::new(),
        timeout_seconds: 30,
        output_byte_budget: 8 * 1024 * 1024,
        canonical_namespace_root: None,
        pinned_files: Vec::new(),
        pinned_trees: Vec::new(),
        arktrace_summary: Some(manifest.contract()),
        arktrace_analysis: None,
    }
}

#[test]
fn inspection_envelopes_bind_all_identities_budgets_and_private_data() {
    use crate::arktrace_inspection::{InspectionInvocation, valid_inspection_envelope};
    let bytes =
        include_bytes!("../../../tests/fixtures/windows-arktrace-distribution/inspect.json");
    let recorded: Value = serde_json::from_slice(bytes).unwrap();
    let profile = inspection_profile();
    // A wire-validation fixture is never an executable profile.
    assert!(!pins_match(&profile));
    let invocation = InspectionInvocation {
        profile: &profile,
        source_sha256: recorded["trace"]["sha256"].as_str().unwrap(),
        source_byte_count: recorded["trace"]["byteCount"].as_u64().unwrap(),
        source_path: r"C:\source\trace.htrace",
        timeout_ms: 30000,
    };
    assert!(valid_inspection_envelope(bytes, &invocation).is_some());
    for (pointer, edit) in [
        ("/tool/buildRevision", json!("0".repeat(64))),
        ("/trace/sha256", json!("0".repeat(64))),
        ("/trace/byteCount", json!(1)),
        ("/trace/durationNs", json!(-1)),
        ("/trace/parser/binarySha256", json!("0".repeat(64))),
        ("/trace/schemaFingerprint", json!("not-a-digest")),
        ("/limits/timeoutMs", json!(30000.0)),
        ("/limits/maxRows", json!(999)),
        ("/request/command", json!("summary")),
        ("/result/cacheHit", json!(true)),
        ("/result/indexSchemaVersion", json!(3)),
        ("/result/capabilities/namedSlices", json!(1)),
        (
            "/provenance/parserBuildRecipeVersion",
            json!("0".repeat(64)),
        ),
        ("/provenance/upstreamDatabaseByteCount", json!(-1)),
        (
            "/dataQuality/warnings/0/message",
            json!(r"C:\private\trace.htrace"),
        ),
        ("/dataQuality/warnings/0/count", json!(-1)),
        ("/dataQuality/warnings/0/scope", json!("unreviewed.scope")),
        ("/truncation/truncated", json!(false)),
    ] {
        let mut changed = recorded.clone();
        *changed.pointer_mut(pointer).unwrap() = edit;
        assert!(
            valid_inspection_envelope(&serde_json::to_vec(&changed).unwrap(), &invocation)
                .is_none(),
            "{pointer}"
        );
    }
    let mut missing = recorded.clone();
    missing["result"]
        .as_object_mut()
        .unwrap()
        .remove("capabilities");
    assert!(
        valid_inspection_envelope(&serde_json::to_vec(&missing).unwrap(), &invocation).is_none()
    );
    let mut extra = recorded.clone();
    extra["result"]["extra"] = json!(1);
    assert!(valid_inspection_envelope(&serde_json::to_vec(&extra).unwrap(), &invocation).is_none());
    let duplicate =
        String::from_utf8(bytes.to_vec())
            .unwrap()
            .replacen('{', "{\"schemaVersion\":\"1.0\",", 1);
    assert!(valid_inspection_envelope(duplicate.as_bytes(), &invocation).is_none());
}

fn capture_fixture(
    state: &Path,
    source: &Path,
) -> (crate::JobStore, crate::ArtifactReadStore, Value) {
    use crate::artifact_publication::{ArtifactPublisher, Product};
    let root = HostDirectory::open(state).unwrap();
    root.private_child("jobs-state").unwrap();
    root.private_child("artifacts").unwrap();
    let jobs = crate::JobStore::open_owner(&state.join("jobs-state")).unwrap();
    let artifacts = crate::ArtifactReadStore::open(&state.join("artifacts")).unwrap();
    // An isolated host-test Job: never run, no HDC, no capability or hardware
    // evidence. Only the declared raw product contains the repository fixture.
    let request = json!({"documentType":"runtime-operation-request","schemaVersion":"1.0.0",
        "requestId":"windows-trace-fixture","idempotencyKey":"windows-trace-fixture",
        "target":{"targetId":"TGT-FIXTURE"},"operation":{"id":"capture.diagnostics","version":1},
        "inputs":{},"requestedOutputs":["rawArtifacts"]});
    let typed = crate::OperationRequest::decode(&serde_json::to_vec(&request).unwrap()).unwrap();
    let request = typed.canonical_value();
    let record = crate::JobRecord::admitted(
        "job-windows-trace-fixture",
        request.clone(),
        request,
        "capture.diagnostics@1",
        arkdeck_contract::CATALOG_DIGEST,
        "hdc",
        "2026-10-18T00:00:00Z",
        "readOnly",
        None,
        &"f".repeat(64),
    );
    jobs.admit(&record, &typed.fingerprint()).unwrap();
    let product = Product {
        job_id: "job-windows-trace-fixture",
        session_id: "session-windows-trace-fixture",
        step_id: "capture",
        name: "trace.htrace",
        media_type: "application/octet-stream",
        privacy: "sensitive",
        retention_class: "default",
        source_operation: "capture.diagnostics@1",
        provider_id: "hdc",
        binding: json!({"targetID":"TGT-FIXTURE"}),
        observation_window: None,
    };
    let publisher = ArtifactPublisher {
        store: &artifacts,
        quota: 1 << 30,
        home: r"C:\not-a-user-home",
        now: || Some("2026-10-18T00:00:00Z".into()),
    };
    let bytes = read_host_file(source, 1 << 30).unwrap();
    let metadata = publisher.publish(&product, &bytes).unwrap();
    (jobs, artifacts, metadata)
}

fn inspect_and_export_fixture(state: &Path, profiles: &[AnalyzerProfile], source: &Path) {
    let profile = &profiles[0];
    let nonce = u64::from_ne_bytes(arkdeck_platform::random_bytes::<8>().unwrap());
    let name = format!("fixture-{nonce:016x}");
    HostDirectory::open(state)
        .unwrap()
        .private_child(&name)
        .unwrap();
    let state = state.join(name);
    let (jobs, artifacts, metadata) = capture_fixture(&state, source);
    let params = json!({"owner":{"kind":"job","id":"job-windows-trace-fixture"},
        "artifactId":metadata["artifactID"],"allowSensitive":true,"timeoutMs":30000});
    let before_job = jobs
        .read_snapshot("job-windows-trace-fixture")
        .unwrap()
        .value()
        .unwrap();
    let before_index =
        std::fs::read(state.join("artifacts/job-windows-trace-fixture/index.json")).unwrap();
    let report =
        crate::inspect_trace_artifact(&jobs, &artifacts, profile, params.as_object().unwrap())
            .unwrap();
    arkdeck_contract::validate_method_value("trace.inspect", "result", &report).unwrap();
    assert_eq!(report["source"]["artifactDigest"], metadata["sha256"]);
    assert_eq!(
        report["source"]["byteCount"],
        metadata["byteCount"].as_u64().unwrap().to_string()
    );
    assert_eq!(report["storageMode"], "ephemeral");
    assert_eq!(report["deviceEvidenceCreated"], false);
    assert_eq!(
        jobs.read_snapshot("job-windows-trace-fixture")
            .unwrap()
            .value()
            .unwrap(),
        before_job
    );
    assert_eq!(
        std::fs::read(state.join("artifacts/job-windows-trace-fixture/index.json")).unwrap(),
        before_index
    );
    for missing_job in [true, false] {
        let mut request = params.clone();
        if missing_job {
            request["owner"]["id"] = json!("job-absent-windows-trace");
        } else {
            request["artifactId"] = json!("ART-00000000000000000000000000000000");
        }
        let error =
            crate::inspect_trace_artifact(&jobs, &artifacts, profile, request.as_object().unwrap())
                .unwrap_err();
        assert_eq!(error.code, "resourceNotFound");
        println!(
            "TRACE_FRAME {}",
            serde_json::to_string(
                &json!({"protocolVersion":arkdeck_contract::PROTOCOL_VERSION,
            "method":"trace.inspect","params":request,"ok":false,"error":error})
            )
            .unwrap()
        );
    }
    let mut denied = params.clone();
    denied["allowSensitive"] = json!(false);
    assert_eq!(
        crate::inspect_trace_artifact(&jobs, &artifacts, profile, denied.as_object().unwrap())
            .unwrap_err()
            .code,
        "invalidInput"
    );
    // Exercise the complete Runtime host-only operation path, including the
    // Windows dispatch added in job_run, closed receipt validation and exact
    // derived-Artifact publication. No HDC or mutation authority is composed.
    let composition = crate::AnalyzerProfiles::new(profiles.to_vec(), Default::default());
    let planner = || crate::JobPlanner {
        imports: None,
        artifacts: Some(&artifacts),
        analyzer: Some(&composition),
        state_root: &state,
        hdc: None,
        workspace: None,
    };
    fn now() -> Option<String> {
        Some("2026-10-18T00:00:00Z".into())
    }
    fn precise_now() -> Option<String> {
        Some("2026-10-18T00:00:00.000Z".into())
    }
    for operation in ["analyzer.summarize-trace", "analyzer.analyze-trace"] {
        let mut inputs = json!({"sourceArtifactRef":format!("lease-v1:job-windows-trace-fixture:{}",metadata["artifactID"].as_str().unwrap())});
        if operation == "analyzer.analyze-trace" {
            inputs["kind"] = json!("cpu");
            inputs["startNs"] = json!(0);
            inputs["endNs"] = json!(1000000000);
            inputs["timeoutMs"] = json!(60000);
            inputs["maxRows"] = json!(1000);
            inputs["maxEvents"] = json!(10000);
            inputs["maxOutputBytes"] = json!(8388608);
            inputs["thresholdNs"] = json!(1000000);
            inputs["limit"] = json!(20);
        }
        let request = json!({"documentType":"runtime-operation-request","schemaVersion":"1.0.0",
            "requestId":format!("request-{}",operation.replace('.',"-")),"idempotencyKey":format!("key-{}",operation.replace('.',"-")),
            "target":{"targetId":"TGT-FIXTURE"},"operation":{"id":operation,"version":1},
            "inputs":inputs,"requestedOutputs":["derivedArtifacts"]});
        let bytes = serde_json::to_vec(&request).unwrap();
        planner().plan(&bytes).unwrap();
        let accepted = crate::JobAdmitter {
            planner: planner(),
            jobs: &jobs,
            now,
            authority: None,
        }
        .submit(&bytes)
        .unwrap();
        let job = accepted["jobId"].as_str().unwrap();
        let params = json!({"jobId":job});
        let completed = crate::JobRunner {
            imports: None,
            mutation: None,
            jobs: &jobs,
            artifacts: &artifacts,
            analyzer: Some(&composition),
            quota: 1 << 30,
            home: r"C:\not-a-user-home",
            now,
            precise_now,
            sessions: None,
            cancellation: None,
            after_commit: None,
            hdc: None,
            workspace: None,
        }
        .handle(params.as_object().unwrap())
        .unwrap();
        assert_eq!(completed["state"], "succeeded", "{completed}");
        assert_eq!(completed["actualEffect"], "hostOnly");
        assert_eq!(artifacts.list(job).unwrap().len(), 1);
        let reader = crate::JobResultReader {
            jobs: &jobs,
            artifacts: &artifacts,
        };
        reader
            .handle("job.result", params.as_object().unwrap())
            .unwrap();
        reader
            .handle("job.evidence", params.as_object().unwrap())
            .unwrap();
    }
    HostDirectory::open(&state)
        .unwrap()
        .private_child("export")
        .unwrap();
    let export = json!({"owner":params["owner"],"artifactId":metadata["artifactID"],
        "destinationDirectory":state.join("export").to_str().unwrap(),"overwrite":false,"allowSensitive":true});
    let request = crate::ArtifactExportRequest::from_params(export.as_object().unwrap()).unwrap();
    let exported = artifacts.export_wire(&request).unwrap();
    assert_eq!(exported["artifactDigest"], metadata["sha256"]);
    let copied = std::fs::read(exported["exportedPath"].as_str().unwrap()).unwrap();
    assert_eq!(sha256_hex(&copied), metadata["sha256"]);
    assert_eq!(
        artifacts
            .inspect(
                "job-windows-trace-fixture",
                metadata["artifactID"].as_str().unwrap()
            )
            .unwrap(),
        metadata
    );
}

/// This explicitly invoked test consumes a real, externally built, signed
/// recipe distribution. Default CI has no signing key or parser binary and
/// does not turn that absence into a synthetic acceptance pass.
#[test]
#[ignore = "requires a real signed Windows CLI descriptor and a qualified private host root"]
fn signed_windows_distribution_loads_and_produces_validated_summary_and_analysis() {
    let descriptor =
        std::env::var_os("ARKDECK_WINDOWS_TRACE_TEST_DESCRIPTOR").expect("signed descriptor");
    let state = std::env::var_os("ARKDECK_WINDOWS_TRACE_TEST_STATE").expect("private state");
    let source = std::env::var_os("ARKDECK_WINDOWS_TRACE_TEST_SOURCE").expect("trace source");
    let loader = WindowsArkTraceProfileLoader {
        state: Path::new(&state),
    };
    let profiles = loader
        .load_profiles(Path::new(&descriptor))
        .expect("production loader and doctor");
    assert_eq!(profiles.len(), 2);
    assert!(profiles.iter().all(AnalyzerProfile::holds));
    let summary = &profiles[0];
    let source = Path::new(&source);
    let facts = arkdeck_platform::measure_host_file(source, 1 << 30).unwrap();
    let source_sha256: String = facts
        .sha256
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect();
    let held = VerifiedSource::open(source, &source_sha256, facts.identity.size).unwrap();
    let mut arguments = summary.fixed_arguments.clone();
    arguments.push(held.inode_path());
    let run = run_profile(
        summary,
        &arguments.iter().map(OsString::from).collect::<Vec<_>>(),
        Duration::from_secs(35),
        8 * 1024 * 1024,
        &|| false,
    )
    .unwrap();
    assert_eq!(run.termination, ToolTermination::Exited(0));
    assert!(run.stderr.is_empty() && !run.truncated);
    assert!(crate::arktrace_summary::valid_summary(
        &run.stdout,
        &crate::arktrace_summary::SummaryInvocation {
            analyzer_ref: SUMMARY_REF,
            executable_sha256: &summary.executable_sha256,
            arguments: &arguments,
            timeout_seconds: 30,
            output_byte_budget: Some(8 * 1024 * 1024),
            source_sha256: &source_sha256,
            source_byte_count: facts.identity.size,
            contract: summary.arktrace_summary.as_ref(),
        }
    ));
    let analysis = &profiles[1];
    let inputs = json!({"kind":"cpu","thresholdNs":1000000,"limit":20,"startNs":0,"endNs":1000000000,
        "timeoutMs":60000,"maxRows":1000,"maxEvents":10000,"maxOutputBytes":8388608});
    let invocation = crate::analyzer_output::Invocation::of(
        analysis,
        inputs.as_object().unwrap(),
        &held.inode_path(),
    )
    .unwrap();
    let arguments: Vec<_> = invocation.arguments.iter().map(OsString::from).collect();
    let run = run_profile(
        analysis,
        &arguments,
        Duration::from_secs(invocation.timeout_seconds as u64),
        64 * 1024 * 1024,
        &|| false,
    )
    .unwrap();
    assert_eq!(run.termination, ToolTermination::Exited(0));
    let source = crate::analyzer_output::Source {
        artifact_id: "ART-test",
        sha256: &source_sha256,
        byte_count: facts.identity.size,
        path: source.to_str().unwrap(),
    };
    assert!(
        crate::analyzer_output::verify(
            &crate::analyzer_output::Receipt {
                exit_status: 0,
                stdout: &run.stdout,
                stderr: &run.stderr,
                truncated: run.truncated,
            },
            &source,
            &invocation
        )
        .is_ok()
    );
    inspect_and_export_fixture(Path::new(&state), &profiles, Path::new(source.path));
    // Once profiled, an extra file makes both profiles unavailable. A restored
    // tree regains availability; no existing resource is repaired by the loader.
    let root = Path::new(summary.canonical_namespace_root.as_deref().unwrap());
    let executable = root.join(wire::EXECUTABLES[0]);
    let bound = BoundDistribution::open(root, None, true).unwrap();
    assert!(verify_windows_publisher(&executable, "an unrelated publisher", false).is_err());
    if !bound.manifest.timestamped() {
        assert!(
            verify_windows_publisher(&executable, bound.manifest.publisher(), true).is_err(),
            "an untimestamped development image cannot satisfy a timestamp claim"
        );
    }
    drop(bound);
    let mut substituted = summary.clone();
    substituted.pinned_files[0] = substituted.pinned_files[1].clone();
    assert!(!substituted.holds());
    let empty = root.join("undeclared-directory");
    std::fs::create_dir(&empty).unwrap();
    assert!(profiles.iter().all(|profile| !profile.holds()));
    std::fs::remove_dir(empty).unwrap();
    let extra = root.join("undeclared.txt");
    std::fs::write(&extra, b"undeclared").unwrap();
    assert!(profiles.iter().all(|profile| !profile.holds()));
    std::fs::remove_file(extra).unwrap();
    assert!(profiles.iter().all(AnalyzerProfile::holds));
    let license = root.join(r"resources\licenses\LICENSES\zlib-Zlib.txt");
    let original = std::fs::read(&license).unwrap();
    let mut altered = original.clone();
    altered.push(b'\n');
    std::fs::write(&license, altered).unwrap();
    assert!(!summary.holds());
    assert!(run_profile(summary, &[], Duration::from_secs(1), 1024, &|| false).is_err());
    std::fs::write(&license, original).unwrap();
    let path = root.join(wire::MANIFEST);
    let original = std::fs::read(&path).unwrap();
    let mut manifest: Value = serde_json::from_slice(&original).unwrap();
    manifest["source"]["revision"] = json!("0".repeat(40));
    std::fs::write(&path, serde_json::to_vec(&manifest).unwrap()).unwrap();
    assert!(!summary.holds());
    std::fs::write(&path, original).unwrap();
    assert!(profiles.iter().all(AnalyzerProfile::holds));
    let reloaded = loader.load_profiles(Path::new(&descriptor)).unwrap();
    assert_eq!(reloaded, profiles);
}
