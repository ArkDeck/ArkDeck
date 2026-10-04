//! Replay the recorded host facts against an extended compiled Catalog.
//! New operations are unavailable on these recorded hosts; all existing
//! readiness, blocker, provider and storage assertions remain exact.
use serde_json::{Value, json};

pub fn current_catalog_report(recorded: &Value) -> Value {
    let mut expected = recorded.clone();
    let catalog: Vec<Value> =
        serde_json::from_str(arkdeck_contract::CATALOG_CANONICAL_JSON).unwrap();
    let count = catalog.len() as u64;
    let baseline = expected["checks"]["catalog"]["operationCount"]
        .as_u64()
        .unwrap();
    assert_eq!(baseline, 30);
    let additional = count.checked_sub(baseline).unwrap();
    let unavailable = expected["checks"]["catalog"]["unavailableOperationCount"]
        .as_u64()
        .unwrap()
        + additional;
    expected["checks"]["catalog"]["digest"] = json!(arkdeck_contract::CATALOG_DIGEST);
    expected["checks"]["catalog"]["operationCount"] = json!(count);
    expected["checks"]["catalog"]["unavailableOperationCount"] = json!(unavailable);
    for finding in expected["findings"].as_array_mut().unwrap() {
        if finding["code"] == "catalog.unavailableOperations" {
            finding["details"]["unavailableOperationCount"] = json!(unavailable);
        }
    }
    expected
}
