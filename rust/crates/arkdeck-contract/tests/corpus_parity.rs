use std::collections::BTreeSet;
use std::fs;

use arkdeck_contract::{
    CONTRACT_IDENTITY, DeviceObservationsRequest, DeviceObservationsResult, DoctorRequest,
    DoctorResult, HealthRequest, HealthResult, MAX_REQUEST_BYTES, MAX_RESPONSE_BYTES,
    METHOD_SCHEMAS, METHODS, OperationListRequest, OperationListResult, PROTOCOL_VERSION, Request,
    SWIFT_BASELINE, decode_request, decode_response, encode_frame, sha256_hex, strict_json,
    validate_health, validate_method_value,
};
use serde::{Serialize, de::DeserializeOwned};
use serde_json::{Value, json};

#[path = "common/mod.rs"]
mod common;

fn corpus(method: &str) -> Vec<Value> {
    let bytes = fs::read(common::repo_root().join(format!(
        "Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames/{method}.jsonl"
    )))
    .unwrap();
    assert_eq!(bytes.last(), Some(&b'\n'), "{method}: torn corpus tail");
    bytes[..bytes.len() - 1]
        .split(|byte| *byte == b'\n')
        .map(|line| strict_json(line).unwrap())
        .collect()
}

fn wire_response(row: &Value, id: &str) -> Value {
    if row["ok"] == true {
        json!({"id": id, "ok": true, "result": row["result"]})
    } else {
        json!({"id": id, "ok": false, "error": row["error"]})
    }
}

#[test]
fn all_96_methods_and_all_378_recorded_shapes_replay_through_rust() {
    let registry = common::load_json("Packages/ArkDeckKit/Contracts/control-protocol.json");
    assert_eq!(METHODS.len(), 96);
    assert_eq!(METHOD_SCHEMAS.len(), METHODS.len());
    assert_eq!(serde_json::to_value(METHODS).unwrap(), registry["methods"]);
    let files = fs::read_dir(
        common::repo_root()
            .join("Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames"),
    )
    .unwrap()
    .map(|entry| entry.unwrap().path())
    .filter(|path| path.extension().is_some_and(|ext| ext == "jsonl"))
    .map(|path| path.file_stem().unwrap().to_str().unwrap().to_owned())
    .collect::<BTreeSet<_>>();
    assert_eq!(
        files,
        METHODS.iter().map(|method| (*method).to_owned()).collect()
    );
    assert_eq!(
        METHOD_SCHEMAS
            .iter()
            .map(|(method, _)| *method)
            .collect::<BTreeSet<_>>(),
        METHODS.iter().copied().collect::<BTreeSet<_>>()
    );
    let mut requests = 0;
    let mut successes = 0;
    let mut failures = 0;
    for method in METHODS {
        let rows = corpus(method);
        assert!(!rows.is_empty(), "no corpus for {method}");
        for (index, row) in rows.into_iter().enumerate() {
            assert_eq!(row["method"], *method);
            assert_eq!(row["protocolVersion"], PROTOCOL_VERSION);
            let params = row.get("params").cloned().unwrap_or_else(|| json!({}));
            validate_method_value(method, "request", &params)
                .unwrap_or_else(|error| panic!("{method} row {index} request: {error}"));
            // The committed recording intentionally omits transport IDs and
            // handshake identity. Rebuild those envelope fields explicitly;
            // this replays the corpus, not a new live-frame recording.
            let id = format!("corpus-{index}");
            let request = Request::new(&id, *method, Some(params.as_object().unwrap().clone()));
            let request_bytes = encode_frame(&request, MAX_REQUEST_BYTES).unwrap();
            assert_eq!(
                decode_request(&request_bytes[..request_bytes.len() - 1]).unwrap(),
                request
            );
            requests += 1;
            if row["ok"] == true {
                successes += 1;
                validate_method_value(method, "result", &row["result"])
                    .unwrap_or_else(|error| panic!("{method} row {index} result: {error}"));
            } else {
                failures += 1;
                validate_method_value(method, "errorCode", &row["error"]["code"])
                    .unwrap_or_else(|error| panic!("{method} row {index} error code: {error}"));
                if let Some(details) = row["error"].get("details") {
                    validate_method_value(method, "errorDetails", details).unwrap_or_else(
                        |error| panic!("{method} row {index} error details: {error}"),
                    );
                }
            }
            let response_value = wire_response(&row, &id);
            let response_bytes = encode_frame(&response_value, MAX_RESPONSE_BYTES).unwrap();
            let response =
                decode_response(&response_bytes[..response_bytes.len() - 1], &id, method)
                    .unwrap_or_else(|error| {
                        panic!("{method} row {index} response envelope: {error}")
                    });
            assert_eq!(response.value(), response_value);
            if *method == "health" {
                validate_health(&response).unwrap();
            }
        }
    }
    assert_eq!((requests, successes, failures), (378, 214, 164));
}

fn typed_roundtrip<T: DeserializeOwned + Serialize>(value: &Value) {
    let typed: T = serde_json::from_value(value.clone()).unwrap();
    assert_eq!(serde_json::to_value(typed).unwrap(), *value);
    if let Some(object) = value.as_object() {
        let mut extra = object.clone();
        extra.insert("__unpublishedField".into(), json!(true));
        assert!(serde_json::from_value::<T>(Value::Object(extra)).is_err());
    }
}

#[test]
fn generated_read_only_types_preserve_all_current_recorded_values() {
    let mut count = 0;
    for method in ["health", "doctor", "operation.list", "device.observations"] {
        for row in corpus(method) {
            let params = row.get("params").cloned().unwrap_or_else(|| json!({}));
            match method {
                "health" => typed_roundtrip::<HealthRequest>(&params),
                "doctor" => typed_roundtrip::<DoctorRequest>(&params),
                "operation.list" => typed_roundtrip::<OperationListRequest>(&params),
                "device.observations" => typed_roundtrip::<DeviceObservationsRequest>(&params),
                _ => unreachable!(),
            }
            if row["ok"] == true {
                match method {
                    "health" => typed_roundtrip::<HealthResult>(&row["result"]),
                    "doctor" => typed_roundtrip::<DoctorResult>(&row["result"]),
                    "operation.list" => typed_roundtrip::<OperationListResult>(&row["result"]),
                    "device.observations" => {
                        typed_roundtrip::<DeviceObservationsResult>(&row["result"])
                    }
                    _ => unreachable!(),
                }
                count += 1;
            }
        }
    }
    assert_eq!(count, 17, "successful results across all four methods");
}

fn required_nullable_fields<T: DeserializeOwned + Serialize>(method: &str, pointers: &[&str]) {
    let results = corpus(method)
        .into_iter()
        .filter(|row| row["ok"] == true)
        .map(|row| row["result"].clone())
        .collect::<Vec<_>>();
    for pointer in pointers {
        let result = results
            .iter()
            .find(|result| result.pointer(pointer).is_some())
            .unwrap_or_else(|| panic!("{method}: no recorded value at {pointer}"));
        let mut explicit_null = result.clone();
        *explicit_null.pointer_mut(pointer).unwrap() = Value::Null;
        validate_method_value(method, "result", &explicit_null).unwrap();
        typed_roundtrip::<T>(&explicit_null);

        let mut missing = result.clone();
        let (parent, key) = pointer.rsplit_once('/').unwrap();
        missing
            .pointer_mut(parent)
            .unwrap()
            .as_object_mut()
            .unwrap()
            .remove(key);
        assert!(
            validate_method_value(method, "result", &missing).is_err(),
            "{method}: schema accepted missing required field {pointer}"
        );
        assert!(
            serde_json::from_value::<T>(missing).is_err(),
            "{method}: generated type accepted missing required field {pointer}"
        );
    }
}

#[test]
fn generated_types_distinguish_required_null_from_missing_fields() {
    required_nullable_fields::<DoctorResult>(
        "doctor",
        &[
            "/checks/recovery/outstandingCleanupCount",
            "/checks/storage/runtimeArtifacts/remainingBytes",
            "/checks/storage/runtimeArtifacts/totalBytes",
            "/checks/storage/runtimeArtifacts/usedBytes",
            "/checks/target/adoptedTargetCount",
        ],
    );
    required_nullable_fields::<OperationListResult>("operation.list", &["/0/aliasFor"]);
    required_nullable_fields::<DeviceObservationsResult>(
        "device.observations",
        &[
            "/observations/0/adoptedTargetId",
            "/observations/0/bindingRevision",
            "/observations/0/deviceInformation",
            "/observations/0/displayName",
        ],
    );
}

#[test]
fn actual_step_kinds_null_is_preserved_and_other_shapes_are_rejected() {
    for (method, pointer) in [
        ("agent.run", "/evidence/actualStepKinds"),
        ("agent.status", "/evidence/actualStepKinds"),
        ("job.evidence", "/actualStepKinds"),
        ("job.result", "/evidence/actualStepKinds"),
        ("job.show", "/actualStepKinds"),
    ] {
        let results = corpus(method)
            .into_iter()
            .filter(|row| row["ok"] == true)
            .map(|row| row["result"].clone())
            .collect::<Vec<_>>();
        let result = results
            .iter()
            .find(|result| result.pointer(pointer) == Some(&Value::Null))
            .unwrap_or_else(|| panic!("{method}: current corpus lost its unknown-step case"));
        validate_method_value(method, "result", result).unwrap();
        let encoded =
            serde_json::to_vec(&json!({"id":"unknown-steps","ok":true,"result":result})).unwrap();
        let decoded = decode_response(&encoded, "unknown-steps", method).unwrap();
        assert_eq!(
            decoded.outcome.unwrap().pointer(pointer),
            Some(&Value::Null)
        );
        assert!(
            results
                .iter()
                .any(|value| value.pointer(pointer).is_some_and(Value::is_array)),
            "{method}: the known-step array case must remain covered too"
        );
        for invalid in [
            json!(false),
            json!(0),
            json!("unknown"),
            json!({}),
            json!([null]),
            json!(["a", 1]),
        ] {
            let mut malformed = result.clone();
            *malformed.pointer_mut(pointer).unwrap() = invalid;
            assert!(
                validate_method_value(method, "result", &malformed).is_err(),
                "{method}: malformed actualStepKinds"
            );
        }
        let mut omitted = result.clone();
        let parent = pointer.strip_suffix("/actualStepKinds").unwrap();
        omitted
            .pointer_mut(parent)
            .unwrap()
            .as_object_mut()
            .unwrap()
            .remove("actualStepKinds");
        assert!(
            validate_method_value(method, "result", &omitted).is_err(),
            "{method}: missing required actualStepKinds"
        );
    }
}

#[test]
fn current_schema_closure_rejects_unpublished_fields_in_every_method() {
    for method in METHODS {
        for row in corpus(method) {
            let mut request = row.get("params").cloned().unwrap_or_else(|| json!({}));
            request
                .as_object_mut()
                .unwrap()
                .insert("__unpublishedField".into(), json!(true));
            assert!(
                validate_method_value(method, "request", &request).is_err(),
                "{method} request closure"
            );
            if row["ok"] == true {
                let mut result = row["result"].clone();
                if let Some(object) = result.as_object_mut() {
                    object.insert("__unpublishedField".into(), json!(true));
                    assert!(
                        validate_method_value(method, "result", &result).is_err(),
                        "{method} result closure"
                    );
                }
            } else if let Some(mut details) = row["error"].get("details").cloned() {
                details
                    .as_object_mut()
                    .unwrap()
                    .insert("__unpublishedField".into(), json!(true));
                assert!(
                    validate_method_value(method, "errorDetails", &details).is_err(),
                    "{method} error closure"
                );
            }
        }
    }
}

#[test]
fn pinned_swift_source_schema_and_corpus_files_match_the_development_baseline() {
    let baseline = strict_json(SWIFT_BASELINE.as_bytes()).unwrap();
    assert_eq!(baseline["kind"], "development");
    assert_eq!(
        baseline["schemaVersion"],
        "arkdeck.swift-development-baseline/1"
    );
    assert_eq!(baseline["protocolVersion"], PROTOCOL_VERSION);
    assert_eq!(baseline["contractIdentity"], CONTRACT_IDENTITY);
    assert_eq!(baseline["methodCount"], METHODS.len());
    assert_eq!(baseline["corpusFileCount"], 96);
    let commit = baseline["commit"].as_str().unwrap();
    assert_eq!(commit.len(), 40);
    assert!(
        commit
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
    );
    let files = baseline["files"].as_object().unwrap();
    for (path, pin) in files {
        assert_eq!(
            sha256_hex(&fs::read(common::repo_root().join(path)).unwrap()),
            pin["sha256"],
            "pinned file drift: {path}"
        );
        assert_eq!(
            pin["blob"].as_str().unwrap().len(),
            40,
            "full blob pin for {path}"
        );
    }
    for (directory, expected) in baseline["directoryDigests"].as_object().unwrap() {
        let prefix = format!("{directory}/");
        let mut entries = files
            .iter()
            .filter(|(path, _)| path.starts_with(&prefix))
            .map(|(path, pin)| format!("{} {path}\n", pin["blob"].as_str().unwrap()))
            .collect::<Vec<_>>();
        entries.sort();
        assert!(!entries.is_empty());
        assert_eq!(
            sha256_hex(entries.concat().as_bytes()),
            *expected,
            "directory hash closure: {directory}"
        );
    }
}
