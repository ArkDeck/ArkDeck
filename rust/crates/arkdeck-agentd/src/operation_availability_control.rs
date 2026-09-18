//! Actual daemon composition; all tools here are inert test executables.
use arkdeck_contract::{
    MAX_REQUEST_BYTES, Request, Response, decode_response, encode_frame, sha256_hex,
};
use arkdeck_control::Control;
use arkdeck_hoststore::{AnalyzerProfile, ArtifactReadStore, JobStore, TargetStore};
use arkdeck_platform::VerifiedTool;
use arkdeck_provider_hdc::ProcessDispatch;
use serde_json::{Value, json};
use std::{
    fs,
    os::unix::fs::{DirBuilderExt, PermissionsExt},
    path::PathBuf,
};

struct Fixture(PathBuf);
impl Fixture {
    fn new() -> Self {
        let root = std::env::temp_dir().canonicalize().unwrap().join(format!(
            "operation-availability-{:x}",
            u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap())
        ));
        for name in ["jobs", "artifacts", "targets"] {
            fs::DirBuilder::new()
                .recursive(true)
                .mode(0o700)
                .create(root.join(name))
                .unwrap();
        }
        // If anything dispatches these tools, the sentinel exposes it. The
        // launcher never needs to execute a tool to answer availability.
        for name in ["analyzer", "hdc"] {
            fs::write(
                root.join(name),
                format!(
                    "#!/bin/sh\ntouch '{}'\nexit 93\n",
                    root.join("DISPATCHED").display()
                ),
            )
            .unwrap();
            fs::set_permissions(root.join(name), fs::Permissions::from_mode(0o700)).unwrap();
        }
        Self(root)
    }
    fn host(&self, artifacts: bool, jobs: bool) -> crate::host::Host {
        let mut host = crate::host::Host::from_environment()
            .with_targets(TargetStore::open(&self.0.join("targets")).unwrap())
            .with_planning(
                &self.0,
                Some(AnalyzerProfile::crash_signature(&self.0.join("analyzer")).unwrap()),
            )
            .with_development_hdc(Some(ProcessDispatch::new(
                VerifiedTool::open(
                    self.0.join("hdc"),
                    &sha256_hex(&fs::read(self.0.join("hdc")).unwrap()),
                )
                .unwrap(),
                None,
            )));
        if artifacts {
            host = host.with_artifacts(ArtifactReadStore::open(&self.0.join("artifacts")).unwrap());
        }
        if jobs {
            host = host.with_jobs(JobStore::open(&self.0.join("jobs")).unwrap());
        }
        host
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        assert!(
            !self.0.join("DISPATCHED").exists(),
            "availability dispatched a process"
        );
        fs::remove_dir_all(&self.0).unwrap();
    }
}
fn call(control: &Control<crate::host::Host>, method: &str, params: Value) -> Value {
    let request = Request::new("availability", method, params.as_object().cloned());
    let frame = encode_frame(&request, MAX_REQUEST_BYTES).unwrap();
    let answer = control.handle_frame(frame.trim_ascii_end());
    let answer: Response =
        decode_response(answer.trim_ascii_end(), "availability", method).unwrap();
    answer.outcome.unwrap()
}
fn entry<'a>(rows: &'a Value, reference: &str) -> &'a Value {
    rows.as_array()
        .unwrap()
        .iter()
        .find(|v| v["reference"] == reference)
        .unwrap()
}
#[test]
fn live_discovery_and_describe_follow_actual_executors_and_executable_drift_without_dispatch() {
    let fixture = Fixture::new();
    let control = Control::new(fixture.host(true, true)).unwrap();
    let rows = call(&control, "operation.list", json!({}));
    let available: Vec<_> = rows
        .as_array()
        .unwrap()
        .iter()
        .filter(|v| v["availability"] == "available")
        .map(|v| v["reference"].as_str().unwrap())
        .collect();
    assert_eq!(
        available,
        [
            "analyzer.extract-crash-signature@1",
            "capture.diagnostics@1",
            "observe.device@1"
        ]
    );
    for reference in available {
        let descriptor = call(
            &control,
            "operation.describe",
            json!({"reference":reference}),
        );
        for (field, description_field) in [
            ("availability", "availability"),
            ("reasons", "availabilityReasons"),
            ("reasonCodes", "availabilityReasonCodes"),
            ("reasonOrigins", "availabilityReasonOrigins"),
        ] {
            assert_eq!(
                descriptor[description_field],
                entry(&rows, reference)[field]
            );
        }
    }
    for reference in ["input.tap@1", "input.long-press@1", "input.swipe@1"] {
        assert_eq!(
            entry(&rows, reference)["reasonCodes"],
            json!(["operation_not_supported"])
        );
    }
    let original = fs::read(fixture.0.join("analyzer")).unwrap();
    fs::write(fixture.0.join("analyzer"), b"#!/bin/sh\nexit 81\n").unwrap();
    let descriptor = call(
        &control,
        "operation.describe",
        json!({"reference":"analyzer.extract-crash-signature@1"}),
    );
    assert_eq!(descriptor["availability"], "unavailable");
    assert_eq!(
        descriptor["availabilityReasonCodes"],
        json!(["tool_identity_drift"])
    );
    assert_eq!(
        descriptor["availabilityReasonOrigins"],
        json!(["host_configuration"])
    );
    fs::write(fixture.0.join("analyzer"), original).unwrap();
    let rows = call(&control, "operation.list", json!({}));
    assert_eq!(
        entry(&rows, "analyzer.extract-crash-signature@1")["availability"],
        "available"
    );
    fs::write(fixture.0.join("hdc"), b"#!/bin/sh\nexit 82\n").unwrap();
    let rows = call(&control, "operation.list", json!({}));
    assert_eq!(
        entry(&rows, "observe.device@1")["reasonCodes"],
        json!(["tool_identity_drift"])
    );
    assert_eq!(
        entry(&rows, "capture.diagnostics@1")["availability"],
        "unavailable"
    );
}
#[test]
fn absent_artifact_and_job_owners_are_configuration_failures_not_available() {
    let fixture = Fixture::new();
    let control = Control::new(fixture.host(false, false)).unwrap();
    let rows = call(&control, "operation.list", json!({}));
    for reference in [
        "analyzer.extract-crash-signature@1",
        "capture.diagnostics@1",
        "observe.device@1",
    ] {
        assert_eq!(entry(&rows, reference)["availability"], "unavailable");
        assert_eq!(
            entry(&rows, reference)["reasonCodes"],
            json!(["provider_tool_unavailable", "artifact_store_unavailable"])
        );
        assert_eq!(
            entry(&rows, reference)["reasonOrigins"],
            json!(["host_configuration", "host_configuration"])
        );
    }
}
