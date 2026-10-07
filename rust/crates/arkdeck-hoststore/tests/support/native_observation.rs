//! Genuine typed preflight replies for the current native plan. The frozen
//! native fixture and its 225 deployment/rollback calls remain unchanged.
use arkdeck_provider_hdc::{DispatchFailure, HdcDispatch, ProcessPlan, Receipt};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Duration;

pub struct Observed<'a> {
    pub inner: &'a (dyn HdcDispatch + Sync),
    pub missing_firmware: bool,
    pub mismatched_target: bool,
    pub reads: AtomicUsize,
}

impl<'a> Observed<'a> {
    pub fn new(inner: &'a (dyn HdcDispatch + Sync)) -> Self {
        Self {
            inner,
            missing_firmware: false,
            mismatched_target: false,
            reads: AtomicUsize::new(0),
        }
    }
}

impl HdcDispatch for Observed<'_> {
    fn mutation_identity_current(&self) -> bool {
        self.inner.mutation_identity_current()
    }

    fn dispatch(&self, plan: &ProcessPlan) -> Result<Receipt, DispatchFailure> {
        let args: Vec<&str> = plan.arguments.iter().map(String::as_str).collect();
        let key = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
        let stdout = if args == ["list", "targets", "-v"] {
            if self.mismatched_target {
                "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\t\tUSB\tConnected\tlocalhost\n"
            } else {
                "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\t\tUSB\tConnected\tlocalhost\n"
            }
        } else if args == ["-t", key, "shell", "param", "get", "const.product.name"] {
            "OpenHarmony Reference Device\n"
        } else if args == ["-t", key, "shell", "param", "get", "const.ohos.fullname"] {
            if self.missing_firmware {
                ""
            } else {
                "OpenHarmony-4.1-release\n"
            }
        } else {
            return self.inner.dispatch(plan);
        };
        self.reads.fetch_add(1, Ordering::SeqCst);
        Ok(Receipt {
            exit_status: 0,
            stdout: stdout.as_bytes().to_vec(),
            stderr: Vec::new(),
            truncated: false,
            duration: Duration::ZERO,
        })
    }
}

pub fn assert_observation(record: &serde_json::Value, tool_sha: &str) {
    use serde_json::json;
    let observation = &record["evidenceObservation"];
    assert_eq!(observation["providerID"], "hdc");
    assert_eq!(
        observation["targetID"],
        record["request"]["target"]["targetId"]
    );
    assert_eq!(observation["bindingRevision"], 1);
    assert_eq!(
        observation["stableIdentitySHA256"],
        record["materializedStableTargetIdentitySHA256"]
    );
    assert_eq!(observation["toolSHA256"], tool_sha);
    assert_eq!(observation["toolVersion"], "3.2.0d");
    assert_eq!(observation["model"], "OpenHarmony Reference Device");
    assert_eq!(observation["firmware"], "OpenHarmony-4.1-release");
    assert_eq!(observation["transport"], "usb");
    assert_eq!(observation["confirmationMethod"], "machineReadback");
    assert_eq!(observation["confirmedAtUTC"], "2026-09-14T00:00:00Z");
    let steps: Vec<_> = observation["preflightSteps"]
        .as_array()
        .unwrap()
        .iter()
        .map(|step| step["stepID"].clone())
        .collect();
    assert_eq!(
        steps,
        json!([
            "confirm-evidence-target",
            "read-evidence-model",
            "read-evidence-firmware"
        ])
        .as_array()
        .unwrap()
        .clone()
    );
    let timeline = record["timeline"].as_array().unwrap();
    let firmware = timeline
        .iter()
        .position(|line| line == "evidence-preflight read-evidence-firmware")
        .unwrap();
    let consumed = timeline
        .iter()
        .position(|line| line == "capability consumed before first mutation")
        .unwrap();
    let send = timeline
        .iter()
        .position(|line| {
            line.as_str()
                .is_some_and(|line| line.starts_with("intent send-to-staging"))
        })
        .unwrap();
    assert!(firmware < consumed && consumed < send);
}

/// Read every published Manifest byte and its strict public Session projection.
pub fn assert_session(owners: &super::hdc_oracle::Owners, record: &serde_json::Value) {
    use arkdeck_contract::sha256_hex;
    use serde_json::{Value, json};
    let marker = &record["sessionPublicationRecord"];
    let path = owners
        .root
        .join("Sessions")
        .join(marker["relativeSessionPath"].as_str().unwrap());
    let bytes = std::fs::read(path.join("manifest.json")).unwrap();
    assert_eq!(sha256_hex(&bytes), marker["receipt"]["manifestSHA256"]);
    let manifest: Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(manifest["jobId"], record["jobID"]);
    assert_eq!(manifest["sessionId"], marker["sessionID"]);
    assert_eq!(manifest["status"], record["state"]);
    assert_eq!(
        manifest["workflow"]["profileVersion"],
        record["catalogDigest"]
    );
    assert_eq!(
        manifest["originalTarget"]["identitySnapshot"]["model"],
        "OpenHarmony Reference Device"
    );
    assert_eq!(
        manifest["originalTarget"]["identitySnapshot"]["firmware"],
        "OpenHarmony-4.1-release"
    );
    assert_eq!(manifest["toolchain"]["sha256"], owners.digest);
    assert_eq!(manifest["toolchain"]["reportedVersion"], "3.2.0d");
    let shown = owners
        .sessions
        .handle_resource(
            "session.show",
            json!({"sessionId":marker["sessionID"]})
                .as_object()
                .unwrap(),
        )
        .unwrap();
    assert_eq!(shown["sessionId"], marker["sessionID"]);
    assert_eq!(shown["generation"], marker["receipt"]["catalogGeneration"]);
}
