//! The published contract admits what Swift answered for the agent execution
//! and agent-owned human-action members, wherever a method answers them
//! (TASK-XPA-018). Before, each method's schema admitted only the values its
//! own recorded frames happened to carry, so a correct answer was replaced by
//! `internalError`:
//!
//! * `failureCode` is the execution's failure code or null
//!   (`RuntimeAgentExecutionRecord.projection`). A string was only ever
//!   recorded for `agent.run`.
//! * An agent-owned human action's `selectionSchema` is null or `{"type":
//!   "string", "enum": [...]}` (`RuntimeAgentHumanAction.projection`). An
//!   object was only ever recorded for `agent.run`.
//! * `agent.run` refuses before admission with `orchestrationBudgetExpired` or
//!   `orchestrationClockUntrusted`, which were never recorded.
//!
//! Each case grafts the value Swift recorded for `agent.run` into another
//! method's own recorded answer and validates it against that method's
//! published schema. Control-action human actions keep a null-only
//! `selectionSchema`, as Swift's `HDCControlActionRecord` wrote it.
//!
//! check-contracts' published view compiles this build against the merge
//! base's contract, which predates the widening: there the grafted answers are
//! refused, and nothing else is asserted.
use arkdeck_contract::validate_method_value;
use serde_json::{Value, json};
use std::path::Path;

fn frames(method: &str) -> Vec<Value> {
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join(format!(
        "../../../Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames/{method}.jsonl"
    ));
    std::fs::read_to_string(path)
        .unwrap()
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect()
}

fn published_view() -> bool {
    let inputs: Value = serde_json::from_str(arkdeck_contract::CONTRACT_INPUTS).unwrap();
    inputs["kind"] == "development" && inputs.get("commit").is_some()
}

/// What Swift's `agent.run` recorded: a failure code, and a choose-a-candidate
/// selection schema.
fn recorded() -> (Value, Value) {
    let run = frames("agent.run");
    let failure = run
        .iter()
        .find_map(|frame| {
            frame["result"]["failureCode"]
                .as_str()
                .map(|code| json!(code))
        })
        .expect("a recorded agent.run failure code");
    let selection = run
        .iter()
        .map(|frame| frame["result"]["humanAction"]["selectionSchema"].clone())
        .find(Value::is_object)
        .expect("a recorded agent.run selection schema");
    assert_eq!(selection["type"], "string");
    (failure, selection)
}

/// `root` with `value` at `pointer`, or `None` when the recorded answer has
/// no such member to replace.
fn grafted(root: &Value, pointer: &str, value: &Value) -> Option<Value> {
    let mut root = root.clone();
    let slot = root.pointer_mut(pointer)?;
    *slot = value.clone();
    Some(root)
}

#[test]
fn the_agent_members_admit_what_swift_answered_in_every_method() {
    let (failure, selection) = recorded();
    let cases: &[(&str, &str, &str, &Value)] = &[
        ("agent.status", "result", "/failureCode", &failure),
        ("agent.resume", "result", "/failureCode", &failure),
        ("agent.abandon", "result", "/failureCode", &failure),
        ("agent.list", "result", "/items/0/failureCode", &failure),
        ("human-action.resume", "result", "/failureCode", &failure),
        (
            "agent.status",
            "result",
            "/humanAction/selectionSchema",
            &selection,
        ),
        (
            "agent.resume",
            "result",
            "/humanAction/selectionSchema",
            &selection,
        ),
        (
            "human-action.list",
            "result",
            "/items/0/selectionSchema",
            &selection,
        ),
        (
            "human-action.show",
            "result",
            "/selectionSchema",
            &selection,
        ),
        (
            "human-action.resume",
            "result",
            "/selectionSchema",
            &selection,
        ),
    ];
    let mut checked = 0;
    let mut refused = Vec::new();
    for (method, part, pointer, value) in cases {
        let answers: Vec<Value> = frames(method)
            .iter()
            .filter(|frame| frame["ok"] == true)
            .filter_map(|frame| grafted(&frame["result"], pointer, value))
            .collect();
        assert!(
            !answers.is_empty(),
            "{method}: no recorded answer carries {pointer}"
        );
        for answer in answers {
            checked += 1;
            if validate_method_value(method, part, &answer).is_err() {
                refused.push(format!("{method} {pointer}"));
            }
        }
    }
    if published_view() {
        return;
    }
    assert!(refused.is_empty(), "refused: {refused:#?}");
    assert!(checked >= 10);
}

#[test]
fn agent_run_publishes_its_orchestration_refusals() {
    let details = json!({"executionId": "execution-1", "phase": "preAdmission",
        "newDispatchCount": 0});
    for code in ["orchestrationBudgetExpired", "orchestrationClockUntrusted"] {
        let published = validate_method_value("agent.run", "errorCode", &json!(code)).is_ok();
        if !published {
            assert!(published_view(), "agent.run must publish {code}");
            continue;
        }
        validate_method_value("agent.run", "errorDetails", &details).unwrap();
    }
}

/// The Rust owner's exact answers S1 captured from `AgentExecutionStore`
/// (the code the daemon runs on macOS and Windows) at a fixed clock:
/// an execution stopped at its deadline or by an untrusted clock, the page
/// that lists it, a waiting pick-a-device execution, and `agent.run`'s
/// refusals of a stopped execution and of a new one without trusted time.
#[test]
fn the_rust_owner_s_captured_answers_conform() {
    let stopped = |failure: &str, state: &str| {
        json!({"bindingRevision": null,
            "catalogDigest": "508783acdf9e9b13d2d4a969e7e26f6fd60094a39d1cc9e02d2198e02ea13684",
            "createdAt": "2026-09-14T00:00:00.000Z", "deadline": "2026-09-14T00:05:00.000Z",
            "executionId": "har-ambiguous", "failureCode": failure, "generation": "4",
            "humanAction": null, "jobId": null, "jobState": null,
            "lastObservedAt": "2026-09-14T00:00:00.000Z", "nextAction": null,
            "operation": "observe.device@1", "outcomeUnknown": false,
            "schemaVersion": "arkdeck.agent-execution/1", "state": state, "targetId": null})
    };
    let deadline = stopped("orchestrationBudgetExpired", "budgetExpired");
    let clock = stopped("orchestrationClockUntrusted", "clockUntrusted");
    let mut item = deadline.clone();
    item.as_object_mut().unwrap().remove("humanAction");
    let page = json!({"hasMore": false, "items": [item], "nextCursor": null,
        "order": "createdAtDescExecutionIdAsc", "pageKind": "snapshot",
        "schemaVersion": "arkdeck.cli.page/1",
        "snapshotRevision": "00000000-0000-4000-8000-000000000000"});
    let action = json!({"actionId": "har-00000000-0000-4000-8000-000000000003",
        "category": "ambiguousIdentity",
        "choices": [
            {"candidateKey": "a".repeat(32), "value": "candidate-00000000-0000-4000-8000-000000000001"},
            {"candidateKey": "b".repeat(32), "value": "candidate-00000000-0000-4000-8000-000000000002"}],
        "createdAt": "2026-09-14T00:00:00.000Z", "expiresAt": "2026-09-14T00:05:00.000Z",
        "minimumAction": "human.confirmDeviceIdentity", "newDispatchCount": 0,
        "owner": {"id": "har-ambiguous", "kind": "agentExecution"},
        "reasonCode": "device.identityAmbiguous",
        "resumeReference": "resume-00000000-0000-4000-8000-000000000003",
        "schemaVersion": "arkdeck.human-action/1",
        "selectionSchema": {"enum": ["candidate-00000000-0000-4000-8000-000000000001",
            "candidate-00000000-0000-4000-8000-000000000002"], "type": "string"},
        "status": "waiting"});
    let mut waiting = stopped("", "waitingForHuman");
    waiting["failureCode"] = Value::Null;
    waiting["generation"] = json!("3");
    waiting["humanAction"] = action.clone();
    waiting["nextAction"] = json!({"expiresAt": "2026-09-14T00:05:00.000Z", "kind": "humanAction",
        "owner": {"id": "har-ambiguous", "kind": "agentExecution"},
        "reasonCode": "device.identityAmbiguous",
        "resource": {"id": "har-00000000-0000-4000-8000-000000000003", "kind": "humanAction"},
        "resumeReference": "resume-00000000-0000-4000-8000-000000000003"});
    let answers = [
        ("agent.status", "result", &deadline),
        ("agent.status", "result", &clock),
        ("agent.list", "result", &page),
        ("agent.status", "result", &waiting),
        ("human-action.show", "result", &action),
    ];
    let refusals = [
        json!({"executionId": "har-ambiguous", "newDispatchCount": 0, "phase": "preAdmission"}),
        json!({"newDispatchCount": 0, "phase": "preAdmission"}),
    ];
    let widened = validate_method_value(
        "agent.run",
        "errorCode",
        &json!("orchestrationBudgetExpired"),
    )
    .is_ok();
    if !widened {
        assert!(
            published_view(),
            "agent.run must publish its orchestration refusals"
        );
        return;
    }
    for (method, part, answer) in answers {
        validate_method_value(method, part, answer)
            .unwrap_or_else(|error| panic!("{method}: {error:?}: {answer}"));
    }
    for code in ["orchestrationBudgetExpired", "orchestrationClockUntrusted"] {
        validate_method_value("agent.run", "errorCode", &json!(code)).unwrap();
    }
    for details in &refusals {
        validate_method_value("agent.run", "errorDetails", details).unwrap();
    }
    // The resume owners already publish the clock refusal they pass through.
    for method in ["agent.resume", "human-action.resume"] {
        validate_method_value(method, "errorCode", &json!("orchestrationClockUntrusted")).unwrap();
    }
}

#[test]
fn control_action_human_actions_keep_a_null_selection_schema() {
    let (_, selection) = recorded();
    for (method, pointer) in [
        ("control-action.show", "/humanAction/selectionSchema"),
        ("runtime.tool.select", "/humanAction/selectionSchema"),
    ] {
        for answer in frames(method)
            .iter()
            .filter(|frame| frame["ok"] == true)
            .filter_map(|frame| grafted(&frame["result"], pointer, &selection))
        {
            assert!(
                validate_method_value(method, "result", &answer).is_err(),
                "{method} admits a selection schema its owner never writes"
            );
        }
    }
}
