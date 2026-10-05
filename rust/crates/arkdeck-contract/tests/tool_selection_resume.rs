//! Tool-selection actions keep their own closed projection when a foreground
//! human-action resume carries the challenge or returns the consumed action,
//! and the union control-action owner lists, shows or reconciles that action.
use arkdeck_contract::{METHOD_SCHEMAS, validate_method_value};
use serde_json::{Value, json};

const ACTION_SURFACES: [&str; 4] = [
    "human-action.resume",
    "control-action.show",
    "control-action.reconcile",
    "control-action.list",
];

fn schema(method: &str) -> Value {
    let (_, text) = METHOD_SCHEMAS
        .iter()
        .find(|(name, _)| *name == method)
        .unwrap();
    serde_json::from_str(text).unwrap()
}

fn published_view() -> bool {
    let inputs: Value = serde_json::from_str(arkdeck_contract::CONTRACT_INPUTS).unwrap();
    inputs["kind"] == "development" && inputs.get("commit").is_some()
}

fn projections() -> Vec<Value> {
    serde_json::from_str(include_str!(
        "../../../tests/fixtures/tool-selection-store/projections.json"
    ))
    .unwrap()
}

fn answer(method: &str, selection: &Value) -> Value {
    if method != "control-action.list" {
        return selection.clone();
    }
    let mut page = include_str!(
        "../../../../Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames/control-action.list.jsonl"
    )
    .lines()
    .map(|line| serde_json::from_str::<Value>(line).unwrap())
    .find(|frame| frame["ok"] == true)
    .expect("a recorded control-action list page")["result"]
        .clone();
    page["items"] = json!([selection]);
    page
}

#[test]
fn every_selection_alternative_is_exactly_the_published_select_result() {
    let select = schema("runtime.tool.select")["$defs"]["result"].clone();
    let resume = schema("human-action.resume");
    let result = &resume["$defs"]["result"];
    if published_view() && result.get("anyOf").is_none() {
        eprintln!("the merge base has no resumed tool-selection result alternative");
        return;
    }
    assert_eq!(result["anyOf"].as_array().unwrap().len(), 2);
    assert_eq!(result["anyOf"][1], select);
    let challenge = &result["anyOf"][0]["properties"]["controlAction"];
    assert_eq!(challenge["anyOf"].as_array().unwrap().len(), 2);
    assert_eq!(challenge["anyOf"][1], select);
    for method in [
        "control-action.show",
        "control-action.reconcile",
        "control-action.list",
    ] {
        let method_schema = schema(method);
        let mut action = &method_schema["$defs"]["result"];
        if method == "control-action.list" {
            action = &action["properties"]["items"]["items"];
        }
        assert_eq!(action["anyOf"].as_array().unwrap().len(), 2, "{method}");
        assert_eq!(action["anyOf"][1], select, "{method}");
    }
}

#[test]
fn swift_selection_projections_conform_on_every_action_surface_and_remain_closed() {
    let projections = projections();
    for projection in &projections {
        assert!(validate_method_value("runtime.tool.select", "result", projection).is_ok());
        for method in ACTION_SURFACES {
            let conforms = validate_method_value(method, "result", &answer(method, projection));
            if published_view() && conforms.is_err() {
                continue;
            }
            assert!(conforms.is_ok(), "{method}: {conforms:?}: {projection}");
        }
    }
    if published_view() {
        return;
    }
    let selection = projections
        .iter()
        .find(|projection| projection["state"] == "awaitingImpactApproval")
        .unwrap();
    let mut challenge = include_str!(
        "../../../../Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames/human-action.resume.jsonl"
    )
    .lines()
    .map(|line| serde_json::from_str::<Value>(line).unwrap())
    .find(|frame| frame["ok"] == true && frame["result"]["controlAction"].is_object())
    .expect("a recorded foreground-console challenge")["result"]
        .clone();
    challenge["controlAction"] = selection.clone();
    assert!(validate_method_value("human-action.resume", "result", &challenge).is_ok());
    let refused = |selection: Value| {
        for method in ACTION_SURFACES {
            assert!(
                validate_method_value(method, "result", &answer(method, &selection)).is_err(),
                "{method}"
            );
        }
        let mut nested = challenge.clone();
        nested["controlAction"] = selection;
        assert!(validate_method_value("human-action.resume", "result", &nested).is_err());
    };
    // These belong to the agent-execution owner; reusing its shared samples
    // while inferring selection would silently widen this closed projection.
    let mut changed = selection.clone();
    changed["humanAction"]["selectionSchema"] = json!({"type":"string","enum":["candidate"]});
    refused(changed);
    for field in ["retryAfter", "expiresAt", "resumeReference"] {
        let mut changed = selection.clone();
        changed["nextAction"][field] = json!("unpublished");
        refused(changed);
    }
    let mut changed = selection.clone();
    changed["preview"]["unregisteredFact"] = json!(true);
    refused(changed);
}
