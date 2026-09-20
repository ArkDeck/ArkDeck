//! Every argv fixture Swift's CLI publishes for a leaf the Rust CLI serves,
//! copied unchanged into `rust/tests/fixtures/current-cli-argv`, replays
//! through the Rust parser: the leaf Swift's parser names, help where Swift
//! answers help, and Swift's refusal code and exit status where Swift refuses.
//! The cases this parser still answers otherwise are listed exactly, each a
//! parity defect of a leaf it serves (TASK-XPA-018's audit,
//! `evidence/runs/TASK-XPA-018/cli-parity-audit-20260919.md`).
use arkdeck_cli::{
    command_registry, completion_script, failure_envelope, help_text, parse, render,
};
use serde_json::{Value, json};
use std::{collections::BTreeSet, fs, path::Path, process::Command};

/// `(fixture, case, macOS only)`: `runtime tool register` takes `--socket`
/// for every kind, where Swift's parser refuses it unless the kind is DevEco —
/// Swift registers an HDC in its own process, while this CLI sends every
/// registration to the Runtime that owns the Bootstrap store, so the endpoint
/// is what the leaf needs (`tool_register.rs`). Off macOS `--socket` is
/// `unsupportedOnPlatform`, which is what the replay expects there.
const KNOWN_DEVIATIONS: &[(&str, &str, bool)] = &[
    ("runtime.tool.register", "hdcSocketRefused", true),
    ("runtime.tool.register", "macosCompatibilityOption", true),
];

fn fixtures() -> Vec<(String, Value)> {
    let directory =
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/fixtures/current-cli-argv");
    let mut documents: Vec<(String, Value)> = fs::read_dir(&directory)
        .unwrap()
        .map(|entry| {
            let path = entry.unwrap().path();
            let name = path.file_stem().unwrap().to_str().unwrap().to_owned();
            (
                name,
                serde_json::from_slice(&fs::read(&path).unwrap()).unwrap(),
            )
        })
        .collect();
    documents.sort_by(|left, right| left.0.cmp(&right.0));
    documents
}

/// How this parser's answer differs from Swift's for one case, if it does.
fn deviation(case: &Value) -> Option<String> {
    let argv: Vec<String> = case["argv"]
        .as_array()
        .unwrap()
        .iter()
        .map(|argument| argument.as_str().unwrap().to_owned())
        .collect();
    let expected = &case["expected"];
    let parsed = parse(&argv);
    // Swift's fixtures are macOS recordings. `--socket` is
    // `macosCompatibilityOnly` (CLI spec §11.1): elsewhere it is
    // `unsupportedOnPlatform`, whatever the case expects on macOS.
    let socket = argv.iter().any(|argument| argument == "--socket");
    let matches = match (expected["outcome"].as_str().unwrap(), &parsed) {
        _ if socket && !cfg!(target_os = "macos") => {
            matches!(&parsed, Err(error) if error.code == "unsupportedOnPlatform")
        }
        ("failure", Err(error)) => {
            json!(error.code) == expected["code"]
                && json!(error.exit_code()) == expected["exitCode"]
        }
        ("dispatch", Ok(invocation)) => {
            json!(invocation.command) == expected["command"] && !invocation.help
        }
        ("leafHelp", Ok(invocation)) => {
            json!(invocation.command) == expected["command"] && invocation.help
        }
        ("commands", Ok(invocation)) => {
            invocation.command == "commands"
                && !invocation.help
                && invocation.json == (expected["outputMode"] == "json")
        }
        ("completion", Ok(invocation)) => {
            invocation.command == "completion"
                && !invocation.help
                && invocation
                    .params
                    .as_ref()
                    .and_then(|params| params["path"][0].as_str())
                    == expected["shell"].as_str()
        }
        ("rootHelp", Ok(invocation)) => invocation.command == "help",
        _ => false,
    };
    (!matches).then(|| match &parsed {
        Ok(invocation) => format!("{} help={}", invocation.command, invocation.help),
        Err(error) => format!("{} ({})", error.code, error.exit_code()),
    })
}

#[test]
fn every_copied_swift_argv_fixture_replays_but_the_known_deviations() {
    let (mut cases, mut deviating, mut report) = (0, BTreeSet::new(), Vec::new());
    for (name, document) in fixtures() {
        assert_eq!(document["command"], name.as_str(), "{name}");
        for case in document["cases"].as_array().unwrap() {
            cases += 1;
            if let Some(actual) = deviation(case) {
                let case_name = case["name"].as_str().unwrap().to_owned();
                report.push(format!(
                    "{name} {case_name}: Swift {}, Rust {actual}",
                    case["expected"]
                ));
                deviating.insert((name.clone(), case_name));
            }
        }
    }
    assert!(cases > 400, "{cases} cases");
    let known: BTreeSet<(String, String)> = KNOWN_DEVIATIONS
        .iter()
        .filter(|(_, _, macos_only)| !macos_only || cfg!(target_os = "macos"))
        .map(|(name, case, _)| ((*name).to_owned(), (*case).to_owned()))
        .collect();
    assert_eq!(deviating, known, "{}", report.join("\n"));
}

#[test]
fn commands_lists_the_leaves_this_cli_serves_in_the_registrys_order() {
    let registry = command_registry();
    assert_eq!(
        registry["commandRegistrySchemaVersion"],
        "arkdeck.cli.command-registry/1"
    );
    let listed: Vec<String> = registry["commands"]
        .as_array()
        .unwrap()
        .iter()
        .map(|entry| entry["command"].as_str().unwrap().to_owned())
        .collect();
    // Every listed leaf is one whose Swift argv fixture replays above, and
    // every such leaf is listed.
    let replayed: BTreeSet<String> = fixtures().into_iter().map(|(name, _)| name).collect();
    assert_eq!(
        listed.iter().cloned().collect::<BTreeSet<_>>(),
        replayed,
        "{listed:?}"
    );
    // The registry's own order, which is Swift's.
    let all: Vec<Value> = serde_json::from_str::<Value>(include_str!(
        "../src/command_registry.json"
    ))
    .unwrap()["commands"]
        .as_array()
        .unwrap()
        .clone();
    let order: Vec<String> = all
        .iter()
        .map(|entry| entry["command"].as_str().unwrap().to_owned())
        .filter(|command| listed.contains(command))
        .collect();
    assert_eq!(order, listed);
    for entry in registry["commands"].as_array().unwrap() {
        assert!(all.contains(entry), "{}", entry["command"]);
    }
}

#[test]
fn the_commands_leaf_answers_as_swifts_local_envelope() {
    let output = Command::new(env!("CARGO_BIN_EXE_arkdeck"))
        .args(["commands", "--output", "json"])
        .output()
        .unwrap();
    assert_eq!(output.status.code(), Some(0));
    let envelope: Value = serde_json::from_slice(&output.stdout).unwrap();
    // One canonical document, as every machine answer is.
    assert_eq!(render(&envelope).unwrap(), output.stdout);
    assert_eq!(envelope["schemaVersion"], "arkdeck.cli.result/1");
    assert_eq!(envelope["command"], "commands");
    assert_eq!(envelope["ok"], true);
    assert_eq!(envelope["result"], command_registry());
    let meta = envelope["meta"].as_object().unwrap();
    assert_eq!(
        meta.keys().collect::<Vec<_>>(),
        ["cliVersion", "controlRequestId"]
    );
    assert_eq!(meta["cliVersion"], "0.1.0");

    let output = Command::new(env!("CARGO_BIN_EXE_arkdeck"))
        .arg("commands")
        .output()
        .unwrap();
    assert_eq!(output.status.code(), Some(0));
    let text = String::from_utf8(output.stdout).unwrap();
    assert!(text.lines().any(|line| line == "runtime tool select"));
    assert_eq!(
        text.lines().count(),
        command_registry()["commands"].as_array().unwrap().len()
    );
    for argv in [
        vec!["commands", "--control-request-id", "ctl-1"],
        vec!["commands", "--output", "jsonl"],
    ] {
        let error = parse(&argv.into_iter().map(str::to_owned).collect::<Vec<_>>()).unwrap_err();
        assert_eq!((error.code, error.exit_code()), ("invalidOption", 64));
    }
}

#[test]
fn a_retired_leaf_answers_swifts_removed_command_envelope() {
    // Swift's published sample, copied unchanged from its CLI fixtures.
    let sample =
        include_bytes!("../../../tests/fixtures/current-cli-envelopes/result-removed-command.json");
    let error = parse(&["agent".to_owned(), "chat".to_owned()]).unwrap_err();
    let envelope = failure_envelope(error.command.unwrap(), &error, "ctl-fixture-0001", false);
    assert_eq!(render(&envelope).unwrap(), sample.to_vec());
    // Answered by name before any flag, as Swift's parser answers it.
    for argv in [
        vec!["agent", "chat", "--no-such-option"],
        vec!["--output", "json", "agent", "chat", "--prompt", "x"],
    ] {
        let error = parse(&argv.into_iter().map(str::to_owned).collect::<Vec<_>>()).unwrap_err();
        assert_eq!(
            (error.code, error.command),
            ("commandRemoved", Some("agent.chat"))
        );
    }
    let error = parse(&["flash".to_owned(), "continue".to_owned()]).unwrap_err();
    assert_eq!(
        error.message,
        "`flash continue` is retired: historical campaigns are decode-only"
    );
    assert_eq!(
        error.details["reason"],
        "historical campaigns are decode-only"
    );
    assert_eq!(error.details["replacementArgvPattern"], Value::Null);
    let error = parse(&["capability".to_owned(), "install".to_owned()]).unwrap_err();
    assert_eq!((error.code, error.exit_code()), ("invalidCommand", 64));
    assert_eq!(
        error.message,
        "`capability install` is not caller-facing: capability administration is Runtime-owned"
    );
    assert_eq!(
        Value::Object(error.details),
        json!({"command": "capability.install"})
    );
    let help = parse(&["flash".to_owned(), "plan".to_owned(), "--help".to_owned()]).unwrap();
    assert_eq!((help.command, help.help), ("flash.plan", true));
}

#[test]
fn help_and_completion_render_the_registry_this_cli_serves() {
    // Root help lists the first token of every served leaf, and a leaf's help
    // is its own summary, usage and published options.
    let root = help_text(&[]).unwrap();
    assert!(root.starts_with("arkdeck 0.1.0 — headless product face"));
    for token in ["job", "artifact", "runtime", "commands", "help"] {
        assert!(root.contains(&format!("  {token}")), "{token} missing");
    }
    let leaf = help_text(&["job".to_owned(), "status".to_owned()]).unwrap();
    assert!(leaf.starts_with("arkdeck job status — "));
    assert!(leaf.contains("usage: arkdeck job status --job <job-id>"));
    assert!(leaf.contains("connects to the local Runtime"));
    let node = help_text(&["runtime".to_owned(), "tool".to_owned()]).unwrap();
    assert!(node.contains("select"), "{node}");
    // A retired leaf's help says so rather than a usage it cannot serve.
    let retired = help_text(&["agent".to_owned(), "chat".to_owned()]).unwrap();
    assert!(
        retired.contains("retired. use `arkdeck agent run`."),
        "{retired}"
    );
    assert_eq!(
        help_text(&["nope".to_owned()]).unwrap_err().code,
        "invalidCommand"
    );

    // `arkdeck <node> --help` is that node's help, as Swift answers it, and the
    // path is the node itself; `arkdeck help <path>` drops its own token.
    let invocation = parse(&["runtime".to_owned(), "--help".to_owned()]).unwrap();
    assert_eq!(invocation.command, "help");
    assert_eq!(
        invocation.params.as_ref().unwrap()["path"],
        serde_json::json!(["runtime"])
    );
    let asked = Command::new(env!("CARGO_BIN_EXE_arkdeck"))
        .args(["runtime", "tool", "--help"])
        .output()
        .unwrap();
    assert_eq!(asked.status.code(), Some(0));
    assert_eq!(
        String::from_utf8(asked.stdout).unwrap(),
        format!("{node}\n")
    );
    // A node of the registry this CLI serves nothing under is still refused,
    // and so is a node's help in a machine mode.
    for argv in [
        vec!["debug", "--help"],
        vec!["nope", "--help"],
        vec!["runtime", "--help", "--output", "json"],
    ] {
        let answer = Command::new(env!("CARGO_BIN_EXE_arkdeck"))
            .args(&argv)
            .output()
            .unwrap();
        assert_eq!(answer.status.code(), Some(64), "{argv:?}");
    }

    // Every shell the registry publishes has a script, and each names every
    // served leaf's tokens; nothing else does.
    for shell in ["bash", "zsh", "fish", "powershell"] {
        let script = completion_script(shell).unwrap();
        assert!(script.ends_with('\n'));
        assert!(script.contains("runtime tool select"), "{shell}");
        assert!(script.contains("--expected-active-generation"), "{shell}");
        assert!(
            !script.contains("flash lane-preview"),
            "{shell} names a leaf this CLI refuses"
        );
    }
    assert!(completion_script("elvish").is_none());
    for argv in [
        vec!["completion"],
        vec!["completion", "elvish"],
        vec!["completion", "bash", "--output", "json"],
        vec!["help", "--output", "json"],
    ] {
        let error = parse(&argv.into_iter().map(str::to_owned).collect::<Vec<_>>()).unwrap_err();
        assert_eq!(
            (error.code, error.exit_code()),
            ("invalidOption", 64),
            "{error:?}"
        );
    }
    let script = Command::new(env!("CARGO_BIN_EXE_arkdeck"))
        .args(["completion", "zsh"])
        .output()
        .unwrap();
    assert_eq!(script.status.code(), Some(0));
    assert_eq!(
        String::from_utf8(script.stdout).unwrap(),
        completion_script("zsh").unwrap()
    );
}
