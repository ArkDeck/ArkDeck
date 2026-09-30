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
