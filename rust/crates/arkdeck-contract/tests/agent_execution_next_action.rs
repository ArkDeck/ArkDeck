//! `agent.resume` and `human-action.resume` answer the same agent-execution
//! projection, whose `nextAction` names a `retryAfter` while the execution's
//! Job still runs (`{kind: wait, reasonCode: job.running, retryAfter: 250ms}`).
//! Swift's oracle recorded that only through `agent.resume`, and
//! `human-action.resume` only after the Job completed, so the published
//! `human-action.resume` admitted no `retryAfter`: resuming a still-waiting
//! action by it answered `internalError` ("the result does not conform to the
//! current contract") on every host (TASK-XPA-005; delegated 2026-10-05,
//! sibling consistency).
//!
//! These tests hold `human-action.resume`'s `nextAction` to `agent.resume`'s,
//! so the two cannot drift apart again, and validate each recorded
//! `agent.resume` answer of a running Job as a `human-action.resume` answer.
//! check-contracts' published view compiles this build against the merge
//! base's contract, which predates the widening: there only the drift is
//! reported, and nothing is asserted.
use arkdeck_contract::{METHOD_SCHEMAS, validate_method_value};
use serde_json::Value;
use std::path::Path;

fn schema(method: &str) -> Value {
    let (_, text) = METHOD_SCHEMAS
        .iter()
        .find(|(name, _)| *name == method)
        .unwrap();
    serde_json::from_str(text).unwrap()
}

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

fn next_action(method: &str) -> Value {
    schema(method)["$defs"]["result"]["properties"]["nextAction"].clone()
}

#[test]
fn human_action_resume_publishes_agent_resume_s_next_action() {
    let (agent, human) = (
        next_action("agent.resume"),
        next_action("human-action.resume"),
    );
    assert!(agent.is_object(), "agent.resume publishes a nextAction");
    if published_view() && agent != human {
        eprintln!("the merge base's human-action.resume nextAction differs: {human}");
        return;
    }
    assert_eq!(
        human, agent,
        "human-action.resume's nextAction is agent.resume's"
    );
}

#[test]
fn a_running_resume_conforms_as_a_human_action_resume_answer() {
    let running: Vec<Value> = frames("agent.resume")
        .into_iter()
        .filter(|frame| {
            frame["ok"] == true && frame["result"]["nextAction"]["retryAfter"].is_string()
        })
        .map(|frame| frame["result"].clone())
        .collect();
    assert!(!running.is_empty(), "a recorded resume of a running Job");
    for result in running {
        assert!(validate_method_value("agent.resume", "result", &result).is_ok());
        let conforms = validate_method_value("human-action.resume", "result", &result);
        if published_view() && conforms.is_err() {
            eprintln!("the merge base's human-action.resume refuses {result}");
            continue;
        }
        assert!(conforms.is_ok(), "{conforms:?}: {result}");
    }
}
