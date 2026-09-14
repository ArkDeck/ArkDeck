//! `job result`: the current argv, every Swift-recorded result of the run
//! oracle it accepts and the exit each earns, the refusals a result that
//! disagrees with itself meets, and the read's error mapping.
use arkdeck_cli::{
    CliError, evidence_exit, failure_envelope, parse, project_read_only_response, result_exit,
    validate_read_only_request, validate_read_only_response,
};
use arkdeck_client::ClientError;
use arkdeck_contract::WireError;
use serde_json::{Value, json};

const CASES: &str = include_str!("../../../tests/fixtures/job-run-analyzer/cases.json");
const READS: &str = include_str!("../../../tests/fixtures/job-run-analyzer/reads.json");
const REFUSED: &str = include_str!("../../../tests/fixtures/job-run-analyzer/refused-reads.json");

fn args(values: &[&str]) -> Vec<String> {
    values.iter().map(|value| (*value).to_owned()).collect()
}

fn wire(error: &Value) -> ClientError {
    ClientError::Remote(WireError {
        code: error["code"].as_str().unwrap().into(),
        message: error["message"].as_str().unwrap().into(),
        details: error.get("details").and_then(Value::as_object).cloned(),
    })
}

/// Every recorded `job.result` answer, named by the first oracle case that
/// ran its Job.
fn recorded() -> Vec<(String, String, Value)> {
    let cases: Value = serde_json::from_str(CASES).unwrap();
    let reads: Value = serde_json::from_str(READS).unwrap();
    reads
        .as_object()
        .unwrap()
        .iter()
        .map(|(job, answers)| {
            let name = cases
                .as_array()
                .unwrap()
                .iter()
                .find(|case| case["params"]["jobId"] == job.as_str())
                .map(|case| case["name"].as_str().unwrap().to_owned())
                .unwrap_or_else(|| panic!("no oracle case ran {job}"));
            (name, job.clone(), answers["job.result"].clone())
        })
        .collect()
}

#[test]
fn result_argv_matches_current_swift() {
    let fixture: Value = serde_json::from_str(include_str!(
        "../../../tests/fixtures/current-cli-argv/job.result.json"
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
            assert_eq!(invocation.command, "job.result", "{row}");
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
    let bounded = parse(&args(&[
        "job",
        "result",
        "--job",
        "job-a",
        "--timeout",
        "5m",
    ]))
    .unwrap();
    assert_eq!(bounded.timeout_ms, Some(300_000));
    for argv in [
        vec!["job", "result", "--job", "bad:id"],
        vec!["job", "result", "--job", "job-a", "--timeout", "0s"],
        vec!["job", "result", "--job", "job-a", "--include-timeline"],
    ] {
        assert!(parse(&args(&argv)).is_err(), "{argv:?}");
    }
}

#[test]
fn recorded_results_validate_and_earn_their_exit() {
    let mut exits = Vec::new();
    for (name, job, answer) in recorded() {
        let invocation = parse(&args(&["job", "result", "--job", &job])).unwrap();
        validate_read_only_request(&invocation).unwrap();
        let exit = if answer["ok"] == true {
            let result = &answer["result"];
            assert_eq!(
                project_read_only_response(&invocation, result.clone()).unwrap(),
                *result,
                "{name}"
            );
            // Another Job's result is not this read's answer.
            let other = parse(&args(&["job", "result", "--job", "job-other"])).unwrap();
            assert!(
                validate_read_only_response(&other, result).is_err(),
                "{name}"
            );
            result_exit(result)
        } else {
            CliError::from_client(wire(&answer["error"]), "job.result").exit_code()
        };
        exits.push((name, exit));
    }
    // A failed analyzer Job never publishes its required product, so its
    // evidence needs attention (2) before its failed state (1) is reported;
    // a parked Job has no result yet (75) and an absent one is not found.
    for (name, exit) in [
        ("answered", 0),
        ("redacted", 0),
        ("emptyResult", 2),
        ("quotaExceeded", 2),
        ("sourceRemoved", 2),
        ("nonZeroExit", 2),
        ("timedOut", 75),
        ("signalled", 75),
        ("absentJob", 65),
    ] {
        assert!(
            exits.contains(&(name.to_owned(), exit)),
            "{name}: {exits:?}"
        );
    }
    assert_eq!(exits.len(), 16);
}

#[test]
fn a_result_that_disagrees_with_itself_is_refused() {
    let (_, job, answer) = recorded()
        .into_iter()
        .find(|(name, ..)| name == "answered")
        .unwrap();
    let invocation = parse(&args(&["job", "result", "--job", &job])).unwrap();
    let result = answer["result"].clone();
    validate_read_only_response(&invocation, &result).unwrap();
    let refused = |bad: &Value, label: &str| {
        assert_eq!(
            validate_read_only_response(&invocation, bad)
                .unwrap_err()
                .code,
            "recordUnreadable",
            "{label}"
        );
    };
    for (pointer, value) in [
        ("/schemaVersion", json!("arkdeck.job-result/2")),
        ("/terminal", json!(false)),
        ("/outcomeUnknown", json!(true)),
        (
            "/nextAction",
            json!({"kind": "cleanup", "owner": {"kind": "job", "id": job},
                "resource": {"kind": "cleanupDebt", "id": "cleanup-x"},
                "reasonCode": "recovery.cleanupDebt"}),
        ),
        ("/job/state", json!("running")),
        ("/evidence/jobId", json!("job-other")),
        ("/artifacts/0/owner/id", json!("job-other")),
        ("/artifacts/0/artifactId", json!("ART:other")),
        (
            "/artifacts/0/reference",
            json!("arkdeck-artifact://job-other/x"),
        ),
        ("/artifacts/0/sha256", json!("")),
        ("/artifacts/0/byteCount", json!("01")),
        ("/artifacts/0/privacy", json!("public")),
        ("/artifacts/0/status", json!("pending")),
        ("/artifacts/0/mediaType", json!("")),
    ] {
        let mut bad = result.clone();
        *bad.pointer_mut(pointer).unwrap() = value;
        refused(&bad, pointer);
    }
    let mut duplicated = result.clone();
    let row = duplicated["artifacts"][0].clone();
    duplicated["artifacts"].as_array_mut().unwrap().push(row);
    refused(&duplicated, "duplicate Artifact row");
    let mut extended = result.clone();
    extended["future"] = json!(true);
    refused(&extended, "unknown key");

    // An outstanding cleanup row turns the next action into its cleanup.
    let debt = format!("cleanup-{}", "a".repeat(64));
    let mut owed = result.clone();
    owed["job"]["outstandingResidueCount"] = json!(1);
    owed["cleanup"] = json!([{"cleanupDebtId": debt, "jobId": job,
        "stepId": "extract-crash-signature", "recordedAtUtc": "2026-09-14T00:00:00Z",
        "outcomeUnknown": false}]);
    owed["nextAction"] = json!({"kind": "cleanup", "owner": {"kind": "job", "id": job},
        "resource": {"kind": "cleanupDebt", "id": debt}, "reasonCode": "recovery.cleanupDebt"});
    validate_read_only_response(&invocation, &owed).unwrap();
    assert_eq!(result_exit(&owed), 0);
    for (pointer, value) in [
        ("/nextAction", Value::Null),
        (
            "/nextAction/resource/id",
            json!(format!("cleanup-{}", "b".repeat(64))),
        ),
        ("/nextAction/reasonCode", json!("job.resultAvailable")),
        ("/cleanup/0/cleanupDebtId", json!("cleanup-short")),
        ("/cleanup/0/jobId", json!("job-other")),
        ("/cleanup/0/stepId", json!("")),
        ("/cleanup/0/recordedAtUtc", json!("yesterday")),
    ] {
        let mut bad = owed.clone();
        *bad.pointer_mut(pointer).unwrap() = value;
        refused(&bad, pointer);
    }
}

#[test]
fn the_exit_follows_the_outcome_then_the_evidence_then_the_state() {
    let with = |unknown: bool, status: &str, state: &str| {
        json!({"outcomeUnknown": unknown, "evidence": {"status": status},
            "job": {"state": state, "outcomeUnknown": unknown}})
    };
    assert_eq!(result_exit(&with(true, "verified", "succeeded")), 75);
    assert_eq!(result_exit(&with(false, "verified", "succeeded")), 0);
    assert_eq!(result_exit(&with(false, "verified", "recovered")), 0);
    assert_eq!(result_exit(&with(false, "verified", "cancelled")), 1);
    assert_eq!(result_exit(&with(false, "futureStatus", "failed")), 2);
    assert_eq!(evidence_exit(&json!({"status": "verified"})), 0);
    assert_eq!(evidence_exit(&json!({"status": "resultNotReady"})), 75);
    assert_eq!(evidence_exit(&json!({"status": "stepKindsUnprovable"})), 2);
}

#[test]
fn a_pending_result_is_retryable_and_refusals_keep_only_proven_codes() {
    let (_, _, pending) = recorded()
        .into_iter()
        .find(|(name, ..)| name == "timedOut")
        .unwrap();
    let error = CliError::from_client(wire(&pending["error"]), "job.result");
    assert_eq!((error.code, error.exit_code()), ("resultNotReady", 75));
    let envelope = failure_envelope("job.result", &error, "ctl-test", true);
    assert_eq!(envelope["error"]["controlRequestRetryable"], true);
    assert_eq!(envelope["error"]["attentionRequired"], true);
    assert_eq!(envelope["error"]["details"]["state"], "waitingForRecovery");
    let refused: Vec<Value> = serde_json::from_str(REFUSED).unwrap();
    for read in &refused {
        let error = CliError::from_client(
            wire(&read["response"]["error"]),
            read["method"].as_str().unwrap(),
        );
        assert_eq!(
            (error.code, error.exit_code()),
            ("invalidInput", 65),
            "{read}"
        );
    }
    let proof = json!({"phase": "preAdmission", "newDispatchCount": 0});
    for (code, proven, expected) in [
        ("inputTooLarge", true, "inputTooLarge"),
        ("inputTooLarge", false, "internalError"),
        ("resourceConflict", true, "resourceConflict"),
        ("resourceConflict", false, "internalError"),
        ("rejected", true, "admissionDenied"),
        ("notFound", false, "resourceNotFound"),
        ("recordUnreadable", false, "recordUnreadable"),
    ] {
        for method in ["job.result", "job.evidence"] {
            let error = CliError::from_client(
                ClientError::Remote(WireError {
                    code: code.into(),
                    message: "fixture".into(),
                    details: proven.then(|| proof.as_object().unwrap().clone()),
                }),
                method,
            );
            assert_eq!(error.code, expected, "{method} {code} {proven}");
        }
    }
}
