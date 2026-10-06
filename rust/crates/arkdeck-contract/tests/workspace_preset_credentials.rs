//! A signing preset retains the registration owner's credential projection on
//! every existing preset result surface, without opening other record fields.
use arkdeck_contract::{METHOD_SCHEMAS, validate_method_value};
use serde_json::{Value, json};

const CONSUMERS: [&str; 4] = [
    "workspace.preset.list",
    "workspace.preset.show",
    "workspace.preset.update",
    "workspace.preset.remove",
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

fn signing() -> Value {
    include_str!(
        "../../../../Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames/workspace.preset.register.jsonl"
    )
    .lines()
    .map(|line| serde_json::from_str::<Value>(line).unwrap())
    .find(|frame| frame["ok"] == true && frame["result"]["kind"] == "signing")
    .expect("a recorded signing registration")["result"]
        .clone()
}

fn answer(method: &str, preset: Value) -> Value {
    if method != "workspace.preset.list" {
        return preset;
    }
    json!({"schemaVersion": "arkdeck.workspace-preset-list/1",
           "projectRef": preset["projectRef"], "presets": [preset]})
}

#[test]
fn consumers_publish_registration_credential_type_and_keep_old_view_refusal() {
    let credential =
        schema("workspace.preset.register")["$defs"]["result"]["properties"]["credentialRef"]
            .clone();
    assert_eq!(credential, json!({"type": ["null", "string"]}));
    for method in CONSUMERS {
        let schema = schema(method);
        let mut preset = &schema["$defs"]["result"];
        if method == "workspace.preset.list" {
            preset = &preset["properties"]["presets"]["items"];
        }
        let actual = &preset["properties"]["credentialRef"];
        if published_view() && actual == &json!({"type": "null"}) {
            assert!(validate_method_value(method, "result", &answer(method, signing())).is_err());
        } else {
            assert_eq!(actual, &credential, "{method}");
            assert!(validate_method_value(method, "result", &answer(method, signing())).is_ok());
        }
        assert_eq!(preset["additionalProperties"], false);
        assert!(
            preset["required"]
                .as_array()
                .unwrap()
                .contains(&json!("credentialRef"))
        );
    }
}

#[test]
fn existing_recorded_null_presets_still_conform() {
    for line in include_str!(
        "../../../../Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames/workspace.preset.list.jsonl"
    )
    .lines()
    {
        let frame: Value = serde_json::from_str(line).unwrap();
        if frame["ok"] == true {
            assert!(validate_method_value("workspace.preset.list", "result", &frame["result"]).is_ok());
        }
    }
    assert!(validate_method_value("workspace.preset.register", "result", &signing()).is_ok());
}

#[test]
fn malformed_missing_credentials_and_unknown_record_fields_still_refuse() {
    for method in CONSUMERS {
        for value in [json!(false), json!(1), json!([]), json!({})] {
            let mut preset = signing();
            preset["credentialRef"] = value;
            assert!(validate_method_value(method, "result", &answer(method, preset)).is_err());
        }
        let mut preset = signing();
        preset.as_object_mut().unwrap().remove("credentialRef");
        assert!(validate_method_value(method, "result", &answer(method, preset)).is_err());
        let mut preset = signing();
        preset["unknownCredentialProof"] = json!("not a published field");
        assert!(validate_method_value(method, "result", &answer(method, preset)).is_err());
    }
}
