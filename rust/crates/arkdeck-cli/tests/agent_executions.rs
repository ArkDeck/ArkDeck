//! `agent run`, `agent status` and `artifact list` against the Swift CLI's argv
//! fixtures and the answers Swift's agent execution oracle recorded
//! (`rust/tests/fixtures/agent-execution`): the parse outcomes, the intent a run
//! sends, every recorded execution checked as Swift's `executionFields` checks
//! it, how a run settles and exits, how refusals map, and an Artifact page.
use arkdeck_cli::*;
use arkdeck_client::ClientError;
use arkdeck_contract::WireError;
use serde_json::{Map, Value, json};

fn args(values: &[&str]) -> Vec<String> {
    values.iter().map(|value| (*value).to_owned()).collect()
}

fn oracle() -> Value {
    serde_json::from_str(include_str!(
        "../../../tests/fixtures/agent-execution/cases.json"
    ))
    .unwrap()
}

fn exchange(name: &str) -> Value {
    oracle()["exchanges"]
        .as_array()
        .unwrap()
        .iter()
        .find(|exchange| exchange["name"] == name)
        .unwrap_or_else(|| panic!("no exchange {name}"))
        .clone()
}

fn remote(code: &str, proven: bool) -> ClientError {
    ClientError::Remote(WireError {
        code: code.into(),
        message: "refused".into(),
        details: proven.then(|| {
            Map::from_iter([
                ("phase".into(), json!("preAdmission")),
                ("newDispatchCount".into(), json!(0)),
            ])
        }),
    })
}

#[test]
fn argv_fixtures_replay_as_the_swift_cli_parses_them() {
    // The Swift CLI's argv fixtures, as packaged beside the other parser
    // samples, which `check-contracts.py` keeps byte-identical to Swift's.
    for bytes in [
        include_str!("../../../tests/fixtures/current-cli-argv/agent.run.json"),
        include_str!("../../../tests/fixtures/current-cli-argv/agent.status.json"),
        include_str!("../../../tests/fixtures/current-cli-argv/artifact.list.json"),
    ] {
        let document: Value = serde_json::from_str(bytes).unwrap();
        for case in document["cases"].as_array().unwrap() {
            let argv: Vec<String> = case["argv"]
                .as_array()
                .unwrap()
                .iter()
                .map(|value| value.as_str().unwrap().to_owned())
                .collect();
            let parsed = parse(&argv);
            let name = format!("{} {}", document["command"], case["name"]);
            if case["name"] == "macosCompatibilityOption" && !cfg!(target_os = "macos") {
                assert_eq!(parsed.unwrap_err().code, "unsupportedOnPlatform", "{name}");
                continue;
            }
            if case["expected"]["outcome"] == "failure" {
                let error = parsed.unwrap_err();
                assert_eq!(error.code, case["expected"]["code"], "{name}");
                assert_eq!(
                    json!(error.exit_code()),
                    case["expected"]["exitCode"],
                    "{name}"
                );
            } else {
                let parsed = parsed.unwrap_or_else(|error| panic!("{name}: {}", error.message));
                assert_eq!(parsed.command, case["expected"]["command"], "{name}");
                assert_eq!(
                    parsed.help,
                    case["expected"]["outcome"] == "leafHelp",
                    "{name}"
                );
            }
        }
    }
}

#[test]
fn a_run_sends_the_intent_the_swift_cli_sent_to_the_oracle() {
    let target = oracle()["target"]["targetId"].as_str().unwrap().to_owned();
    let observed = parse(&args(&[
        "agent",
        "run",
        "--operation",
        "observe.device@1",
        "--target",
        &target,
        "--execution-id",
        "gj1-observe",
    ]))
    .unwrap();
    assert_eq!(
        Value::Object(execution_intent(&observed).unwrap()),
        exchange("observed.run")["params"]
    );
    let inputs = std::env::temp_dir().join(format!(
        "arkdeck-cli-agent-inputs-{}.json",
        std::process::id()
    ));
    std::fs::write(&inputs, br#"{"durationSeconds": 5}"#).unwrap();
    let captured = parse(&args(&[
        "agent",
        "run",
        "--operation",
        "capture.diagnostics@1",
        "--target",
        &target,
        "--inputs-file",
        inputs.to_str().unwrap(),
        "--execution-id",
        "gj1-capture",
    ]))
    .unwrap();
    let intent = execution_intent(&captured);
    std::fs::remove_file(&inputs).unwrap();
    assert_eq!(
        Value::Object(intent.unwrap()),
        exchange("captured.run")["params"]
    );
}

#[test]
fn intents_are_refused_as_swift_refuses_them() {
    let parsed = |values: &[&str]| parse(&args(values));
    let target = ["--target", "TGT-3ba3f5f43b92"];
    // The Swift registry refuses these before any handler runs.
    for (argv, code) in [
        (vec!["agent", "run"], "invalidOption"),
        (
            vec![
                "agent",
                "run",
                "--request-file",
                "a",
                "--operation",
                "observe.device@1",
            ],
            "invalidOption",
        ),
        (
            vec![
                "agent",
                "run",
                "--request-file",
                "a",
                "--capability",
                "CAP-1",
            ],
            "invalidOption",
        ),
        (
            vec![
                "agent",
                "run",
                "--operation",
                "observe.device@1",
                "--maximum-wait",
                "05m",
            ],
            "invalidOption",
        ),
        (
            vec![
                "agent",
                "run",
                "--operation",
                "observe.device@1",
                "--timeout",
                "25h",
            ],
            "invalidOption",
        ),
        (vec!["agent", "status"], "invalidOption"),
        (
            vec!["agent", "status", "--execution-id", "a", "--operation", "b"],
            "invalidOption",
        ),
    ] {
        assert_eq!(parsed(&argv).unwrap_err().code, code, "{argv:?}");
    }
    for (argv, message) in [
        (
            vec![
                "agent",
                "run",
                "--operation",
                "observe.device@2",
                target[0],
                target[1],
            ],
            "operation must be an exact token published by the current Catalog",
        ),
        (
            vec![
                "agent",
                "run",
                "--operation",
                "observe.device@1",
                "--expected-binding-revision",
                "2",
            ],
            "expected-binding-revision requires an explicit target",
        ),
        (
            vec![
                "agent",
                "run",
                "--operation",
                "observe.device@1",
                target[0],
                target[1],
                "--idempotency-key",
                "short",
            ],
            "idempotencyKey must contain at least 8 characters",
        ),
        (
            vec![
                "agent",
                "run",
                "--operation",
                "observe.device@1",
                target[0],
                target[1],
                "--execution-id",
                "-bad",
            ],
            "an exact published operation, executionId, inputs and bounded orchestration budget are required",
        ),
        (
            vec![
                "agent",
                "run",
                "--operation",
                "observe.device@1",
                target[0],
                target[1],
                "--reviewed-plan-digest",
                "ABC",
            ],
            "reviewedPlanDigest must be an exact lowercase SHA-256",
        ),
    ] {
        let error = execution_intent(&parsed(&argv).unwrap()).unwrap_err();
        assert_eq!(
            (error.code, error.message.as_str()),
            ("invalidInput", message),
            "{argv:?}"
        );
    }
    let missing = parsed(&[
        "agent",
        "run",
        "--request-file",
        "/nonexistent/request.json",
    ])
    .unwrap();
    assert_eq!(execution_intent(&missing).unwrap_err().code, "invalidInput");
}

#[test]
fn a_request_file_carries_its_typed_request_into_the_intent() {
    let path = std::env::temp_dir().join(format!(
        "arkdeck-cli-agent-request-{}.json",
        std::process::id()
    ));
    std::fs::write(
        &path,
        serde_json::to_vec(&json!({
            "documentType": "runtime-operation-request",
            "schemaVersion": "1.0.0",
            "requestId": "request-1",
            "idempotencyKey": "idempotency-1",
            "target": {"targetId": "TGT-3ba3f5f43b92", "expectedBindingRevision": 1},
            "operation": {"id": "observe.device", "version": 1},
            "inputs": {},
            "requestedOutputs": ["derivedArtifacts"],
        }))
        .unwrap(),
    )
    .unwrap();
    let invocation = parse(&args(&[
        "agent",
        "run",
        "--request-file",
        path.to_str().unwrap(),
        "--execution-id",
        "gj1-file",
        "--maximum-wait",
        "10m",
    ]))
    .unwrap();
    let intent = execution_intent(&invocation);
    std::fs::write(
        &path,
        br#"{"documentType": "runtime-operation-request", "extra": 1}"#,
    )
    .unwrap();
    let closed = execution_intent(&invocation).unwrap_err();
    std::fs::remove_file(&path).unwrap();
    assert_eq!(
        Value::Object(intent.unwrap()),
        json!({
            "schemaVersion": "arkdeck.agent-execution-request/1",
            "executionId": "gj1-file",
            "maximumWaitMilliseconds": "600000",
            "requestId": "request-1",
            "idempotencyKey": "idempotency-1",
            "operation": "observe.device@1",
            "inputs": {},
            "requestedOutputs": ["derivedArtifacts"],
            "target": {"targetId": "TGT-3ba3f5f43b92", "expectedBindingRevision": 1},
        })
    );
    assert_eq!(
        (closed.code, closed.message.as_str()),
        (
            "invalidInput",
            "request-file must be a closed typed operation request"
        )
    );
}

/// The recorded answer with the Job state the oracle labels read as running.
fn unlabelled(mut answer: Value) -> Value {
    let result = answer["result"].as_object_mut().unwrap();
    if result["jobState"] == "<jobState>" {
        result.insert("jobState".into(), json!("running"));
        result["job"]["state"] = json!("running");
        result["job"]["outcome"] = json!("running");
    }
    answer["result"].take()
}

#[test]
fn every_recorded_execution_checks_and_settles_as_in_swift() {
    for name in [
        "observed.run",
        "observed.running",
        "captured.run",
        "captured.running",
    ] {
        let fields = validate_execution(&unlabelled(exchange(name)["answer"].clone()))
            .unwrap_or_else(|error| panic!("{name}: {}", error.message));
        assert_eq!(
            settle_execution(&fields).unwrap(),
            Settlement::Pending,
            "{name}"
        );
    }
    for name in [
        "observed.status",
        "observed.rerun",
        "captured.status",
        "captured.rerun",
    ] {
        let answer = exchange(name)["answer"]["result"].clone();
        let fields =
            validate_execution(&answer).unwrap_or_else(|error| panic!("{name}: {}", error.message));
        assert_eq!(
            settle_execution(&fields).unwrap(),
            Settlement::Settled(answer.clone()),
            "{name}"
        );
        assert_eq!(agent_exit(&answer), None, "{name}");
    }
}

#[test]
fn a_settled_run_exits_as_swift_exits() {
    let completed = exchange("observed.status")["answer"]["result"].clone();
    let mut failed = completed.clone();
    failed["jobState"] = json!("failed");
    failed["job"]["state"] = json!("failed");
    failed["job"]["outcome"] = json!("failed");
    assert_eq!(
        agent_exit(&failed),
        Some((1, "job terminal state is failed".into()))
    );
    let mut blocked = completed.clone();
    blocked["evidence"]["blockers"] = json!(["deviceIdentityMismatch"]);
    blocked["evidence"]["status"] = json!("blocked");
    validate_execution(&blocked).unwrap();
    assert_eq!(
        agent_exit(&blocked),
        Some((
            2,
            "required evidence could not be verified: deviceIdentityMismatch".into()
        ))
    );
    let mut unknown = completed.clone();
    unknown["outcomeUnknown"] = json!(true);
    unknown["job"]["outcomeUnknown"] = json!(true);
    unknown["job"]["outcome"] = json!("outcomeUnknown");
    let fields = validate_execution(&unknown).unwrap();
    assert_eq!(
        settle_execution(&fields).unwrap(),
        Settlement::Settled(unknown.clone())
    );
    assert_eq!(agent_exit(&unknown).map(|(code, _)| code), Some(75));
    let mut abandoned = unlabelled(exchange("observed.running")["answer"].clone());
    for key in [
        "jobId",
        "jobState",
        "targetId",
        "bindingRevision",
        "nextAction",
    ] {
        abandoned[key] = Value::Null;
    }
    abandoned.as_object_mut().unwrap().remove("job");
    abandoned["state"] = json!("abandoned");
    abandoned["outcomeUnknown"] = json!(false);
    let fields = validate_execution(&abandoned).unwrap();
    let Settlement::Settled(result) = settle_execution(&fields).unwrap() else {
        panic!("an abandoned execution settles");
    };
    assert_eq!(result["executionOutcome"], "abandoned");
    assert_eq!(
        agent_exit(&result),
        Some((1, "execution was abandoned; no Job was cancelled".into()))
    );
}

#[test]
fn a_failure_or_a_waiting_person_is_raised_with_the_execution() {
    let running = unlabelled(exchange("observed.running")["answer"].clone());
    let mut stopped = running.clone();
    for key in ["jobId", "jobState", "targetId", "bindingRevision"] {
        stopped[key] = Value::Null;
    }
    stopped.as_object_mut().unwrap().remove("job");
    stopped["state"] = json!("failed");
    stopped["failureCode"] = json!("admissionDenied");
    stopped["nextAction"] = Value::Null;
    stopped["outcomeUnknown"] = json!(false);
    let fields = validate_execution(&stopped).unwrap();
    let error = settle_execution(&fields).unwrap_err();
    assert_eq!(
        (error.code, error.message.as_str(), error.exit_code()),
        (
            "admissionDenied",
            "execution stopped before Job creation",
            77
        )
    );
    assert_eq!(error.details["execution"], stopped);

    let id = running["executionId"].as_str().unwrap();
    let owner = json!({"kind": "agentExecution", "id": id});
    let mut waiting = stopped.clone();
    waiting["state"] = json!("waitingForHuman");
    waiting["failureCode"] = Value::Null;
    waiting["humanAction"] = json!({
        "schemaVersion": "arkdeck.human-action/1", "actionId": "har-1", "owner": owner,
        "status": "waiting", "resumeReference": "resume-1", "expiresAt": "2026-09-14T00:05:00Z",
        "reasonCode": "device.recoveryModeRequired",
    });
    waiting["nextAction"] = json!({
        "kind": "humanAction", "owner": owner, "resource": {"kind": "humanAction", "id": "har-1"},
        "reasonCode": "device.recoveryModeRequired", "resumeReference": "resume-1",
        "expiresAt": "2026-09-14T00:05:00Z",
    });
    let fields = validate_execution(&waiting).unwrap();
    let error = settle_execution(&fields).unwrap_err();
    assert_eq!((error.code, error.exit_code()), ("humanActionRequired", 75));
    assert_eq!(
        human_action_progress(&error).as_deref(),
        Some(
            "Physical assistance required. Resume with: arkdeck agent resume --resume-reference resume-1"
        )
    );
}

#[test]
fn an_inconsistent_projection_is_unreadable() {
    let completed = exchange("observed.status")["answer"]["result"].clone();
    let mut cases = Vec::new();
    let mut status = completed.clone();
    status["evidence"]["status"] = json!("blocked");
    cases.push(status);
    let mut artifacts = completed.clone();
    artifacts["artifacts"] = json!([]);
    cases.push(artifacts);
    let mut state = completed.clone();
    state["state"] = json!("jobOwned");
    cases.push(state);
    let mut generation = completed.clone();
    generation["generation"] = json!("07");
    cases.push(generation);
    let mut extra = completed.clone();
    extra["unexpected"] = json!(1);
    cases.push(extra);
    let mut next = completed;
    next["nextAction"]["reasonCode"] = json!("job.running");
    cases.push(next);
    for case in cases {
        assert_eq!(
            validate_execution(&case).unwrap_err().code,
            "recordUnreadable"
        );
    }
}

#[test]
fn refusals_keep_their_code_only_with_the_pre_admission_proof() {
    for name in [
        "observed.conflict",
        "unadopted.run",
        "staleBinding.run",
        "budgetOutOfBound.run",
        "rejectedInputs.run",
    ] {
        let error = &exchange(name)["answer"]["error"];
        let code = error["code"].as_str().unwrap();
        let wire = ClientError::Remote(WireError {
            code: code.into(),
            message: error["message"].as_str().unwrap().into(),
            details: error["details"].as_object().cloned(),
        });
        let mapped = CliError::from_client(wire, "agent.run");
        assert_eq!(mapped.code, code, "{name}");
        assert_eq!(mapped.details["wireCode"], code, "{name}");
    }
    assert_eq!(
        CliError::from_client(remote("bindingRevisionStale", true), "agent.run").exit_code(),
        77
    );
    assert_eq!(
        CliError::from_client(remote("bindingRevisionStale", false), "agent.run").code,
        "outcomeUnknown"
    );
    let absent = &exchange("absentExecution.status")["answer"]["error"];
    let wire = ClientError::Remote(WireError {
        code: absent["code"].as_str().unwrap().into(),
        message: absent["message"].as_str().unwrap().into(),
        details: absent["details"].as_object().cloned(),
    });
    assert_eq!(
        CliError::from_client(wire, "agent.status").code,
        "resourceNotFound"
    );
    assert_eq!(
        CliError::from_client(remote("resourceNotFound", false), "agent.status").code,
        "internalError"
    );
    assert_eq!(
        CliError::from_client(remote("rejected", false), "agent.status").code,
        "operationFailed"
    );
    assert_eq!(
        CliError::from_client(remote("rejected", false), "agent.run").code,
        "outcomeUnknown"
    );
    let lost = CliError::from_client(
        ClientError::Transport(std::io::Error::other("connection reset")),
        "agent.run",
    );
    assert_eq!((lost.code, lost.exit_code()), ("outcomeUnknown", 75));
}

#[test]
fn an_artifact_page_is_the_owner_s_snapshot_in_its_order() {
    let answer = exchange("observed.artifacts")["answer"]["result"].clone();
    let owner = exchange("observed.artifacts")["params"]["owner"].clone();
    let revision = "5f0c3a8e-1d2b-4c6d-8e9f-0a1b2c3d4e5f";
    let mut page = answer.clone();
    page["snapshotRevision"] = json!(revision);
    validate_artifact_page(&page, &owner, 100).unwrap();
    assert!(validate_artifact_page(&page, &owner, 2).is_err());
    let mut reversed = page.clone();
    reversed["items"].as_array_mut().unwrap().reverse();
    assert!(validate_artifact_page(&reversed, &owner, 100).is_err());
    let mut more = page.clone();
    more["hasMore"] = json!(true);
    assert!(validate_artifact_page(&more, &owner, 100).is_err());
    more["nextCursor"] = json!(format!("{revision}.token"));
    validate_artifact_page(&more, &owner, 100).unwrap();
    let other = json!({"kind": "job", "id": "job-00000000000000000000000000000000"});
    assert!(validate_artifact_page(&page, &other, 100).is_err());
    let parsed = parse(&args(&[
        "artifact",
        "list",
        "--job",
        "job-1",
        "--artifact",
        "ART-1",
    ]))
    .unwrap_err();
    assert_eq!(parsed.code, "invalidInput");
    let listed = parse(&args(&[
        "artifact",
        "list",
        "--job",
        "job-1",
        "--page-size",
        "7",
    ]))
    .unwrap();
    assert_eq!(
        listed.params.unwrap(),
        Map::from_iter([
            ("owner".into(), json!({"kind": "job", "id": "job-1"})),
            ("pageSize".into(), json!(7)),
        ])
    );
}
