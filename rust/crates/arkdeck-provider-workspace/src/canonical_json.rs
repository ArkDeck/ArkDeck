//! Swift `CanonicalJSONEncoders.canonicalPretty()` — Foundation `JSONEncoder`
//! with `[.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]` — for the
//! string-valued documents the signing layer writes: two-space indentation,
//! `" : "` between a key and its value, an empty container as its bracket, a
//! blank line and its close, and no trailing newline. serde escapes the same
//! set Foundation does here (quote, backslash, C0 controls with the short
//! forms and lowercase `\u00xx`) and leaves the solidus alone.
use serde_json::Value;

pub(crate) fn encode(value: &Value) -> Option<Vec<u8>> {
    let mut output = Vec::new();
    write(value, 0, &mut output)?;
    Some(output)
}

/// Swift `CanonicalJSONEncoders.canonical()` — `[.sortedKeys,
/// .withoutEscapingSlashes]` — for the same string- and integer-valued
/// documents: no whitespace at all.
pub(crate) fn encode_compact(value: &Value) -> Option<Vec<u8>> {
    let mut output = Vec::new();
    write_compact(value, &mut output)?;
    Some(output)
}

fn write_compact(value: &Value, output: &mut Vec<u8>) -> Option<()> {
    match value {
        Value::Object(fields) => {
            let mut keys: Vec<&String> = fields.keys().collect();
            keys.sort_unstable();
            output.push(b'{');
            for (index, key) in keys.iter().enumerate() {
                if index > 0 {
                    output.push(b',');
                }
                output.extend(serde_json::to_vec(key).ok()?);
                output.push(b':');
                write_compact(&fields[key.as_str()], output)?;
            }
            output.push(b'}');
        }
        Value::Array(values) => {
            output.push(b'[');
            for (index, value) in values.iter().enumerate() {
                if index > 0 {
                    output.push(b',');
                }
                write_compact(value, output)?;
            }
            output.push(b']');
        }
        Value::Number(number) if !number.is_i64() && !number.is_u64() => return None,
        other => output.extend(serde_json::to_vec(other).ok()?),
    }
    Some(())
}

fn line(output: &mut Vec<u8>, depth: usize) {
    output.push(b'\n');
    output.resize(output.len() + 2 * depth, b' ');
}

fn write(value: &Value, depth: usize, output: &mut Vec<u8>) -> Option<()> {
    match value {
        Value::Object(fields) => {
            let mut keys: Vec<&String> = fields.keys().collect();
            keys.sort_unstable();
            output.push(b'{');
            for (index, key) in keys.iter().enumerate() {
                if index > 0 {
                    output.push(b',');
                }
                line(output, depth + 1);
                output.extend(serde_json::to_vec(key).ok()?);
                output.extend_from_slice(b" : ");
                write(&fields[key.as_str()], depth + 1, output)?;
            }
            if fields.is_empty() {
                output.push(b'\n');
            }
            line(output, depth);
            output.push(b'}');
        }
        Value::Array(values) => {
            output.push(b'[');
            for (index, value) in values.iter().enumerate() {
                if index > 0 {
                    output.push(b',');
                }
                line(output, depth + 1);
                write(value, depth + 1, output)?;
            }
            if values.is_empty() {
                output.push(b'\n');
            }
            line(output, depth);
            output.push(b']');
        }
        // Floating point spellings are Foundation's own and never needed here.
        Value::Number(number) if !number.is_i64() && !number.is_u64() => return None,
        other => output.extend(serde_json::to_vec(other).ok()?),
    }
    Some(())
}

#[cfg(test)]
mod tests {
    use super::encode;
    use serde_json::json;

    /// Printed by Foundation `JSONEncoder([.sortedKeys, .prettyPrinted,
    /// .withoutEscapingSlashes])` for the same record shape.
    #[test]
    fn matches_the_foundation_spelling() {
        let value = json!({
            "summary": {"signedHapSha256": "ab", "b": "x/y", "signedHapByteCount": "12", "a": "1"},
            "schemaVersion": "arkdeck-openharmony-signing-result/v1",
        });
        assert_eq!(
            String::from_utf8(encode(&value).unwrap()).unwrap(),
            "{\n  \"schemaVersion\" : \"arkdeck-openharmony-signing-result/v1\",\n  \"summary\" : {\n    \"a\" : \"1\",\n    \"b\" : \"x/y\",\n    \"signedHapByteCount\" : \"12\",\n    \"signedHapSha256\" : \"ab\"\n  }\n}"
        );
        assert_eq!(encode(&json!({})).unwrap(), b"{\n\n}");
        assert!(encode(&json!({"a": 0.5})).is_none());
    }

    /// Printed by Foundation `JSONEncoder([.sortedKeys,
    /// .withoutEscapingSlashes])`.
    #[test]
    fn the_compact_form_matches_the_foundation_spelling() {
        let value = json!({"b": ["x/y", 2], "a": {"d": "", "c": 1}, "e": []});
        assert_eq!(
            String::from_utf8(super::encode_compact(&value).unwrap()).unwrap(),
            r#"{"a":{"c":1,"d":""},"b":["x/y",2],"e":[]}"#
        );
    }
}
