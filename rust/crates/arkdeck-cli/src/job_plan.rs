//! `job plan` and `job submit`: the current typed request, planned by the
//! Runtime without admission, or admitted idempotently without dispatch.
//! `--request-file` passes a complete document through verbatim; the flag form
//! wraps typed inputs in a request envelope as the Swift CLI does. Either way
//! the Runtime, not this CLI, validates the request.
use crate::read_only_resources::{duration, keys};
use crate::{CliError, Invocation};
use arkdeck_client::ClientError;
use arkdeck_contract::ContractError;
use serde_json::{Map, Value, json};

/// Every flag-form field is exclusive with a complete request document.
const REQUEST_FILE_EXCLUSIONS: [(&str, &str); 6] = [
    ("targetId", "--target"),
    ("operation", "--operation"),
    ("inputsFile", "--inputs-file"),
    ("expectedBindingRevision", "--expected-binding-revision"),
    ("requestId", "--request-id"),
    ("idempotencyKey", "--idempotency-key"),
];
const EFFECTS: [&str; 4] = ["hostOnly", "readOnly", "deviceMutation", "destructive"];
const PLAN_KEYS: [&str; 17] = [
    "schemaVersion",
    "executionMode",
    "operation",
    "targetId",
    "bindingRevision",
    "stableIdentitySha256",
    "providerId",
    "catalogDigest",
    "requestFingerprintSha256",
    "materializedPlanDigest",
    "inputs",
    "steps",
    "effectiveEffect",
    "authorizationPolicy",
    "providerAdmissionBlocker",
    "jobAdmitted",
    "dispatchDisposition",
];

fn usage(message: impl Into<String>) -> CliError {
    CliError::new("invalidOption", message)
}

fn subcommand(command: &str) -> &'static str {
    if command == "job.submit" {
        "job submit"
    } else {
        "job plan"
    }
}

/// Swift `AgentExecutionIntent.validIdentifier`.
fn valid_identifier(id: &str) -> bool {
    (1..=128).contains(&id.len())
        && id.as_bytes()[0].is_ascii_alphanumeric()
        && id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || b"._-".contains(&byte))
}

/// Parse-time `job plan` and `job submit` checks. Returns the client deadline,
/// 30 s unless `--timeout` names another bounded one.
pub(super) fn configure(
    command: &str,
    fields: &mut Map<String, Value>,
    help: bool,
) -> Result<Option<u64>, CliError> {
    if help || !matches!(command, "job.plan" | "job.submit") {
        return Ok(None);
    }
    if fields.contains_key("requestFile")
        && let Some((_, option)) = REQUEST_FILE_EXCLUSIONS
            .iter()
            .find(|(key, _)| fields.contains_key(*key))
    {
        let mut names = ["--request-file", option];
        names.sort_unstable();
        return Err(usage(format!(
            "`{}` accepts only one of {}",
            subcommand(command),
            names.join(", ")
        )));
    }
    if fields
        .get("expectedBindingRevision")
        .and_then(Value::as_str)
        .is_some_and(|text| !text.parse::<i64>().is_ok_and(|revision| revision >= 1))
    {
        return Err(usage(
            "--expected-binding-revision takes a positive integer",
        ));
    }
    let timeout = fields.remove("timeout").unwrap_or(json!("30s"));
    duration(timeout.as_str().unwrap_or_default())
        .map(Some)
        .ok_or_else(|| usage("timeout must be a positive duration bounded by 24h"))
}

/// A random version 4 UUID in lowercase text.
fn uuid() -> Result<String, CliError> {
    let mut bytes = arkdeck_platform::random_bytes::<16>()
        .map_err(|_| CliError::new("internalError", "no random request identity is available"))?;
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    let hex: String = bytes.iter().map(|byte| format!("{byte:02x}")).collect();
    Ok(format!(
        "{}-{}-{}-{}-{}",
        &hex[..8],
        &hex[8..12],
        &hex[12..16],
        &hex[16..20],
        &hex[20..]
    ))
}

/// The binding the published catalog declares for an exact reference.
fn catalog_binding(id: &str, version: Option<i64>) -> Option<String> {
    let catalog: Value = serde_json::from_str(arkdeck_contract::CATALOG_CANONICAL_JSON).ok()?;
    catalog
        .as_array()?
        .iter()
        .find(|operation| operation["id"] == id && operation["version"].as_i64() == version)?
        ["binding"]
        .as_str()
        .map(str::to_owned)
}

/// The document the flag form sends: Swift `operationRequestJSON` over
/// `RuntimeOperationRequest.operatorFlagForm`.
fn flag_form(fields: &Map<String, Value>, subcommand: &str) -> Result<String, CliError> {
    let text = |key: &str| fields.get(key).and_then(Value::as_str);
    let (Some(target), Some(reference)) = (text("targetId"), text("operation")) else {
        return Err(usage(format!(
            "{subcommand} requires --target <id> --operation <reference> [--inputs-file <typed-inputs.json>], or --request-file <path>"
        )));
    };
    let (operation, version) = match reference.split_once('@') {
        None => (reference, None),
        Some((id, version)) => (
            id,
            Some(
                version
                    .parse::<i64>()
                    .ok()
                    .filter(|version| *version > 0)
                    .ok_or_else(|| usage("invalid operation version"))?,
            ),
        ),
    };
    let revision = text("expectedBindingRevision").and_then(|text| text.parse::<i64>().ok());
    let inputs = match text("inputsFile") {
        None => Map::new(),
        Some(path) => {
            let bytes = std::fs::read(path).map_err(|_| usage(format!("cannot read {path}")))?;
            let Ok(Value::Object(inputs)) = serde_json::from_slice::<Value>(&bytes) else {
                return Err(usage(format!(
                    "--inputs-file must be a JSON object of typed inputs: {path}"
                )));
            };
            // A whole document here would silently lose its envelope.
            if inputs.contains_key("schemaVersion") || inputs.contains_key("operation") {
                return Err(usage(
                    "--inputs-file looks like a complete request document; pass it with --request-file, or reduce it to the inputs object",
                ));
            }
            inputs
        }
    };
    let reference = match version {
        Some(version) => format!("{operation}@{version}"),
        None => operation.to_owned(),
    };
    match (catalog_binding(operation, version).as_deref(), revision) {
        (Some("confirmedDevice"), None) => {
            return Err(usage(format!(
                "{reference} is device-bound: pass --expected-binding-revision <n> (the revision `arkdeck target list` reports for this target)"
            )));
        }
        (Some("none"), Some(_)) => {
            return Err(usage(format!(
                "{reference} is host-only: it has no binding revision to pin"
            )));
        }
        _ => (),
    }
    let mut target = json!({"targetId": target});
    if let Some(revision) = revision {
        target["expectedBindingRevision"] = json!(revision);
    }
    let mut operation = json!({"id": operation});
    if let Some(version) = version {
        operation["version"] = json!(version);
    }
    let request_id = match text("requestId") {
        Some(id) => id.to_owned(),
        None => format!("cli-{}", &uuid()?[..8]),
    };
    let idempotency_key = match text("idempotencyKey") {
        Some(key) => key.to_owned(),
        None => format!("cli-{}", uuid()?),
    };
    Ok(json!({
        "documentType": "runtime-operation-request",
        "schemaVersion": "1.0.0",
        "requestId": request_id,
        "idempotencyKey": idempotency_key,
        "target": target,
        "operation": operation,
        "inputs": inputs,
        "requestedOutputs": ["derivedArtifacts"],
    })
    .to_string())
}

fn request_params(invocation: &Invocation) -> Result<Map<String, Value>, CliError> {
    let fields = invocation.params.clone().unwrap_or_default();
    let document = match fields.get("requestFile").and_then(Value::as_str) {
        Some(path) => {
            std::fs::read_to_string(path).map_err(|_| usage(format!("cannot read {path}")))?
        }
        None => flag_form(&fields, subcommand(invocation.command))?,
    };
    Ok(Map::from_iter([("requestJson".into(), json!(document))]))
}

/// The `job.plan` parameters: exactly the request document, read from
/// `--request-file` verbatim or built from the flag form.
pub fn job_plan_params(invocation: &Invocation) -> Result<Map<String, Value>, CliError> {
    request_params(invocation)
}

/// The `job.submit` parameters, built exactly as `job plan` builds them.
pub fn job_submit_params(invocation: &Invocation) -> Result<Map<String, Value>, CliError> {
    request_params(invocation)
}

/// Swift `generatesItsOwnIdempotencyKey`: a flag-form submit without a caller
/// key uses a generated one, which a retry cannot repeat.
pub fn generates_identity(invocation: &Invocation) -> bool {
    invocation.params.as_ref().is_some_and(|fields| {
        !fields.contains_key("idempotencyKey") && !fields.contains_key("requestFile")
    })
}

/// Swift `CLIJobLifecycleValidation.validateAcceptance`: an idempotent
/// acceptance that dispatched nothing.
pub fn validate_acceptance(value: &Value) -> Result<(), CliError> {
    if !keys(
        value,
        &["schemaVersion", "jobId", "deduplicated", "newDispatchCount"],
    ) || value["schemaVersion"] != "arkdeck.job-acceptance/1"
        || !value["jobId"].as_str().is_some_and(valid_identifier)
        || !value["deduplicated"].is_boolean()
        || value["newDispatchCount"].as_i64() != Some(0)
    {
        return Err(CliError::new(
            "recordUnreadable",
            "the Runtime returned an invalid target Job acceptance",
        ));
    }
    Ok(())
}

/// Swift `CLIControlFailureMapper` for the mutation-capable `job.submit`: a
/// refusal keeps its code only with the pre-admission zero-dispatch proof;
/// any reply that cannot prove nothing was admitted is an unknown outcome.
pub(crate) fn submit_error(error: ClientError) -> CliError {
    let wire = match error {
        ClientError::Remote(wire) => wire,
        ClientError::Contract(
            ContractError::UnsupportedVersion | ContractError::ContractMismatch,
        ) => {
            return CliError::new(
                "protocolVersionUnsupported",
                "client and Runtime must use the same current control contract",
            );
        }
        _ => {
            let mut result = CliError::new(
                "outcomeUnknown",
                "the Job submission reply is unconfirmed; submit the same request again to learn its Job",
            );
            result.details.insert("method".into(), json!("job.submit"));
            return result;
        }
    };
    let proof = wire.details.as_ref().is_some_and(|details| {
        details.get("phase") == Some(&json!("preAdmission"))
            && details.get("newDispatchCount") == Some(&json!(0))
    });
    let code = match (wire.code.as_str(), proof) {
        ("invalidInput", true) | ("invalidParams", _) => "invalidInput",
        ("inputTooLarge", true) => "inputTooLarge",
        ("operationUnavailable", true) => "operationUnavailable",
        ("idempotencyConflict", true) => "idempotencyConflict",
        ("reviewedPlanMismatch", true) => "reviewedPlanMismatch",
        ("admissionDenied" | "rejected", true) => "admissionDenied",
        ("resourceConflict", true) | ("conflict", _) => "resourceConflict",
        ("resourceNotFound", true) | ("notFound", _) => "resourceNotFound",
        ("recordUnreadable", _) => "recordUnreadable",
        ("workspaceReferenceNotFound", _) => "workspaceReferenceNotFound",
        ("unsupportedProtocolVersion", _) => "protocolVersionUnsupported",
        ("malformedFrame", _) => "protocolMalformed",
        ("unknownMethod", _) => "controlMethodUnavailable",
        (_, true) => "internalError",
        (_, false) => "outcomeUnknown",
    };
    let mut result = CliError::new(code, wire.message);
    result.details = wire.details.unwrap_or_default();
    result.details.insert("wireCode".into(), json!(wire.code));
    result.details.insert("method".into(), json!("job.submit"));
    result
}

/// Swift `CLIJobLifecycleValidation.validatePlan`: the complete
/// `arkdeck.job-plan/1` projection of a plan never admitted or dispatched.
pub fn validate_plan(value: &Value) -> Result<(), CliError> {
    let refuse = |message: &str| Err(CliError::new("recordUnreadable", message));
    let digest = |value: &Value| {
        value.as_str().is_some_and(|text| {
            text.len() == 64
                && text
                    .bytes()
                    .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
        })
    };
    let named = |value: &Value| value.as_str().is_some_and(|text| !text.is_empty());
    let effect = |value: &Value| value.as_str().is_some_and(|text| EFFECTS.contains(&text));
    let target = value["targetId"].as_str().is_some_and(valid_identifier);
    if !keys(value, &PLAN_KEYS)
        || value["schemaVersion"] != "arkdeck.job-plan/1"
        || value["executionMode"] != "planOnly"
        || value["jobAdmitted"] != false
        || value["dispatchDisposition"] != "notDispatched"
        || !named(&value["operation"])
        || !target
        || !named(&value["providerId"])
        || !digest(&value["catalogDigest"])
        || !digest(&value["requestFingerprintSha256"])
        || !digest(&value["materializedPlanDigest"])
        || !value["inputs"].is_object()
        || !value["steps"].is_array()
        || !effect(&value["effectiveEffect"])
    {
        return refuse("the Runtime returned an invalid target Job plan");
    }
    if !(value["bindingRevision"].is_null()
        || value["bindingRevision"]
            .as_i64()
            .is_some_and(|revision| revision > 0))
    {
        return refuse("the target Job plan has an invalid binding revision");
    }
    if !(value["stableIdentitySha256"].is_null() || digest(&value["stableIdentitySha256"])) {
        return refuse("the target Job plan has an invalid stable identity");
    }
    match &value["authorizationPolicy"] {
        Value::Null => (),
        Value::String(policy)
            if ["defaultReadOnly", "standingCapability", "runtimeCapability"]
                .contains(&policy.as_str()) => {}
        Value::String(_) => {
            return refuse("the target Job plan has an unknown authorization policy");
        }
        _ => return refuse("the target Job plan has an invalid authorization policy"),
    }
    match &value["providerAdmissionBlocker"] {
        Value::Null => (),
        Value::String(blocker) if !blocker.is_empty() => (),
        Value::String(_) => return refuse("the target Job plan has an empty blocker"),
        _ => return refuse("the target Job plan has an invalid blocker"),
    }
    for step in value["steps"].as_array().into_iter().flatten() {
        if !keys(
            step,
            &[
                "stepId",
                "kind",
                "effect",
                "cancellation",
                "binding",
                "optional",
            ],
        ) || !named(&step["stepId"])
            || !named(&step["kind"])
            || !effect(&step["effect"])
            || !named(&step["cancellation"])
            || !named(&step["binding"])
            || !step["optional"].is_boolean()
        {
            return refuse("the target Job plan contains an invalid step");
        }
    }
    Ok(())
}
