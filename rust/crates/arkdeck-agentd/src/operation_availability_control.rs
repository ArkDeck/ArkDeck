//! Actual daemon composition; all tools here are inert test executables.
use arkdeck_contract::{
    MAX_REQUEST_BYTES, Request, Response, decode_response, encode_frame, sha256_hex,
};
use arkdeck_control::Control;
use arkdeck_hoststore::{ArtifactReadStore, JobStore, TargetStore};
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
    fn adopt(&self) -> String {
        use arkdeck_hoststore::{ObservationReference, Sources, TargetObservations};
        use arkdeck_provider_hdc::{
            DispatchFailure, HdcDispatch, ProcessPlan, Receipt, UsbRelation,
        };
        // Seed the durable binding through the real adoption owner, using an
        // in-memory source explicitly confined to this synthetic host test.
        struct AdoptionFixture;
        impl HdcDispatch for AdoptionFixture {
            fn dispatch(&self, plan: &ProcessPlan) -> Result<Receipt, DispatchFailure> {
                let argv: Vec<_> = plan.arguments.iter().map(String::as_str).collect();
                let stdout = match argv.as_slice() {
                    ["-v"] => "Ver: 3.2.0f\n",
                    ["list", "targets", "-v"] => "fixture-device\t\tUSB\tConnected\tlocalhost\n",
                    _ => {
                        return Err(DispatchFailure::Refused(
                            "unexpected adoption action".into(),
                        ));
                    }
                };
                Ok(Receipt {
                    exit_status: 0,
                    stdout: stdout.as_bytes().to_vec(),
                    stderr: Vec::new(),
                    truncated: false,
                    duration: std::time::Duration::ZERO,
                })
            }
        }
        let targets = TargetStore::open(&self.0.join("targets")).unwrap();
        let observer = TargetObservations::default();
        let usb = || {
            Ok(vec![UsbRelation {
                serial: "fixture-device".into(),
                location: "1".into(),
                attachment_id: 1,
                vendor_id: 0x2207,
                product_id: 0x5000,
            }])
        };
        let now = || "2026-09-19T00:00:00Z".to_owned();
        let sources = Sources {
            dispatch: &AdoptionFixture,
            relations: &usb,
            targets: &targets,
            now: &now,
        };
        let snapshot = observer.snapshot(&sources, None).unwrap();
        observer
            .adopt(
                &sources,
                &ObservationReference {
                    candidate: snapshot.observations[0].candidate.connect_key.clone(),
                    observation_id: snapshot.observations[0].observation_id.clone(),
                    generation: snapshot.generation,
                },
            )
            .unwrap()
            .target_id
    }

    fn host(&self, artifacts: bool, jobs: bool) -> crate::host::Host {
        self.host_with(artifacts, jobs, None)
    }
    fn host_with(
        &self,
        artifacts: bool,
        jobs: bool,
        arktrace: Option<&std::ffi::OsStr>,
    ) -> crate::host::Host {
        let mut host = crate::host::Host::from_environment()
            .with_targets(TargetStore::open(&self.0.join("targets")).unwrap())
            // The daemon's own composition of the analyzer it is named: the
            // crash-ledger analyzer, and no HiLog summary, since that
            // executable is not this one; with or without an ArkTrace
            // descriptor named.
            .with_planning(
                &self.0,
                crate::hilog_summary_analyzer::composed(
                    Some(&self.0.join("analyzer")),
                    arktrace,
                    &self.0,
                )
                .unwrap(),
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
fn assert_target_operations(control: &Control<crate::host::Host>, target: &str, rows: &Value) {
    let aggregate = call(control, "target.availability", json!({"targetId":target}));
    let projected: Vec<_> = rows
        .as_array()
        .unwrap()
        .iter()
        .map(|row| {
            json!({
                "reference":row["reference"], "availability":row["availability"],
                "reasons":row["reasons"], "reasonCodes":row["reasonCodes"],
            })
        })
        .collect();
    assert_eq!(aggregate["operations"]["items"], json!(projected));
    assert_eq!(aggregate["operations"]["scope"], "host");
    assert_eq!(aggregate["operations"]["targetResolution"], "unresolved");
    assert_eq!(aggregate["binding"]["state"], "ready");
    assert_eq!(aggregate["presence"]["state"], "unresolved");
    assert_eq!(aggregate["profile"]["state"], "unresolved");
}

#[test]
fn live_discovery_and_describe_follow_actual_executors_and_executable_drift_without_dispatch() {
    let fixture = Fixture::new();
    let target = fixture.adopt();
    let control = Control::new(fixture.host(true, true)).unwrap();
    let rows = call(&control, "operation.list", json!({}));
    assert_target_operations(&control, &target, &rows);
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
    for reference in [
        "input.tap@1",
        "input.long-press@1",
        "input.swipe@1",
        "port-forward.create@1",
        "port-forward.remove@1",
        "debug.hap@1",
        "capture.screen-sequence@1",
    ] {
        // The executor exists, but this development composition cannot acquire
        // the account-fixed Runtime mutation owner or grant dispatch authority.
        assert_eq!(entry(&rows, reference)["availability"], "unavailable");
        assert_eq!(
            entry(&rows, reference)["reasonCodes"],
            json!(["provider_tool_unavailable"])
        );
        assert_eq!(
            entry(&rows, reference)["reasons"],
            json!(["runtime.mutationOwnerUnavailable"])
        );
        assert_eq!(
            entry(&rows, reference)["reasonOrigins"],
            json!(["host_configuration"])
        );
    }
    // The HiLog summary is the daemon's own mode: an analyzer executable that
    // is not this daemon is no HiLog producer, and says so by name.
    let hilog = entry(&rows, "analyzer.summarize-hilog@1");
    assert_eq!(hilog["availability"], "unavailable");
    assert_eq!(hilog["reasonCodes"], json!(["provider_tool_unavailable"]));
    assert_eq!(
        hilog["reasons"],
        json!(["analyzer.hilogRequiresCurrentDaemon"])
    );
    assert_eq!(hilog["reasonOrigins"], json!(["host_configuration"]));
    // Without an ArkTrace descriptor, both ArkTrace analyzers are described
    // as Swift's composition describes them (the `arktrace-absent` oracle).
    let absent: Value = serde_json::from_str(include_str!(
        "../../../tests/fixtures/arktrace-absent/cases.json"
    ))
    .unwrap();
    let mut described = 0;
    for exchange in absent["exchanges"].as_array().unwrap() {
        if exchange["method"] != "operation.describe" {
            continue;
        }
        let reference = exchange["params"]["reference"].as_str().unwrap();
        let descriptor = call(
            &control,
            "operation.describe",
            json!({"reference": reference}),
        );
        assert_eq!(descriptor, exchange["answer"]["result"], "{reference}");
        let row = entry(&rows, reference);
        assert_eq!(row["reasons"], json!(["analyzer.arktraceNotFound"]));
        assert_eq!(row["reasonCodes"], json!(["provider_tool_unavailable"]));
        described += 1;
    }
    assert_eq!(described, 2);
    // A native library deployment also needs the verified code-sign helper,
    // which this composition does not carry.
    let native = entry(&rows, "deploy.native-library.app-owned@1");
    assert_eq!(native["availability"], "unavailable");
    assert_eq!(
        native["reasonCodes"],
        json!(["provider_tool_unavailable", "provider_tool_unavailable"])
    );
    assert_eq!(
        native["reasons"],
        json!([
            "runtime.mutationOwnerUnavailable",
            "bundled arm64 OpenHarmony code-sign helper cannot be verified"
        ])
    );
    let original = fs::read(fixture.0.join("analyzer")).unwrap();
    let mut changed = original.clone();
    changed.extend_from_slice(b"# analyzer identity drift\n");
    fs::write(fixture.0.join("analyzer"), changed).unwrap();
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
    assert_target_operations(
        &control,
        &target,
        &call(&control, "operation.list", json!({})),
    );
    fs::write(fixture.0.join("analyzer"), original).unwrap();
    let rows = call(&control, "operation.list", json!({}));
    assert_target_operations(&control, &target, &rows);
    assert_eq!(
        entry(&rows, "analyzer.extract-crash-signature@1")["availability"],
        "available"
    );
    let mut changed = fs::read(fixture.0.join("hdc")).unwrap();
    changed.extend_from_slice(b"# HDC identity drift\n");
    fs::write(fixture.0.join("hdc"), changed).unwrap();
    let rows = call(&control, "operation.list", json!({}));
    assert_target_operations(&control, &target, &rows);
    assert_eq!(
        entry(&rows, "observe.device@1")["reasonCodes"],
        json!(["tool_identity_drift"])
    );
    assert_eq!(
        entry(&rows, "capture.diagnostics@1")["availability"],
        "unavailable"
    );
    // Composed with a verified helper, the operation loses that reason and
    // keeps only what this composition is still missing. The helper
    // ArkDeckWorkflows carries is read when this checkout has it: the
    // isolated contract view keeps only `rust/`, so its absence is not a
    // failure.
    let bundled = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../../Packages/ArkDeckKit/Sources/ArkDeckWorkflows/Resources")
        .join("OpenHarmonyNativeCodeSign/arkdeck-code-sign-enable");
    // The Job owner is this composition's; the first Control holds it
    // until it goes.
    drop(control);
    if bundled.exists() {
        let helper = crate::code_sign_helper::verified(&bundled).unwrap();
        assert_eq!(helper.facts.abi, arkdeck_provider_hdc::NativeAbi::Arm64);
        let composed =
            Control::new(fixture.host(true, true).with_code_sign_helper(helper)).unwrap();
        let rows = call(&composed, "operation.list", json!({}));
        let native = entry(&rows, "deploy.native-library.app-owned@1");
        assert_eq!(native["availability"], "unavailable");
        assert_eq!(native["reasonCodes"], json!(["provider_tool_unavailable"]));
        assert_eq!(
            native["reasons"],
            json!(["runtime.mutationOwnerUnavailable"])
        );
    }
}
/// A named ArkTrace descriptor is loaded as Swift's daemon loads it: one
/// that does not load leaves both ArkTrace analyzers unavailable for the
/// loader's reason, an absent descriptor and a malformed one alike, refused
/// before the reviewed CLI's self-test could run.
#[test]
fn a_named_arktrace_descriptor_that_does_not_load_names_the_loader_s_reason() {
    let fixture = Fixture::new();
    let malformed = fixture.0.join("arktrace-descriptor.json");
    fs::write(&malformed, "{}").unwrap();
    fs::set_permissions(&malformed, fs::Permissions::from_mode(0o600)).unwrap();
    for (descriptor, reason) in [
        (
            fixture.0.join("absent-descriptor.json"),
            "analyzer.arktraceNotFound",
        ),
        (malformed, "analyzer.arktraceDescriptorInvalid"),
    ] {
        let control =
            Control::new(fixture.host_with(true, true, Some(descriptor.as_os_str()))).unwrap();
        let rows = call(&control, "operation.list", json!({}));
        for reference in ["analyzer.summarize-trace@1", "analyzer.analyze-trace@1"] {
            let row = entry(&rows, reference);
            assert_eq!(row["availability"], "unavailable", "{reference}");
            assert_eq!(row["reasonCodes"], json!(["provider_tool_unavailable"]));
            assert_eq!(row["reasons"], json!([reason]), "{reference}");
        }
    }
    // No doctor ran: its private home was never made.
    assert!(!fixture.0.join("arktrace-availability-home").exists());
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
