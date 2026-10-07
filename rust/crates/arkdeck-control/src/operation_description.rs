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

    // Preserve the historical Swift frames. CHG-2026-081 adds only these
    // three required read-only declarations to the Native descriptor; its
    // published-base view still compiles the original eleven declarations.
    fn native_descriptor_expectation(
        recorded: &Value,
        catalog: &str,
    ) -> Result<Value, &'static str> {
        if recorded["reference"] != "deploy.native-library.app-owned@1" {
            return Ok(recorded.clone());
        }
        match catalog {
            "c6e92eb252fe7653ed303a9ce34d12635bbc5f71ffb2a54fb8eb1fa3a9b99036" => {
                Ok(recorded.clone())
            }
            "e4e8a47cc4e9f6f099c9f4c47ef701fc928c20103cc42a23a46e887f624ab5f7" => {
                let old = recorded["steps"]
                    .as_array()
                    .ok_or("historical Native steps")?;
                if recorded["stepCount"] != 11
                    || old.len() != 11
                    || old[0]["stepId"] != "verify-elf-locally"
                    || old[1]["stepId"] != "hash-library"
                    || old[2]["stepId"] != "send-to-staging"
                    || old.iter().any(|step| {
                        matches!(
                            step["stepId"].as_str(),
                            Some(
                                "confirm-evidence-target"
                                    | "read-evidence-model"
                                    | "read-evidence-firmware"
                            )
                        )
                    })
                {
                    return Err("historical Native declaration shape changed");
                }
                let mut steps = old.clone();
                let prefix = [
                    ("confirm-evidence-target", "probeDevice", Value::Null),
                    ("read-evidence-model", "runApprovedRemoteRead", json!({"catalogId":"arkdeck-remote-operations","actionId":"deviceModel"})),
                    ("read-evidence-firmware", "runApprovedRemoteRead", json!({"catalogId":"arkdeck-remote-operations","actionId":"firmwareBuild"})),
                ].map(|(id, kind, action)| json!({
                    "stepId":id, "kind":kind, "effect":"readOnly", "cancellation":"immediate",
                    "binding":"confirmedDevice", "optional":false, "compensation":"none", "action":action
                }));
                steps.splice(2..2, prefix);
                let mut expected = recorded.clone();
                expected["steps"] = json!(steps);
                expected["stepCount"] = json!(14);
                Ok(expected)
            }
            _ => Err("unreviewed Native descriptor Catalog"),
        }
    }

    #[test]
    fn matches_actual_swift_descriptor_recordings_and_never_infers_availability() {
        let mut matched = std::collections::BTreeSet::new();
        for line in include_str!("../../../../Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames/operation.describe.jsonl").lines() {
            let row:Value=serde_json::from_str(line).unwrap();
            if row["ok"]!=true {continue;}
            let expected=native_descriptor_expectation(&row["result"], arkdeck_contract::CATALOG_DIGEST).unwrap();let reference=expected["reference"].as_str().unwrap();
            let availability=json!({"availability":expected["availability"],"reasons":expected["availabilityReasons"],
                "reasonCodes":expected["availabilityReasonCodes"],"reasonOrigins":expected["availabilityReasonOrigins"]});
            if let Some(actual)=describe(reference,&availability).unwrap() {
                assert_eq!(actual,expected,"{reference}");matched.insert(reference.to_owned());
            }
        }
        let catalog: Vec<Value> = serde_json::from_str(CATALOG_CANONICAL_JSON).unwrap();
        // Keep every historical representative and both Catalog additions.
        let has_keyboard = catalog.iter().any(|entry| entry["id"] == "input.keyboard");
        let has_session = catalog
            .iter()
            .any(|entry| entry["id"] == "capture.diagnostic-session");
        assert_eq!(
            matched.len(),
            24 + usize::from(has_keyboard) + usize::from(has_session)
        );
        assert_eq!(matched.contains("input.keyboard@1"), has_keyboard);
        assert_eq!(
            matched.contains("capture.diagnostic-session@1"),
            has_session
        );
        let mut invalid = Vec::new();
        for d in catalog {
            let reference = match d["version"].as_u64() {
                Some(v) => format!("{}@{v}", d["id"].as_str().unwrap()),
                None => d["id"].as_str().unwrap().into(),
            };
            let availability = json!({"availability":"unavailable","reasons":["provider is not registered"],
                "reasonCodes":["provider_not_registered"],"reasonOrigins":["product_build"]});
            let actual = describe(&reference, &availability).unwrap().unwrap();
            if let Some(directory) = std::env::var_os("ARKDECK_CATALOG_CONTRACT_RECORD") {
                use std::io::Write;
                std::fs::create_dir_all(&directory).unwrap();
                let path = std::path::PathBuf::from(directory).join("operation.describe.jsonl");
                let mut file = std::fs::OpenOptions::new()
                    .create(true)
                    .append(true)
                    .open(path)
                    .unwrap();
                writeln!(
                    file,
                    "{}",
                    json!({"method":"operation.describe", "protocolVersion":"1.0.0",
                    "params":{"reference":reference}, "ok":true, "result":actual})
                )
                .unwrap();
            }
            if let Err(error) =
                arkdeck_contract::validate_method_value("operation.describe", "result", &actual)
            {
                invalid.push(format!("{reference}: {error}"));
            }
            assert_eq!(actual["availability"], "unavailable");
        }
        assert!(invalid.is_empty(), "{}", invalid.join("; "));
        assert!(describe("unknown@1", &Value::Null).unwrap().is_none());
    }

    #[test]
    fn native_descriptor_delta_preserves_every_historical_field_and_declaration() {
        let frames = include_str!(
            "../../../../Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames/operation.describe.jsonl"
        );
        let native: Vec<Value> = frames
            .lines()
            .map(|line| serde_json::from_str::<Value>(line).unwrap())
            .filter(|row| {
                row["ok"] == true
                    && row["result"]["reference"] == "deploy.native-library.app-owned@1"
            })
            .map(|row| row["result"].clone())
            .collect();
        assert_eq!(native.len(), 2);
        for old in native {
            let mut current = native_descriptor_expectation(
                &old,
                "e4e8a47cc4e9f6f099c9f4c47ef701fc928c20103cc42a23a46e887f624ab5f7",
            )
            .unwrap();
            let steps = current["steps"].as_array_mut().unwrap();
            assert_eq!(steps.len(), 14);
            assert!(
                steps[2..5]
                    .iter()
                    .all(|step| step["effect"] == "readOnly" && step["optional"] == false)
            );
            steps.drain(2..5);
            current["stepCount"] = json!(11);
            assert_eq!(current, old);
            assert_eq!(
                native_descriptor_expectation(
                    &old,
                    "c6e92eb252fe7653ed303a9ce34d12635bbc5f71ffb2a54fb8eb1fa3a9b99036"
                )
                .unwrap(),
                old
            );
            assert!(native_descriptor_expectation(&old, &"0".repeat(64)).is_err());
            let mut drift = old.clone();
            drift["stepCount"] = json!(10);
            assert!(
                native_descriptor_expectation(
                    &drift,
                    "e4e8a47cc4e9f6f099c9f4c47ef701fc928c20103cc42a23a46e887f624ab5f7"
                )
                .is_err()
            );
            drift = old.clone();
            drift["steps"][2]["stepId"] = json!("different-mutation");
            assert!(
                native_descriptor_expectation(
                    &drift,
                    "e4e8a47cc4e9f6f099c9f4c47ef701fc928c20103cc42a23a46e887f624ab5f7"
                )
                .is_err()
            );
        }
    }
}
