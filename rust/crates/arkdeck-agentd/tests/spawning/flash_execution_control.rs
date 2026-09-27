//! Host/control Flash execution with real Runtime owners and fake external ports.
//! Each fixture runs alone in a child, and spawning holds the suite turn.
use arkdeck_contract::{CONTRACT_IDENTITY, PROTOCOL_VERSION};
use arkdeck_control::Control;
use arkdeck_hoststore::{
    ArtifactReadStore, FlashHostFacts, FlashPlanning, ImportUploadStore, JobStore,
    NativeRockUsbIdentity, TargetStore,
};
use serde_json::{Value, json};
use std::fs;
use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
use std::path::{Path, PathBuf};

fn fixtures() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../tests/fixtures/flash-plan")
}

struct Root(PathBuf);

impl Root {
    /// The oracle's Artifact root and Target store, laid down as Swift left
    /// them, beside an empty Job state.
    fn new() -> Self {
        let root = std::env::temp_dir().canonicalize().unwrap().join(format!(
            "flash-plan-control-{:x}",
            u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap())
        ));
        for name in ["artifacts", "targets", "jobs"] {
            directory(&root.join(name));
        }
        let cases = cases();
        for input in cases["inputs"].as_array().unwrap() {
            let path = input["path"].as_str().unwrap();
            let (source, destination) = match path.strip_prefix("../targets/") {
                Some(target) => (
                    fixtures().join("inputs/targets").join(target),
                    root.join("targets").join(target),
                ),
                None => (
                    fixtures().join("inputs/artifacts").join(path),
                    root.join("artifacts").join(path),
                ),
            };
            directory(destination.parent().unwrap());
            fs::write(&destination, fs::read(source).unwrap()).unwrap();
            let mode = u32::from_str_radix(input["mode"].as_str().unwrap(), 8).unwrap();
            fs::set_permissions(&destination, fs::Permissions::from_mode(mode)).unwrap();
        }
        Self(root)
    }

    /// The Host every composition below starts from: the Target, Artifact,
    /// Import and Job owners and the planner over the Job state.
    fn host(&self) -> crate::host::Host {
        crate::host::Host::from_environment()
            .with_targets(TargetStore::open(&self.0.join("targets")).unwrap())
            .with_artifacts(ArtifactReadStore::open(&self.0.join("artifacts")).unwrap())
            .with_imports(ImportUploadStore::open(&self.0.join("artifacts")).unwrap())
            .with_jobs(JobStore::open_owner(&self.0.join("jobs")).unwrap())
            .with_planning(&self.0.join("jobs"), None)
    }
}

impl Drop for Root {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn directory(path: &Path) {
    fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(path)
        .unwrap();
    fs::set_permissions(path, fs::Permissions::from_mode(0o700)).unwrap();
}

fn cases() -> Value {
    serde_json::from_slice(&fs::read(fixtures().join("cases.json")).unwrap()).unwrap()
}

/// The request the oracle recorded for `exchange`.
fn request(exchange: &str) -> String {
    cases()["exchanges"]
        .as_array()
        .unwrap()
        .iter()
        .find(|recorded| recorded["name"] == exchange)
        .unwrap()["requestJson"]
        .as_str()
        .unwrap()
        .to_owned()
}

fn call(control: &Control<crate::host::Host>, method: &str, request: &str) -> Value {
    serde_json::from_slice(
        &control.handle_frame(
            &serde_json::to_vec(&json!({
                "protocolVersion": PROTOCOL_VERSION, "contractIdentity": CONTRACT_IDENTITY,
                "id": "flash-plan-control", "method": method,
                "params": {"requestJson": request},
            }))
            .unwrap(),
        ),
    )
    .unwrap()
}

fn control(host: crate::host::Host) -> Control<crate::host::Host> {
    Control::new(host).unwrap()
}

// Reuse the Swift oracle's fake lane and receipts. Only the Host/control and
// durable Runtime owners are real; the fixture shell never reaches a device.
#[path = "../../../arkdeck-hoststore/tests/support/flash_lane.rs"]
#[allow(dead_code)]
mod execution_fakes;

#[test]
fn flash_execution_reaches_the_runtime_owner_in_a_separate_process() {
    flash_execution_fixture("completed");
}

#[test]
fn flash_unknown_outcome_reconciles_passively_without_replay() {
    flash_execution_fixture("unknown");
}

fn flash_execution_fixture(outcome: &str) {
    let _turn = crate::turn();
    let output = std::process::Command::new(std::env::current_exe().unwrap())
        .env("ARKDECK_TEST_FLASH_OWNER_OUTCOME", outcome)
        .args([
            "--exact",
            "flash_execution_control::flash_execution_process_fixture",
            "--ignored",
            "--nocapture",
        ])
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
}

#[test]
#[ignore = "subprocess fixture: invoked by flash_execution_reaches_the_runtime_owner_in_a_separate_process"]
fn flash_execution_process_fixture() {
    let _turn = crate::turn();
    use execution_fakes::{FakeHost, FakeLane, Fakes};
    use std::sync::Arc;
    let unknown = std::env::var("ARKDECK_TEST_FLASH_OWNER_OUTCOME").as_deref() == Ok("unknown");
    let root = Root::new();
    let hdc_bytes = br#"#!/bin/sh
case "$*" in
  *"list targets"*) printf '150100424a544e4600\t\tUSB\tConnected\tlocalhost\n' ;;
  *"param get const.ohos.fullname"*) printf 'OpenHarmony-7.0.0.35-20260728_180253\n' ;;
  *"param get const.product.model"*) printf 'DAYU200\n' ;;
  "-v") printf 'Ver: 3.2.0f\n' ;;
  *) exit 1 ;;
esac
"#;
    let hdc = root.0.join("fixture-hdc");
    fs::write(&hdc, hdc_bytes).unwrap();
    fs::set_permissions(&hdc, fs::Permissions::from_mode(0o700)).unwrap();
    let digest = arkdeck_contract::sha256_hex(hdc_bytes);
    let tool = arkdeck_platform::VerifiedTool::open(&hdc, &digest).unwrap();
    let rockusb =
        NativeRockUsbIdentity::configured(Some(hdc.to_string_lossy().into_owned()), Some(digest));
    fs::write(
        root.0.join("rockchip-binding.json"),
        serde_json::to_vec(&json!({
            "revision": 1, "serial": "150100424a544e4600", "usbTopology": "42",
            "evidence": [format!("identity:serial-sha256={}",
                arkdeck_contract::sha256_hex(b"150100424a544e4600"))]
        }))
        .unwrap(),
    )
    .unwrap();
    fs::set_permissions(
        root.0.join("rockchip-binding.json"),
        fs::Permissions::from_mode(0o600),
    )
    .unwrap();
    let fakes = Fakes::default();
    if unknown {
        fakes.begin(execution_fakes::Script {
            perform: "outcomeUnknown".into(),
            terminal: "outcomeUnknown".into(),
            ..Default::default()
        });
    }
    let host = root
        .host()
        .with_capabilities(
            arkdeck_hoststore::CapabilityStore::open(&root.0.join("jobs/capabilities")).unwrap(),
        )
        .with_development_mutation_root(root.0.join("jobs"))
        .with_development_hdc(Some(arkdeck_provider_hdc::ProcessDispatch::new(tool, None)))
        .with_flash_host_facts(
            FlashHostFacts::new(&root.0, || {
                Ok(vec![arkdeck_platform::UsbHostDevice {
                    serial: "150100424a544e4600".into(),
                    vendor_id: 0x2207,
                    product_id: 0x5000,
                    topology: "42".into(),
                    product_name: Some("HDC Device".into()),
                    registry_entry_id: Some(1),
                }])
            })
            .with_rockusb(rockusb),
        )
        .with_flash_planning(FlashPlanning::new(
            None,
            || None,
            Some(execution_fakes::TOOLCHAIN.into()),
        ))
        .with_flash_execution(
            Arc::new(FakeLane::new(&fakes)),
            Arc::new(FakeHost(fakes.clone())),
            "org.openharmony.dayu200@1.0.0".into(),
        );
    let control = control(host);
    let mut request: Value = serde_json::from_str(&request("canonical.full")).unwrap();
    let plan = call(&control, "job.plan", &request.to_string());
    assert_eq!(plan["ok"], true, "{plan}");
    request["reviewedPlanDigest"] = plan["result"]["materializedPlanDigest"].clone();
    let admitted = call(&control, "job.submit", &request.to_string());
    assert_eq!(admitted["ok"], true, "{admitted}");
    let job = admitted["result"]["jobId"].as_str().unwrap();
    let job_call = |method: &str| -> Value {
        serde_json::from_slice(
            &control.handle_frame(
                &serde_json::to_vec(&json!({
                    "protocolVersion": PROTOCOL_VERSION, "contractIdentity": CONTRACT_IDENTITY,
                    "id": "flash-execution-control", "method": method, "params": {"jobId": job},
                }))
                .unwrap(),
            ),
        )
        .unwrap()
    };
    let result = job_call("job.run");
    assert_eq!(result["ok"], true, "{result}");
    let status = job_call("job.status");
    if unknown {
        assert_eq!(status["result"]["state"], "waitingForRecovery", "{status}");
        assert_eq!(status["result"]["outcomeUnknown"], true, "{status}");
        let calls = fakes.calls();
        assert!(
            calls.0.iter().any(|call| call.starts_with("perform ")),
            "{calls:?}"
        );
        assert_eq!(job_call("job.run")["ok"], false);
        assert_eq!(fakes.calls(), calls, "an unknown intent must never replay");
        let reconciled = job_call("job.reconcile");
        assert_eq!(reconciled["ok"], true, "{reconciled}");
        let after = fakes.calls();
        assert_eq!(after.1, calls.1, "reconcile never dispatches a host action");
        assert_eq!(&after.0[..calls.0.len()], calls.0.as_slice());
        assert_eq!(after.0.len(), calls.0.len() + 1, "{after:?}");
        assert!(after.0.last().unwrap().starts_with("observe "), "{after:?}");
        let status = job_call("job.status");
        assert_eq!(status["result"]["state"], "waitingForRecovery", "{status}");
        assert_eq!(status["result"]["outcomeUnknown"], true, "{status}");
        let attempts = fakes.calls();
        assert_eq!(job_call("job.run")["ok"], false);
        assert_eq!(fakes.calls(), attempts);
        return;
    }
    assert_eq!(
        status["result"]["state"],
        "succeeded",
        "{status}; result: {}; calls: {:?}",
        job_call("job.result"),
        fakes.calls()
    );
    let calls = fakes.calls();
    assert!(
        calls.0.iter().any(|call| call.starts_with("prepare ")),
        "{calls:?}"
    );
    assert!(
        calls.0.iter().any(|call| call.starts_with("perform ")),
        "{calls:?}"
    );
    let terminal = job_call("job.run");
    assert_eq!(terminal["error"]["code"], "resourceConflict", "{terminal}");
    assert_eq!(fakes.calls(), calls, "terminal records never redispatch");
    assert_eq!(job_call("job.reconcile")["ok"], true);
    assert_eq!(
        fakes.calls(),
        calls,
        "terminal reconciliation never redispatches"
    );
}
