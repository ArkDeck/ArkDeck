//! `control-action list|show|reconcile` as Swift's CLI parses and consumes
//! them: the argv fixtures Swift's CLI publishes, the registry's grammar, the
//! handler's identity check, and the answers in Swift's frame corpora served
//! to the actual CLI by a fake Runtime.
use arkdeck_cli::parse;
use serde_json::{Value, json};

#[cfg(target_os = "macos")]
mod support;

const ARGV: [&str; 3] = [
    include_str!("../../../tests/fixtures/current-cli-argv/control-action.list.json"),
    include_str!("../../../tests/fixtures/current-cli-argv/control-action.show.json"),
    include_str!("../../../tests/fixtures/current-cli-argv/control-action.reconcile.json"),
];

fn args(argv: &[&str]) -> Vec<String> {
    argv.iter().map(|arg| (*arg).to_owned()).collect()
}

#[test]
fn the_published_argv_fixtures_replay() {
    for corpus in ARGV {
        let doc: Value = serde_json::from_str(corpus).unwrap();
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
                assert_eq!(result.help, case["expected"]["outcome"] == "leafHelp");
            }
        }
    }
}

#[test]
fn the_registry_grammar_is_swifts() {
    let parsed = parse(&args(&[
        "control-action",
        "list",
        "--kind",
        "hdcLifecycle",
        "--state",
        "awaitingImpactApproval",
        "--page-size",
        "5",
        "--cursor",
        "opaque",
        "--timeout",
        "5s",
    ]))
    .unwrap();
    assert_eq!(parsed.method, "control-action.list");
    assert_eq!(parsed.timeout_ms, Some(5000));
    assert_eq!(
        Value::Object(parsed.params.unwrap()),
        json!({"kind": "hdcLifecycle", "state": "awaitingImpactApproval", "pageSize": 5,
            "cursor": "opaque"})
    );
    // A list sends only the filters it was given.
    assert_eq!(
        Value::Object(
            parse(&args(&["control-action", "list"]))
                .unwrap()
                .params
                .unwrap()
        ),
        json!({})
    );
    for argv in [
        vec!["control-action", "list", "--kind", "other"],
        vec!["control-action", "list", "--state", "running"],
        vec!["control-action", "list", "--page-size", "0"],
        vec!["control-action", "list", "--page-size", "01"],
        vec!["control-action", "list", "--page-size", "1001"],
        vec!["control-action", "show"],
        vec![
            "control-action",
            "reconcile",
            "--control-action",
            "a",
            "--timeout",
            "25h",
        ],
    ] {
        assert_eq!(
            parse(&args(&argv)).unwrap_err().code,
            "invalidOption",
            "{argv:?}"
        );
    }
}

#[cfg(target_os = "macos")]
mod runtime {
    use super::support::run;
    use serde_json::{Value, json};

    /// The control action Swift's recorded requests name.
    const CONTROL_ACTION: &str = "control-action-accf9f29-7fc0-4a6a-b18c-9105d6cefbaa";
    const SHOW: &str = include_str!(
        "../../../../Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames/control-action.show.jsonl"
    );
    const LIST: &str = include_str!(
        "../../../../Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames/control-action.list.jsonl"
    );
    const RECONCILE: &str = include_str!(
        "../../../../Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames/control-action.reconcile.jsonl"
    );

    fn frames(corpus: &str) -> Vec<Value> {
        corpus
            .lines()
            .map(|line| serde_json::from_str(line).unwrap())
            .collect()
    }

    /// Each leaf's argv for its recorded request, with its corpus.
    fn recorded() -> [(Vec<&'static str>, &'static str); 3] {
        [
            (
                vec!["control-action", "show", "--control-action", CONTROL_ACTION],
                SHOW,
            ),
            (vec!["control-action", "list", "--page-size", "1"], LIST),
            (
                vec![
                    "control-action",
                    "reconcile",
                    "--control-action",
                    CONTROL_ACTION,
                ],
                RECONCILE,
            ),
        ]
    }

    #[test]
    fn each_read_and_reconciliation_is_emitted_as_the_runtime_answered_it() {
        for (argv, corpus) in recorded() {
            let frames = frames(corpus);
            let answered = frames.iter().find(|frame| frame["ok"] == true).unwrap();
            let method = answered["method"].as_str().unwrap().to_owned();
            let (output, envelope) = run(
                &argv,
                vec![(
                    method.clone(),
                    answered["params"].clone(),
                    json!({"ok": true, "result": answered["result"]}),
                )],
            );
            assert_eq!(output.status.code(), Some(0), "{method}: {envelope}");
            assert_eq!(envelope["command"], method.as_str());
            assert_eq!(envelope["result"], answered["result"], "{method}");
        }
    }

    #[test]
    fn refusals_are_unknown_outcomes_without_proof_and_invalid_identities_are_never_sent() {
        for (argv, corpus) in recorded() {
            let frames = frames(corpus);
            let answered = frames.iter().find(|frame| frame["ok"] == true).unwrap();
            let method = answered["method"].as_str().unwrap().to_owned();
            // The corpus's refusals: their published details admit only a
            // dispatch count, so none can carry the pre-admission proof.
            let mut refusals: Vec<(Value, &str, i32)> = frames
                .iter()
                .filter(|frame| frame["ok"] == false)
                .map(|frame| (frame["error"].clone(), "outcomeUnknown", 75))
                .collect();
            // The Rust foundation's answer while it serves no control action.
            refusals.push((
                json!({"code": "rejected",
                    "message": "this method is unavailable in the read-only Rust foundation"}),
                "outcomeUnknown",
                75,
            ));
            refusals.push((
                json!({"code": "unknownMethod", "message": "method is not published by this Runtime"}),
                "controlMethodUnavailable",
                69,
            ));
            for (error, code, exit) in refusals {
                let wire = error["code"].clone();
                let (output, envelope) = run(
                    &argv,
                    vec![(
                        method.clone(),
                        answered["params"].clone(),
                        json!({"ok": false, "error": error}),
                    )],
                );
                assert_eq!(output.status.code(), Some(exit), "{method}: {envelope}");
                assert_eq!(envelope["error"]["code"], code, "{method}: {envelope}");
                assert_eq!(envelope["error"]["details"]["wireCode"], wire, "{envelope}");
            }
        }
        // Swift's handler check: nothing is sent.
        for leaf in ["show", "reconcile"] {
            let (output, envelope) = run(
                &["control-action", leaf, "--control-action", "-bad"],
                Vec::new(),
            );
            assert_eq!(output.status.code(), Some(65), "{leaf}: {envelope}");
            assert_eq!(envelope["error"]["code"], "invalidInput", "{leaf}");
        }
    }
}
