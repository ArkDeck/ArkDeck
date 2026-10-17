//! Bounded convenience commands over the existing typed Job protocol.
use crate::{CliError, Invocation};
use serde_json::{Map, Value, json};

pub fn serves(command: &str) -> bool {
    matches!(command, "flash.verify" | "flash.restore-boot-loop")
}
fn identifier(s: &Value) -> bool {
    s.as_str().is_some_and(|s| {
        (1..=128).contains(&s.len())
            && s.as_bytes()[0].is_ascii_alphanumeric()
            && s.bytes()
                .all(|c| c.is_ascii_alphanumeric() || b"._-".contains(&c))
    })
}
pub(crate) fn configure(
    command: &str,
    fields: &Map<String, Value>,
    help: bool,
) -> Result<(), CliError> {
    if serves(command) && !help && !fields.contains_key("requestFile") {
        return Err(CliError::new(
            "invalidOption",
            "maintenance requires --request-file with a complete typed request",
        ));
    }
    if serves(command)
        && fields.get("timeout").is_some_and(|v| {
            v.as_str()
                .and_then(crate::read_only_resources::duration)
                .is_none()
        })
    {
        return Err(CliError::new(
            "invalidOption",
            "invalid maintenance timeout",
        ));
    }
    Ok(())
}
/// Parameter errors are caught before a connection or durable record exists.
pub fn request(invocation: &Invocation) -> Result<(Map<String, Value>, u64), CliError> {
    let invalid = || {
        CliError::new(
            "invalidOption",
            "invalid maintenance request; no request or record was created",
        )
    };
    let path = invocation
        .params
        .as_ref()
        .and_then(|p| p.get("requestFile"))
        .and_then(Value::as_str)
        .ok_or_else(invalid)?;
    let file = std::fs::File::open(path).map_err(|_| invalid())?;
    use std::io::Read;
    let mut bytes = Vec::new();
    file.take(4 * 1024 * 1024 + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| invalid())?;
    if bytes.len() > 4 * 1024 * 1024 {
        return Err(invalid());
    }
    let value = arkdeck_contract::strict_json(&bytes).map_err(|_| invalid())?;
    let inputs = value["inputs"].as_object().ok_or_else(invalid)?;
    let restore = invocation.command == "flash.restore-boot-loop";
    let budget = inputs
        .get("budgetMs")
        .and_then(Value::as_u64)
        .filter(|n| (1_000..=600_000).contains(n))
        .ok_or_else(invalid)?;
    let expected = if restore {
        vec!["sourceJobId", "budgetMs", "artifactLease"]
    } else {
        vec!["sourceJobId", "budgetMs"]
    };
    if !value.as_object().is_some_and(|o| {
        o.keys().all(|k| {
            [
                "documentType",
                "schemaVersion",
                "requestId",
                "idempotencyKey",
                "target",
                "operation",
                "inputs",
                "requestedOutputs",
                "clientContext",
                "reviewedPlanDigest",
            ]
            .contains(&k.as_str())
        })
    }) || value["documentType"] != "runtime-operation-request"
        || value["schemaVersion"] != "1.0.0"
        || !identifier(&value["requestId"])
        || !identifier(&value["idempotencyKey"])
        || value["operation"] != json!({"id":invocation.command,"version":1})
        || !identifier(&value["target"]["targetId"])
        || value["target"]["expectedBindingRevision"]
            .as_i64()
            .is_none_or(|r| r <= 0)
        || inputs.len() != expected.len()
        || !expected.iter().all(|key| inputs.contains_key(*key))
        || !identifier(&inputs["sourceJobId"])
        || (restore
            && inputs["artifactLease"]
                .as_str()
                .is_none_or(|s| s.is_empty() || s.len() > 4096))
        || value["requestedOutputs"].as_array().is_none_or(|a| {
            a.is_empty()
                || a.iter().any(|v| {
                    !v.as_str().is_some_and(|s| {
                        ["rawArtifacts", "derivedArtifacts", "hardwareEvidence"].contains(&s)
                    })
                })
        })
    {
        return Err(invalid());
    }
    let text = String::from_utf8(bytes).map_err(|_| invalid())?;
    Ok((
        json!({"requestJson":text}).as_object().unwrap().clone(),
        budget,
    ))
}
pub fn exit_code(command: &str, status: &Value) -> u8 {
    let result = &status["maintenanceResult"];
    if command == "flash.restore-boot-loop" {
        if status["state"] == "succeeded"
            && status["outcomeUnknown"] == false
            && result["schema"] == "arkforge.boot-loop-restoration/v1"
            && result["exit_code"] == 0
        {
            0
        } else {
            1
        }
    } else if status["outcomeUnknown"] == true {
        7
    } else {
        match result["exit_code"].as_u64() {
            Some(0) if status["state"] == "succeeded" => 0,
            Some(9) if status["state"] == "succeeded" => 9,
            _ => 7,
        }
    }
}
