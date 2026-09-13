//! `job submit`: the request it sends, the identity note, the acceptance it
//! accepts and the mutation-capable error mapping.
use arkdeck_cli::{CliError, generates_identity, job_submit_params, parse, validate_acceptance};
use arkdeck_client::ClientError;
use arkdeck_contract::WireError;
use serde_json::{Value, json};

fn args(values: &[&str]) -> Vec<String> {
    values.iter().map(|value| (*value).to_owned()).collect()
}

#[test]
fn submit_builds_the_same_request_as_plan_and_names_itself() {
    let invocation = parse(&args(&[
        "job",
        "submit",
        "--target",
        "TGT-A",
        "--operation",
        "analyzer.extract-crash-signature@1",
        "--idempotency-key",
        "idem-cli-submit-0001",
        "--request-id",
        "req-cli-submit",
    ]))
    .unwrap();
    assert_eq!(
        (invocation.command, invocation.method, invocation.timeout_ms),
        ("job.submit", "job.submit", Some(30_000))
    );
    assert!(!generates_identity(&invocation));
    let params = job_submit_params(&invocation).unwrap();
    let document: Value = serde_json::from_str(params["requestJson"].as_str().unwrap()).unwrap();
    assert_eq!(document["idempotencyKey"], "idem-cli-submit-0001");
    assert_eq!(document["target"], json!({"targetId": "TGT-A"}));

    let generated = parse(&args(&[
        "job",
        "submit",
        "--target",
        "TGT-A",
        "--operation",
        "analyzer.extract-crash-signature@1",
    ]))
    .unwrap();
    assert!(generates_identity(&generated));
    assert_eq!(
        job_submit_params(&parse(&args(&["job", "submit"])).unwrap())
            .unwrap_err()
            .message,
        "job submit requires --target <id> --operation <reference> [--inputs-file <typed-inputs.json>], or --request-file <path>"
    );
    let exclusive = parse(&args(&[
        "job",
        "submit",
        "--request-file",
        "request.json",
        "--idempotency-key",
        "idem-cli-submit-0001",
    ]))
    .unwrap_err();
    assert_eq!(
        (exclusive.code, exclusive.message.as_str()),
        (
            "invalidOption",
            "`job submit` accepts only one of --idempotency-key, --request-file"
        )
    );
    // The Rust CLI cannot wait for a Job to run: there is no executor yet.
    assert_eq!(
        parse(&args(&["job", "submit", "--wait"])).unwrap_err().code,
        "invalidOption"
    );
}

#[test]
fn only_an_acceptance_without_dispatch_is_accepted() {
    let acceptance = json!({"schemaVersion": "arkdeck.job-acceptance/1",
        "jobId": "job-19068673bce19fa55ee6207e00812877", "deduplicated": false,
        "newDispatchCount": 0});
    validate_acceptance(&acceptance).unwrap();
    for (field, value) in [
        ("schemaVersion", json!("arkdeck.job-acceptance/2")),
        ("jobId", json!("-job")),
        ("deduplicated", json!("no")),
        ("newDispatchCount", json!(1)),
        ("newDispatchCount", json!(0.0)),
    ] {
        let mut changed = acceptance.clone();
        changed[field] = value;
        assert_eq!(
            validate_acceptance(&changed).unwrap_err().code,
            "recordUnreadable",
            "{field}"
        );
    }
    let mut extra = acceptance;
    extra["extra"] = json!(true);
    assert!(validate_acceptance(&extra).is_err());
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
        "job.submit",
    )
}

#[test]
fn a_submit_refusal_keeps_its_code_only_with_zero_dispatch_proof() {
    for (code, expected, exit) in [
        ("invalidInput", "invalidInput", 65),
        ("inputTooLarge", "inputTooLarge", 65),
        ("operationUnavailable", "operationUnavailable", 69),
        ("idempotencyConflict", "idempotencyConflict", 65),
        ("reviewedPlanMismatch", "reviewedPlanMismatch", 65),
        ("admissionDenied", "admissionDenied", 77),
        ("rejected", "admissionDenied", 77),
        ("resourceConflict", "resourceConflict", 65),
        ("internalError", "internalError", 70),
    ] {
        let error = remote(code, true);
        assert_eq!((error.code, error.exit_code()), (expected, exit), "{code}");
        assert_eq!(error.details["wireCode"], code);
    }
    // Without the proof an admission may have happened: the outcome is unknown.
    for code in [
        "invalidInput",
        "rejected",
        "internalError",
        "resourceConflict",
    ] {
        let error = remote(code, false);
        assert_eq!(
            (error.code, error.exit_code()),
            ("outcomeUnknown", 75),
            "{code}"
        );
    }
    let lost = CliError::from_client(
        ClientError::Transport(std::io::ErrorKind::BrokenPipe.into()),
        "job.submit",
    );
    assert_eq!(lost.code, "outcomeUnknown");
    assert_eq!(lost.details["method"], "job.submit");
}
