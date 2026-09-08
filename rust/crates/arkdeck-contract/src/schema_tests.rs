use super::validate;
use serde_json::{Value, json};

fn shared_pattern(name: &str) -> Value {
    let patterns: Value = serde_json::from_str(include_str!("schema_patterns.json")).unwrap();
    patterns[name].clone()
}

fn accepts(schema: &Value, value: Value) {
    assert!(
        validate(schema, &value).is_ok(),
        "schema {schema} rejected {value}"
    );
}

fn rejects(schema: &Value, value: Value) {
    assert!(
        validate(schema, &value).is_err(),
        "schema {schema} accepted {value}"
    );
}

#[test]
fn one_of_requires_exactly_one_matching_branch() {
    let disjoint = json!({"oneOf": [{"const": 7}, {"const": "seven"}]});
    accepts(&disjoint, json!(7));
    accepts(&disjoint, json!("seven"));
    rejects(&disjoint, json!(null));

    let overlapping = json!({"oneOf": [{"type": "integer"}, {"type": "number"}]});
    rejects(&overlapping, json!(7));
    accepts(&overlapping, json!(7.5));
    rejects(&overlapping, json!("7"));
    rejects(&json!({"oneOf": [{}, {}]}), json!(null));
    rejects(&json!({"oneOf": [{"const": 1}, {"const": 1.0}]}), json!(1));
}

#[test]
fn combinators_and_sibling_constraints_are_conjunctive() {
    let typed = json!({"type": "string", "oneOf": [{"const": "ok"}, {"const": 7}]});
    accepts(&typed, json!("ok"));
    rejects(&typed, json!(7));
    let bounded = json!({"minLength": 2, "oneOf": [{"const": "x"}, {"const": "long"}]});
    accepts(&bounded, json!("long"));
    rejects(&bounded, json!("x"));
    let limited = json!({"const": 2, "anyOf": [{"const": 2}, {"const": 3}]});
    accepts(&limited, json!(2));
    rejects(&limited, json!(3));
    let closed = json!({
        "type": "object", "required": ["state"], "additionalProperties": false,
        "properties": {"state": {"type": "string"}},
        "oneOf": [{"properties": {"state": {"const": "ready"}}}]
    });
    accepts(&closed, json!({"state": "ready"}));
    rejects(&closed, json!({}));
    rejects(&closed, json!({"state": "ready", "extra": true}));
}

#[test]
fn not_inverts_valid_schemas_and_keeps_sibling_constraints() {
    let non_null = json!({"not": {"const": null}});
    rejects(&non_null, json!(null));
    for value in [json!(false), json!(0), json!(""), json!([]), json!({})] {
        accepts(&non_null, value);
    }
    rejects(&json!({"not": {}}), json!(true));
    let typed = json!({"type": "boolean", "not": {"const": false}});
    accepts(&typed, json!(true));
    rejects(&typed, json!(false));
    rejects(&typed, json!(1));
    let inverted_overlap = json!({
        "type": "number", "not": {"oneOf": [{"type": "integer"}, {"type": "number"}]}
    });
    accepts(&inverted_overlap, json!(1));
    rejects(&inverted_overlap, json!(1.5));
}

#[test]
fn const_compares_json_types_and_complete_nested_structures() {
    for value in [
        json!(null),
        json!(true),
        json!(false),
        json!("1"),
        json!([]),
        json!({}),
    ] {
        accepts(&json!({"const": value}), value);
    }
    for (constant, instance) in [
        (json!(false), json!(0)),
        (json!(true), json!(1)),
        (json!(null), json!(false)),
        (json!("1"), json!(1)),
        (json!([1, 2]), json!([2, 1])),
        (json!([1]), json!([1, 2])),
        (json!({"a": null}), json!({})),
        (json!({"a": 1}), json!({"a": 1, "b": 2})),
    ] {
        rejects(&json!({"const": constant}), instance);
    }
    let nested = json!({"const": {"a": [null, true, {"n": 1}], "b": "value"}});
    accepts(
        &nested,
        json!({"b": "value", "a": [null, true, {"n": 1.0}]}),
    );
    rejects(&nested, json!({"b": "value", "a": [null, 1, {"n": 1}]}));
}

#[test]
fn const_numbers_compare_exact_values_without_rounding_large_integers() {
    for (left, right) in [
        (json!(1), json!(1.0)),
        (json!(-0.0), json!(0)),
        (json!(i64::MIN), json!(-9_223_372_036_854_775_808_f64)),
        (json!(1_u64 << 63), json!(9_223_372_036_854_775_808_f64)),
        (
            json!(9_007_199_254_740_992_u64),
            json!(9_007_199_254_740_992_f64),
        ),
    ] {
        accepts(&json!({"const": left}), right.clone());
        accepts(&json!({"enum": [left]}), right.clone());
        accepts(&json!({"const": right}), left);
    }
    for (integer, rounded) in [
        (
            json!(9_007_199_254_740_993_u64),
            json!(9_007_199_254_740_992_f64),
        ),
        (
            json!(-9_007_199_254_740_993_i64),
            json!(-9_007_199_254_740_992_f64),
        ),
        (json!(i64::MAX), json!(9_223_372_036_854_775_808_f64)),
        (
            json!((1_u64 << 63) + 1),
            json!(9_223_372_036_854_775_808_f64),
        ),
        (json!(u64::MAX), json!(18_446_744_073_709_551_616_f64)),
    ] {
        rejects(&json!({"const": integer}), rounded.clone());
        rejects(&json!({"enum": [integer]}), rounded.clone());
        rejects(&json!({"const": rounded}), integer);
    }
}

#[test]
fn min_length_counts_unicode_scalars_and_only_applies_to_strings() {
    let schema = json!({"minLength": 2});
    for value in ["", "a", "é", "😀"] {
        rejects(&schema, json!(value));
    }
    for value in ["ab", "汉字", "e\u{301}", "🇨🇳"] {
        accepts(&schema, json!(value));
    }
    accepts(&json!({"minLength": 3}), json!("👩‍💻"));
    rejects(&json!({"minLength": 4}), json!("👩‍💻"));
    accepts(&json!({"minLength": 0}), json!(""));
    rejects(&json!({"minLength": u64::MAX}), json!(""));
    accepts(&json!({"minLength": u64::MAX}), json!(null));
    for value in [json!(null), json!(false), json!(1), json!([]), json!({})] {
        accepts(&schema, value);
    }
}

#[test]
fn malformed_min_length_bounds_are_rejected_before_instance_type_checks() {
    for bound in [
        json!(-1),
        json!(1.0),
        json!(1.5),
        json!("2"),
        json!(true),
        json!(null),
        json!([]),
        json!({}),
    ] {
        let schema = json!({"minLength": bound});
        rejects(&schema, json!("long enough"));
        rejects(&schema, json!(null));
    }
}

#[test]
fn sha256_pattern_requires_exact_lowercase_ascii_and_full_input_consumption() {
    let schema = json!({"type": "string", "pattern": shared_pattern("lowercaseSha256")});
    for digest in ["0".repeat(64), "f".repeat(64), "0123456789abcdef".repeat(4)] {
        accepts(&schema, json!(digest));
    }
    let digest = "a".repeat(64);
    for invalid in [
        "a".repeat(63),
        "a".repeat(65),
        "A".repeat(64),
        "g".repeat(64),
        "０".repeat(64),
        format!("{digest}\n"),
        format!("{digest}\r\n"),
        format!("{digest}\u{2028}"),
        format!("{digest}\u{2029}"),
        format!("\n{digest}"),
        format!("x{digest}"),
        format!("{digest}x"),
        format!(" {digest}"),
        format!("{digest} "),
        format!("{digest}\0"),
        format!("{}\n{}", "a".repeat(32), "a".repeat(31)),
    ] {
        rejects(&schema, json!(invalid));
    }
    rejects(&schema, json!(0));
}

#[test]
fn decimal_pattern_accepts_canonical_ascii_values_through_i64_maximum() {
    let schema = json!({"type": "string", "pattern": shared_pattern("nonnegativeInt64Decimal")});
    for value in [
        "0",
        "1",
        "9",
        "10",
        "99",
        "9007199254740993",
        "999999999999999999",
        "1000000000000000000",
        "8999999999999999999",
        "9000000000000000000",
        "9220000000000000000",
        "9223372036854775000",
        "9223372036854775806",
        "9223372036854775807",
    ] {
        accepts(&schema, json!(value));
    }
    for value in [
        "",
        "00",
        "01",
        "-0",
        "-1",
        "+1",
        " 1",
        "1 ",
        "1\n",
        "1\r\n",
        "1\u{2028}",
        "1\u{2029}",
        "\n1",
        "1x",
        "x1",
        "1\0",
        "1.0",
        "1e2",
        "１",
        "١",
        "9223372036854775808",
        "18446744073709551615",
        "9999999999999999999999999999999999999999",
    ] {
        rejects(&schema, json!(value));
    }
    rejects(&schema, json!(1));
}

#[test]
fn patterns_admit_only_the_two_shared_spellings_and_ignore_non_string_instances() {
    for name in ["lowercaseSha256", "nonnegativeInt64Decimal"] {
        let schema = json!({"pattern": shared_pattern(name)});
        for value in [json!(null), json!(false), json!(1), json!([]), json!({})] {
            accepts(&schema, value);
        }
    }
    for pattern in [
        json!(".*"),
        json!("^[a-f0-9]{64}$"),
        json!("^[0-9]+$"),
        json!(format!(
            "{} ",
            shared_pattern("lowercaseSha256").as_str().unwrap()
        )),
        json!(null),
        json!(1),
        json!(true),
        json!([]),
        json!({}),
    ] {
        let schema = json!({"pattern": pattern});
        rejects(&schema, json!("anything"));
        rejects(&schema, json!(null));
    }
}

#[test]
fn unknown_vocabulary_cannot_hide_in_unvisited_or_inverted_branches() {
    let unknown = json!({"type": "number", "unsupportedKeyword": true});
    for (schema, instance) in [
        (unknown.clone(), json!("hit")),
        (json!({"not": unknown}), json!("hit")),
        (json!({"anyOf": [{}, unknown]}), json!("hit")),
        (json!({"oneOf": [{"const": "hit"}, unknown]}), json!("hit")),
        (json!({"properties": {"absent": unknown}}), json!({})),
        (json!({"items": unknown}), json!([])),
        (json!({"not": {"not": unknown}}), json!(1)),
    ] {
        rejects(&schema, instance);
    }
}

#[test]
fn malformed_definitions_cannot_hide_behind_a_successful_any_of_branch() {
    for malformed in [
        json!({"oneOf": []}),
        json!({"oneOf": {}}),
        json!({"oneOf": [null]}),
        json!({"anyOf": [null]}),
        json!({"not": []}),
        json!({"properties": []}),
        json!({"properties": {"absent": null}}),
        json!({"items": null}),
        json!({"type": "unknownType"}),
        json!({"required": "absent"}),
        json!({"required": [1]}),
        json!({"additionalProperties": 1}),
        json!({"minLength": -1}),
        json!({"pattern": ".*"}),
    ] {
        rejects(&malformed, json!(null));
        rejects(&json!({"anyOf": [{}, malformed]}), json!(null));
    }
}

#[test]
fn isolated_publication_shape_keeps_status_and_payload_consistent() {
    // This synthetic schema exercises the vocabulary together; it does not
    // consume or define a production method or an external recording.
    let schema = json!({
        "type": "object", "additionalProperties": false,
        "required": ["status", "sha256", "byteCount"],
        "properties": {
            "status": {"type": "string", "minLength": 1},
            "sha256": {"type": ["string", "null"], "pattern": shared_pattern("lowercaseSha256")},
            "byteCount": {"type": ["string", "null"], "pattern": shared_pattern("nonnegativeInt64Decimal")}
        },
        "oneOf": [
            {"properties": {"status": {"const": "published"}, "sha256": {"type": "string"}, "byteCount": {"type": "string"}}},
            {"properties": {"status": {"const": "unpublished"}, "sha256": {"const": null}, "byteCount": {"const": null}}}
        ]
    });
    let digest = "a".repeat(64);
    accepts(
        &schema,
        json!({"status": "published", "sha256": digest, "byteCount": "0"}),
    );
    accepts(
        &schema,
        json!({"status": "unpublished", "sha256": null, "byteCount": null}),
    );
    for value in [
        json!({"status": "published", "sha256": null, "byteCount": "1"}),
        json!({"status": "published", "sha256": digest, "byteCount": null}),
        json!({"status": "unpublished", "sha256": digest, "byteCount": "1"}),
        json!({"status": "unknown", "sha256": null, "byteCount": null}),
        json!({"status": "unpublished", "sha256": null}),
        json!({"status": "published", "sha256": digest, "byteCount": "01"}),
        json!({"status": "published", "sha256": digest, "byteCount": "9223372036854775808"}),
        json!({"status": "unpublished", "sha256": null, "byteCount": null, "extra": true}),
    ] {
        rejects(&schema, value);
    }
}

#[test]
fn isolated_catalog_count_shape_preserves_empty_and_populated_invariants() {
    let schema = json!({
        "type": "object", "additionalProperties": false,
        "required": ["state", "operationCount", "operations"],
        "properties": {
            "state": {"type": "string"},
            "operationCount": {"type": "string", "pattern": shared_pattern("nonnegativeInt64Decimal")},
            "operations": {"type": "array", "items": {"type": "string", "minLength": 1}}
        },
        "oneOf": [
            {"properties": {"state": {"const": "empty"}, "operationCount": {"const": "0"}, "operations": {"const": []}}},
            {"properties": {"state": {"const": "populated"}, "operationCount": {"not": {"const": "0"}}, "operations": {"not": {"const": []}}}}
        ]
    });
    accepts(
        &schema,
        json!({"state": "empty", "operationCount": "0", "operations": []}),
    );
    accepts(
        &schema,
        json!({"state": "populated", "operationCount": "1", "operations": ["inspect"]}),
    );
    for value in [
        json!({"state": "empty", "operationCount": "1", "operations": []}),
        json!({"state": "empty", "operationCount": "0", "operations": ["inspect"]}),
        json!({"state": "populated", "operationCount": "0", "operations": ["inspect"]}),
        json!({"state": "populated", "operationCount": "1", "operations": []}),
        json!({"state": "populated", "operationCount": "01", "operations": ["inspect"]}),
        json!({"state": "populated", "operationCount": "1", "operations": [""]}),
        json!({"state": "populated", "operationCount": 1, "operations": ["inspect"]}),
    ] {
        rejects(&schema, value);
    }
}
