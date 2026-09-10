use arkdeck_cli::*;
use arkdeck_client::ClientError;
use arkdeck_contract::WireError;
use serde_json::{Value, json};

#[test]
fn current_argv_fixture_families_replay_without_a_device() {
    for bytes in [
        include_str!(
            "../../../../Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/CLI/argv/doctor.json"
        ),
        include_str!(
            "../../../../Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/CLI/argv/operation.list.json"
        ),
        include_str!(
            "../../../../Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/CLI/argv/device.candidates.json"
        ),
    ] {
        let doc: Value = serde_json::from_str(bytes).unwrap();
        for case in doc["cases"].as_array().unwrap() {
            let args = case["argv"]
                .as_array()
                .unwrap()
                .iter()
                .map(|v| v.as_str().unwrap().to_owned())
                .collect::<Vec<_>>();
            let parsed = parse(&args);
            if case["name"] == "macosCompatibilityOption" && !cfg!(target_os = "macos") {
                assert_eq!(parsed.unwrap_err().code, "unsupportedOnPlatform");
                continue;
            }
            if case["expected"]["outcome"] == "failure" {
                let error = parsed.unwrap_err();
                assert_eq!(error.code, case["expected"]["code"]);
                assert_eq!(json!(error.exit_code()), case["expected"]["exitCode"]);
            } else {
                let parsed = parsed.unwrap();
                assert_eq!(parsed.command, case["expected"]["command"]);
                assert_eq!(parsed.help, case["expected"]["outcome"] == "leafHelp");
                if parsed.command == "device.candidates" {
                    assert_eq!(parsed.method, "device.observations");
                }
            }
        }
    }
}

#[test]
fn machine_envelope_uses_current_versions_and_canonical_bytes() {
    let envelope = success_envelope("operation.list", json!([]), "ctl-fixture-0001");
    assert_eq!(render(&envelope).unwrap(),b"{\"command\":\"operation.list\",\"meta\":{\"cliVersion\":\"0.1.0\",\"controlProtocolVersion\":\"1.0.0\",\"controlRequestId\":\"ctl-fixture-0001\"},\"ok\":true,\"result\":[],\"schemaVersion\":\"arkdeck.cli.result/1\"}\n");
}

#[test]
fn doctor_flags_correlation_and_duplicate_flags_are_strict() {
    for args in [
        vec!["device", "candidates", "--deep"],
        vec!["doctor", "--deep", "--deep"],
        vec!["doctor", "--output"],
        vec!["doctor", "--control-request-id", "bad\nvalue"],
        vec!["doctor", "--help", "--output", "json"],
    ] {
        assert!(parse(&args.into_iter().map(str::to_owned).collect::<Vec<_>>()).is_err());
    }
    let args = [
        "doctor",
        "--deep",
        "--require-healthy",
        "--output",
        "json",
        "--control-request-id",
        "ctl-123",
    ];
    let parsed = parse(&args.map(str::to_owned)).unwrap();
    assert!(parsed.require_healthy && parsed.json);
    assert_eq!(parsed.params.unwrap()["deep"], true);
}

#[test]
fn unknown_execution_is_never_invented_as_zero_execution_by_error_mapping() {
    let error = CliError::from_client(
        ClientError::Remote(WireError {
            code: "rejected".into(),
            message: "unknown: reply lost".into(),
            details: None,
        }),
        "device.observations",
    );
    assert_eq!(error.code, "operationFailed");
    assert!(!error.details.contains_key("newDispatchCount"));
    let envelope = failure_envelope("device.candidates", &error, "ctl-test", true);
    assert_eq!(envelope["error"]["controlRequestRetryable"], false);
}

#[test]
fn history_owner_failure_scope_and_lost_reply_are_preserved() {
    for (method, phase, expected) in [
        (
            "history.filter.save",
            "historyFilterOwner",
            "resourceConflict",
        ),
        ("job.run", "historyFilterOwner", "internalError"),
        ("history.filter.save", "other", "internalError"),
    ] {
        let error = CliError::from_client(
            ClientError::Remote(WireError {
                code: "resourceConflict".into(),
                message: "version changed".into(),
                details: Some(
                    serde_json::from_value(json!({"phase":phase,"newDispatchCount":0})).unwrap(),
                ),
            }),
            method,
        );
        assert_eq!(error.code, expected);
    }
    let interrupted = CliError::from_client(
        ClientError::Transport(std::io::ErrorKind::BrokenPipe.into()),
        "history.filter.save",
    );
    assert_eq!(interrupted.code, "outcomeUnknown");
    assert!(!interrupted.details.contains_key("newDispatchCount"));
    assert_eq!(
        failure_envelope("history.filter.save", &interrupted, "ctl-test", true)["error"]["controlRequestRetryable"],
        false
    );
}

#[test]
fn history_cli_builds_complete_queries_and_rejects_invalid_options() {
    let save =
        parse(&["history", "filter", "save", "--expected-generation", "1"].map(str::to_owned))
            .unwrap();
    assert_eq!(save.method, "history.filter.save");
    assert_eq!(
        json!(save.params),
        json!({"expectedGeneration":"1", "search":"", "status":"all", "mode":"all", "sessionId":null, "targetId":null, "timeRange":"anyTime", "activity":"all"})
    );
    for args in [
        vec!["history", "filter", "save"],
        vec!["history", "filter", "save", "--expected-generation", "01"],
        vec![
            "history",
            "filter",
            "save",
            "--expected-generation",
            "1",
            "--status",
            "invalid",
        ],
        vec![
            "history",
            "filter",
            "delete",
            "--expected-generation",
            "1",
            "--search",
            "value",
        ],
        vec!["history", "filter", "list", "--expected-generation", "1"],
        vec![
            "history",
            "filter",
            "delete",
            "--expected-generation",
            "1",
            "--expected-generation",
            "1",
        ],
    ] {
        assert_eq!(
            parse(&args.into_iter().map(str::to_owned).collect::<Vec<_>>())
                .unwrap_err()
                .code,
            "invalidOption"
        );
    }
    let help = parse(&["history", "filter", "save", "--help"].map(str::to_owned)).unwrap();
    assert!(help.help);
}
