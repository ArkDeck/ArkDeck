//! The target-bound Debug read. All observation and execution remain in Runtime.
use crate::{CliError, Invocation};
use serde_json::{Map, Value};

pub(crate) fn configure(
    command: &str,
    fields: &Map<String, Value>,
    help: bool,
) -> Result<(), CliError> {
    if command == "debug.probe" && !help {
        let target = fields
            .get("targetId")
            .and_then(Value::as_str)
            .ok_or_else(|| CliError::new("invalidOption", "debug probe requires --target <id>"))?;
        if target.is_empty() || target.len() > 128 {
            return Err(CliError::new(
                "invalidInput",
                "targetId must be a bounded durable target identity",
            ));
        }
    }
    Ok(())
}

pub fn validate_debug_probe(invocation: &Invocation, value: &Value) -> Result<(), CliError> {
    if invocation.command != "debug.probe" {
        return Ok(());
    }
    let invalid = || {
        CliError::new(
            "recordUnreadable",
            "Runtime returned an invalid target-bound Debug probe",
        )
    };
    if !crate::read_only_resources::keys(
        value,
        &[
            "schemaVersion",
            "targetId",
            "bindingRevision",
            "packages",
            "portRules",
            "warnings",
        ],
    ) || value["schemaVersion"] != "arkdeck.debug-probe/1"
        || invocation.params.as_ref().and_then(|p| p.get("targetId")) != value.get("targetId")
        || !value["bindingRevision"].as_u64().is_some_and(|v| v > 0)
    {
        return Err(invalid());
    }
    let packages = value["packages"].as_array().ok_or_else(invalid)?;
    let mut previous = None;
    if packages.len() > 10_000 {
        return Err(invalid());
    }
    for item in packages {
        let name = item.as_str().ok_or_else(invalid)?;
        if name.len() > 200
            || !name.contains('.')
            || !name.split('.').all(|part| {
                part.as_bytes().first().is_some_and(u8::is_ascii_alphabetic)
                    && part.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_')
            })
            || previous.is_some_and(|p| p >= name)
        {
            return Err(invalid());
        }
        previous = Some(name);
    }
    let rules = value["portRules"].as_array().ok_or_else(invalid)?;
    let mut previous = None;
    if rules.len() > 4096 {
        return Err(invalid());
    }
    for rule in rules {
        if !crate::read_only_resources::keys(rule, &["direction", "localPort", "remotePort"]) {
            return Err(invalid());
        }
        let direction = rule["direction"]
            .as_str()
            .filter(|s| matches!(*s, "forward" | "reverse"))
            .ok_or_else(invalid)?;
        let port = |key| {
            rule[key]
                .as_u64()
                .filter(|p| (1..=65535).contains(p))
                .ok_or_else(invalid)
        };
        let key = (direction, port("localPort")?, port("remotePort")?);
        if previous.is_some_and(|p| p > key) {
            return Err(invalid());
        }
        previous = Some(key);
    }
    let warnings = value["warnings"].as_array().ok_or_else(invalid)?;
    let mut previous = None;
    if warnings.len() > 4 {
        return Err(invalid());
    }
    for warning in warnings {
        let warning = warning
            .as_str()
            .filter(|s| {
                matches!(
                    *s,
                    "packageInventoryUnavailable"
                        | "packageInventoryUnparseable"
                        | "forwardRulesUnavailable"
                        | "reverseRulesUnavailable"
                )
            })
            .ok_or_else(invalid)?;
        if previous.is_some_and(|p| p >= warning) {
            return Err(invalid());
        }
        previous = Some(warning);
    }
    Ok(())
}
