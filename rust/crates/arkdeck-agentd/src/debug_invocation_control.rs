//! `debug.start` and `debug.evaluate` through the production Host and
//! Control: routed to the Runtime Flash invocation owner, which plans a seed
//! with this Host's own `job.plan` planner, Flash composition and facts, as
//! Swift's broker plans with its engine, on the Runtime clock.
//!
//! The inputs are the Swift broker oracle's
//! (`rust/tests/fixtures/debug-invocation`): the Artifact root its Import
//! left, its Target store and the four documents laid down before its
//! exchanges. The documents used here are given a lifetime this test cannot
//! outlive, since the Host's clock is the host's. The broker's answers are
//! replayed against Swift in `arkdeck-hoststore` (`tests/debug_invocation.rs`).
use arkdeck_contract::{CONTRACT_IDENTITY, PROTOCOL_VERSION};
use arkdeck_control::Control;
use arkdeck_hoststore::{
    ArtifactReadStore, FlashHostFacts, FlashInvocations, ImportUploadStore, NativeRockUsbIdentity,
    TargetStore,
};
use serde_json::{Value, json};
use std::fs;
use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
use std::path::{Path, PathBuf};

fn fixtures() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../tests/fixtures/debug-invocation")
}

fn cases() -> Value {
    serde_json::from_slice(&fs::read(fixtures().join("cases.json")).unwrap()).unwrap()
}

fn directory(path: &Path) {
    fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(path)
        .unwrap();
    fs::set_permissions(path, fs::Permissions::from_mode(0o700)).unwrap();
}

struct Root(PathBuf);

impl Root {
    fn new() -> Self {
        let root = std::env::temp_dir().canonicalize().unwrap().join(format!(
            "debug-invocation-control-{:x}",
            u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap())
        ));
        for name in ["artifacts", "targets", "state"] {
            directory(&root.join(name));
        }
        for input in cases()["inputs"].as_array().unwrap() {
            let path = input["path"].as_str().unwrap();
            let destination = if path.starts_with("runtime-debug-invocations/") {
                root.join("state").join(path)
            } else {
                root.join(path)
            };
            directory(destination.parent().unwrap());
            fs::write(
                &destination,
                fs::read(fixtures().join("inputs").join(path)).unwrap(),
            )
            .unwrap();
            let mode = u32::from_str_radix(input["mode"].as_str().unwrap(), 8).unwrap();
            fs::set_permissions(&destination, fs::Permissions::from_mode(mode)).unwrap();
        }
        Self(root)
    }

    /// A laid-down document by the oracle's label, its lifetime extended past
    /// any clock this test runs on; the rest of it is Swift's.
    fn outlive(&self, label: &str) -> String {
        let identity = cases()["documents"][label].as_str().unwrap().to_owned();
        let path = self
            .0
            .join("state/runtime-debug-invocations")
            .join(format!("{identity}.json"));
        let mut document: Value = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
        document["expiresAtUTC"] = json!("2999-01-01T00:00:00Z");
        fs::write(&path, serde_json::to_vec(&document).unwrap()).unwrap();
        identity
    }

    /// The Host every composition starts from: the Target, Artifact and
    /// Import owners, the planner and the invocation owner over one state.
    fn host(&self) -> crate::host::Host {
        let state = self.0.join("state");
        crate::host::Host::from_environment()
            .with_targets(TargetStore::open(&self.0.join("targets")).unwrap())
            .with_artifacts(ArtifactReadStore::open(&self.0.join("artifacts")).unwrap())
            .with_imports(ImportUploadStore::open(&self.0.join("artifacts")).unwrap())
            .with_planning(&state, None)
            .with_flash_invocations(FlashInvocations::open(&state).unwrap())
    }
}

impl Drop for Root {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn call(control: &Control<crate::host::Host>, method: &str, params: Value) -> Value {
    serde_json::from_slice(
        &control.handle_frame(
            &serde_json::to_vec(&json!({
                "protocolVersion": PROTOCOL_VERSION, "contractIdentity": CONTRACT_IDENTITY,
                "id": "debug-invocation-control", "method": method, "params": params,
            }))
            .unwrap(),
        ),
    )
    .unwrap()
}

fn refused(reply: &Value, code: &str, message: &str) {
    assert_eq!(reply["ok"], false, "{reply}");
    assert_eq!(reply["error"]["code"], code, "{reply}");
    assert_eq!(reply["error"]["message"], message, "{reply}");
    assert!(
        reply["error"].get("details").is_none_or(Value::is_null),
        "{reply}"
    );
}

/// The seed the oracle started its first invocation with.
fn seed() -> Value {
    cases()["exchanges"]
        .as_array()
        .unwrap()
        .iter()
        .find(|exchange| exchange["name"] == "start.canonical")
        .unwrap()["params"]
        .clone()
}

fn evaluate(invocation: &str, action: &str) -> Value {
    json!({
        "invocationId": invocation, "actionJson": action,
        "sourceSha256": format!("{:064x}", 1), "buildSha256": format!("{:064x}", 101),
    })
}

/// check-contracts' published view: this build with the contract inputs of
/// the merge base, which name their commit.
fn published_view() -> bool {
    let inputs =
        arkdeck_contract::strict_json(arkdeck_contract::CONTRACT_INPUTS.as_bytes()).unwrap();
    inputs["kind"] == "development" && inputs.get("commit").is_some()
}

/// Whether the contract this build compiled publishes `debug.evaluate`'s
/// answer here: a stop evaluation, which has no observation, beside the
/// attempts Swift recorded, which carry their epoch, request, key, Job and
/// outcome. A merge base older than that widening refuses the answer; one
/// that includes it publishes it, as the checkout does.
fn publishes_stop_beside_attempts() -> bool {
    let (_, schema) = arkdeck_contract::METHOD_SCHEMAS
        .iter()
        .find(|(name, _)| *name == "debug.evaluate")
        .unwrap();
    let schema: Value = serde_json::from_str(schema).unwrap();
    let item = &schema["$defs"]["result"]["properties"]["evaluations"]["items"];
    !item["required"]
        .as_array()
        .is_some_and(|required| required.contains(&json!("observation")))
        && [
            "destructiveEpoch",
            "requestID",
            "idempotencyKey",
            "jobID",
            "outcome",
        ]
        .iter()
        .all(|field| item["properties"].get(*field).is_some())
}

#[test]
fn the_broker_plans_with_this_hosts_planner_and_answers_as_swifts() {
    let root = Root::new();
    let state = root.0.join("state");

    // Without the owner, whatever the parameters: Swift's daemon without its
    // controller.
    {
        let control = Control::new(crate::host::Host::from_environment()).unwrap();
        for method in ["debug.start", "debug.evaluate"] {
            refused(
                &call(&control, method, json!({})),
                "internalError",
                "Runtime debug invocation is not configured",
            );
        }
    }

    // No lane: Swift's engine refuses to plan, which the broker answers as
    // an internal failure with the error Swift's planner threw.
    {
        let absent = crate::arkforge_lane::compose(&state, |_| None, None);
        let control = Control::new(
            root.host()
                .with_flash_planning(absent.planning(&state, false)),
        )
        .unwrap();
        refused(
            &call(&control, "debug.start", seed()),
            "internalError",
            &format!(
                "rejected(ArkDeckCore.RuntimeOperationErrorCode.invalidInput, \"flash.full-restore@1 \
                 is runtime unavailable: {}\")",
                arkdeck_provider_arkforge::Absence::NotConfigured
            ),
        );
    }

    // A lane that may flash, with this Host's facts: an `arkforged` measured,
    // a board no Rockchip binding covers. The plan stops where Swift's does.
    let daemon = root.0.join("arkforged");
    fs::write(&daemon, b"#!/bin/sh\nexit 0\n").unwrap();
    fs::set_permissions(&daemon, fs::Permissions::from_mode(0o755)).unwrap();
    let rockusb = NativeRockUsbIdentity::configured(
        Some(daemon.to_string_lossy().into_owned()),
        Some(arkdeck_contract::sha256_hex(b"#!/bin/sh\nexit 0\n")),
    );
    let exhausted = root.outlive("exhausted");
    let interrupted = root.outlive("interrupted");
    let control = Control::new(
        root.host()
            .with_flash_planning(crate::arkforge_lane::flash_planning(
                None,
                Some("c".repeat(64)),
                rockusb.clone(),
                &state,
                true,
            ))
            .with_flash_host_facts(
                FlashHostFacts::new(&root.0, || Ok(Vec::new())).with_rockusb(rockusb),
            ),
    )
    .unwrap();
    refused(
        &call(&control, "debug.start", seed()),
        "internalError",
        "rejected(ArkDeckCore.RuntimeOperationErrorCode.invalidInput, \"typed plan preflight \
         failed before authorization: post-flash HDC binding expectation is absent or \
         malformed\")",
    );

    // The broker's own refusals, before anything is planned or written.
    let execute = r#"{"schemaVersion":"1.0.0","action":"executePinnedRequest"}"#;
    refused(
        &call(&control, "debug.evaluate", evaluate(&exhausted, execute)),
        "rejected",
        "epochBudgetExhausted",
    );
    refused(
        &call(&control, "debug.evaluate", evaluate(&interrupted, execute)),
        "rejected",
        "executePinnedRequest is not available on the Rust Runtime yet: it runs the pinned \
         Flash, which this Runtime does not execute; the invocation is unchanged",
    );
    assert!(!state.join("runtime-debug-attempts").exists());

    // A stop ends the invocation whose sixteen epochs are spent: the answer
    // carries every attempt Swift recorded and the stop, which the contract
    // publishes once it includes this change's widening.
    let stop = r#"{"schemaVersion":"1.0.0","action":"stop","reasonCode":"operator.cancelled"}"#;
    let reply = call(&control, "debug.evaluate", evaluate(&exhausted, stop));
    if !publishes_stop_beside_attempts() {
        // Only a published view's merge base can predate the widening.
        assert!(published_view(), "debug.evaluate must publish a stop");
        assert_eq!(reply["error"]["code"], "internalError", "{reply}");
        assert_eq!(
            reply["error"]["message"], "the result does not conform to the current contract",
            "{reply}"
        );
        return;
    }
    assert_eq!(reply["ok"], true, "{reply}");
    let result = &reply["result"];
    assert_eq!(result["invocationID"], exhausted.as_str());
    assert_eq!(result["state"], "stopped");
    assert_eq!(result["destructiveEpochsUsed"], 16);
    let evaluations = result["evaluations"].as_array().unwrap();
    assert_eq!(evaluations.len(), 17);
    assert!(
        evaluations[..16]
            .iter()
            .all(|attempt| attempt["jobID"].is_string())
    );
    assert_eq!(evaluations[16]["candidateAction"], "stop");
    assert_eq!(evaluations[16]["disposition"], "stopped");
    assert_eq!(evaluations[16]["detail"], "operator.cancelled");
    assert!(evaluations[16].get("observation").is_none());
    refused(
        &call(&control, "debug.evaluate", evaluate(&exhausted, stop)),
        "rejected",
        "invocationNotActive(\"stopped\")",
    );
}
