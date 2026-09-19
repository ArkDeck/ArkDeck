//! Every argv fixture Swift's CLI publishes for a leaf the Rust CLI serves,
//! copied unchanged into `rust/tests/fixtures/current-cli-argv`, replays
//! through the Rust parser: the leaf Swift's parser names, help where Swift
//! answers help, and Swift's refusal code and exit status where Swift refuses.
//! The cases this parser still answers otherwise are listed exactly, each a
//! parity defect of a leaf it serves (TASK-XPA-018's audit,
//! `evidence/runs/TASK-XPA-018/cli-parity-audit-20260919.md`).
use arkdeck_cli::{command_registry, parse, render};
use serde_json::{Value, json};
use std::{collections::BTreeSet, fs, path::Path, process::Command};

/// `(fixture, case, macOS only)`: Swift's parser takes an opaque value or
/// leaves a missing input to its handler, where this parser refuses at once
/// (`invalidInput`, or `invalidOption` for an import's placeholder values);
/// Swift answers a missing required option `invalidOption` where this parser
/// says `invalidInput`; Swift refuses `--socket` on `runtime tool register`
/// before any path check; and `help` is served only as `--help`. The
/// `--socket` cases deviate only where `--socket` is accepted at all: macOS.
const KNOWN_DEVIATIONS: &[(&str, &str, bool)] = &[
    ("artifact.import.release", "macosCompatibilityOption", true),
    ("artifact.import.release", "valid", false),
    ("help", "leafHelp", false),
    ("help", "valid", false),
    ("runtime.bundle.register", "valid", false),
    ("runtime.tool.register", "hdcSocketRefused", true),
    ("runtime.tool.register", "macosCompatibilityOption", true),
    ("runtime.tool.register", "valid", false),
    ("session.cleanup.apply", "macosCompatibilityOption", true),
    ("session.cleanup.apply", "missingRequired", false),
    ("session.cleanup.apply", "valid", false),
    ("session.export.apply", "macosCompatibilityOption", true),
    ("session.export.apply", "missingRequired", false),
    ("session.export.apply", "valid", false),
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
    // every such leaf is listed but `help`, which this parser serves only as
    // `--help`.
    let replayed: BTreeSet<String> = fixtures()
        .into_iter()
        .map(|(name, _)| name)
        .filter(|name| name != "help")
        .collect();
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
