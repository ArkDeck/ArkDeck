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
fn host_owner_failure_scope_and_lost_reply_are_preserved() {
    for (method, phase, expected) in [
        (
            "history.filter.save",
            "historyFilterOwner",
            "resourceConflict",
        ),
        ("job.run", "historyFilterOwner", "internalError"),
        ("history.filter.save", "other", "internalError"),
        (
            "runtime.storage.root",
            "runtimeStorageOwner",
            "resourceConflict",
        ),
        (
            "runtime.storage.policy",
            "historyFilterOwner",
            "internalError",
        ),
        ("job.run", "runtimeStorageOwner", "internalError"),
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
    for method in [
        "history.filter.save",
        "runtime.storage.root",
        "runtime.storage.policy",
        "session.pin",
        "session.unpin",
    ] {
        let interrupted = CliError::from_client(
            ClientError::Transport(std::io::ErrorKind::BrokenPipe.into()),
            method,
        );
        assert_eq!(interrupted.code, "outcomeUnknown");
        assert!(!interrupted.details.contains_key("newDispatchCount"));
        assert_eq!(
            failure_envelope(method, &interrupted, "ctl-test", true)["error"]["controlRequestRetryable"],
            false
        );
    }
}

#[test]
fn session_cli_requires_exact_identity_and_preserves_zero_catalog_generation() {
    for verb in ["pin", "unpin"] {
        let parsed = parse(
            &[
                "session",
                verb,
                "--session",
                "session-one",
                "--expected-generation",
                "0",
            ]
            .map(str::to_owned),
        )
        .unwrap();
        assert_eq!(
            json!(parsed.params),
            json!({"sessionId":"session-one","expectedGeneration":"0"})
        );
    }
    let page =
        parse(&["session", "list", "--page-size", "1", "--cursor", "opaque"].map(str::to_owned))
            .unwrap();
    assert_eq!(json!(page.params), json!({"pageSize":1,"cursor":"opaque"}));
    for args in [
        vec!["session", "pin", "--session", "one"],
        vec!["session", "show"],
        vec![
            "session",
            "show",
            "--session",
            "one",
            "--expected-generation",
            "0",
        ],
        vec!["session", "list", "--page-size", "0"],
        vec!["session", "list", "--page-size", "1001"],
    ] {
        assert!(parse(&args.into_iter().map(str::to_owned).collect::<Vec<_>>()).is_err());
    }
}

#[test]
fn session_client_refuses_invalid_rows_and_partial_or_mixed_pages() {
    let invocation = parse(&["session", "list", "--page-size", "2"].map(str::to_owned)).unwrap();
    let row = json!({"schemaVersion":"arkdeck.session/1","sessionId":"session-one","generation":"0","completedAtUtc":"2026-08-02T00:00:00Z", "expiresAtUtc":"2026-10-31T00:00:00Z","sizeBytes":"1","pinned":false,"policyGeneration":"1"});
    let page = json!({"schemaVersion":"arkdeck.cli.page/1","pageKind":"snapshot","order":"completedAtDescSessionIdAsc", "snapshotRevision":"aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa","hasMore":false,"nextCursor":null,"items":[row.clone()]});
    validate_session_response(&invocation, &page).unwrap();
    for (field, value) in [
        ("generation", json!("00")),
        ("sizeBytes", json!("9223372036854775808")),
        ("policyGeneration", json!("0")),
        ("completedAtUtc", json!("2026-02-30T00:00:00Z")),
        ("expiresAtUtc", json!("2026-08-01T00:00:00Z")),
    ] {
        let mut invalid = page.clone();
        invalid["items"][0][field] = value;
        assert_eq!(
            validate_session_response(&invocation, &invalid)
                .unwrap_err()
                .code,
            "recordUnreadable"
        );
    }
    let mut duplicate = page.clone();
    duplicate["items"] = json!([row.clone(), row]);
    assert!(validate_session_response(&invocation, &duplicate).is_err());
    let mut invalid = page;
    invalid["hasMore"] = json!(true);
    assert!(validate_session_response(&invocation, &invalid).is_err());
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

#[test]
fn export_apply_requires_one_exact_preview_tuple_and_keeps_its_method_scope() {
    let args = |values: &[&str]| values.iter().map(|s| s.to_string()).collect::<Vec<_>>();
    assert_eq!(
        parse(&args(&["session", "export", "apply"]))
            .unwrap_err()
            .code,
        "invalidInput"
    );
    let digest = "a".repeat(64);
    let valid = args(&[
        "session",
        "export",
        "apply",
        "--preview-id",
        "00000000-0000-0000-0000-000000000001",
        "--preview-digest",
        &digest,
    ]);
    let invocation = parse(&valid).unwrap();
    assert_eq!(invocation.command, "session.export.apply");
    assert_eq!(invocation.params.unwrap()["previewDigest"], digest);
    let mut bad = valid.clone();
    bad[4] = "bad".into();
    assert_eq!(parse(&bad).unwrap_err().code, "invalidInput");
    let mut extra = valid;
    extra.extend(args(&["--allow-sensitive"]));
    assert_eq!(parse(&extra).unwrap_err().code, "invalidOption");
}

#[test]
fn cleanup_apply_requires_one_exact_preview_tuple_and_keeps_its_method_scope() {
    let args = |values: &[&str]| values.iter().map(|s| s.to_string()).collect::<Vec<_>>();
    assert_eq!(
        parse(&args(&["session", "cleanup", "apply"]))
            .unwrap_err()
            .code,
        "invalidInput"
    );
    let digest = "a".repeat(64);
    let valid = args(&[
        "session",
        "cleanup",
        "apply",
        "--preview-id",
        "00000000-0000-0000-0000-000000000001",
        "--preview-digest",
        &digest,
    ]);
    let invocation = parse(&valid).unwrap();
    assert_eq!(invocation.command, "session.cleanup.apply");
    assert_eq!(invocation.params.unwrap()["previewDigest"], digest);
    let mut bad = valid.clone();
    bad[4] = "bad".into();
    assert_eq!(parse(&bad).unwrap_err().code, "invalidInput");
    let mut extra = valid;
    extra.extend(args(&["--allow-sensitive"]));
    assert_eq!(parse(&extra).unwrap_err().code, "invalidOption");
}

#[test]
fn cleanup_apply_unconfirmed_reply_is_unknown_and_never_retryable() {
    for error in [
        ClientError::Transport(std::io::ErrorKind::BrokenPipe.into()),
        ClientError::Transport(std::io::ErrorKind::TimedOut.into()),
        ClientError::ConnectionUnusable,
        ClientError::Contract(arkdeck_contract::ContractError::SchemaMismatch),
    ] {
        let error = CliError::from_client(error, "session.cleanup.apply");
        assert_eq!(error.code, "outcomeUnknown");
        assert!(!error.details.contains_key("newDispatchCount"));
        assert_eq!(
            failure_envelope("session.cleanup.apply", &error, "ctl-fixture", true)["error"]["controlRequestRetryable"],
            false
        );
    }
    for code in [
        "resourceConflict",
        "resourceNotFound",
        "invalidInput",
        "recordUnreadable",
        "operationUnavailable",
        "outcomeUnknown",
    ] {
        let error = CliError::from_client(
            ClientError::Remote(WireError {
                code: code.into(),
                message: "fixture".into(),
                details: Some(
                    json!({"phase":"sessionOwner", "newDispatchCount":0})
                        .as_object()
                        .unwrap()
                        .clone(),
                ),
            }),
            "session.cleanup.apply",
        );
        assert_eq!(error.code, code);
    }
}
