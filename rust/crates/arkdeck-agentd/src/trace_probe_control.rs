//! Production Host/Control `trace.probe` over the shared fake HDC: the Swift
//! oracle (`rust/tests/fixtures/trace-probe`) replayed through the real
//! Target owner and the verified process dispatch, answer by answer and call
//! by call. Host tests only: the fake reaches no device, and nothing
//! installed is read or written.
use arkdeck_contract::{
    CONTRACT_IDENTITY, CONTRACT_INPUTS, PROTOCOL_VERSION, sha256_hex, strict_json,
    validate_method_value,
};
use arkdeck_control::Control;
use arkdeck_hoststore::TargetStore;
use arkdeck_platform::VerifiedTool;
use arkdeck_provider_hdc::ProcessDispatch;
use serde_json::{Value, json};
use std::{
    fs,
    os::unix::fs::{DirBuilderExt, PermissionsExt},
    path::PathBuf,
};

/// The fake's fixed root, shared with every oracle replay under one lock.
struct Oracle {
    root: PathBuf,
    fixtures: PathBuf,
    _lock: fs::File,
}
impl Oracle {
    /// `HDCOracleFake.install` with the oracle's answers, the registered
    /// resources they read and the adopted Target document.
    fn install() -> Self {
        let lock = fs::OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .open("/private/tmp/arkdeck-hdc-oracle.lock")
            .unwrap();
        lock.lock().unwrap();
        let root = PathBuf::from("/private/tmp/arkdeck-hdc-oracle");
        let _ = fs::remove_dir_all(&root);
        for directory in ["targets-state", "resources"] {
            fs::DirBuilder::new()
                .recursive(true)
                .mode(0o700)
                .create(root.join(directory))
                .unwrap();
        }
        let fixtures =
            PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../tests/fixtures/trace-probe");
        let resources = fs::read_dir(fixtures.join("resources"))
            .unwrap()
            .map(|entry| format!("resources/{}", entry.unwrap().file_name().to_str().unwrap()));
        for file in ["hdc", "hdc-answers.sh", "targets-state/targets.json"]
            .map(str::to_owned)
            .into_iter()
            .chain(resources)
        {
            fs::copy(fixtures.join(&file), root.join(&file)).unwrap();
            fs::set_permissions(
                root.join(&file),
                fs::Permissions::from_mode(if file == "hdc" { 0o700 } else { 0o600 }),
            )
            .unwrap();
        }
        Self {
            root,
            fixtures,
            _lock: lock,
        }
    }
    fn control(&self) -> Control<crate::host::Host> {
        let digest = sha256_hex(&fs::read(self.root.join("hdc")).unwrap());
        Control::new(
            crate::host::Host::from_environment()
                .with_targets(TargetStore::open(&self.root.join("targets-state")).unwrap())
                .with_development_hdc(Some(ProcessDispatch::new(
                    VerifiedTool::open(self.root.join("hdc"), &digest).unwrap(),
                    None,
                ))),
        )
        .unwrap()
    }
    fn mode(&self, mode: &str) {
        fs::write(self.root.join("hdc-mode"), format!("{mode}\n")).unwrap();
    }
    /// The calls the fake received since the last read, sorted, as the
    /// oracle records one exchange's concurrent calls.
    fn calls(&self) -> Vec<String> {
        let log = self.root.join("hdc-calls.log");
        let mut calls: Vec<String> = fs::read_to_string(&log)
            .unwrap_or_default()
            .lines()
            .map(str::to_owned)
            .collect();
        fs::write(log, "").unwrap();
        calls.sort_unstable();
        calls
    }
}
impl Drop for Oracle {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

fn call(control: &Control<crate::host::Host>, params: Value) -> Value {
    let reply: Value = serde_json::from_slice(
        &control.handle_frame(
            &serde_json::to_vec(&json!({
                "protocolVersion": PROTOCOL_VERSION, "contractIdentity": CONTRACT_IDENTITY,
                "id": "trace-probe", "method": "trace.probe", "params": params
            }))
            .unwrap(),
        ),
    )
    .unwrap();
    if reply["ok"] == true {
        json!({"ok": true, "result": reply["result"]})
    } else {
        json!({"ok": false, "error": reply["error"]})
    }
}

/// The published contract view runs this checkout's tests against the merge
/// base's inputs, which name their commit and may predate the production
/// `trace.probe` result shape. The checkout and candidate views carry it.
fn published_view() -> bool {
    let inputs = strict_json(CONTRACT_INPUTS.as_bytes()).unwrap();
    inputs["kind"] == "development" && inputs.get("commit").is_some()
}

/// What the control layer answers in place of Swift's recorded answer under
/// this build's schema: the answer when the schema publishes it, else
/// `internalError`. The checkout and candidate views must publish all of them.
fn published(answer: &Value) -> Value {
    let conforms = if answer["ok"] == true {
        validate_method_value("trace.probe", "result", &answer["result"]).is_ok()
    } else {
        validate_method_value("trace.probe", "errorCode", &answer["error"]["code"]).is_ok()
    };
    assert!(
        conforms || published_view(),
        "the current contract must publish Swift's answer {answer}"
    );
    if conforms {
        answer.clone()
    } else {
        json!({"ok": false, "error": {"code": "internalError",
            "message": "the result does not conform to the current contract"}})
    }
}

#[test]
fn trace_probe_replays_the_swift_oracle_through_production_host() {
    let oracle = Oracle::install();
    let control = oracle.control();
    let cases: Value =
        serde_json::from_slice(&fs::read(oracle.fixtures.join("cases.json")).unwrap()).unwrap();
    let mut calls = String::new();
    for exchange in cases["exchanges"].as_array().unwrap() {
        if let Some(mode) = exchange["mode"].as_str() {
            oracle.mode(mode);
        }
        let answer = call(&control, exchange["params"].clone());
        assert_eq!(
            answer,
            published(&exchange["answer"]),
            "{}",
            exchange["name"]
        );
        for line in oracle.calls() {
            calls.push_str(&line);
            calls.push('\n');
        }
    }
    assert_eq!(
        calls,
        fs::read_to_string(oracle.fixtures.join("hdc-calls.log")).unwrap()
    );
}

/// Swift's handler reads a string `targetId` and nothing else: a member
/// beside it changes neither the reads nor the answer, and no other
/// `targetId` reaches the device.
#[test]
fn only_the_adopted_route_reaches_the_device() {
    let oracle = Oracle::install();
    let control = oracle.control();
    let cases: Value =
        serde_json::from_slice(&fs::read(oracle.fixtures.join("cases.json")).unwrap()).unwrap();
    let portrait = cases["exchanges"]
        .as_array()
        .unwrap()
        .iter()
        .find(|exchange| exchange["name"] == "probe.captureEligible")
        .unwrap();
    let target = cases["target"]["targetId"].as_str().unwrap();
    oracle.mode("normal");
    let answer = call(
        &control,
        json!({"targetId": target, "rawCommand": "shell reboot", "connectKey": "forged"}),
    );
    assert_eq!(answer, published(&portrait["answer"]));
    let calls = oracle.calls();
    assert_eq!(calls.len(), 12);
    assert!(calls.iter().all(|call| call.starts_with(&format!(
        "-t {} shell ",
        cases["target"]["connectKey"].as_str().unwrap()
    ))));
    assert!(
        !calls
            .iter()
            .any(|call| call.contains("reboot") || call.contains("forged"))
    );
    for params in [json!({"targetId": 5}), json!({"target": target}), json!({})] {
        let answer = call(&control, params);
        assert_eq!(answer["error"]["code"], "invalidParams");
        assert_eq!(answer["error"]["message"], "targetId is required");
    }
    assert!(oracle.calls().is_empty());
}
