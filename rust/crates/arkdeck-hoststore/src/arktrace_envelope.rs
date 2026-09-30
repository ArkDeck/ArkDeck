//! What the ArkTrace wire judges share and every host can hold: the
//! contract a reviewed distribution's answers must carry, and Swift's JSON
//! token and member rules for its envelopes. Nothing here reads a file,
//! loads a distribution or runs its CLI; the loader and the doctor probe that
//! do (`arktrace_profile`, `arktrace_doctor`) stay with the macOS host
//! primitives they need.
use serde_json::{Map, Value};
use std::collections::BTreeSet;

/// Swift `ArkTraceSummaryInvocationContract`: the versions a reviewed
/// distribution produces, which every analysis it answers must carry.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ArkTraceContract {
    pub tool_version: String,
    pub parser_version: String,
    pub parser_upstream_revision: String,
    pub parser_sha256: String,
    pub parser_build_recipe_version: String,
    pub parser_adapter_version: String,
    pub schema_adapter_version: String,
    pub index_schema_version: i64,
}

/// Swift `StrictJSONIntegerTokenValidator`: every number outside a string is
/// an integer that fits in 64 bits.
pub(crate) fn integer_tokens(bytes: &[u8]) -> bool {
    let delimiter = |byte: u8| matches!(byte, b',' | b']' | b'}' | b' ' | b'\t' | b'\r' | b'\n');
    let mut index = 0;
    while index < bytes.len() {
        match bytes[index] {
            b'"' => {
                index += 1;
                loop {
                    match bytes.get(index) {
                        None => return false,
                        Some(b'"') => {
                            index += 1;
                            break;
                        }
                        Some(b'\\') => index += 2,
                        Some(_) => index += 1,
                    }
                }
            }
            b'-' | b'0'..=b'9' => {
                let start = index;
                while index < bytes.len() && !delimiter(bytes[index]) {
                    index += 1;
                }
                let valid = std::str::from_utf8(&bytes[start..index])
                    .ok()
                    .is_some_and(swift_int64);
                if !valid {
                    return false;
                }
            }
            _ => index += 1,
        }
    }
    true
}

/// `Int64(String)`: an optional sign and decimal digits, within range.
fn swift_int64(token: &str) -> bool {
    let digits = token
        .strip_prefix('-')
        .or_else(|| token.strip_prefix('+'))
        .unwrap_or(token);
    !digits.is_empty()
        && digits.bytes().all(|byte| byte.is_ascii_digit())
        && token.parse::<i64>().is_ok()
}

pub(crate) fn exact_keys(object: &Map<String, Value>, keys: &[&str]) -> bool {
    object.keys().map(String::as_str).collect::<BTreeSet<_>>()
        == keys.iter().copied().collect::<BTreeSet<_>>()
}

/// `NSNumber` whose type is a Boolean.
pub(crate) fn boolean(value: Option<&Value>) -> Option<bool> {
    value?.as_bool()
}

/// `NSNumber` whose type is not a Boolean, as a 64-bit integer.
pub(crate) fn integer(value: Option<&Value>) -> Option<i64> {
    match value? {
        Value::Number(number) => number.as_i64(),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn integer_tokens_are_swift_int64_outside_strings() {
        assert!(integer_tokens(br#"{"a":1,"b":[-2, 3],"c":"1.5e3"}"#));
        assert!(integer_tokens(b"9223372036854775807"));
        for refused in [
            &b"1.0"[..],
            b"1e3",
            b"9223372036854775808",
            b"{\"a\":-}",
            b"\"unterminated",
            b"[1,2.5]",
        ] {
            assert!(
                !integer_tokens(refused),
                "{}",
                String::from_utf8_lossy(refused)
            );
        }
    }
}
