//! Descriptor projection of the compiled published Catalog. Discovery does not
//! register a Provider or enable execution; availability comes from Control.
use arkdeck_contract::{CATALOG_CANONICAL_JSON, ContractError};
use serde_json::{Map, Value, json};
fn fields(value: &Value) -> Vec<Value> {
    value["fields"]
        .as_object()
        .expect("validated Catalog fields")
        .iter()
        .map(|(name, spec)| {
            let mut row = spec.as_object().expect("validated Catalog field").clone();
            row.insert("name".into(), json!(name));
            Value::Object(row)
        })
        .collect()
}
fn placeholder(field: &Value) -> Value {
    if let Some(value) = field.get("default") {
        return value.clone();
    }
    if let Some(value) = field
        .get("enum")
        .and_then(Value::as_array)
        .and_then(|v| v.first())
    {
        return value.clone();
    }
    match field["type"].as_str().expect("Catalog field type") {
        "integer" => field.get("minimum").cloned().unwrap_or(json!(1)),
        "boolean" => json!(false),
        "stringArray" => json!(["REPLACE_ME"]),
        "artifactLease" | "artifactReference" => json!("lease-v1:JOB-REPLACE-ME:ART-REPLACE-ME"),
        "artifactLeaseArray" => json!(["lease-v1:JOB-REPLACE-ME:ART-REPLACE-ME"]),
        _ => json!("REPLACE_ME"),
    }
}
pub(crate) fn describe(
    reference: &str,
    availability: &Value,
) -> Result<Option<Value>, ContractError> {
    let catalog: Vec<Value> =
        serde_json::from_str(CATALOG_CANONICAL_JSON).map_err(|_| ContractError::Malformed)?;
    let Some(d) = catalog.into_iter().find(|d| match d["version"].as_u64() {
        Some(v) => format!("{}@{v}", d["id"].as_str().unwrap()) == reference,
        None => d["id"] == reference,
    }) else {
        return Ok(None);
    };
    let inputs = fields(&d["inputs"]);
    let outputs = fields(&d["outputs"]);
    let mut target = json!({"targetId":"TGT-REPLACE-ME"});
    if d["binding"] == "confirmedDevice" {
        target["expectedBindingRevision"] = json!(1);
    }
    let mut operation = json!({"id":d["id"]});
    if let Some(version) = d.get("version") {
        operation["version"] = version.clone();
    }
    let example_inputs: Map<String, Value> = inputs
        .iter()
        .filter(|f| f["required"] == true)
        .map(|f| (f["name"].as_str().unwrap().into(), placeholder(f)))
        .collect();
    let steps:Vec<Value>=d["steps"].as_array().unwrap().iter().map(|s|json!({"stepId":s["stepID"],"kind":s["kind"],
        "effect":s["effect"],"cancellation":s["cancellation"],"binding":s["binding"],"optional":s.get("optional").unwrap_or(&json!(false)),
        "compensation":s["compensation"],"action":s.get("actionRef").unwrap_or(&Value::Null)})).collect();
    let artifacts: Vec<Value> = d["artifacts"]
        .as_array()
        .unwrap()
        .iter()
        .map(|a| {
            let mut a = a.clone();
            if a.get("retentionClass").is_none() {
                a["retentionClass"] = json!("default");
            }
            a
        })
        .collect();
    let recovery=d.get("completeOverwriteRecovery").map(|r|json!({"contractVersion":r["contractVersion"],
        "overwriteStepId":r["overwriteStepID"],"verificationStepIds":r["verificationStepIDs"],"profiles":r["profiles"]})).unwrap_or(Value::Null);
    let concurrency = match d["concurrencyKey"].as_str().unwrap() {
        "device-exclusive" => "deviceExclusive",
        "device-shared-readonly" => "deviceSharedReadOnly",
        _ => "hostExclusive",
    };
    let effects = ["hostOnly", "readOnly", "deviceMutation", "destructive"];
    let mut permitted = d["effect"]["permitted"].as_array().unwrap().clone();
    permitted.sort_by_key(|e| effects.iter().position(|v| e == v).unwrap());
    Ok(Some(
        json!({"reference":reference,"title":d["title"],"provider":d["provider"],"minimumEffect":d["effect"]["minimum"],
        "binding":d["binding"],"timeoutSeconds":d["timeoutSeconds"],"stepCount":steps.len(),
        "availability":availability["availability"],"availabilityReasons":availability["reasons"],
        "availabilityReasonCodes":availability["reasonCodes"],"availabilityReasonOrigins":availability["reasonOrigins"],
        "inputs":inputs,"outputs":outputs,"exampleRequest":{"schemaVersion":"1.0.0","documentType":"runtime-operation-request",
            "requestId":"req-example","idempotencyKey":"idem-example-0001","target":target,"operation":operation,
            "inputs":example_inputs,"requestedOutputs":["derivedArtifacts"]},
        "aliasFor":d.get("aliasFor").unwrap_or(&Value::Null),"permittedEffects":permitted,"authorization":d["authorization"],
        "defaultPolicyIssuanceEnabled":d.get("defaultPolicyIssuance").is_none_or(|v|v=="enabled"),
        "concurrencyKey":concurrency,"outputByteBudget":d["outputByteBudget"],"preflightAttempts":d["retry"]["preflightAttempts"],
        "profiles":d["profiles"],"steps":steps,"artifacts":artifacts,"completeOverwriteRecovery":recovery}),
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn matches_actual_swift_descriptor_recordings_and_never_infers_availability() {
        let mut matched = std::collections::BTreeSet::new();
        for line in include_str!("../../../../Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames/operation.describe.jsonl").lines() {
            let row:Value=serde_json::from_str(line).unwrap();
            if row["ok"]!=true {continue;}
            let expected=&row["result"];let reference=expected["reference"].as_str().unwrap();
            let availability=json!({"availability":expected["availability"],"reasons":expected["availabilityReasons"],
                "reasonCodes":expected["availabilityReasonCodes"],"reasonOrigins":expected["availabilityReasonOrigins"]});
            if let Some(actual)=describe(reference,&availability).unwrap() {
                assert_eq!(&actual,expected,"{reference}");matched.insert(reference.to_owned());
            }
        }
        // The schema corpus retains 24 representative signatures, not every
        // Catalog reference. Every retained real result must compare equal.
        assert_eq!(matched.len(), 24);
        let catalog: Vec<Value> = serde_json::from_str(CATALOG_CANONICAL_JSON).unwrap();
        for d in catalog {
            let reference = match d["version"].as_u64() {
                Some(v) => format!("{}@{v}", d["id"].as_str().unwrap()),
                None => d["id"].as_str().unwrap().into(),
            };
            let availability = json!({"availability":"unavailable","reasons":["provider is not registered"],
                "reasonCodes":["provider_not_registered"],"reasonOrigins":["product_build"]});
            let actual = describe(&reference, &availability).unwrap().unwrap();
            arkdeck_contract::validate_method_value("operation.describe", "result", &actual)
                .unwrap();
            assert_eq!(actual["availability"], "unavailable");
        }
        assert!(describe("unknown@1", &Value::Null).unwrap().is_none());
    }
}
