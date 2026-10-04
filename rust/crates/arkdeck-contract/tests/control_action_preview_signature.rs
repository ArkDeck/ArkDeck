//! A control action's preview tool signature is one projection
//! (`HDCControlActionRecord`), published by `runtime.hdc.impact-preview`,
//! `runtime.hdc.restart` and `control-action.*` with an identifier and a team
//! each a string or null, and carried twice by `human-action.resume`: as the
//! console challenge's `controlAction` and as the consumed action's preview.
//! Those two copies admitted only a string identifier and a null team (the
//! values Swift's fixture tool happened to record), so the challenge of an
//! unsigned tool — DevEco's Windows `hdc.exe`, Authenticode NotSigned, whose
//! signature reads `identifier: null` — became `internalError` and no Windows
//! restart could be approved (TASK-XPA-005; delegated 2026-10-04, sibling
//! consistency, no Swift oracle records an unsigned tool).
//!
//! These tests hold the copies to the sibling definition, so they cannot
//! drift apart again, and graft an unsigned signature into recorded answers.
//! check-contracts' published view compiles this build against the merge
//! base's contract, which predates the widening: there only the drift is
//! reported, and nothing is asserted.
use arkdeck_contract::{METHOD_SCHEMAS, validate_method_value};
use serde_json::{Value, json};
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

/// Every schema object under `value` that describes a preview's `tool`
/// signature: the `signature` member of an object schema with `tool`-shaped
/// properties (`executablePath`, `sha256`, `signature`).
fn tool_signatures(value: &Value, found: &mut Vec<Value>) {
    match value {
        Value::Object(map) => {
            if let Some(properties) = map.get("properties").and_then(Value::as_object)
                && properties.contains_key("executablePath")
                && properties.contains_key("sha256")
                && let Some(signature) = properties.get("signature")
            {
                found.push(signature.clone());
            }
            for child in map.values() {
                tool_signatures(child, found);
            }
        }
        Value::Array(items) => {
            for child in items {
                tool_signatures(child, found);
            }
        }
        _ => {}
    }
}

fn signatures(method: &str) -> Vec<Value> {
    let mut found = Vec::new();
    tool_signatures(&schema(method)["$defs"]["result"], &mut found);
    found
}

#[test]
fn every_copy_of_the_preview_tool_signature_is_the_sibling_definition() {
    let sibling = signatures("runtime.hdc.impact-preview");
    assert_eq!(sibling.len(), 1, "{sibling:#?}");
    let sibling = &sibling[0];
    assert_eq!(
        sibling["anyOf"][0]["properties"]["identifier"],
        json!({"type": ["null", "string"]})
    );
    let mut drifted = Vec::new();
    for method in [
        "runtime.hdc.restart",
        "control-action.show",
        "control-action.list",
        "control-action.reconcile",
        "human-action.resume",
    ] {
        let copies = signatures(method);
        assert!(!copies.is_empty(), "{method} carries no preview tool");
        for copy in copies {
            if &copy != sibling {
                drifted.push(format!("{method}: {copy}"));
            }
        }
    }
    if published_view() {
        eprintln!("published view: {drifted:#?}");
        return;
    }
    assert!(drifted.is_empty(), "drifted: {drifted:#?}");
}

/// The console challenge and the consumed action of `human-action.resume`,
/// as recorded, admit an unsigned tool's signature.
#[test]
fn an_unsigned_tool_s_challenge_and_consumed_action_conform() {
    let unsigned = json!({"executionAssessment": "notPerformed", "identifier": null,
        "platformTrust": "unverified", "state": "unsigned", "teamIdentifier": null});
    let mut checked = 0;
    let mut refused = Vec::new();
    for frame in frames("human-action.resume") {
        if frame["ok"] != true {
            continue;
        }
        for pointer in [
            "/controlAction/preview/tool/signature",
            "/preview/tool/signature",
        ] {
            let mut answer = frame["result"].clone();
            let Some(slot) = answer.pointer_mut(pointer) else {
                continue;
            };
            if !slot.is_object() {
                continue;
            }
            *slot = unsigned.clone();
            checked += 1;
            if validate_method_value("human-action.resume", "result", &answer).is_err() {
                refused.push(pointer);
            }
        }
    }
    assert!(checked >= 2, "recorded answers carry both copies");
    if published_view() {
        return;
    }
    assert!(refused.is_empty(), "refused: {refused:?}");
}
