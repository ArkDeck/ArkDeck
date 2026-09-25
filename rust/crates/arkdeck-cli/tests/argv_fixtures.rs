//! The argv fixture of every leaf the Rust CLI serves replays through its
//! parser: the leaf Swift's parser names, help where Swift answers help, and
//! Swift's refusal code and exit status where Swift refuses. The fixtures are
//! the ones this CLI renders for the machine-contract bundle
//! (`machine_contracts::argv_fixture`), which `machine_contracts.rs` holds
//! byte for byte to the documents Swift publishes.
use arkdeck_cli::machine_contracts::{argv_fixture, fixture_products};
use arkdeck_cli::{
    command_registry, completion_script, failure_envelope, help_text, parse, render,
};
use serde_json::{Value, json};
use std::process::Command;

/// Each served leaf's argv fixture, in the registry's order.
fn fixtures() -> Vec<(String, Value)> {
    command_registry()["commands"]
        .as_array()
        .unwrap()
        .iter()
        .map(|entry| {
            let command = entry["command"].as_str().unwrap().to_owned();
            let document = argv_fixture(&command).unwrap();
            (command, document)
        })
        .collect()
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
        // Swift's fixture names the leaf a refusal belongs to exactly when
        // its `CLIRegistryError` does (TASK-XPA-018 a3).
        ("failure", Err(error)) => {
            json!(error.code) == expected["code"]
                && json!(error.exit_code()) == expected["exitCode"]
                && error.command.map(|command| json!(command)) == expected.get("command").cloned()
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
        Err(error) => format!(
            "{} ({}) naming {:?}",
            error.code,
            error.exit_code(),
            error.command
        ),
    })
}

#[test]
fn every_served_leafs_argv_fixture_replays() {
    let (mut cases, mut report) = (0, Vec::new());
    for (name, document) in fixtures() {
        assert_eq!(document["command"], name.as_str(), "{name}");
        for case in document["cases"].as_array().unwrap() {
            cases += 1;
            if let Some(actual) = deviation(case) {
                report.push(format!(
                    "{name} {}: Swift {}, Rust {actual}",
                    case["name"], case["expected"]
                ));
            }
        }
    }
    assert!(cases > 400, "{cases} cases");
    assert!(report.is_empty(), "{}", report.join("\n"));
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
    // Swift's published sample, as the bundle's envelope fixtures render it.
    let sample = fixture_products()
        .into_iter()
        .find(|product| product.relative_path == "envelopes/result-removed-command.json")
        .unwrap()
        .bytes;
    let error = parse(&["agent".to_owned(), "chat".to_owned()]).unwrap_err();
    let envelope = failure_envelope(error.command.unwrap(), &error, "ctl-fixture-0001", false);
    assert_eq!(render(&envelope).unwrap(), sample);
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
    let debug = Command::new(env!("CARGO_BIN_EXE_arkdeck"))
        .args(["debug", "--help"])
        .output()
        .unwrap();
    assert!(debug.status.success());
    assert!(String::from_utf8(debug.stdout).unwrap().contains("probe"));
    let templates = Command::new(env!("CARGO_BIN_EXE_arkdeck"))
        .args(["debug", "template", "--help"])
        .output()
        .unwrap();
    assert!(templates.status.success());
    assert!(
        String::from_utf8(templates.stdout)
            .unwrap()
            .contains("list")
    );
    // A node of the registry this CLI serves nothing under is still refused,
    // and so is a node's help in a machine mode. Which nodes those are changes
    // as leaves are served, so the node is found here: every node of the
    // registry none of whose leaves is served (none, once all are).
    let all: Vec<Vec<String>> = serde_json::from_str::<Value>(include_str!(
        "../src/command_registry.json"
    ))
    .unwrap()["commands"]
        .as_array()
        .unwrap()
        .iter()
        .map(|entry| {
            entry["path"]
                .as_array()
                .unwrap()
                .iter()
                .map(|token| token.as_str().unwrap().to_owned())
                .collect()
        })
        .collect();
    let served: Vec<Vec<String>> = command_registry()["commands"]
        .as_array()
        .unwrap()
        .iter()
        .map(|entry| {
            entry["path"]
                .as_array()
                .unwrap()
                .iter()
                .map(|token| token.as_str().unwrap().to_owned())
                .collect()
        })
        .collect();
    let mut unserved_nodes: Vec<Vec<String>> = Vec::new();
    for path in &all {
        for length in 1..path.len() {
            let node = &path[..length];
            let below = |paths: &[Vec<String>]| paths.iter().any(|leaf| leaf.starts_with(node));
            if !below(&served) && !unserved_nodes.iter().any(|seen| seen == node) {
                unserved_nodes.push(node.to_vec());
            }
        }
    }
    let mut refused: Vec<Vec<String>> = unserved_nodes
        .into_iter()
        .map(|mut node| {
            node.push("--help".into());
            node
        })
        .collect();
    refused.push(vec!["nope".into(), "--help".into()]);
    refused.push(vec![
        "runtime".into(),
        "--help".into(),
        "--output".into(),
        "json".into(),
    ]);
    for argv in refused {
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
        assert!(script.contains("debug probe"), "{shell}");
        assert!(script.contains("--expected-active-generation"), "{shell}");
        assert!(script.contains("flash lane-preview"), "{shell}");
        assert!(
            !script.contains("flash install-binding"),
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

/// TASK-XPA-018 a3: a refusal is reported as Swift's CLI reports it. Where
/// Swift's registry pass refuses too, its words, details and leaf are the
/// answer; a refusal only this parser makes (what a value means) names the
/// leaf; and what this parser accepts, Swift's registry notwithstanding,
/// stays accepted.
#[test]
fn a_refusal_is_reported_as_swifts_parser_reports_it() {
    let refused = |tokens: &[&str]| {
        let argv: Vec<String> = tokens.iter().map(|token| (*token).to_owned()).collect();
        parse(&argv).expect_err("refused")
    };
    for (tokens, message, details) in [
        (
            &["job", "status"][..],
            "`job status` requires --job <job-id>",
            json!({"command": "job.status", "option": "--job"}),
        ),
        (
            &["job", "status", "--job", "a", "--job", "b"],
            "--job was given more than once",
            json!({"option": "--job"}),
        ),
        (
            &["job", "status", "--job", "a", "--bogus"],
            "`job status` does not accept --bogus; run `arkdeck help job status` for its options",
            json!({"command": "job.status", "option": "--bogus"}),
        ),
        (
            &["job", "status", "--job", "a", "--output", "jsonl"],
            "--output must be one of human|json",
            json!({"command": "job.status", "value": "jsonl"}),
        ),
        (
            &["job", "list", "--page-size", "0"],
            "`job list` --page-size must be 1...1000",
            json!({"command": "job.list", "option": "--page-size", "value": "0"}),
        ),
        (
            &["job", "list", "--order", "newest"],
            "`job list` --order must be one of oldestFirst|newestFirst|createdAtDescJobIdAsc|createdAtAscJobIdAsc",
            json!({"command": "job.list", "option": "--order", "value": "newest"}),
        ),
    ] {
        let error = refused(tokens);
        assert_eq!(
            (error.code, error.message.as_str()),
            ("invalidOption", message),
            "{tokens:?}"
        );
        assert_eq!(Value::Object(error.details), details, "{tokens:?}");
        assert_eq!(
            error.command,
            tokens.first().map(|_| {
                if tokens[1] == "list" {
                    "job.list"
                } else {
                    "job.status"
                }
            }),
            "{tokens:?}"
        );
    }
    // What a value means is this parser's to judge, as Swift's handler does;
    // the refusal still names the leaf.
    let error = refused(&["job", "watch", "--job", "job:1"]);
    assert_eq!(
        (error.code, error.command),
        ("invalidInput", Some("job.watch"))
    );
    // An unknown path names no leaf, in Swift's words.
    let error = refused(&["nope"]);
    assert_eq!(
        (error.code, error.message.as_str(), error.command),
        (
            "invalidCommand",
            "unknown command `nope`; run `arkdeck commands` to list the published surface",
            None
        )
    );
    // An option this parser serves beyond Swift's registry stays served.
    let argv: Vec<String> = [
        "target",
        "display-name",
        "set",
        "--target",
        "TGT-1",
        "--expected-generation",
        "1",
        "--name",
        "Bench",
        "--timeout",
        "5s",
    ]
    .iter()
    .map(|token| (*token).to_owned())
    .collect();
    assert!(parse(&argv).is_ok());
    // A global option ahead of the path (CLI spec §5.1) stays served, and a
    // refusal is about what is wrong after it, as the read-only host check
    // asks: its argv lead with `--output` and `--control-request-id`.
    let error = refused(&[
        "--output",
        "json",
        "--control-request-id",
        "ctl-unknown-command",
        "job",
        "no-such-command",
    ]);
    assert_eq!((error.code, error.command), ("invalidCommand", None));
    let error = refused(&[
        "--output",
        "json",
        "--control-request-id",
        "ctl-bad-option",
        "doctor",
        "--shell",
        "x",
    ]);
    assert_eq!(
        (error.code, error.command),
        ("invalidOption", Some("doctor"))
    );
    let argv: Vec<String> = [
        "--control-request-id",
        "ctl-1",
        "job",
        "status",
        "--job",
        "j",
    ]
    .iter()
    .map(|token| (*token).to_owned())
    .collect();
    assert!(parse(&argv).is_ok());
}
