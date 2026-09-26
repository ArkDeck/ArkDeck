//! Registry refusal and help remain available after updater cutover.
use serde_json::Value;
use std::process::Command;

fn cli(argv: &[&str]) -> std::process::Output {
    Command::new(env!("CARGO_BIN_EXE_arkdeck"))
        .args(argv)
        .env_remove("ARKDECK_ENDPOINT")
        .output()
        .unwrap()
}

/// Swift's registry pass still judges the argv: a missing required option is
/// its refusal, and help is the leaf's own.
#[test]
fn the_registry_judges_update_argv_before_any_effect() {
    let output = cli(&["runtime", "update", "handoff", "--output", "json"]);
    assert_eq!(output.status.code(), Some(64));
    let envelope: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(envelope["error"]["code"], "invalidOption");
    let output = cli(&["runtime", "update", "check", "--help"]);
    assert_eq!(output.status.code(), Some(0));
    assert!(
        String::from_utf8(output.stdout)
            .unwrap()
            .starts_with("arkdeck runtime update check — ")
    );
    // Listed by `commands`: the registry's leaf is answered, never unknown.
    let output = cli(&["commands", "--output", "json"]);
    let envelope: Value = serde_json::from_slice(&output.stdout).unwrap();
    let listed: Vec<&str> = envelope["result"]["commands"]
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|entry| entry["command"].as_str())
        .filter(|command| command.starts_with("runtime.update.") || command.contains("update-feed"))
        .collect();
    assert_eq!(listed.len(), 10, "{listed:?}");
}
