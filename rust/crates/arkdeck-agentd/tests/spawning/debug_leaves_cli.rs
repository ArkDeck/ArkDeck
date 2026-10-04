//! The Debug probe leaf end to end on Windows (TASK-XPA-008): the real
//! signed `arkdeck.exe` against the signed test daemon (`signed_daemon.rs`),
//! which composes the production Windows development root and the shared
//! fake HDC's Debug probe answers in process. `debug probe --target <id>`
//! replays every recorded `debug.probe` exchange the CLI can send
//! (`rust/tests/fixtures/debug-probe`: the seven whose parameters are one
//! `targetId`), each in its recorded mode, and its answer must be Swift's.
//!
//! What this measured is what the coverage manifest counts: `debug.probe`
//! is Windows `implemented`. `debug template run` stays `partial`: it runs
//! the `debug.template@1` Job, whose admission observes the Target, and no
//! Swift oracle records that Job's HDC answers. Host tests only: nothing
//! reaches a device or an installed Runtime.
use crate::signed_daemon::{self, SignedDaemon};
use crate::support;
use serde_json::{Value, json};
use std::fs;

/// The Runtime's answer behind the CLI's envelope: the result, or the
/// Runtime's refusal (its wire code, words and details, without the method
/// and wire code the CLI adds).
fn wire(envelope: &Value) -> Value {
    if envelope["ok"] == true {
        return json!({"ok": true, "result": envelope["result"]});
    }
    let error = &envelope["error"];
    let mut details = error["details"].as_object().cloned().unwrap_or_default();
    let code = details
        .remove("wireCode")
        .unwrap_or_else(|| panic!("a refusal the Runtime did not give: {envelope}"));
    details.remove("method");
    let mut answer = json!({"code": code, "message": error["message"]});
    if !details.is_empty() {
        answer["details"] = Value::Object(details);
    }
    json!({"ok": false, "error": answer})
}

fn windows_statuses(feature: &str) -> Vec<String> {
    let product = arkdeck_cli::machine_contracts::contract_products()
        .into_iter()
        .find(|product| product.relative_path == "cli-feature-coverage.json")
        .expect("the CLI renders its feature coverage");
    let coverage: Value = serde_json::from_slice(&product.bytes).unwrap();
    coverage["entries"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|entry| entry["feature"] == feature)
        .map(|entry| {
            entry["implementationStatusByPlatform"]["windows"]
                .as_str()
                .unwrap_or("unset")
                .to_owned()
        })
        .collect()
}

#[test]
fn the_real_cli_reads_debug_probes_through_the_signed_test_daemon() {
    let _turn = crate::turn();
    let scratch = support::fixture_fs::temporary_root().join(format!(
        "debug-leaves-cli-{:x}",
        u64::from_ne_bytes(arkdeck_platform::random_bytes::<8>().unwrap())
    ));
    let Some((executable, pin)) = signed_daemon::signed_copy(&scratch.join("signed-bin")) else {
        return;
    };
    let fixture = support::fixture("debug-probe");
    let cases = support::document(&fixture, "cases.json");
    let root = scratch.join("root");
    arkdeck_platform::HostDirectory::open_or_create_private(&root).unwrap();
    arkdeck_platform::HostDirectory::open_or_create_private(&root.join("targets-state")).unwrap();
    fs::write(
        root.join("targets-state").join("targets.json"),
        fs::read(fixture.join("targets-state/targets.json")).unwrap(),
    )
    .unwrap();
    let fake_root = scratch.join("hdc");
    fs::create_dir_all(&fake_root).unwrap();
    let daemon = SignedDaemon::start(&executable, &pin, &root, &fixture, &fake_root);

    // `debug probe`: every exchange whose parameters the leaf sends.
    let mut probed = 0;
    for exchange in cases["exchanges"].as_array().unwrap() {
        let params = exchange["params"].as_object().unwrap();
        if exchange["method"] != "debug.probe"
            || params.len() != 1
            || !params["targetId"]
                .as_str()
                .is_some_and(|target| !target.is_empty() && target.len() <= 128)
        {
            continue;
        }
        let mode = exchange["mode"].as_str().unwrap_or("normal");
        fs::write(fake_root.join("hdc-mode"), format!("{mode}\n")).unwrap();
        let (_, envelope) = daemon.cli(&[
            "debug",
            "probe",
            "--target",
            params["targetId"].as_str().unwrap(),
        ]);
        assert_eq!(wire(&envelope), exchange["answer"], "{}", exchange["name"]);
        probed += 1;
    }
    assert_eq!(probed, 7, "every probe the leaf can send");

    daemon.stop();
    let _ = fs::remove_dir_all(&scratch);

    assert_eq!(windows_statuses("debug.probe"), ["implemented"]);
}
