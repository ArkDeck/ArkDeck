//! `runtime tool select` as Swift's CLI parses and consumes it
//! (`CLICommandRegistry`'s select leaf, `CLIBootstrapTools.runBootstrapTool`):
//! the argv fixture Swift's CLI publishes, the registry's grammar, the
//! handler's intent check before any connection, and the answers in Swift's
//! frame corpus served to the actual CLI by a fake Runtime.
use arkdeck_cli::parse;
use serde_json::{Value, json};

#[cfg(target_os = "macos")]
mod support;

fn args(argv: &[&str]) -> Vec<String> {
    argv.iter().map(|arg| (*arg).to_owned()).collect()
}

/// The tool reference Swift's recorded request names.
fn tool() -> String {
    format!("tool:sha256:{}", "b".repeat(64))
}

fn select(tool: &str, generation: &str, request: &str) -> Vec<String> {
    args(&[
        "runtime",
        "tool",
        "select",
        "--tool",
        tool,
        "--expected-active-generation",
        generation,
        "--action-request-id",
        request,
    ])
}

#[test]
fn the_published_argv_fixture_replays() {
    let doc = arkdeck_cli::machine_contracts::argv_fixture("runtime.tool.select").unwrap();
    for case in doc["cases"].as_array().unwrap() {
        let argv: Vec<String> = case["argv"]
            .as_array()
            .unwrap()
            .iter()
            .map(|arg| arg.as_str().unwrap().to_owned())
            .collect();
        let result = parse(&argv);
        if case["name"] == "macosCompatibilityOption" && !cfg!(target_os = "macos") {
            assert_eq!(result.unwrap_err().code, "unsupportedOnPlatform");
        } else if case["expected"]["outcome"] == "failure" {
            let error = result.unwrap_err();
            assert_eq!(error.code, case["expected"]["code"], "{case}");
            assert_eq!(
                i64::from(error.exit_code()),
                case["expected"]["exitCode"],
                "{case}"
            );
        } else {
            let result = result.unwrap();
            assert_eq!(result.command, doc["command"]);
            assert_eq!(result.method, "runtime.tool.select");
            assert_eq!(result.help, case["expected"]["outcome"] == "leafHelp");
        }
    }
}

#[test]
fn the_registry_grammar_is_swifts() {
    let mut argv = select(&tool(), "1", "cli-selection");
    argv.extend(args(&["--timeout", "5s"]));
    let parsed = parse(&argv).unwrap();
    assert_eq!(parsed.method, "runtime.tool.select");
    assert_eq!(parsed.timeout_ms, Some(5000));
    // Exactly the intent, as strings: the Runtime reads nothing else.
    assert_eq!(
        Value::Object(parsed.params.unwrap()),
        json!({"tool": tool(), "expectedActiveGeneration": "1",
            "actionRequestId": "cli-selection"})
    );
    let mut too_long = select(&tool(), "1", "cli-selection");
    too_long.extend(args(&["--timeout", "25h"]));
    for argv in [
        // A positive integer: no zero, no leading zero, at most Int64.max.
        select(&tool(), "0", "cli-selection"),
        select(&tool(), "01", "cli-selection"),
        select(&tool(), "+1", "cli-selection"),
        select(&tool(), "9223372036854775808", "cli-selection"),
        // A duration of at most a day.
        too_long,
        // Every option of the intent.
        args(&[
            "runtime",
            "tool",
            "select",
            "--tool",
            &tool(),
            "--expected-active-generation",
            "1",
        ]),
        args(&[
            "runtime",
            "tool",
            "select",
            "--expected-active-generation",
            "1",
            "--action-request-id",
            "cli-selection",
        ]),
        // No caller-supplied path or selection field.
        {
            let mut argv = select(&tool(), "1", "cli-selection");
            argv.extend(args(&["--file", "/tmp/caller-hdc"]));
            argv
        },
    ] {
        assert_eq!(parse(&argv).unwrap_err().code, "invalidOption", "{argv:?}");
    }
}

#[cfg(target_os = "macos")]
mod runtime {
    use super::support::run;
    use super::tool;
    use serde_json::{Value, json};

    const SELECT: &str = include_str!(
        "../../../../Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames/runtime.tool.select.jsonl"
    );

    /// The corpus's answered frame and its refusal of a Runtime with no
    /// tool-selection owner.
    fn frames() -> (Value, Value) {
        let frames: Vec<Value> = SELECT
            .lines()
            .map(|line| serde_json::from_str(line).unwrap())
            .collect();
        let answered = frames.iter().find(|frame| frame["ok"] == true).unwrap();
        let refused = frames
            .iter()
            .find(|frame| frame["error"]["code"] == "operationUnavailable")
            .unwrap();
        (answered.clone(), refused.clone())
    }

    /// The argv that sends the recorded request.
    fn recorded() -> Vec<String> {
        super::select(&tool(), "1", "tool-selection-request")
    }

    #[test]
    fn a_selection_is_emitted_as_the_runtime_answered_it() {
        let (answered, _) = frames();
        assert_eq!(
            answered["params"],
            json!({"actionRequestId": "tool-selection-request",
                "expectedActiveGeneration": "1", "tool": tool()})
        );
        let argv = recorded();
        let argv: Vec<&str> = argv.iter().map(String::as_str).collect();
        let (output, envelope) = run(
            &argv,
            vec![(
                "runtime.tool.select".into(),
                answered["params"].clone(),
                json!({"ok": true, "result": answered["result"]}),
            )],
        );
        assert_eq!(output.status.code(), Some(0), "{envelope}");
        assert_eq!(envelope["command"], "runtime.tool.select");
        assert_eq!(envelope["result"], answered["result"]);
    }

    #[test]
    fn refusals_are_unknown_outcomes_without_proof_and_invalid_intents_are_never_sent() {
        let (answered, refused) = frames();
        let argv = recorded();
        let argv: Vec<&str> = argv.iter().map(String::as_str).collect();
        for (error, code, exit) in [
            // The corpus's refusal of a Runtime with no tool-selection owner:
            // its published details admit only a dispatch count, so it
            // cannot carry the pre-admission proof.
            (refused["error"].clone(), "outcomeUnknown", 75),
            // The Rust foundation's answer before this route existed.
            (
                json!({"code": "rejected",
                    "message": "this method is unavailable in the read-only Rust foundation"}),
                "outcomeUnknown",
                75,
            ),
            (
                json!({"code": "unknownMethod", "message": "method is not published by this Runtime"}),
                "controlMethodUnavailable",
                69,
            ),
            (
                json!({"code": "invalidParams", "message": "the intent is not exact"}),
                "invalidInput",
                65,
            ),
        ] {
            let wire = error["code"].clone();
            let (output, envelope) = run(
                &argv,
                vec![(
                    "runtime.tool.select".into(),
                    answered["params"].clone(),
                    json!({"ok": false, "error": error}),
                )],
            );
            assert_eq!(output.status.code(), Some(exit), "{envelope}");
            assert_eq!(envelope["error"]["code"], code, "{envelope}");
            assert_eq!(envelope["error"]["details"]["wireCode"], wire, "{envelope}");
            assert_eq!(
                envelope["error"]["details"]["method"], "runtime.tool.select",
                "{envelope}"
            );
        }
        // Swift's handler checks the intent: nothing is sent.
        let upper = format!("tool:sha256:{}", "B".repeat(64));
        for argv in [
            super::select("sample", "1", "sample"),
            super::select(&upper, "1", "sample"),
            super::select(&format!("tool:sha256:{}", "b".repeat(63)), "1", "sample"),
            super::select(&tool(), "1", "-bad"),
            super::select(&tool(), "1", &"a".repeat(129)),
        ] {
            let argv: Vec<&str> = argv.iter().map(String::as_str).collect();
            let (output, envelope) = run(&argv, Vec::new());
            assert_eq!(output.status.code(), Some(65), "{argv:?}: {envelope}");
            assert_eq!(envelope["error"]["code"], "invalidInput", "{argv:?}");
            assert_eq!(
                envelope["error"]["message"], "tool-selection intent failed validation",
                "{argv:?}"
            );
        }
    }
}
