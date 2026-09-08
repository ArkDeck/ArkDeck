use crate::{ContractError, METHOD_SCHEMAS};
use serde_json::Value;
use std::collections::BTreeMap;
use std::sync::OnceLock;

/// Only the closed vocabulary actually published by the Swift generator.
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
    let failure = || ContractError::SchemaMismatch;
    if let Some(alternatives) = schema.get("anyOf").and_then(Value::as_array)
        && !alternatives.iter().any(|s| validate(s, value).is_ok())
    {
        return Err(failure());
    }
    if let Some(variants) = schema.get("enum").and_then(Value::as_array)
        && !variants.contains(value)
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
                validate(child, value)?;
            } else if schema.get("additionalProperties") == Some(&Value::Bool(false)) {
                return Err(failure());
            }
        }
    }
    if let Some(items) = value.as_array()
        && let Some(item_schema) = schema.get("items")
    {
        for item in items {
            validate(item_schema, item)?;
        }
    }
    Ok(())
}
