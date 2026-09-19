//! `runtime hdc status` as Swift's CLI parses and consumes it: the argv
//! fixture Swift's CLI publishes, and every answer in Swift's
//! `runtime.hdc.status` frame corpus, served to the actual CLI by a fake
//! Runtime that checks the request carries no parameters.
use arkdeck_cli::parse;
use serde_json::Value;

#[cfg(target_os = "macos")]
mod support;

const ARGV: &str = include_str!("../../../tests/fixtures/current-cli-argv/runtime.hdc.status.json");

fn args(argv: &[&str]) -> Vec<String> {
    argv.iter().map(|arg| (*arg).to_owned()).collect()
}

#[test]
fn the_published_argv_fixture_replays() {
    let doc: Value = serde_json::from_str(ARGV).unwrap();
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
            assert!(result.params.is_none(), "{case}");
            assert_eq!(result.timeout_ms, None, "{case}");
        }
    }
    // Swift gives this read no wait of its own, and a leaf this CLI does not
    // have is a usage error.
    assert_eq!(
        parse(&args(&["runtime", "hdc", "status", "--timeout", "5s"]))
            .unwrap_err()
            .code,
        "invalidOption"
    );
    let missing = parse(&args(&["runtime", "hdc"])).unwrap_err();
    assert_eq!(missing.code, "invalidCommand");
    assert_eq!(missing.exit_code(), 64);
}

#[cfg(target_os = "macos")]
mod runtime {
    use super::support::run;
    use serde_json::{Value, json};

    const FRAMES: &str = include_str!(
        "../../../../Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames/runtime.hdc.status.jsonl"
    );

    fn frames() -> Vec<Value> {
        FRAMES
            .lines()
            .map(|line| serde_json::from_str(line).unwrap())
            .collect()
    }

    fn status(answer: Value) -> (std::process::Output, Value) {
        run(
            &["runtime", "hdc", "status"],
            vec![("runtime.hdc.status".into(), Value::Null, answer)],
        )
    }

    #[test]
    fn every_status_swift_recorded_is_emitted_as_the_runtime_answered_it() {
        let recorded: Vec<Value> = frames()
            .into_iter()
            .filter(|frame| frame["ok"] == true)
            .collect();
        assert_eq!(recorded.len(), 6);
        for frame in recorded {
            let (output, envelope) = status(json!({"ok": true, "result": frame["result"]}));
            // An unavailable or unknown status is still an answer, as in Swift.
            assert_eq!(output.status.code(), Some(0), "{envelope}");
            assert_eq!(envelope["command"], "runtime.hdc.status");
            assert_eq!(envelope["result"], frame["result"]);
        }
    }

    #[test]
    fn refusals_map_as_swifts_bounded_read() {
        let refused = frames()
            .into_iter()
            .find(|frame| frame["ok"] == false)
            .unwrap();
        for (error, code, exit) in [
            // The Rust foundation's answer while it serves no status.
            (
                json!({"code": "rejected",
                    "message": "this method is unavailable in the read-only Rust foundation"}),
                "operationFailed",
                1,
            ),
            // Swift's refusal of a caller's facts, which this CLI never sends.
            (refused["error"].clone(), "invalidInput", 65),
            (
                json!({"code": "unknownMethod", "message": "method is not published by this Runtime"}),
                "controlMethodUnavailable",
                69,
            ),
            (
                json!({"code": "internalError",
                    "message": "the result does not conform to the current contract"}),
                "internalError",
                70,
            ),
        ] {
            let wire = error["code"].clone();
            let (output, envelope) = status(json!({"ok": false, "error": error}));
            assert_eq!(output.status.code(), Some(exit), "{envelope}");
            assert_eq!(envelope["error"]["code"], code, "{envelope}");
            assert_eq!(envelope["error"]["details"]["wireCode"], wire, "{envelope}");
        }
    }
}
