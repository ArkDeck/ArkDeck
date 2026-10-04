//! The Swift Debug probe oracle (`rust/tests/fixtures/debug-probe`, recorded
//! by `DebugProbeOracleContractTests`) replayed on Windows (TASK-XPA-008)
//! through the production Host and Control, as the macOS replay
//! (`debug_read_control.rs`) replays it: `debug.probe` and
//! `debug.template.run` over the oracle's Target store and the shared fake
//! HDC's answers, ported in process (`oracle_fake.rs`, its own root below
//! `TEMP`), which the Host reads through its test-only seam; the production
//! Windows daemon composes an HDC only for the registered tuple. Every answer
//! must be Swift's, byte for byte (the template's duration is the host
//! clock's, which the oracle fixed), and the calls the fake received, one
//! line each, must be the ones Swift's made. Host tests only: nothing reaches
//! a device or an installed Runtime.
use arkdeck_contract::{CONTRACT_IDENTITY, PROTOCOL_VERSION, sha256_hex};
use arkdeck_control::Control;
use arkdeck_hoststore::TargetStore;
use serde_json::{Value, json};
use std::fs;
use std::path::PathBuf;
use std::sync::Arc;

fn fixtures() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../tests/fixtures/debug-probe")
}

/// A fresh directory below `TEMP` in its plain, long spelling, removed on
/// drop.
struct Root(PathBuf);

impl Root {
    fn new() -> Self {
        let base = std::env::temp_dir().canonicalize().unwrap();
        let base = match base.to_str().and_then(|text| text.strip_prefix(r"\\?\")) {
            Some(plain) => PathBuf::from(plain),
            None => base,
        };
        let root = base.join(format!(
            "arkdeck-debug-probe-{:x}",
            u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap())
        ));
        arkdeck_platform::HostDirectory::open_or_create_private(&root).unwrap();
        arkdeck_platform::HostDirectory::open_or_create_private(&root.join("targets-state"))
            .unwrap();
        arkdeck_platform::HostDirectory::open_or_create_private(&root.join("hdc")).unwrap();
        Self(root)
    }
}

impl Drop for Root {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn call(control: &Control<crate::host::Host>, method: &str, params: Value) -> Value {
    let reply: Value = serde_json::from_slice(
        &control.handle_frame(
            &serde_json::to_vec(&json!({
                "protocolVersion": PROTOCOL_VERSION, "contractIdentity": CONTRACT_IDENTITY,
                "id": "debug-probe-replay", "method": method, "params": params,
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

#[test]
fn debug_reads_replay_the_swift_oracle_through_the_production_host() {
    let _turn = crate::turn();
    let fixtures = fixtures();
    let provenance: Value =
        serde_json::from_slice(&fs::read(fixtures.join("provenance.json")).unwrap()).unwrap();
    for (name, digest) in provenance["files"].as_object().unwrap() {
        assert_eq!(
            sha256_hex(&fs::read(fixtures.join(name)).unwrap()),
            digest.as_str().unwrap(),
            "{name} is the recorded file"
        );
    }
    let root = Root::new();
    // The oracle's Target store, as Swift left it before its first request.
    fs::write(
        root.0.join("targets-state").join("targets.json"),
        fs::read(fixtures.join("targets-state/targets.json")).unwrap(),
    )
    .unwrap();
    let fake_root = root.0.join("hdc");
    let answers = crate::oracle_fake::Answers::of(
        &fs::read_to_string(fixtures.join("hdc-answers.sh")).unwrap(),
    );
    assert_eq!(answers, crate::oracle_fake::Answers::DebugProbe);
    let tool_sha256 = sha256_hex(&fs::read(fixtures.join("hdc")).unwrap());
    assert_eq!(provenance["hdcSHA256"], tool_sha256.as_str());
    let control = Control::new(
        crate::host::Host::from_environment()
            .with_targets(TargetStore::open(&root.0.join("targets-state")).unwrap())
            .with_test_hdc(
                Arc::new(crate::oracle_fake::OracleFake::new(&fake_root, answers)),
                &tool_sha256,
            ),
    )
    .unwrap();
    let cases: Value =
        serde_json::from_slice(&fs::read(fixtures.join("cases.json")).unwrap()).unwrap();
    let exchanges = cases["exchanges"].as_array().unwrap();
    assert_eq!(exchanges.len(), 23);
    let mut all_calls = String::new();
    for exchange in exchanges {
        let mode = exchange["mode"].as_str().unwrap_or("normal");
        fs::write(fake_root.join("hdc-mode"), format!("{mode}\n")).unwrap();
        fs::write(fake_root.join("hdc-calls.log"), "").unwrap();
        let mut answer = call(
            &control,
            exchange["method"].as_str().unwrap(),
            exchange["params"].clone(),
        );
        if answer["result"].get("durationMilliseconds").is_some() {
            assert!(answer["result"]["durationMilliseconds"].as_u64().is_some());
            // The oracle fixed the host clock.
            answer["result"]["durationMilliseconds"] = json!(12);
        }
        assert_eq!(answer, exchange["answer"], "{}", exchange["name"]);
        let calls = fs::read_to_string(fake_root.join("hdc-calls.log")).unwrap();
        let mut calls: Vec<_> = calls.lines().collect();
        calls.sort_unstable();
        for line in calls {
            all_calls.push_str(line);
            all_calls.push('\n');
        }
    }
    assert_eq!(
        all_calls,
        fs::read_to_string(fixtures.join("hdc-calls.log")).unwrap()
    );
    // The Target store is read, never written.
    assert_eq!(
        fs::read(root.0.join("targets-state").join("targets.json")).unwrap(),
        fs::read(fixtures.join("targets-state/targets.json")).unwrap()
    );
}
