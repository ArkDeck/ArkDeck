//! `job reconcile` as Swift's CLI parses and consumes it: the argv fixture
//! Swift's CLI publishes, the mutation-capable error mapping (Swift's
//! `CLIControlMethodRegistry` classifies `job.reconcile` as
//! mutation-capable), and every answer in Swift's `job.reconcile` frame
//! corpus served to the actual CLI by a fake Runtime.
use arkdeck_cli::{CliError, parse};
use arkdeck_client::ClientError;
use arkdeck_contract::WireError;
use serde_json::{Value, json};

#[cfg(target_os = "macos")]
mod support;

fn args(values: &[&str]) -> Vec<String> {
    values.iter().map(|value| (*value).to_owned()).collect()
}

#[test]
fn reconcile_argv_matches_current_swift() {
    let fixture: Value = arkdeck_cli::machine_contracts::argv_fixture("job.reconcile").unwrap();
    assert_eq!(fixture["command"], "job.reconcile");
    for row in fixture["cases"].as_array().unwrap() {
        let argv: Vec<String> = row["argv"]
            .as_array()
            .unwrap()
            .iter()
            .map(|value| value.as_str().unwrap().to_owned())
            .collect();
        let result = parse(&argv);
        let expected = &row["expected"];
        if row["name"] == "macosCompatibilityOption" && !cfg!(target_os = "macos") {
            assert_eq!(result.unwrap_err().code, "unsupportedOnPlatform");
        } else if expected["outcome"] == "failure" {
            let error = result.unwrap_err();
            assert_eq!(
                (error.code, i64::from(error.exit_code())),
                (
                    expected["code"].as_str().unwrap(),
                    expected["exitCode"].as_i64().unwrap()
                ),
                "{row}"
            );
        } else {
            let invocation = result.unwrap();
            assert_eq!(invocation.command, "job.reconcile", "{row}");
            if expected["outcome"] == "dispatch" {
                assert_eq!(invocation.method, "job.reconcile");
                assert_eq!(
                    invocation.params,
                    json!({"jobId": "sample"}).as_object().cloned()
                );
                assert_eq!(invocation.timeout_ms, None);
            } else {
                assert!(invocation.help, "{row}");
            }
        }
    }
    // Swift `job reconcile` takes the same options as `job cancel`: no wait
    // bound.
    let bounded = parse(&args(&[
        "job",
        "reconcile",
        "--job",
        "job-a",
        "--timeout",
        "5m",
    ]));
    assert_eq!(bounded.unwrap_err().code, "invalidOption");
}

fn remote(code: &str, details: Option<Value>) -> CliError {
    CliError::from_client(
        ClientError::Remote(WireError {
            code: code.into(),
            message: "refused".into(),
            details: details.map(|details| serde_json::from_value(details).unwrap()),
        }),
        "job.reconcile",
    )
}

#[test]
fn a_reconcile_refusal_maps_as_a_mutation_without_proof() {
    // Swift's `job.reconcile` answers carry no details, so only the codes
    // that need no zero-dispatch proof keep a meaning of their own.
    for (code, expected, exit) in [
        ("notFound", "resourceNotFound", 65),
        ("invalidParams", "invalidInput", 65),
        ("unknownMethod", "controlMethodUnavailable", 69),
        ("rejected", "outcomeUnknown", 75),
        ("internalError", "outcomeUnknown", 75),
    ] {
        let error = remote(code, None);
        assert_eq!((error.code, error.exit_code()), (expected, exit), "{code}");
        assert_eq!(error.details["method"], "job.reconcile");
        assert_eq!(error.details["wireCode"], code);
    }
    // With the pre-admission proof, as a mutation owner's refusal would carry.
    let proven = remote(
        "rejected",
        Some(json!({"phase": "preAdmission", "newDispatchCount": 0})),
    );
    assert_eq!(proven.code, "admissionDenied");
    let lost = CliError::from_client(
        ClientError::Transport(std::io::ErrorKind::BrokenPipe.into()),
        "job.reconcile",
    );
    assert_eq!((lost.code, lost.exit_code()), ("outcomeUnknown", 75));
    assert_eq!(lost.details["method"], "job.reconcile");
    assert!(lost.message.contains("never replayed"), "{}", lost.message);
}

#[cfg(target_os = "macos")]
mod runtime {
    use super::support::run;
    use serde_json::{Value, json};

    const CORPUS: &str = include_str!(
        "../../../../Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames/job.reconcile.jsonl"
    );

    fn frames() -> Vec<Value> {
        CORPUS
            .lines()
            .map(|line| serde_json::from_str(line).unwrap())
            .collect()
    }

    #[test]
    fn each_recorded_answer_is_emitted_as_the_runtime_answered_it() {
        let mut states = Vec::new();
        for frame in frames().iter().filter(|frame| frame["ok"] == true) {
            let job = frame["params"]["jobId"].as_str().unwrap();
            let (output, envelope) = run(
                &["job", "reconcile", "--job", job],
                vec![(
                    "job.reconcile".into(),
                    json!({"jobId": job}),
                    json!({"ok": true, "result": frame["result"]}),
                )],
            );
            // Swift emits the reconcile's answer and exits 0 whatever the
            // Job's state: an outcome still unknown is the answer, not a
            // failure of the request.
            assert_eq!(output.status.code(), Some(0), "{job}: {envelope}");
            assert_eq!(envelope["command"], "job.reconcile");
            assert_eq!(envelope["result"], frame["result"], "{job}");
            states.push((
                frame["result"]["state"].as_str().unwrap().to_owned(),
                frame["result"]["outcomeUnknown"] == true,
            ));
        }
        for state in [
            ("waitingForRecovery", true),
            ("failed", false),
            ("succeeded", false),
            ("preflight", false),
            ("resumeAtConfirmedSafeBoundary", false),
        ] {
            assert!(states.contains(&(state.0.to_owned(), state.1)), "{state:?}");
        }
    }

    #[test]
    fn each_recorded_refusal_maps_as_a_mutation_without_proof() {
        let mut refused = 0;
        for frame in frames().iter().filter(|frame| frame["ok"] == false) {
            // The corpus's own malformed request is refused before the CLI
            // sends anything; only the ones naming a Job reach the Runtime.
            let Some(job) = frame["params"]["jobId"].as_str() else {
                continue;
            };
            let (code, exit) = match frame["error"]["code"].as_str().unwrap() {
                "notFound" => ("resourceNotFound", 65),
                "internalError" => ("outcomeUnknown", 75),
                other => panic!("unexpected corpus refusal {other}"),
            };
            let (output, envelope) = run(
                &["job", "reconcile", "--job", job],
                vec![(
                    "job.reconcile".into(),
                    json!({"jobId": job}),
                    json!({"ok": false, "error": frame["error"]}),
                )],
            );
            assert_eq!(output.status.code(), Some(exit), "{job}: {envelope}");
            assert_eq!(envelope["error"]["code"], code, "{envelope}");
            assert_eq!(
                envelope["error"]["details"]["wireCode"], frame["error"]["code"],
                "{envelope}"
            );
            refused += 1;
        }
        assert_eq!(refused, 2);
    }
}
