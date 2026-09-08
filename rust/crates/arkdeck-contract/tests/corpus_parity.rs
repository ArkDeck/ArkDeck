use std::collections::BTreeSet;
use std::fs;

use arkdeck_contract::{
    CONTRACT_IDENTITY, CONTRACT_INPUTS, DeviceObservationsRequest, DeviceObservationsResult,
    DoctorRequest, DoctorResult, HealthRequest, HealthResult, MAX_REQUEST_BYTES,
    MAX_RESPONSE_BYTES, METHOD_SCHEMAS, METHODS, OperationListRequest, OperationListResult,
    PROTOCOL_VERSION, Request, SWIFT_BASELINE, decode_request, decode_response, encode_frame,
    sha256_hex, strict_json, validate_health, validate_method_value,
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
fn all_methods_and_recorded_shapes_in_the_input_manifest_replay_through_rust() {
    let inputs = strict_json(CONTRACT_INPUTS.as_bytes()).unwrap();
    let registry = common::load_json("Packages/ArkDeckKit/Contracts/control-protocol.json");
    assert_eq!(inputs["methodCount"], METHODS.len());
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
    assert_eq!(inputs["corpusFileCount"], files.len());
    let expected_counts = inputs["corpusMethodCounts"].as_object().unwrap();
    assert_eq!(
        expected_counts
            .keys()
            .map(String::as_str)
            .collect::<BTreeSet<_>>(),
        METHODS.iter().copied().collect()
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
        let mut method_requests = 0_u64;
        let mut method_successes = 0_u64;
        let mut method_errors = 0_u64;
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
            method_requests += 1;
            if row["ok"] == true {
                method_successes += 1;
                validate_method_value(method, "result", &row["result"])
                    .unwrap_or_else(|error| panic!("{method} row {index} result: {error}"));
            } else {
                method_errors += 1;
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
        assert_eq!(
            json!({"requests": method_requests, "successes": method_successes, "errors": method_errors}),
            expected_counts[*method],
            "recorded shape counts: {method}"
        );
        requests += method_requests;
        successes += method_successes;
        failures += method_errors;
    }
    assert_eq!(
        json!({"requests": requests, "successes": successes, "errors": failures}),
        inputs["corpusRecordCounts"]
    );
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
    let inputs = strict_json(CONTRACT_INPUTS.as_bytes()).unwrap();
    let methods = ["health", "doctor", "operation.list", "device.observations"];
    let mut count = 0_u64;
    for method in methods {
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
    let expected = methods
        .iter()
        .map(|method| {
            inputs["corpusMethodCounts"][*method]["successes"]
                .as_u64()
                .unwrap()
        })
        .sum::<u64>();
    assert_eq!(
        count, expected,
        "successful results across all four methods"
    );
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
fn job_failure_objects_remain_required_nullable_and_closed() {
    let fields = [
        "category",
        "code",
        "recovery",
        "retryability",
        "schemaVersion",
    ];
    for (method, pointer) in [("job.show", "/job/failure"), ("job.reconcile", "/failure")] {
        let result = corpus(method)
            .into_iter()
            .filter(|row| row["ok"] == true)
            .map(|row| row["result"].clone())
            .find(|result| result.pointer(pointer).is_some_and(Value::is_object))
            .unwrap_or_else(|| panic!("{method}: missing recorded structured failure"));
        let failure = result.pointer(pointer).unwrap();
        assert_eq!(
            failure
                .as_object()
                .unwrap()
                .keys()
                .map(String::as_str)
                .collect::<BTreeSet<_>>(),
            fields.into_iter().collect()
        );
        validate_method_value(method, "result", &result).unwrap();

        let mut nullable = result.clone();
        *nullable.pointer_mut(pointer).unwrap() = Value::Null;
        validate_method_value(method, "result", &nullable).unwrap();
        let frame =
            serde_json::to_vec(&json!({"id":"null-failure","ok":true,"result":nullable})).unwrap();
        let decoded = decode_response(&frame, "null-failure", method).unwrap();
        assert_eq!(
            decoded.outcome.unwrap().pointer(pointer),
            Some(&Value::Null)
        );

        let mut missing = result.clone();
        let (parent, field) = pointer.rsplit_once('/').unwrap();
        missing
            .pointer_mut(parent)
            .unwrap()
            .as_object_mut()
            .unwrap()
            .remove(field);
        assert!(validate_method_value(method, "result", &missing).is_err());

        for field in fields {
            let mut missing = result.clone();
            missing
                .pointer_mut(pointer)
                .unwrap()
                .as_object_mut()
                .unwrap()
                .remove(field);
            assert!(
                validate_method_value(method, "result", &missing).is_err(),
                "{method}: missing failure.{field}"
            );
            let mut non_string = result.clone();
            non_string.pointer_mut(pointer).unwrap()[field] = json!(0);
            assert!(
                validate_method_value(method, "result", &non_string).is_err(),
                "{method}: non-string failure.{field}"
            );
        }
        let mut extra = result.clone();
        extra.pointer_mut(pointer).unwrap()["__unpublishedField"] = json!(true);
        assert!(validate_method_value(method, "result", &extra).is_err());
        for invalid in [json!(false), json!(0), json!("unknown"), json!([])] {
            let mut malformed = result.clone();
            *malformed.pointer_mut(pointer).unwrap() = invalid;
            assert!(
                validate_method_value(method, "result", &malformed).is_err(),
                "{method}: malformed failure"
            );
        }
    }
}

#[test]
fn reconciled_finish_time_and_optional_retry_after_keep_their_value_types() {
    let result = corpus("job.reconcile")
        .into_iter()
        .filter(|row| row["ok"] == true)
        .map(|row| row["result"].clone())
        .find(|result| result["finishedAtUtc"].is_string())
        .expect("missing recorded terminal reconciliation");
    for valid in [Value::Null, result["finishedAtUtc"].clone()] {
        let mut changed = result.clone();
        changed["finishedAtUtc"] = valid;
        validate_method_value("job.reconcile", "result", &changed).unwrap();
    }
    let mut omitted = result.clone();
    omitted.as_object_mut().unwrap().remove("finishedAtUtc");
    assert!(validate_method_value("job.reconcile", "result", &omitted).is_err());
    for invalid in [json!(false), json!(0), json!([]), json!({})] {
        let mut malformed = result.clone();
        malformed["finishedAtUtc"] = invalid;
        assert!(validate_method_value("job.reconcile", "result", &malformed).is_err());
    }

    for (method, part) in [("job.reconcile", "result"), ("job.result", "errorDetails")] {
        let value = corpus(method)
            .into_iter()
            .map(|row| {
                if part == "result" {
                    row["result"].clone()
                } else {
                    row["error"]["details"].clone()
                }
            })
            .find(|value| {
                value["nextAction"]
                    .as_object()
                    .is_some_and(|action| !action.contains_key("retryAfter"))
            })
            .unwrap_or_else(|| panic!("{method}: missing recorded nextAction without retryAfter"));
        validate_method_value(method, part, &value).unwrap();
        let mut polling = value.clone();
        polling["nextAction"]["retryAfter"] = json!("250ms");
        validate_method_value(method, part, &polling).unwrap();
        for invalid in [Value::Null, json!(false), json!(0), json!([]), json!({})] {
            let mut malformed = value.clone();
            malformed["nextAction"]["retryAfter"] = invalid;
            assert!(
                validate_method_value(method, part, &malformed).is_err(),
                "{method}: malformed retryAfter"
            );
        }
        let mut missing_kind = value.clone();
        missing_kind["nextAction"]
            .as_object_mut()
            .unwrap()
            .remove("kind");
        assert!(validate_method_value(method, part, &missing_kind).is_err());
        let mut extra = value.clone();
        extra["nextAction"]["__unpublishedField"] = json!(true);
        assert!(validate_method_value(method, part, &extra).is_err());
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
fn source_schema_and_corpus_files_match_the_selected_input_manifest() {
    fn assert_git_object_id(value: &Value) {
        let identifier = value.as_str().unwrap();
        assert_eq!(identifier.len(), 40);
        assert!(
            identifier
                .bytes()
                .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
        );
    }

    fn directory_files(directory: &std::path::Path) -> BTreeSet<String> {
        let mut paths = BTreeSet::new();
        let mut pending = vec![directory.to_owned()];
        let root = common::repo_root();
        while let Some(path) = pending.pop() {
            for entry in fs::read_dir(path).unwrap() {
                let entry = entry.unwrap();
                if entry.file_type().unwrap().is_dir() {
                    pending.push(entry.path());
                } else {
                    paths.insert(
                        entry
                            .path()
                            .strip_prefix(&root)
                            .unwrap()
                            .to_str()
                            .unwrap()
                            .replace('\\', "/"),
                    );
                }
            }
        }
        paths
    }

    let inputs = strict_json(CONTRACT_INPUTS.as_bytes()).unwrap();
    let published = strict_json(SWIFT_BASELINE.as_bytes()).unwrap();
    assert_eq!(published["kind"], "development");
    assert_eq!(
        published["schemaVersion"],
        "arkdeck.swift-development-baseline/1"
    );
    assert_git_object_id(&published["commit"]);
    match inputs["kind"].as_str().unwrap() {
        "development" => assert_eq!(CONTRACT_INPUTS, SWIFT_BASELINE),
        "candidate" => {
            assert_eq!(inputs["schemaVersion"], "arkdeck.swift-candidate-inputs/1");
            assert!(
                inputs.get("commit").is_none(),
                "candidate inputs have no published commit"
            );
            assert_eq!(inputs["publishedBaselineCommit"], published["commit"]);
            assert_git_object_id(&inputs["sourceRevision"]);
        }
        kind => panic!("unknown contract input kind: {kind}"),
    }
    assert_eq!(inputs["protocolVersion"], PROTOCOL_VERSION);
    assert_eq!(inputs["contractIdentity"], CONTRACT_IDENTITY);
    assert_eq!(inputs["methodCount"], METHODS.len());
    assert_eq!(
        inputs["corpusFileCount"],
        inputs["corpusMethodCounts"].as_object().unwrap().len()
    );
    let files = inputs["files"].as_object().unwrap();
    for (path, pin) in files {
        assert_eq!(
            sha256_hex(&fs::read(common::repo_root().join(path)).unwrap()),
            pin["sha256"],
            "contract input file drift: {path}"
        );
        assert_git_object_id(&pin["blob"]);
    }
    for (directory, expected) in inputs["directoryDigests"].as_object().unwrap() {
        let prefix = format!("{directory}/");
        let expected_paths = files
            .keys()
            .filter(|path| path.starts_with(&prefix))
            .cloned()
            .collect::<BTreeSet<_>>();
        assert_eq!(
            directory_files(&common::repo_root().join(directory)),
            expected_paths,
            "directory file closure: {directory}"
        );
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
