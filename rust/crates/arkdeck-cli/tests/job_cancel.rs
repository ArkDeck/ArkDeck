//! `job cancel`: the current argv, the answer it accepts and the
//! mutation-capable error mapping.
use arkdeck_cli::{CliError, parse, validate_cancellation};
use arkdeck_client::ClientError;
use arkdeck_contract::WireError;
use serde_json::{Value, json};

fn args(values: &[&str]) -> Vec<String> {
    values.iter().map(|value| (*value).to_owned()).collect()
}

#[test]
fn cancel_argv_matches_current_swift() {
    let fixture: Value = arkdeck_cli::machine_contracts::argv_fixture("job.cancel").unwrap();
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
            assert_eq!(invocation.command, "job.cancel", "{row}");
            if expected["outcome"] == "dispatch" {
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
    // Swift `job cancel` takes no wait bound.
    let bounded = parse(&args(&[
        "job",
        "cancel",
        "--job",
        "job-a",
        "--timeout",
        "5m",
    ]));
    assert_eq!(bounded.unwrap_err().code, "invalidOption");
}

#[test]
fn recorded_cancellation_answers_validate() {
    let cases: Value = serde_json::from_str(include_str!(
        "../../../tests/fixtures/job-cancel-analyzer/cases.json"
    ))
    .unwrap();
    let answered = cases
        .as_array()
        .unwrap()
        .iter()
        .filter(|case| case["method"] == "job.cancel" && case["response"]["ok"] == true)
        .inspect(|case| validate_cancellation(&case["response"]["result"]).unwrap())
        .count();
    assert_eq!(answered, 5);
    for answer in [
        json!({"cancelRequested": false}),
        json!({}),
        json!({"cancelRequested": true, "state": "cancelled"}),
    ] {
        assert_eq!(
            validate_cancellation(&answer).unwrap_err().code,
            "recordUnreadable",
            "{answer}"
        );
    }
}

fn remote(code: &str) -> CliError {
    CliError::from_client(
        ClientError::Remote(WireError {
            code: code.into(),
            message: "refused".into(),
            details: None,
        }),
        "job.cancel",
    )
}

#[test]
fn a_cancel_refusal_maps_as_a_mutation_without_proof() {
    // Swift attaches no details to a `job.cancel` refusal, so only the codes
    // that need no zero-dispatch proof keep a meaning of their own.
    for (code, expected, exit) in [
        ("notFound", "resourceNotFound", 65),
        ("invalidParams", "invalidInput", 65),
        ("unknownMethod", "controlMethodUnavailable", 69),
        ("rejected", "outcomeUnknown", 75),
        ("internalError", "outcomeUnknown", 75),
    ] {
        let error = remote(code);
        assert_eq!((error.code, error.exit_code()), (expected, exit), "{code}");
        assert_eq!(error.details["method"], "job.cancel");
        assert_eq!(error.details["wireCode"], code);
    }
    let lost = CliError::from_client(
        ClientError::Transport(std::io::ErrorKind::BrokenPipe.into()),
        "job.cancel",
    );
    assert_eq!((lost.code, lost.exit_code()), ("outcomeUnknown", 75));
    assert_eq!(lost.details["method"], "job.cancel");
}
