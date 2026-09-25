//! `runtime hdc impact-preview` and `runtime hdc restart` as Swift's CLI
//! parses and consumes them: the argv fixtures Swift's CLI publishes, the
//! registry's grammar, the handler's checks, and the answers in Swift's frame
//! corpora served to the actual CLI by a fake Runtime.
use arkdeck_cli::parse;
use serde_json::{Value, json};

#[cfg(target_os = "macos")]
mod support;

const LEAVES: [&str; 2] = ["runtime.hdc.impact-preview", "runtime.hdc.restart"];
/// The endpoint and digest Swift's recorded requests name.
const ENDPOINT: &str =
    "hdc-endpoint:a29f70813dca5c16bc287e590177e3b9da8354d2d3409abcede8b1c0d0bd420e";
const DIGEST: &str = "93018d9ea5cc752d60ecc03f3aced1b3cc1538dde27c9025a222b0122392beee";

fn args(argv: &[&str]) -> Vec<String> {
    argv.iter().map(|arg| (*arg).to_owned()).collect()
}

#[test]
fn the_published_argv_fixtures_replay() {
    for command in LEAVES {
        let doc = arkdeck_cli::machine_contracts::argv_fixture(command).unwrap();
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
        "runtime",
        "hdc",
        "impact-preview",
        "--action",
        "restart",
        "--server-endpoint-ref",
        ENDPOINT,
        "--expected-server-generation",
        "100000023",
        "--action-request-id",
        "cli-action",
        "--timeout",
        "5s",
    ]))
    .unwrap();
    assert_eq!(parsed.method, "runtime.hdc.impact-preview");
    assert_eq!(parsed.timeout_ms, Some(5000));
    assert_eq!(
        Value::Object(parsed.params.unwrap()),
        json!({"action": "restart", "serverEndpointRef": ENDPOINT,
            "expectedServerGeneration": "100000023", "actionRequestId": "cli-action"})
    );
    let preview = |action: &str, generation: &str, timeout: &str| {
        args(&[
            "runtime",
            "hdc",
            "impact-preview",
            "--action",
            action,
            "--server-endpoint-ref",
            ENDPOINT,
            "--expected-server-generation",
            generation,
            "--action-request-id",
            "cli-action",
            "--timeout",
            timeout,
        ])
    };
    let upper = DIGEST.to_uppercase();
    for argv in [
        // Restart is the only lifecycle action.
        preview("stop", "1", "5s"),
        // A positive integer: no zero, no leading zero, at most Int64.max.
        preview("restart", "0", "5s"),
        preview("restart", "01", "5s"),
        preview("restart", "9223372036854775808", "5s"),
        // A duration of at most a day.
        preview("restart", "1", "25h"),
        // A digest is 64 lowercase hexadecimal digits.
        args(&[
            "runtime",
            "hdc",
            "restart",
            "--control-action",
            "a",
            "--preview-id",
            "b",
            "--preview-digest",
            &upper,
        ]),
        // Every option of the tuple.
        args(&[
            "runtime",
            "hdc",
            "restart",
            "--control-action",
            "a",
            "--preview-id",
            "b",
        ]),
    ] {
        assert_eq!(parse(&argv).unwrap_err().code, "invalidOption", "{argv:?}");
    }
}

#[cfg(target_os = "macos")]
mod runtime {
    use super::support::run;
    use super::{DIGEST, ENDPOINT};
    use serde_json::{Value, json};

    const PREVIEW: &str = include_str!(
        "../../../../Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames/runtime.hdc.impact-preview.jsonl"
    );
    const RESTART: &str = include_str!(
        "../../../../Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames/runtime.hdc.restart.jsonl"
    );

    /// A corpus's answered frame and its refusal.
    fn frames(corpus: &str) -> (Value, Value) {
        let frames: Vec<Value> = corpus
            .lines()
            .map(|line| serde_json::from_str(line).unwrap())
            .collect();
        let answered = frames.iter().find(|frame| frame["ok"] == true).unwrap();
        let refused = frames.iter().find(|frame| frame["ok"] == false).unwrap();
        (answered.clone(), refused.clone())
    }

    /// The argv that sends each recorded request, with its corpus.
    fn recorded() -> [(Vec<&'static str>, &'static str); 2] {
        [
            (
                vec![
                    "runtime",
                    "hdc",
                    "impact-preview",
                    "--action",
                    "restart",
                    "--server-endpoint-ref",
                    ENDPOINT,
                    "--expected-server-generation",
                    "100000023",
                    "--action-request-id",
                    "cli-action",
                ],
                PREVIEW,
            ),
            (
                vec![
                    "runtime",
                    "hdc",
                    "restart",
                    "--control-action",
                    "control-action-accf9f29-7fc0-4a6a-b18c-9105d6cefbaa",
                    "--preview-id",
                    "preview-76cea92c-d4e2-483c-bdce-8c22e429d66e",
                    "--preview-digest",
                    DIGEST,
                ],
                RESTART,
            ),
        ]
    }

    #[test]
    fn a_preview_and_a_restart_are_emitted_as_the_runtime_answered_them() {
        for (argv, corpus) in recorded() {
            let (answered, _) = frames(corpus);
            let method = answered["method"].as_str().unwrap().to_owned();
            let (output, envelope) = run(
                &argv,
                vec![(
                    method.clone(),
                    answered["params"].clone(),
                    json!({"ok": true, "result": answered["result"]}),
                )],
            );
            // A restart awaiting a person's approval is still an answer.
            assert_eq!(output.status.code(), Some(0), "{envelope}");
            assert_eq!(envelope["command"], method.as_str());
            assert_eq!(envelope["result"], answered["result"]);
        }
    }

    #[test]
    fn refusals_are_unknown_outcomes_without_proof_and_invalid_tuples_are_never_sent() {
        for (argv, corpus) in recorded() {
            let (answered, refused) = frames(corpus);
            let method = answered["method"].as_str().unwrap().to_owned();
            for (error, code, exit) in [
                // The corpus's refusal. Both methods' published details
                // admit only a dispatch count, so no refusal can carry the
                // pre-admission proof.
                (refused["error"].clone(), "outcomeUnknown", 75),
                // The Rust foundation's answer while it serves no control
                // action.
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
        // Swift's handler checks: nothing is sent.
        for argv in [
            vec![
                "runtime",
                "hdc",
                "impact-preview",
                "--action",
                "restart",
                "--server-endpoint-ref",
                "sample",
                "--expected-server-generation",
                "1",
                "--action-request-id",
                "sample",
            ],
            vec![
                "runtime",
                "hdc",
                "impact-preview",
                "--action",
                "restart",
                "--server-endpoint-ref",
                ENDPOINT,
                "--expected-server-generation",
                "1",
                "--action-request-id",
                "-bad",
            ],
            vec![
                "runtime",
                "hdc",
                "restart",
                "--control-action",
                "-bad",
                "--preview-id",
                "sample",
                "--preview-digest",
                DIGEST,
            ],
        ] {
            let (output, envelope) = run(&argv, Vec::new());
            assert_eq!(output.status.code(), Some(65), "{argv:?}: {envelope}");
            assert_eq!(envelope["error"]["code"], "invalidInput", "{argv:?}");
        }
    }
}
