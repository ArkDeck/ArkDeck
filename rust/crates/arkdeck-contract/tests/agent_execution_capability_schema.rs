//! Keep the macOS process test's capability-schema detector exercised on every
//! host: human-action resumes may carry either an execution or a tool action.
use arkdeck_contract::{CONTRACT_INPUTS, METHOD_SCHEMAS};
use serde_json::{Value, json};

mod capability_schema {
    include!("../../../tests/support/agent_execution_capability_schema.rs");
}

fn schema(method: &str) -> Value {
    let (_, text) = METHOD_SCHEMAS
        .iter()
        .find(|(name, _)| *name == method)
        .unwrap();
    serde_json::from_str(text).unwrap()
}

fn published_view() -> bool {
    let inputs: Value = serde_json::from_str(CONTRACT_INPUTS).unwrap();
    inputs["kind"] == "development" && inputs.get("commit").is_some()
}

#[test]
fn every_resumed_execution_finds_its_capability_without_an_artifact() {
    // Match the process test's existing old-view behavior: an old status
    // schema can refuse this capability; current inputs must publish it.
    if !capability_schema::publishes_capability_without_artifact(&schema("agent.status")) {
        assert!(
            published_view(),
            "current agent.status publishes an artifact-free capability"
        );
        return;
    }
    for method in [
        "agent.run",
        "agent.status",
        "agent.resume",
        "human-action.resume",
    ] {
        assert!(
            capability_schema::publishes_capability_without_artifact(&schema(method)),
            "{method}"
        );
    }
}

#[test]
fn execution_detection_is_independent_of_union_order_and_keeps_nullability() {
    let execution_schema = schema("agent.resume");
    let execution = execution_schema["$defs"]["result"].clone();
    let selection = schema("runtime.tool.select")["$defs"]["result"].clone();
    let published = capability_schema::publishes_capability_without_artifact(&execution_schema);
    for alternatives in [json!([execution, selection]), json!([selection, execution])] {
        let union = json!({"$defs":{"result":{"anyOf":alternatives}}});
        assert_eq!(
            capability_schema::publishes_capability_without_artifact(&union),
            published
        );
    }
    // Absence of Artifact authority remains a typed schema fact; the new
    // execution branch must not make a non-nullable authority look nullable.
    let capability = |types: Value| {
        json!({"$defs":{"result":{"anyOf":[
            {"properties":{"executionId":{"type":"string"},"evidence":{"properties":{
                "authority":{"properties":{"artifactDigest":{"type":types}}}
            }}}}, selection
        ]}}})
    };
    assert!(!capability_schema::publishes_capability_without_artifact(
        &capability(json!(["string"]))
    ));
    assert!(capability_schema::publishes_capability_without_artifact(
        &capability(json!(["null", "string"]))
    ));
}
