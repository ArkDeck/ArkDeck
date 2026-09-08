use crate::{ContractError, METHOD_SCHEMAS};
use serde_json::{Number, Value};
use std::collections::{BTreeMap, BTreeSet};
use std::sync::OnceLock;

/// Only the closed vocabulary implemented for the Swift contract generator.
/// The generator refuses a new keyword until its Rust validator is implemented.
pub fn validate_method_value(method: &str, part: &str, value: &Value) -> Result<(), ContractError> {
    static SCHEMAS: OnceLock<BTreeMap<&str, Value>> = OnceLock::new();
    let schemas = SCHEMAS.get_or_init(|| {
        METHOD_SCHEMAS
            .iter()
            .map(|(method, text)| {
                (
                    *method,
                    serde_json::from_str(text).expect("generated schema"),
                )
            })
            .collect()
    });
    let schema = schemas
        .get(method)
        .and_then(|s| s["$defs"].get(part))
        .ok_or(ContractError::UnknownMethod)?;
    validate(schema, value)
}

fn validate(schema: &Value, value: &Value) -> Result<(), ContractError> {
    // Inspect every schema branch first. A definition error under `not` or an
    // unused alternative must never become a successful instance match.
    validate_schema(schema)?;
    validate_instance(schema, value)
}

fn known_type(kind: &str) -> bool {
    matches!(
        kind,
        "null" | "string" | "boolean" | "object" | "array" | "number" | "integer"
    )
}

#[derive(serde::Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct SupportedPatterns {
    lowercase_sha256: String,
    nonnegative_int64_decimal: String,
}

fn supported_patterns() -> &'static SupportedPatterns {
    static PATTERNS: OnceLock<SupportedPatterns> = OnceLock::new();
    PATTERNS.get_or_init(|| {
        serde_json::from_str(include_str!("schema_patterns.json"))
            .expect("checked-in schema pattern vocabulary")
    })
}

fn supported_pattern(pattern: &str) -> bool {
    let patterns = supported_patterns();
    pattern == patterns.lowercase_sha256 || pattern == patterns.nonnegative_int64_decimal
}

fn validate_schema(schema: &Value) -> Result<(), ContractError> {
    let failure = || ContractError::SchemaMismatch;
    let fields = schema.as_object().ok_or_else(failure)?;
    for (key, constraint) in fields {
        match key.as_str() {
            "type" => {
                let valid = if let Some(kind) = constraint.as_str() {
                    known_type(kind)
                } else if let Some(kinds) = constraint.as_array() {
                    let mut seen = BTreeSet::new();
                    !kinds.is_empty()
                        && kinds.iter().all(|kind| {
                            kind.as_str()
                                .is_some_and(|kind| known_type(kind) && seen.insert(kind))
                        })
                } else {
                    false
                };
                if !valid {
                    return Err(failure());
                }
            }
            "properties" => {
                for child in constraint.as_object().ok_or_else(failure)?.values() {
                    validate_schema(child)?;
                }
            }
            "required" => {
                let required = constraint.as_array().ok_or_else(failure)?;
                let mut seen = BTreeSet::new();
                if !required
                    .iter()
                    .all(|key| key.as_str().is_some_and(|key| seen.insert(key)))
                {
                    return Err(failure());
                }
            }
            "items" | "not" => validate_schema(constraint)?,
            "additionalProperties" if constraint.is_boolean() => {}
            "enum"
                if constraint
                    .as_array()
                    .is_some_and(|values| !values.is_empty()) => {}
            "anyOf" | "oneOf" => {
                let alternatives = constraint.as_array().ok_or_else(failure)?;
                if alternatives.is_empty() {
                    return Err(failure());
                }
                for child in alternatives {
                    validate_schema(child)?;
                }
            }
            "const" => {} // The value is data, so its keys are not schema keywords.
            "minLength" if constraint.as_u64().is_some() => {}
            "pattern" if constraint.as_str().is_some_and(supported_pattern) => {}
            _ => return Err(failure()),
        }
    }
    Ok(())
}

fn integer_equals_float(integer: &Number, float: f64) -> bool {
    if !float.is_finite() || float.fract() != 0.0 {
        return false;
    }
    // Bounds are exclusive at 2^63/2^64. Rust's saturating float casts would
    // otherwise make those floats equal the corresponding maximum integer.
    if let Some(integer) = integer.as_i64() {
        ((i64::MIN as f64)..-(i64::MIN as f64)).contains(&float) && float as i64 == integer
    } else if let Some(integer) = integer.as_u64() {
        (0.0..(u64::MAX as f64)).contains(&float) && float as u64 == integer
    } else {
        false
    }
}

fn equal_values(left: &Value, right: &Value) -> bool {
    match (left, right) {
        (Value::Number(left), Value::Number(right)) => {
            if left == right {
                true
            } else if left.is_f64() && !right.is_f64() {
                integer_equals_float(right, left.as_f64().expect("JSON number"))
            } else if right.is_f64() && !left.is_f64() {
                integer_equals_float(left, right.as_f64().expect("JSON number"))
            } else {
                false
            }
        }
        (Value::Array(left), Value::Array(right)) => {
            left.len() == right.len()
                && left
                    .iter()
                    .zip(right)
                    .all(|(left, right)| equal_values(left, right))
        }
        (Value::Object(left), Value::Object(right)) => {
            left.len() == right.len()
                && left.iter().all(|(key, left)| {
                    right
                        .get(key)
                        .is_some_and(|right| equal_values(left, right))
                })
        }
        _ => left == right,
    }
}

fn matches_pattern(pattern: &str, value: &str) -> bool {
    let patterns = supported_patterns();
    if pattern == patterns.lowercase_sha256 {
        value.len() == 64
            && value
                .bytes()
                .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
    } else if pattern == patterns.nonnegative_int64_decimal {
        !value.is_empty()
            && value.len() <= 19
            && (value == "0" || !value.starts_with('0'))
            && value.bytes().all(|byte| byte.is_ascii_digit())
            && value.parse::<i64>().is_ok()
    } else {
        false
    }
}

fn validate_instance(schema: &Value, value: &Value) -> Result<(), ContractError> {
    let failure = || ContractError::SchemaMismatch;
    if let Some(alternatives) = schema.get("anyOf").and_then(Value::as_array)
        && !alternatives
            .iter()
            .any(|s| validate_instance(s, value).is_ok())
    {
        return Err(failure());
    }
    if let Some(alternatives) = schema.get("oneOf").and_then(Value::as_array)
        && alternatives
            .iter()
            .filter(|s| validate_instance(s, value).is_ok())
            .take(2)
            .count()
            != 1
    {
        return Err(failure());
    }
    if let Some(excluded) = schema.get("not")
        && validate_instance(excluded, value).is_ok()
    {
        return Err(failure());
    }
    if let Some(constant) = schema.get("const")
        && !equal_values(constant, value)
    {
        return Err(failure());
    }
    if let Some(variants) = schema.get("enum").and_then(Value::as_array)
        && !variants.iter().any(|variant| equal_values(variant, value))
    {
        return Err(failure());
    }
    fn matches(kind: &str, value: &Value) -> bool {
        match kind {
            "null" => value.is_null(),
            "string" => value.is_string(),
            "boolean" => value.is_boolean(),
            "object" => value.is_object(),
            "array" => value.is_array(),
            "number" => value.is_number(),
            "integer" => {
                value.as_i64().is_some()
                    || value.as_u64().is_some()
                    || value.as_f64().is_some_and(|n| n.fract() == 0.0)
            }
            _ => false,
        }
    }
    if let Some(kind) = schema.get("type") {
        let valid = if let Some(kind) = kind.as_str() {
            matches(kind, value)
        } else {
            kind.as_array().is_some_and(|kinds| {
                kinds
                    .iter()
                    .any(|k| k.as_str().is_some_and(|s| matches(s, value)))
            })
        };
        if !valid {
            return Err(failure());
        }
    }
    if let Some(text) = value.as_str() {
        if let Some(minimum) = schema.get("minLength").and_then(Value::as_u64)
            && (text.chars().count() as u64) < minimum
        {
            return Err(failure());
        }
        if let Some(pattern) = schema.get("pattern").and_then(Value::as_str)
            && !matches_pattern(pattern, text)
        {
            return Err(failure());
        }
    }
    if let Some(fields) = value.as_object() {
        if let Some(required) = schema.get("required").and_then(Value::as_array)
            && required
                .iter()
                .any(|key| !key.as_str().is_some_and(|key| fields.contains_key(key)))
        {
            return Err(failure());
        }
        for (key, value) in fields {
            if let Some(child) = schema.get("properties").and_then(|p| p.get(key)) {
                validate_instance(child, value)?;
            } else if schema.get("additionalProperties") == Some(&Value::Bool(false)) {
                return Err(failure());
            }
        }
    }
    if let Some(items) = value.as_array()
        && let Some(item_schema) = schema.get("items")
    {
        for item in items {
            validate_instance(item_schema, item)?;
        }
    }
    Ok(())
}

#[cfg(test)]
#[path = "schema_tests.rs"]
mod tests;
