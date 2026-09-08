use arkdeck_contract::{
    CborValue, ContractError, canonical_cbor, canonical_json, sha256_hex, strict_json,
};
use hmac::{Hmac, Mac};
use serde_json::{Number, Value, json};
use sha2::{Digest, Sha256};

#[path = "common/mod.rs"]
mod common;

#[test]
fn complete_swift_canonical_json_vector_set_is_byte_identical() {
    let vectors = common::load_json("openspec/contracts/cli-canonical-json-vectors.json");
    assert_eq!(
        vectors["canonicalJsonVersion"],
        "arkdeck.cli.canonical-json/1"
    );
    let cases = vectors["vectors"].as_array().unwrap();
    assert_eq!(cases.len(), 10);
    for case in cases {
        let encoded = canonical_json(&case["value"]).unwrap();
        assert_eq!(
            encoded,
            case["canonical"].as_str().unwrap().as_bytes(),
            "Swift canonical vector {}",
            case["name"]
        );
        assert_eq!(
            canonical_json(&strict_json(&encoded).unwrap()).unwrap(),
            encoded,
            "canonicalization must be idempotent for {}",
            case["name"]
        );
    }
}

#[test]
fn every_swift_canonical_json_rejection_is_represented() {
    let vectors = common::load_json("openspec/contracts/cli-canonical-json-vectors.json");
    let rejections = vectors["rejections"].as_array().unwrap();
    assert_eq!(rejections.len(), 5);
    for case in rejections {
        match case["name"].as_str().unwrap() {
            "positiveInfinity" | "negativeInfinity" | "nan" => {
                let (number, raw) = match case["name"].as_str().unwrap() {
                    "positiveInfinity" => (f64::INFINITY, b"Infinity".as_slice()),
                    "negativeInfinity" => (f64::NEG_INFINITY, b"-Infinity".as_slice()),
                    _ => (f64::NAN, b"NaN".as_slice()),
                };
                // serde_json makes these values unrepresentable before the
                // encoder. Neither a raw token nor numeric overflow may open
                // a path around that invariant.
                assert!(Number::from_f64(number).is_none());
                assert!(strict_json(raw).is_err());
                assert!(
                    strict_json(if number.is_sign_negative() {
                        b"-1e999"
                    } else {
                        b"1e999"
                    })
                    .is_err()
                );
                assert_eq!(case["reason"], "nonFiniteNumber");
            }
            "integerBeyondExactRange" => assert_eq!(
                canonical_json(&json!(i64::MAX)),
                Err(ContractError::IntegerBeyondExactRange)
            ),
            "unsignedIntegerBeyondExactRange" => assert_eq!(
                canonical_json(&json!(u64::MAX)),
                Err(ContractError::IntegerBeyondExactRange)
            ),
            name => panic!("unhandled Swift canonical rejection {name}"),
        }
    }
    for value in [
        json!(9_007_199_254_740_992_u64),
        json!(-9_007_199_254_740_992_i64),
        json!([{"nested": i64::MAX}]),
    ] {
        assert_eq!(
            canonical_json(&value),
            Err(ContractError::IntegerBeyondExactRange)
        );
    }
    assert_eq!(
        canonical_json(&json!(-9_007_199_254_740_991_i64)).unwrap(),
        b"-9007199254740991"
    );
}

#[test]
fn utf16_sorting_and_unicode_normalization_remain_distinct() {
    // U+1F600 sorts before U+E000 in UTF-16 (D83D < E000), but after it
    // in scalar/UTF-8 order. The original basic vector alone cannot catch it.
    let input = json!({"\u{e000}": 1, "😀": 2});
    assert_eq!(
        canonical_json(&input).unwrap(),
        "{\"😀\":2,\"\u{e000}\":1}".as_bytes()
    );
    assert_ne!(
        canonical_json(&json!("é")).unwrap(),
        canonical_json(&json!("e\u{301}")).unwrap()
    );
    assert_eq!(canonical_json(&json!(-0.0_f64)).unwrap(), b"0");
}

#[test]
fn native_current_swift_numeric_boundaries_remain_byte_identical() {
    let vectors = strict_json(include_bytes!("oracles/swift-number-boundaries.json")).unwrap();
    assert_eq!(
        vectors["function"],
        "PortableCanonicalJSON.serialize(Double)"
    );
    assert_eq!(vectors["validationClass"], "nativeSwiftPureEncoding");
    let source =
        std::fs::read(common::repo_root().join(vectors["sourcePath"].as_str().unwrap())).unwrap();
    assert_eq!(
        sha256_hex(&source),
        vectors["sourceSHA256"],
        "Swift numeric oracle source drift"
    );
    assert_eq!(vectors["vectors"].as_array().unwrap().len(), 33);
    for vector in vectors["vectors"].as_array().unwrap() {
        let bits = u64::from_str_radix(vector["binary64Bits"].as_str().unwrap(), 16).unwrap();
        let number = Number::from_f64(f64::from_bits(bits));
        match vector["outcome"].as_str().unwrap() {
            "encoded" => {
                let encoded = canonical_json(&Value::Number(number.unwrap())).unwrap();
                assert_eq!(
                    encoded,
                    vector["canonical"].as_str().unwrap().as_bytes(),
                    "current Swift numeric boundary {}",
                    vector["name"]
                );
            }
            "integerBeyondExactRange" => assert_eq!(
                canonical_json(&Value::Number(number.unwrap())),
                Err(ContractError::IntegerBeyondExactRange),
                "{}",
                vector["name"]
            ),
            "nonFiniteNumber" => assert!(number.is_none()),
            outcome => panic!("unknown native Swift vector outcome {outcome}"),
        }
    }
}

fn text(value: &str) -> CborValue {
    CborValue::Text(value.to_owned())
}

fn digest(value: &str) -> CborValue {
    CborValue::Bytes(Sha256::digest(value.as_bytes()).to_vec())
}

// Test-only model of the exact published Swift permit signing body. No
// production permit type, pairing key store, capability or dispatch is added.
fn permit_body(step: &str, attempt: &str, private_action_preimage: &str) -> CborValue {
    CborValue::Map(vec![
        ("permitId".into(), text(&format!("PERMIT-{step}"))),
        ("authorityNamespace".into(), text("arkdeck")),
        ("controllerSessionId".into(), text("SESSION-VECTOR")),
        ("jobId".into(), text("JOB-VECTOR")),
        ("planId".into(), text("PLAN-VECTOR")),
        ("planDigest".into(), digest("plan-vector")),
        ("stepId".into(), text(step)),
        ("attemptId".into(), text(attempt)),
        ("publicStepDigest".into(), digest("public-step-vector")),
        (
            "privateActionDigest".into(),
            digest(private_action_preimage),
        ),
        ("effectSetDigest".into(), digest("effect-set-vector")),
        (
            "authorityBinding".into(),
            CborValue::Map(vec![
                ("authorityNamespace".into(), text("arkdeck")),
                ("bindingId".into(), text("BINDING-VECTOR")),
                ("bindingRevision".into(), CborValue::Unsigned(3)),
                (
                    "stableIdentityDigest".into(),
                    digest("stable-identity-vector"),
                ),
            ]),
        ),
        (
            "admittedDeviceFactsDigest".into(),
            digest("admitted-facts-vector"),
        ),
        (
            "issuedAtEpochMs".into(),
            CborValue::Unsigned(1_770_000_000_000),
        ),
        (
            "expiresAtEpochMs".into(),
            CborValue::Unsigned(1_770_000_060_000),
        ),
        ("singleUse".into(), CborValue::Bool(true)),
    ])
}

#[test]
fn all_three_published_cbor_body_and_hmac_vectors_match_swift_and_arkforge() {
    let document = std::fs::read_to_string(
        common::repo_root()
            .join("openspec/changes/chg-2026-059-arkdeck-arkforge-authority/permit-vectors.md"),
    )
    .unwrap();
    let cases: Vec<_> = document
        .lines()
        .filter(|line| line.starts_with("| ") && line.contains("`STEP-"))
        .map(|line| {
            line.split('|')
                .map(|part| part.trim().trim_matches('`'))
                .collect::<Vec<_>>()
        })
        .collect();
    assert_eq!(
        cases.len(),
        3,
        "every published permit vector must be exercised"
    );
    for case in cases {
        let body = permit_body(case[2], case[3], case[4]);
        let encoded = canonical_cbor(&body).unwrap();
        assert_eq!(sha256_hex(&encoded), case[5], "{} signing body", case[2]);
        let mut mac =
            Hmac::<Sha256>::new_from_slice(b"arkforge-arkdeck-permit-vector-secret").unwrap();
        mac.update(&encoded);
        assert_eq!(
            format!("{:x}", mac.finalize().into_bytes()),
            case[6],
            "{} HMAC",
            case[2]
        );
        let CborValue::Map(mut reversed) = body else {
            unreachable!()
        };
        reversed.reverse();
        assert_eq!(canonical_cbor(&CborValue::Map(reversed)).unwrap(), encoded);
    }
}

#[test]
fn restricted_cbor_vocabulary_preserves_shortest_forms_and_type_distinctions() {
    for (value, hex) in [
        (0, "00"),
        (23, "17"),
        (24, "1818"),
        (255, "18ff"),
        (256, "190100"),
        (65_535, "19ffff"),
        (65_536, "1a00010000"),
        (4_294_967_295, "1affffffff"),
        (4_294_967_296, "1b0000000100000000"),
        (u64::MAX, "1bffffffffffffffff"),
    ] {
        let encoded = canonical_cbor(&CborValue::Unsigned(value)).unwrap();
        let actual: String = encoded.iter().map(|byte| format!("{byte:02x}")).collect();
        assert_eq!(actual, hex);
    }
    assert_eq!(canonical_cbor(&CborValue::Bool(true)).unwrap(), [0xf5]);
    assert_eq!(canonical_cbor(&CborValue::Bool(false)).unwrap(), [0xf4]);
    assert_eq!(canonical_cbor(&CborValue::Null).unwrap(), [0xf6]);
    assert_eq!(canonical_cbor(&text("a")).unwrap(), [0x61, 0x61]);
    assert_eq!(
        canonical_cbor(&CborValue::Bytes(vec![0x61])).unwrap(),
        [0x41, 0x61]
    );
    assert_eq!(canonical_cbor(&text("é")).unwrap(), [0x62, 0xc3, 0xa9]);
    assert_ne!(
        canonical_cbor(&text("é")).unwrap(),
        canonical_cbor(&text("e\u{301}")).unwrap()
    );
    assert_eq!(
        canonical_cbor(&CborValue::Array(vec![
            CborValue::Null,
            CborValue::Bool(false)
        ]))
        .unwrap(),
        [0x82, 0xf6, 0xf4]
    );
    assert_eq!(
        canonical_cbor(&CborValue::Map(vec![
            ("aa".into(), CborValue::Unsigned(1)),
            ("z".into(), CborValue::Unsigned(2))
        ]))
        .unwrap(),
        [0xa2, 0x61, 0x7a, 0x02, 0x62, 0x61, 0x61, 0x01]
    );
}

#[test]
fn duplicate_cbor_map_keys_are_refused_even_when_nested() {
    let duplicate = CborValue::Map(vec![
        ("same".into(), text("first")),
        ("same".into(), text("second")),
    ]);
    assert_eq!(canonical_cbor(&duplicate), Err(ContractError::DuplicateKey));
    assert_eq!(
        canonical_cbor(&CborValue::Array(vec![duplicate])),
        Err(ContractError::DuplicateKey)
    );
}
