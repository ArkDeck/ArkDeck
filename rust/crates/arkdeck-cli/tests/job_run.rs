//! `job run`: the current argv, the status it accepts, the exit its terminal
//! state earns and the mutation-capable error mapping.
use arkdeck_cli::{CliError, parse, run_exit, validate_read_only_response};
use arkdeck_client::ClientError;
use arkdeck_contract::WireError;
use serde_json::{Value, json};

fn args(values: &[&str]) -> Vec<String> {
    values.iter().map(|value| (*value).to_owned()).collect()
}

#[test]
fn run_argv_matches_current_swift() {
    let fixture: Value = serde_json::from_str(include_str!(
        "../../../tests/fixtures/current-cli-argv/job.run.json"
    ))
    .unwrap();
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
            assert_eq!(invocation.command, "job.run", "{row}");
            if expected["outcome"] == "dispatch" {
                assert_eq!(
                    invocation.params,
                    json!({"jobId": "sample"}).as_object().cloned()
                );
                assert_eq!(invocation.timeout_ms, Some(30_000));
            } else {
                assert!(invocation.help, "{row}");
            }
        }
    }
    let bounded = parse(&args(&["job", "run", "--job", "job-a", "--timeout", "5m"])).unwrap();
    assert_eq!(bounded.timeout_ms, Some(300_000));
}

#[test]
fn recorded_run_statuses_validate_and_earn_their_exit() {
    let cases: Value = serde_json::from_str(include_str!(
        "../../../tests/fixtures/job-run-analyzer/cases.json"
    ))
    .unwrap();
    let mut exits = Vec::new();
    for case in cases.as_array().unwrap() {
        if case["response"]["ok"] != true {
            continue;
        }
        let job = case["params"]["jobId"].as_str().unwrap();
        let status = &case["response"]["result"];
        let invocation = parse(&args(&["job", "run", "--job", job])).unwrap();
        validate_read_only_response(&invocation, status).unwrap();
        // Another Job's status is not this run's answer.
        let other = parse(&args(&["job", "run", "--job", "job-other"])).unwrap();
        assert!(validate_read_only_response(&other, status).is_err());
        exits.push((
            case["name"].as_str().unwrap().to_owned(),
            run_exit(status).map(|(code, _)| code),
        ));
    }
    for (name, exit) in [
        ("answered", None),
        ("redacted", None),
        ("emptyResult", Some(1)),
        ("quotaExceeded", Some(1)),
        ("timedOut", Some(75)),
        ("signalled", Some(75)),
    ] {
        assert!(exits.contains(&(name.to_owned(), exit)), "{name}");
    }
}

fn remote(code: &str, proven: bool) -> CliError {
    CliError::from_client(
        ClientError::Remote(WireError {
            code: code.into(),
            message: "refused".into(),
            details: Some(if proven {
                serde_json::from_value(json!({"phase": "preAdmission", "newDispatchCount": 0}))
                    .unwrap()
            } else {
                serde_json::Map::new()
            }),
        }),
        "job.run",
    )
}

#[test]
fn a_run_refusal_keeps_its_code_only_with_zero_dispatch_proof() {
    for (code, expected) in [
        ("invalidInput", "invalidInput"),
        ("resourceConflict", "resourceConflict"),
        ("resourceNotFound", "resourceNotFound"),
        ("rejected", "admissionDenied"),
    ] {
        let error = remote(code, true);
        assert_eq!(error.code, expected, "{code}");
        assert_eq!(error.details["method"], "job.run");
    }
    // Swift answers an internal failure after dispatch with empty details:
    // the run may have happened, so the outcome is unknown.
    for code in ["internalError", "resourceConflict", "rejected"] {
        let error = remote(code, false);
        assert_eq!(
            (error.code, error.exit_code()),
            ("outcomeUnknown", 75),
            "{code}"
        );
    }
    let lost = CliError::from_client(
        ClientError::Transport(std::io::ErrorKind::BrokenPipe.into()),
        "job.run",
    );
    assert_eq!(lost.code, "outcomeUnknown");
    assert_eq!(lost.details["method"], "job.run");
}
