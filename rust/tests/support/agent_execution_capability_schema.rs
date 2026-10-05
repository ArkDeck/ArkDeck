use serde_json::{Value, json};

/// Whether an agent-execution result publishes a Runtime capability whose
/// authority names no Artifact. Union results also carry tool-selection actions.
pub fn publishes_capability_without_artifact(schema: &Value) -> bool {
    let result = &schema["$defs"]["result"];
    let execution = result
        .get("anyOf")
        .and_then(Value::as_array)
        .map(|alternatives| {
            let executions: Vec<_> = alternatives
                .iter()
                .filter(|alternative| alternative["properties"]["executionId"].is_object())
                .collect();
            assert_eq!(
                executions.len(),
                1,
                "one agent-execution result alternative"
            );
            executions[0]
        })
        .unwrap_or(result);
    let authority = &execution["properties"]["evidence"]["properties"]["authority"];
    let branches = match authority["anyOf"].as_array() {
        Some(branches) => branches.clone(),
        None => vec![authority.clone()],
    };
    branches.iter().any(|branch| {
        branch["properties"]["artifactDigest"]["type"]
            .as_array()
            .is_some_and(|types| types.contains(&json!("null")))
    })
}
