//! `operation validate` — the local half of "will this be accepted".
//!
//! Swift `CLIOperationInputValidation` and `RuntimeCLI.{emitOperationValidation,
//! boundedInputDocument}`. The descriptor is the one `operation.describe`
//! published, never the catalog compiled into this binary: a CLI and a daemon
//! can be different builds, and validating against the local copy would tell a
//! caller their inputs are fine while the running Runtime is about to refuse
//! them. Passing is not admission, and the answer says so by naming the digest
//! that judged it.
use crate::CliError;
use serde_json::{Map, Value, json};
use std::io::Read;

const MAXIMUM_INPUT_BYTES: usize = 3 * 1024 * 1024;

/// §5.3: one UTF-8 JSON document, from a file or from stdin, refused before
/// anything is judged if it is over the bound, not UTF-8, or repeats a key.
pub fn bounded_input_document(path: &str) -> Result<Value, CliError> {
    let bytes = if path == "-" {
        let mut bytes = Vec::new();
        std::io::stdin()
            .lock()
            .read_to_end(&mut bytes)
            .map_err(|_| CliError::new("ioFailure", "cannot read typed inputs from -"))?;
        bytes
    } else {
        std::fs::read(path).map_err(|_| {
            CliError::new("ioFailure", format!("cannot read typed inputs from {path}"))
        })?
    };
    if bytes.len() > MAXIMUM_INPUT_BYTES {
        return Err(CliError::new(
            "inputTooLarge",
            format!(
                "typed inputs are {} bytes; the limit is {MAXIMUM_INPUT_BYTES}",
                bytes.len()
            ),
        ));
    }
    if bytes.starts_with(&[0xEF, 0xBB, 0xBF]) {
        return Err(CliError::new(
            "invalidInput",
            "typed inputs must be UTF-8 without a byte order mark",
        ));
    }
    let text = std::str::from_utf8(&bytes)
        .map_err(|_| CliError::new("invalidInput", "typed inputs must be UTF-8"))?;
    // Strict rather than the parser alone: a repeated key would otherwise be
    // resolved silently, and which of the two values survived would depend on
    // the parser rather than on the document the caller wrote.
    if let Some(key) = first_duplicate_key(text) {
        return Err(CliError::new(
            "invalidInput",
            format!(
                "typed inputs repeat the key {key}; one of the two values would be lost silently"
            ),
        ));
    }
    serde_json::from_str(text).map_err(|_| {
        CliError::new(
            "invalidInput",
            "typed inputs are not one valid JSON document",
        )
    })
}

/// Swift `CLIStrictJSON.firstDuplicateKey`: a key repeated within one object.
///
/// Done on the text because the parsed value cannot show it — by the time a map
/// exists the duplicate is already gone. The scan tracks string and escape
/// state, so a brace or a quote inside a string is not mistaken for structure.
fn first_duplicate_key(text: &str) -> Option<String> {
    let mut stack: Vec<Vec<String>> = Vec::new();
    let mut pending: Option<String> = None;
    let mut current = String::new();
    let (mut in_string, mut escaped, mut expecting_key) = (false, false, false);
    for character in text.chars() {
        if in_string {
            if escaped {
                current.push(character);
                escaped = false;
            } else if character == '\\' {
                current.push(character);
                escaped = true;
            } else if character == '"' {
                in_string = false;
                if expecting_key {
                    pending = Some(unescaped(&current));
                }
            } else {
                current.push(character);
            }
            continue;
        }
        match character {
            '"' => {
                in_string = true;
                current.clear();
            }
            '{' => {
                stack.push(Vec::new());
                expecting_key = true;
            }
            '}' => {
                stack.pop();
                expecting_key = !stack.is_empty();
            }
            '[' => expecting_key = false,
            ']' => expecting_key = !stack.is_empty(),
            ':' => {
                if let (Some(key), Some(keys)) = (pending.take(), stack.last_mut()) {
                    if keys.contains(&key) {
                        return Some(key);
                    }
                    keys.push(key);
                }
                expecting_key = false;
            }
            ',' => expecting_key = !stack.is_empty(),
            _ => (),
        }
    }
    None
}

/// Only the escapes that can appear inside a key matter here: two keys are the
/// same key whether or not one spelled a character with `\u`.
fn unescaped(raw: &str) -> String {
    if !raw.contains('\\') {
        return raw.to_owned();
    }
    serde_json::from_str::<String>(&format!("\"{raw}\"")).unwrap_or_else(|_| raw.to_owned())
}

/// Swift `CLIOperationInputValidation.findings`: the structural check of typed
/// inputs against the descriptor's published field list, in the descriptor's
/// order, then the supplied keys it does not declare, sorted.
pub fn input_findings(document: &Value, inputs: &[Value]) -> Vec<Value> {
    let Some(supplied) = document.as_object() else {
        return vec![finding(
            "",
            "notAnObject",
            "typed inputs must be a JSON object at the root",
        )];
    };
    let mut findings = Vec::new();
    let mut declared: Vec<&str> = Vec::new();
    for descriptor in inputs {
        let Some(field) = descriptor.as_object() else {
            continue;
        };
        let Some(name) = field.get("name").and_then(Value::as_str) else {
            continue;
        };
        declared.push(name);
        match supplied.get(name) {
            None => {
                if field.get("required") == Some(&json!(true)) {
                    findings.push(finding(
                        name,
                        "missingRequired",
                        format!("{name} is required and was not supplied"),
                    ));
                }
            }
            Some(value) => findings.extend(check(value, name, field)),
        }
    }
    // §5.3 makes the input document exact: an unrecognised key is a caller
    // mistake, not decoration to ignore. Reporting it here is the difference
    // between a typo found before dispatch and one found after.
    let mut unknown: Vec<&String> = supplied
        .keys()
        .filter(|name| !declared.contains(&name.as_str()))
        .collect();
    unknown.sort();
    for name in unknown {
        findings.push(finding(
            name,
            "unknownField",
            format!("{name} is not declared by this operation"),
        ));
    }
    findings
}

fn finding(field: &str, code: &str, message: impl Into<String>) -> Value {
    json!({"field": field, "code": code, "message": message.into()})
}

fn check(value: &Value, name: &str, field: &Map<String, Value>) -> Vec<Value> {
    let Some(raw_type) = field.get("type").and_then(Value::as_str) else {
        return Vec::new();
    };
    if !declared_type(raw_type) {
        return Vec::new();
    }
    if !type_matches(value, raw_type) {
        // Every other check reads the value as its declared type, so once the
        // type is wrong the rest would only restate it.
        return vec![finding(
            name,
            "typeMismatch",
            format!("{name} must be {raw_type}"),
        )];
    }
    let mut findings = Vec::new();
    if let Some(allowed) = field.get("enum").and_then(Value::as_array)
        && !allowed.contains(value)
    {
        let rendered: Vec<&str> = allowed.iter().filter_map(Value::as_str).collect();
        findings.push(finding(
            name,
            "notInEnum",
            format!("{name} must be one of {}", rendered.join(", ")),
        ));
    }
    if let (Some(pattern), Some(text)) =
        (field.get("pattern").and_then(Value::as_str), value.as_str())
        && !pattern_matches(pattern, text)
    {
        findings.push(finding(
            name,
            "patternMismatch",
            format!("{name} must match {pattern}"),
        ));
    }
    if let Some(number) = integer(value) {
        if let Some(minimum) = field.get("minimum").and_then(integer)
            && number < minimum
        {
            findings.push(finding(
                name,
                "outOfRange",
                format!("{name} must be at least {minimum}"),
            ));
        }
        if let Some(maximum) = field.get("maximum").and_then(integer)
            && number > maximum
        {
            findings.push(finding(
                name,
                "outOfRange",
                format!("{name} must be at most {maximum}"),
            ));
        }
    }
    if let (Some(text), Some(maximum)) = (value.as_str(), field.get("maxLength").and_then(integer))
        // Swift counts unicode scalars, which is what `chars()` yields.
        && text.chars().count() as i64 > maximum
    {
        findings.push(finding(
            name,
            "tooLong",
            format!("{name} must be at most {maximum} characters"),
        ));
    }
    if let (Some(items), Some(maximum)) =
        (value.as_array(), field.get("maxItems").and_then(integer))
        && items.len() as i64 > maximum
    {
        findings.push(finding(
            name,
            "tooManyItems",
            format!("{name} must have at most {maximum} items"),
        ));
    }
    findings
}

/// An integer as the catalog means it: never a float, never a string.
fn integer(value: &Value) -> Option<i64> {
    value
        .as_i64()
        .or_else(|| value.as_u64().and_then(|number| i64::try_from(number).ok()))
}

/// `CatalogFieldType`. A type this build does not know is not a caller error:
/// Swift's `CatalogFieldType(rawValue:)` fails the same way and checks nothing.
fn declared_type(raw_type: &str) -> bool {
    matches!(
        raw_type,
        "string"
            | "integer"
            | "boolean"
            | "stringArray"
            | "artifactLease"
            | "artifactLeaseArray"
            | "artifactReference"
    )
}

fn type_matches(value: &Value, raw_type: &str) -> bool {
    match raw_type {
        "string" | "artifactLease" | "artifactReference" => value.is_string(),
        "integer" => value.is_i64() || value.is_u64(),
        "boolean" => value.is_boolean(),
        "stringArray" | "artifactLeaseArray" => value
            .as_array()
            .is_some_and(|items| items.iter().all(Value::is_string)),
        _ => false,
    }
}

/// The catalog's published field patterns, each matched by hand.
///
/// This CLI has no regular-expression engine, and `arkdeck-contract`'s schema
/// compiler answers the same question the same way: a closed vocabulary of the
/// patterns the published contract actually uses (`schema_patterns.json`).
/// A pattern outside it passes, which is Swift's own answer for a pattern its
/// build cannot compile — reporting it would refuse a document the Runtime
/// accepts. `catalog_patterns_are_all_matched_by_hand` keeps the vocabulary
/// closed: a catalog that publishes a new pattern fails there.
fn pattern_matches(pattern: &str, text: &str) -> bool {
    let bytes = text.as_bytes();
    match pattern {
        // An identifier, and the dotted identifier of a process or class.
        "^[a-zA-Z][a-zA-Z0-9_.]*$" => head_then(
            bytes,
            |b| b.is_ascii_alphabetic(),
            |b| b.is_ascii_alphanumeric() || b == b'_' || b == b'.',
        ),
        "^[a-zA-Z][a-zA-Z0-9_.:]*$" => head_then(
            bytes,
            |b| b.is_ascii_alphabetic(),
            |b| b.is_ascii_alphanumeric() || b == b'_' || b == b'.' || b == b':',
        ),
        "^[a-zA-Z][a-zA-Z0-9_]*(?:\\.[a-zA-Z][a-zA-Z0-9_]*)+$" => {
            let segments: Vec<&str> = text.split('.').collect();
            segments.len() > 1
                && segments.iter().all(|segment| {
                    head_then(
                        segment.as_bytes(),
                        |b| b.is_ascii_alphabetic(),
                        |b| b.is_ascii_alphanumeric() || b == b'_',
                    )
                })
        }
        // A bounded decimal, and a lowercase SHA-256.
        "^[0-9]{1,20}$" => (1..=20).contains(&bytes.len()) && bytes.iter().all(u8::is_ascii_digit),
        "^[0-9a-f]{64}$" => {
            bytes.len() == 64
                && bytes
                    .iter()
                    .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(b))
        }
        // A provider-scoped key, and a shared-object file name.
        "^[a-z]+-[A-Za-z0-9._-]{1,180}$" => match text.split_once('-') {
            Some((head, rest)) => {
                !head.is_empty()
                    && head.bytes().all(|b| b.is_ascii_lowercase())
                    && (1..=180).contains(&rest.len())
                    && rest
                        .bytes()
                        .all(|b| b.is_ascii_alphanumeric() || b == b'.' || b == b'_' || b == b'-')
            }
            None => false,
        },
        "^lib[a-zA-Z0-9_.-]+\\.so$" => match (text.strip_prefix("lib"), text.strip_suffix(".so")) {
            (Some(_), Some(_)) => {
                let middle = &text["lib".len()..text.len() - ".so".len()];
                !middle.is_empty()
                    && middle
                        .bytes()
                        .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'.' || b == b'-')
            }
            _ => false,
        },
        // UTC timestamps: milliseconds with an optional label, microseconds.
        "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]{1,3})?Z(#[A-Za-z0-9 ._-]{1,64})?$" =>
        {
            let (stamp, label) = match text.split_once('#') {
                Some((stamp, label)) => (stamp, Some(label)),
                None => (text, None),
            };
            timestamp(stamp, 3)
                && label.is_none_or(|label| {
                    (1..=64).contains(&label.len())
                        && label.bytes().all(|b| {
                            b.is_ascii_alphanumeric()
                                || b == b' '
                                || b == b'.'
                                || b == b'_'
                                || b == b'-'
                        })
                })
        }
        "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]{1,6})?Z$" => {
            timestamp(text, 6)
        }
        _ => true,
    }
}

fn head_then(bytes: &[u8], head: impl Fn(u8) -> bool, rest: impl Fn(u8) -> bool) -> bool {
    match bytes.split_first() {
        Some((first, tail)) => head(*first) && tail.iter().all(|b| rest(*b)),
        None => false,
    }
}

/// `YYYY-MM-DDTHH:MM:SS` with an optional fraction of at most `digits` digits,
/// then `Z`. Only the shape is judged here, as the pattern judges it.
fn timestamp(text: &str, digits: usize) -> bool {
    let Some(body) = text.strip_suffix('Z') else {
        return false;
    };
    let (head, fraction) = match body.split_once('.') {
        Some((head, fraction)) => (head, Some(fraction)),
        None => (body, None),
    };
    let shape = "0000-00-00T00:00:00";
    head.len() == shape.len()
        && head.bytes().zip(shape.bytes()).all(|(byte, expected)| {
            if expected == b'0' {
                byte.is_ascii_digit()
            } else {
                byte == expected
            }
        })
        && fraction.is_none_or(|fraction| {
            (1..=digits).contains(&fraction.len()) && fraction.bytes().all(|b| b.is_ascii_digit())
        })
}

/// The one document this leaf emits, whatever the findings say.
pub fn validation_document(reference: &str, findings: Vec<Value>, digest: Value) -> Value {
    json!({
        "reference": reference,
        "structurallyValid": findings.is_empty(),
        "findings": findings,
        "checkedAgainst": {"runtimeCatalogDigest": digest, "scope": "publishedInputContract"},
    })
}

/// The exit a validated answer earns. The document is emitted either way — the
/// caller asked what the descriptor says, and it answered — so a document with
/// findings reports them after it, as Swift's post-emit failure does.
pub fn validation_attention(result: &Value) -> Option<(u8, String)> {
    let count = result["findings"].as_array().map_or(0, Vec::len);
    (count > 0).then(|| {
        (
            65,
            format!(
                "{count} input problem{} for {}",
                if count == 1 { "" } else { "s" },
                result["reference"].as_str().unwrap_or_default()
            ),
        )
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use arkdeck_contract::CATALOG_CANONICAL_JSON;

    fn field(body: Value) -> Value {
        body
    }

    fn codes(document: Value, inputs: &[Value]) -> Vec<(String, String)> {
        input_findings(&document, inputs)
            .into_iter()
            .map(|finding| {
                (
                    finding["field"].as_str().unwrap().to_owned(),
                    finding["code"].as_str().unwrap().to_owned(),
                )
            })
            .collect()
    }

    #[test]
    fn each_published_constraint_answers_swifts_finding() {
        let inputs = [
            field(json!({"name":"kind","type":"string","required":true,
                "enum":["context","cpu"],"maxLength":4})),
            field(json!({"name":"limit","type":"integer","minimum":1,"maximum":10})),
            field(json!({"name":"deep","type":"boolean"})),
            field(json!({"name":"tags","type":"stringArray","maxItems":2})),
            field(json!({"name":"process","type":"string","pattern":"^[a-zA-Z][a-zA-Z0-9_.]*$"})),
        ];
        // A document that satisfies every one of them has no findings.
        assert!(
            input_findings(
                &json!({"kind":"cpu","limit":5,"deep":true,"tags":["a"],"process":"com.a_1"}),
                &inputs
            )
            .is_empty()
        );
        assert_eq!(
            codes(json!({}), &inputs),
            [("kind".to_owned(), "missingRequired".to_owned())]
        );
        assert_eq!(
            codes(
                // `nope` is within maxLength: an over-long value would earn
                // both findings, which the pair below shows.
                json!({"kind":"nope","limit":0,"deep":1,"tags":["a","b","c"],
                    "process":"1bad","extra":true,"also":1}),
                &inputs
            ),
            [
                ("kind".to_owned(), "notInEnum".to_owned()),
                ("limit".to_owned(), "outOfRange".to_owned()),
                ("deep".to_owned(), "typeMismatch".to_owned()),
                ("tags".to_owned(), "tooManyItems".to_owned()),
                ("process".to_owned(), "patternMismatch".to_owned()),
                // The keys the descriptor does not declare, sorted, last.
                ("also".to_owned(), "unknownField".to_owned()),
                ("extra".to_owned(), "unknownField".to_owned()),
            ]
        );
        // The type decides alone: once it is wrong the other checks would only
        // restate it, and an enum of the wrong type is the type's finding.
        assert_eq!(
            codes(json!({"kind":7,"limit":"5","tags":"a"}), &inputs),
            [
                ("kind".to_owned(), "typeMismatch".to_owned()),
                ("limit".to_owned(), "typeMismatch".to_owned()),
                ("tags".to_owned(), "typeMismatch".to_owned()),
            ]
        );
        assert_eq!(
            codes(json!({"kind":"cpuu"}), &inputs),
            [("kind".to_owned(), "notInEnum".to_owned())]
        );
        assert_eq!(
            codes(json!({"kind":"cpuuu"}), &inputs),
            [
                ("kind".to_owned(), "notInEnum".to_owned()),
                ("kind".to_owned(), "tooLong".to_owned()),
            ]
        );
        // A root that is not an object is the one finding there is, and a
        // field type this build does not know checks nothing.
        assert_eq!(
            codes(json!([1]), &inputs),
            [(String::new(), "notAnObject".to_owned())]
        );
        assert!(
            input_findings(
                &json!({"opaque":{"a":1}}),
                &[field(
                    json!({"name":"opaque","type":"catalogTypeFromALaterBuild"})
                )]
            )
            .is_empty()
        );
    }

    #[test]
    fn catalog_patterns_are_all_matched_by_hand() {
        // The vocabulary is closed: every pattern the published catalog uses is
        // one `pattern_matches` decides. A new one would pass silently, which
        // is Swift's answer for a pattern it cannot compile — this test is what
        // keeps that from happening quietly.
        let catalog: Value = serde_json::from_str(CATALOG_CANONICAL_JSON).unwrap();
        let mut patterns: Vec<String> = Vec::new();
        for operation in catalog.as_array().unwrap() {
            for (_, declared) in operation["inputs"]["fields"].as_object().unwrap() {
                if let Some(pattern) = declared["pattern"].as_str() {
                    patterns.push(pattern.to_owned());
                }
            }
        }
        patterns.sort();
        patterns.dedup();
        assert!(patterns.len() >= 9, "{patterns:?}");
        for pattern in &patterns {
            assert!(
                !pattern_matches(pattern, "\u{0}unmatchable\u{0}"),
                "{pattern} is not one this build matches by hand"
            );
        }
    }

    #[test]
    fn hand_matched_patterns_accept_and_refuse_what_the_pattern_says() {
        for (pattern, accepted, refused) in [
            (
                "^[a-zA-Z][a-zA-Z0-9_.]*$",
                vec!["a", "com.example_1"],
                vec!["", "1a", "a-b", "a:b"],
            ),
            (
                "^[a-zA-Z][a-zA-Z0-9_.:]*$",
                vec!["a:b.c_1"],
                vec!["", ":a", "a-b"],
            ),
            (
                "^[a-zA-Z][a-zA-Z0-9_]*(?:\\.[a-zA-Z][a-zA-Z0-9_]*)+$",
                vec!["com.example", "a.b.c"],
                vec!["a", "a.", ".a", "a..b", "a.1b"],
            ),
            (
                "^[0-9]{1,20}$",
                vec!["0", &"9".repeat(20)],
                vec!["", &"9".repeat(21), "1a"],
            ),
            (
                "^[0-9a-f]{64}$",
                vec![&"a".repeat(64)],
                vec![&"A".repeat(64), &"a".repeat(63)],
            ),
            (
                "^[a-z]+-[A-Za-z0-9._-]{1,180}$",
                vec!["hdc-abc_1.2-3"],
                vec!["-a", "A-b", "hdc-", &format!("hdc-{}", "a".repeat(181))],
            ),
            (
                "^lib[a-zA-Z0-9_.-]+\\.so$",
                vec!["libfoo.so", "libfoo-1.2.so"],
                vec!["lib.so", "foo.so", "libfoo.dylib"],
            ),
            (
                "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]{1,3})?Z(#[A-Za-z0-9 ._-]{1,64})?$",
                vec!["2026-09-20T10:00:00Z", "2026-09-20T10:00:00.123Z#a label_1"],
                vec![
                    "2026-09-20T10:00:00",
                    "2026-09-20T10:00:00.1234Z",
                    "2026-09-20T10:00:00Z#",
                    "2026-09-20T10:00:00Z#a/b",
                ],
            ),
            (
                "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]{1,6})?Z$",
                vec!["2026-09-20T10:00:00.123456Z"],
                vec!["2026-09-20T10:00:00.1234567Z", "2026-09-20T10:00:00Z#x"],
            ),
        ] {
            for text in accepted {
                assert!(pattern_matches(pattern, text), "{pattern} refused {text}");
            }
            for text in refused {
                assert!(!pattern_matches(pattern, text), "{pattern} accepted {text}");
            }
        }
    }

    #[test]
    fn a_bounded_document_is_one_utf8_json_document_without_a_repeated_key() {
        // The host's own temporary directory: this test runs on every
        // platform the workspace builds for, and `/private/tmp` is macOS's.
        let root = std::env::temp_dir().join(format!(
            "arkdeck-cli-inputs-{:032x}",
            u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap())
        ));
        std::fs::create_dir(&root).unwrap();
        let write = |name: &str, bytes: &[u8]| {
            let path = root.join(name);
            std::fs::write(&path, bytes).unwrap();
            path.to_str().unwrap().to_owned()
        };
        let read = |path: &str| bounded_input_document(path).map_err(|error| error.code);
        assert_eq!(
            read(&write("ok.json", br#"{"a":1,"b":{"a":2}}"#)).unwrap(),
            json!({"a":1,"b":{"a":2}})
        );
        assert_eq!(
            read(root.join("missing.json").to_str().unwrap()),
            Err("ioFailure")
        );
        assert_eq!(
            read(&write("bom.json", b"\xEF\xBB\xBF{}")),
            Err("invalidInput")
        );
        assert_eq!(
            read(&write("latin1.json", b"{\"a\":\"\xFF\"}")),
            Err("invalidInput")
        );
        assert_eq!(read(&write("torn.json", b"{\"a\":")), Err("invalidInput"));
        // The repeat is refused even where a parser would resolve it silently,
        // and a quote or a brace inside a string is not structure.
        assert_eq!(
            read(&write("repeat.json", br#"{"a":1,"a":2}"#)),
            Err("invalidInput")
        );
        assert_eq!(
            bounded_input_document(&write("repeat.json", br#"{"a":1,"a":2}"#))
                .unwrap_err()
                .message,
            "typed inputs repeat the key a; one of the two values would be lost silently"
        );
        assert!(read(&write("strings.json", br#"{"a":"{\"a\": x","b":"}"}"#)).is_ok());
        assert!(read(&write("arrays.json", br#"{"a":[{"b":1},{"b":2}]}"#)).is_ok());
        assert_eq!(
            read(&write(
                "big.json",
                format!("{{\"a\":\"{}\"}}", "x".repeat(MAXIMUM_INPUT_BYTES)).as_bytes()
            )),
            Err("inputTooLarge")
        );
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn the_answer_reports_its_findings_after_it_is_emitted() {
        let clean = validation_document("a@1", Vec::new(), json!("digest"));
        assert_eq!(
            clean,
            json!({"reference":"a@1","structurallyValid":true,"findings":[],
                "checkedAgainst":{"runtimeCatalogDigest":"digest","scope":"publishedInputContract"}})
        );
        assert_eq!(validation_attention(&clean), None);
        let one = validation_document("a@1", vec![finding("f", "unknownField", "m")], Value::Null);
        assert_eq!(one["structurallyValid"], false);
        assert_eq!(one["checkedAgainst"]["runtimeCatalogDigest"], Value::Null);
        assert_eq!(
            validation_attention(&one),
            Some((65, "1 input problem for a@1".to_owned()))
        );
        let two = validation_document(
            "a@1",
            vec![
                finding("f", "unknownField", "m"),
                finding("g", "unknownField", "m"),
            ],
            Value::Null,
        );
        assert_eq!(
            validation_attention(&two),
            Some((65, "2 input problems for a@1".to_owned()))
        );
    }
}
