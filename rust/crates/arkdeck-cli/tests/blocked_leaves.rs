//! The registry leaves whose subsystem the Rust CLI has not ported —
//! `runtime update *`, `maintainer update-feed assemble` and the deprecated
//! `update-feed assemble` — answered by name (`arkdeck_cli::blocked_leaves`): Swift's
//! registry pass judges the argv (its refusals, the leaf's help), and an argv
//! Swift would dispatch is `blockedByProductDefect`, exit 69, with nothing
//! read, written or connected. Swift's argv fixtures for these leaves replay
//! in `argv_fixtures.rs`.
use serde_json::{Value, json};
use std::process::Command;

fn cli(argv: &[&str]) -> std::process::Output {
    Command::new(env!("CARGO_BIN_EXE_arkdeck"))
        .args(argv)
        .env_remove("ARKDECK_ENDPOINT")
        .output()
        .unwrap()
}

/// Each blocked leaf, with the options its registry entry requires.
fn leaves(out: &str) -> Vec<(&'static str, Vec<String>)> {
    let owned = |tokens: &[&str]| tokens.iter().map(|token| (*token).to_owned()).collect();
    let assemble = |path: &[&str]| -> Vec<String> {
        let mut argv: Vec<String> = owned(path);
        argv.extend(
            [
                "--payload",
                "/nonexistent/payload",
                "--signature",
                "/nonexistent/sig",
                "--out",
                out,
            ]
            .map(str::to_owned),
        );
        argv
    };
    vec![
        (
            "runtime.update.check",
            owned(&["runtime", "update", "check"]),
        ),
        (
            "runtime.update.download",
            owned(&["runtime", "update", "download"]),
        ),
        (
            "runtime.update.handoff",
            owned(&[
                "runtime",
                "update",
                "handoff",
                "--consent",
                "reveal-in-finder",
            ]),
        ),
        (
            "runtime.update.status",
            owned(&["runtime", "update", "status"]),
        ),
        (
            "runtime.update.cancel",
            owned(&["runtime", "update", "cancel"]),
        ),
        (
            "runtime.update.cleanup",
            owned(&["runtime", "update", "cleanup"]),
        ),
        (
            "maintainer.update-feed.assemble",
            assemble(&["maintainer", "update-feed", "assemble"]),
        ),
        (
            "update-feed.assemble",
            assemble(&["update-feed", "assemble"]),
        ),
    ]
}

#[test]
fn a_blocked_leaf_is_blocked_by_a_product_defect_and_dispatches_nothing() {
    let root = std::env::temp_dir().join(format!(
        "arkdeck-blocked-{:016x}",
        u64::from_ne_bytes(arkdeck_platform::random_bytes::<8>().unwrap())
    ));
    std::fs::create_dir(&root).unwrap();
    let out = root.join("out.json");
    let out = out.to_str().unwrap();
    let leaves = leaves(out);
    assert_eq!(leaves.len(), 8);
    for (command, argv) in &leaves {
        let argv: Vec<&str> = argv.iter().map(String::as_str).collect();
        let deprecated = command.starts_with("update-feed.");
        // The versioned envelope, with the lifecycle of a deprecated spelling.
        // Only `runtime update` declares a correlation identity.
        let feed = command.contains("update-feed");
        let mut machine = argv.clone();
        machine.extend(["--output", "json"]);
        if !feed {
            machine.extend(["--control-request-id", "ctl-blocked"]);
        }
        let output = cli(&machine);
        assert_eq!(output.status.code(), Some(69), "{command}");
        assert!(output.stderr.is_empty(), "{command}");
        let envelope: Value = serde_json::from_slice(&output.stdout).unwrap();
        assert_eq!(arkdeck_cli::render(&envelope).unwrap(), output.stdout);
        assert_eq!(envelope["command"], *command);
        assert_eq!(envelope["ok"], false);
        if !feed {
            assert_eq!(envelope["meta"]["controlRequestId"], "ctl-blocked");
        }
        assert_eq!(envelope["error"]["code"], "blockedByProductDefect");
        assert_eq!(
            envelope["error"]["details"],
            json!({"command": command, "newDispatchCount": 0})
        );
        assert!(
            envelope["error"]["message"]
                .as_str()
                .unwrap()
                .starts_with(&format!(
                    "`{}` is not provided by the Rust CLI yet (",
                    command.replace('.', " ")
                )),
            "{envelope}"
        );
        assert_eq!(
            envelope["meta"].get("lifecycle").is_some(),
            deprecated,
            "{command}"
        );
        // The human rendering: the deprecation first, then the refusal.
        let output = cli(&argv);
        assert_eq!(output.status.code(), Some(69), "{command}");
        assert!(output.stdout.is_empty(), "{command}");
        let stderr = String::from_utf8(output.stderr).unwrap();
        assert_eq!(stderr.starts_with("warning: "), deprecated, "{stderr}");
        assert!(
            stderr.contains("blocked") || stderr.contains("not provided"),
            "{stderr}"
        );
        // The legacy `--json`, where the leaf declares it.
        if !feed {
            let mut legacy = argv.clone();
            legacy.push("--json");
            let output = cli(&legacy);
            assert_eq!(output.status.code(), Some(69), "{command}");
            let document: Value = serde_json::from_slice(&output.stdout).unwrap();
            assert_eq!(document["error"]["code"], "blockedByProductDefect");
        }
    }
    // Nothing was written where the maintainer tools would have written.
    assert!(!std::path::Path::new(out).exists());
    std::fs::remove_dir_all(&root).unwrap();
}

/// Swift's registry pass still judges the argv: a missing required option is
/// its refusal, and help is the leaf's own.
#[test]
fn the_registry_judges_a_blocked_leafs_argv_first() {
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
