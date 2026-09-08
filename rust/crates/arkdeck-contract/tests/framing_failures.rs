use arkdeck_contract::{
    CATALOG_DIGEST, CONTRACT_IDENTITY, ContractError, MAX_REQUEST_BYTES, MAX_RESPONSE_BYTES,
    METHODS, PROTOCOL_VERSION, Request, Response, decode_request, decode_response, encode_frame,
    strict_json, validate_health, validate_method_value,
};
use serde_json::{Value, json};

#[path = "common/mod.rs"]
mod common;

fn request() -> Value {
    serde_json::to_value(Request::new("frame-id", "doctor", None)).unwrap()
}

fn error_response() -> Value {
    Response::failure("frame-id", "internalError", "bounded error").value()
}

fn decode(value: &Value) -> Result<Request, ContractError> {
    decode_request(&serde_json::to_vec(value).unwrap())
}

#[test]
fn nested_duplicate_keys_escaped_aliases_and_invalid_unicode_are_rejected() {
    for raw in [
        r#"{"same":1,"same":2}"#,
        r#"{"outer":{"same":1,"same":2}}"#,
        r#"{"outer":[{"same":1,"same":2}]}"#,
        r#"{"same":1,"\u0073ame":2}"#,
        r#"{"outer":[{"\ud83d\ude00":1,"😀":2}]}"#,
        r#"{"text":"\ud800"}"#,
        r#"{"text":"\udfff"}"#,
        r#"{"text":"\ud800x"}"#,
        r#"{"text":"\ud800\ud800"}"#,
        r#"{"\ud800":0}"#,
        r#"{"nested":{"one":1,}}"#,
        r#"{"number":01}"#,
        r#"{"number":1e999}"#,
        r#"{"number":NaN}"#,
        r#"{}{}"#,
        "",
    ] {
        assert!(
            strict_json(raw.as_bytes()).is_err(),
            "accepted malformed JSON: {raw}"
        );
    }
    for bytes in [
        &[0xff][..],
        b"{\"key\":\"\xc0\xaf\"}",
        b"{\"key\":\"\xed\xa0\x80\"}",
        b"\xef\xbb\xbf{}",
    ] {
        assert!(strict_json(bytes).is_err());
    }
    assert_eq!(
        strict_json(br#"{"key":"\ud83d\ude00"}"#).unwrap(),
        json!({"key":"😀"})
    );
    assert!(strict_json(br#"{"a":{"same":1},"b":{"same":2}}"#).is_ok());
    let too_deep = format!("{}0{}", "[".repeat(256), "]".repeat(256));
    assert!(strict_json(too_deep.as_bytes()).is_err());
}

#[test]
fn request_envelope_refuses_unknown_fields_invalid_ids_and_nonobject_params() {
    assert!(decode(&request()).is_ok());
    for id in [
        json!(""),
        json!("a".repeat(129)),
        json!("é".repeat(65)),
        json!("\n"),
        json!("\r"),
        json!("\0"),
        json!(7),
        json!(null),
    ] {
        let mut malformed = request();
        malformed["id"] = id;
        assert_eq!(decode(&malformed), Err(ContractError::Malformed));
    }
    for id in ["a".repeat(128), "é".repeat(64), "with spaces".to_owned()] {
        let mut valid = request();
        valid["id"] = json!(id);
        assert!(decode(&valid).is_ok());
    }
    for field in ["id", "method"] {
        let mut malformed = request();
        malformed.as_object_mut().unwrap().remove(field);
        assert_eq!(decode(&malformed), Err(ContractError::Malformed));
    }
    for method in [
        json!(""),
        json!("m".repeat(129)),
        json!(1),
        json!([]),
        json!(null),
    ] {
        let mut malformed = request();
        malformed["method"] = method;
        assert_eq!(decode(&malformed), Err(ContractError::Malformed));
    }
    for params in [json!(null), json!([]), json!(true), json!("{}"), json!(0)] {
        let mut malformed = request();
        malformed["params"] = params;
        assert_eq!(decode(&malformed), Err(ContractError::Malformed));
    }
    for field in [
        "argv",
        "shell",
        "executable",
        "protocolVersions",
        "origin",
        "extra",
    ] {
        let mut malformed = request();
        malformed[field] = json!("caller-supplied");
        assert_eq!(decode(&malformed), Err(ContractError::Malformed));
    }
    for raw in [b"[]".as_slice(), b"null", b"1", b"true", b"\"object\""] {
        assert_eq!(decode_request(raw), Err(ContractError::Malformed));
    }
}

#[test]
fn only_current_version_identity_and_published_method_are_admitted() {
    for version in [
        json!("0.0.0"),
        json!("1.0"),
        json!("1.0.1"),
        json!("2.0.0"),
        json!(1),
        json!(null),
    ] {
        let mut foreign = request();
        foreign["protocolVersion"] = version;
        assert_eq!(decode(&foreign), Err(ContractError::UnsupportedVersion));
    }
    let mut absent_version = request();
    absent_version
        .as_object_mut()
        .unwrap()
        .remove("protocolVersion");
    assert_eq!(
        decode(&absent_version),
        Err(ContractError::UnsupportedVersion)
    );
    for identity in [
        json!("0".repeat(64)),
        json!(CONTRACT_IDENTITY.to_ascii_uppercase()),
        json!(""),
        json!(null),
        json!(1),
    ] {
        let mut foreign = request();
        foreign["contractIdentity"] = identity;
        assert_eq!(decode(&foreign), Err(ContractError::ContractMismatch));
    }
    let mut absent_identity = request();
    absent_identity
        .as_object_mut()
        .unwrap()
        .remove("contractIdentity");
    assert_eq!(
        decode(&absent_identity),
        Err(ContractError::ContractMismatch)
    );
    for method in [
        "not.published",
        "device.candidates",
        "protocol.negotiate",
        "doctor\0",
    ] {
        let mut foreign = request();
        foreign["method"] = json!(method);
        assert_eq!(decode(&foreign), Err(ContractError::UnknownMethod));
        assert!(validate_method_value(method, "request", &json!({})).is_err());
    }
    assert!(validate_method_value("doctor", "notPublishedPart", &json!({})).is_err());
}

#[test]
fn envelope_decoding_cannot_hide_nested_duplicate_params_or_response_fields() {
    let prefix = format!(
        "{{\"id\":\"frame-id\",\"protocolVersion\":\"{PROTOCOL_VERSION}\",\"contractIdentity\":\"{CONTRACT_IDENTITY}\",\"method\":\"doctor\",\"params\":"
    );
    for params in [
        r#"{"deep":true,"deep":false}"#,
        r#"{"nested":[{"x":1,"\u0078":2}]}"#,
    ] {
        assert!(decode_request(format!("{prefix}{params}}}").as_bytes()).is_err());
    }
    for response in [
        r#"{"id":"frame-id","ok":false,"error":{"code":"internalError","message":"x","message":"y"}}"#,
        r#"{"id":"frame-id","ok":false,"error":{"code":"internalError","message":"x","details":{"x":1,"\u0078":2}}}"#,
        r#"{"id":"frame-id","ok":true,"result":{"checks":{"x":1,"x":2}}}"#,
        r#"{"id":"frame-id","id":"another","ok":false,"error":{"code":"internalError","message":"x"}}"#,
    ] {
        assert!(decode_response(response.as_bytes(), "frame-id", "doctor").is_err());
    }
}

#[test]
fn responses_require_exact_correlation_envelopes_and_object_error_details() {
    let good = serde_json::to_vec(&error_response()).unwrap();
    assert!(decode_response(&good, "frame-id", "doctor").is_ok());
    assert!(decode_response(&good, "another-id", "doctor").is_err());
    assert!(decode_response(&good, "", "doctor").is_err());
    assert!(decode_response(&good, "frame-id", "not.published").is_err());
    for field in ["id", "ok", "error"] {
        let mut malformed = error_response();
        malformed.as_object_mut().unwrap().remove(field);
        assert!(
            decode_response(
                &serde_json::to_vec(&malformed).unwrap(),
                "frame-id",
                "doctor"
            )
            .is_err()
        );
    }
    for (field, value) in [
        ("result", json!({})),
        ("extra", json!(true)),
        ("ok", json!(1)),
        ("id", json!(null)),
        ("error", json!("failure")),
        ("error", json!({"code":"internalError"})),
        ("error", json!({"code":"", "message":"x"})),
        ("error", json!({"code":3, "message":"x"})),
        ("error", json!({"code":"internalError", "message":null})),
        (
            "error",
            json!({"code":"internalError", "message":"x", "extra":true}),
        ),
        ("error", json!({"code":"notPublishedError", "message":"x"})),
    ] {
        let mut malformed = error_response();
        malformed[field] = value;
        assert!(
            decode_response(
                &serde_json::to_vec(&malformed).unwrap(),
                "frame-id",
                "doctor"
            )
            .is_err()
        );
    }
    for details in [
        json!(null),
        json!([]),
        json!(true),
        json!(3),
        json!("{}"),
        json!({"notPublishedDetail":0}),
    ] {
        let mut malformed = error_response();
        malformed["error"]["details"] = details;
        assert!(
            decode_response(
                &serde_json::to_vec(&malformed).unwrap(),
                "frame-id",
                "doctor"
            )
            .is_err()
        );
    }
    for response in [
        json!({"id":"frame-id","ok":true,"error":{}}),
        json!({"id":"frame-id","ok":false,"result":{}}),
    ] {
        assert!(
            decode_response(
                &serde_json::to_vec(&response).unwrap(),
                "frame-id",
                "doctor"
            )
            .is_err()
        );
    }
}

fn padded_request(payload_length: usize) -> Vec<u8> {
    let mut value = serde_json::to_value(Request::new(
        "frame-id",
        "target.show",
        Some(json!({"targetId":""}).as_object().unwrap().clone()),
    ))
    .unwrap();
    let overhead = serde_json::to_vec(&value).unwrap().len();
    value["params"]["targetId"] = json!("x".repeat(payload_length - overhead));
    let bytes = serde_json::to_vec(&value).unwrap();
    assert_eq!(bytes.len(), payload_length);
    bytes
}

fn padded_response(payload_length: usize) -> Vec<u8> {
    let mut value = error_response();
    value["error"]["message"] = json!("");
    let overhead = serde_json::to_vec(&value).unwrap().len();
    value["error"]["message"] = json!("x".repeat(payload_length - overhead));
    let bytes = serde_json::to_vec(&value).unwrap();
    assert_eq!(bytes.len(), payload_length);
    bytes
}

#[test]
fn four_mib_request_limit_and_eight_mib_response_limit_include_the_lf_byte() {
    assert_eq!(MAX_REQUEST_BYTES, 4 * 1024 * 1024);
    assert_eq!(MAX_RESPONSE_BYTES, 8 * 1024 * 1024);
    let at_request_limit = padded_request(MAX_REQUEST_BYTES - 1);
    let request = decode_request(&at_request_limit).unwrap();
    let encoded = encode_frame(&request, MAX_REQUEST_BYTES).unwrap();
    assert_eq!(encoded.len(), MAX_REQUEST_BYTES);
    assert_eq!(encoded.last(), Some(&b'\n'));
    // The decoder consumes the transport-delimited payload, never a payload
    // with a second LF/CR or a full frame that escaped transport splitting.
    assert!(decode_request(&encoded).is_err());
    let too_large = padded_request(MAX_REQUEST_BYTES);
    assert!(decode_request(&too_large).is_err());
    assert!(encode_frame(&strict_json(&too_large).unwrap(), MAX_REQUEST_BYTES).is_err());

    let at_response_limit = padded_response(MAX_RESPONSE_BYTES - 1);
    let response = decode_response(&at_response_limit, "frame-id", "doctor").unwrap();
    let encoded = encode_frame(&response.value(), MAX_RESPONSE_BYTES).unwrap();
    assert_eq!(encoded.len(), MAX_RESPONSE_BYTES);
    assert_eq!(encoded.last(), Some(&b'\n'));
    assert!(decode_response(&encoded, "frame-id", "doctor").is_err());
    let too_large = padded_response(MAX_RESPONSE_BYTES);
    assert!(decode_response(&too_large, "frame-id", "doctor").is_err());
    assert!(encode_frame(&strict_json(&too_large).unwrap(), MAX_RESPONSE_BYTES).is_err());
}

#[test]
fn embedded_raw_line_terminators_and_invalid_utf8_are_refused() {
    for newline in *b"\n\r" {
        let mut request_bytes = serde_json::to_vec(&request()).unwrap();
        request_bytes.insert(1, newline);
        assert!(decode_request(&request_bytes).is_err());
        let mut response_bytes = serde_json::to_vec(&error_response()).unwrap();
        response_bytes.insert(1, newline);
        assert!(decode_response(&response_bytes, "frame-id", "doctor").is_err());
    }
    let mut invalid = serde_json::to_vec(&request()).unwrap();
    invalid[2] = 0xff;
    assert!(decode_request(&invalid).is_err());
    let mut invalid = serde_json::to_vec(&error_response()).unwrap();
    invalid[2] = 0xff;
    assert!(decode_response(&invalid, "frame-id", "doctor").is_err());
}

fn health() -> Response {
    Response::success(
        "health-id",
        json!({
            "status":"ok", "protocolVersion":PROTOCOL_VERSION,
            "contractIdentity":CONTRACT_IDENTITY, "catalogDigest":CATALOG_DIGEST,
            "publishedMethods":METHODS, "providers":[],
        }),
    )
}

#[test]
fn health_handshake_refuses_identity_method_set_and_digest_shape_drift() {
    validate_health(&health()).unwrap();
    let registry = common::load_json("Packages/ArkDeckKit/Contracts/control-protocol.json");
    assert_eq!(registry["methods"], json!(METHODS));
    for (field, value) in [
        ("status", json!("ready")),
        ("protocolVersion", json!("1.0.1")),
        ("contractIdentity", json!("0".repeat(64))),
        ("catalogDigest", json!("A".repeat(64))),
        ("catalogDigest", json!("0".repeat(63))),
        ("providers", json!([""])),
        ("providers", json!([3])),
        ("publishedMethods", json!(["health"])),
        ("notPublishedField", json!(true)),
    ] {
        let mut changed = health();
        changed.outcome.as_mut().unwrap()[field] = value;
        assert!(
            validate_health(&changed).is_err(),
            "accepted health drift in {field}"
        );
    }
    let mut reordered = health();
    reordered.outcome.as_mut().unwrap()["publishedMethods"]
        .as_array_mut()
        .unwrap()
        .reverse();
    assert!(validate_health(&reordered).is_err());
    assert!(
        validate_health(&Response::failure(
            "health-id",
            "internalError",
            "not healthy"
        ))
        .is_err()
    );
}
