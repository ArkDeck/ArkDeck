//! `agent run/status/list/abandon/resume` and physical HAR resume: Swift
//! `RuntimeCLI.runRuntimeExecution` for the agent family. A run's intent is
//! built from its options or from a typed request document and checked as
//! Swift's `AgentExecutionIntent` checks it before anything is sent; an
//! execution read or abandoned is named by an exact identity; every execution
//! answered is checked as Swift's `executionFields` checks the projection, and a
//! page is passed on as the Runtime answers it; and a run settles as
//! `emitSettledExecution` settles it, polling `agent.status` until it does.
use crate::read_only_resources::{
    duration, keys, known_job_state, publication, terminal_job_state,
};
use crate::{CliError, Invocation};
use arkdeck_contract::{CATALOG_CANONICAL_JSON, canonical_json, strict_json};
use serde_json::{Map, Value, json};
use std::collections::BTreeSet;
use std::io::Read;
use unicode_segmentation::UnicodeSegmentation;

const INTENT_SCHEMA: &str = "arkdeck.agent-execution-request/1";
const PROJECTION_SCHEMA: &str = "arkdeck.agent-execution/1";
/// Swift `executionInputDocument`'s bound for a request or inputs document.
const MAX_DOCUMENT: usize = 3_145_728;
const OUTPUTS: [&str; 4] = [
    "rawArtifacts",
    "derivedArtifacts",
    "analysisReport",
    "hardwareEvidence",
];
const INTENT_KEYS: [&str; 12] = [
    "schemaVersion",
    "executionId",
    "operation",
    "inputs",
    "target",
    "capabilityReference",
    "maximumWaitMilliseconds",
    "reviewedPlanDigest",
    "requestId",
    "idempotencyKey",
    "requestedOutputs",
    "clientContext",
];
/// The members a `--request-file` document may carry.
const REQUEST_KEYS: [&str; 11] = [
    "documentType",
    "schemaVersion",
    "requestId",
    "idempotencyKey",
    "target",
    "operation",
    "inputs",
    "requestedOutputs",
    "authorization",
    "clientContext",
    "reviewedPlanDigest",
];
/// Every flag-form field is exclusive with a complete request document.
const REQUEST_FILE_EXCLUSIONS: [(&str, &str); 8] = [
    ("targetId", "--target"),
    ("operation", "--operation"),
    ("inputsFile", "--inputs-file"),
    ("expectedBindingRevision", "--expected-binding-revision"),
    ("requestId", "--request-id"),
    ("idempotencyKey", "--idempotency-key"),
    ("capabilityId", "--capability"),
    ("reviewedPlanDigest", "--reviewed-plan-digest"),
];
/// Swift `AgentExecutionState`.
const STATES: [&str; 9] = [
    "orchestrating",
    "waitingForHuman",
    "creatingJob",
    "jobOwned",
    "completed",
    "failed",
    "abandoned",
    "budgetExpired",
    "clockUntrusted",
];
const PROJECTION_KEYS: [&str; 17] = [
    "schemaVersion",
    "executionId",
    "generation",
    "operation",
    "catalogDigest",
    "createdAt",
    "deadline",
    "lastObservedAt",
    "state",
    "targetId",
    "bindingRevision",
    "jobId",
    "jobState",
    "outcomeUnknown",
    "failureCode",
    "humanAction",
    "nextAction",
];
const JOB_KEYS: [&str; 7] = [
    "jobId",
    "state",
    "outcome",
    "outcomeUnknown",
    "waitingForHuman",
    "outstandingResidueCount",
    "sessionPublication",
];

fn usage(message: impl Into<String>) -> CliError {
    CliError::new("invalidOption", message)
}

fn invalid_input(message: impl Into<String>) -> CliError {
    CliError::new("invalidInput", message)
}

/// The static name of a Swift `CLIErrorCode`: an execution's `failureCode`
/// settles a run only when the error registry has it.
fn cli_code(code: &str) -> Option<&'static str> {
    crate::error_registry::code(code)
}

/// Swift `AgentExecutionIntent.validIdentifier`.
fn valid_identifier(value: &str) -> bool {
    (1..=128).contains(&value.len())
        && value.as_bytes()[0].is_ascii_alphanumeric()
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || b"-._".contains(&byte))
}

fn digest(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

fn thread_identity(value: &str) -> bool {
    (1..=64).contains(&value.len())
        && value.as_bytes()[0].is_ascii_alphanumeric()
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || b"._-".contains(&byte))
}

/// The binding the published Catalog declares for an exact `id@version`,
/// or `None` for a reference the Catalog does not publish exactly.
fn published_binding(reference: &str) -> Option<String> {
    let (id, version) = reference.rsplit_once('@')?;
    let version = version
        .parse::<i64>()
        .ok()
        .filter(|number| number.to_string() == version)?;
    let catalog: Value = serde_json::from_str(CATALOG_CANONICAL_JSON).ok()?;
    catalog
        .as_array()?
        .iter()
        .find(|operation| operation["id"] == id && operation["version"].as_i64() == Some(version))?
        ["binding"]
        .as_str()
        .map(str::to_owned)
}

/// Parse-time `agent run`, `agent status`, `agent list` and `agent abandon`
/// checks, as the Swift registry makes them. Returns the client's own wait:
/// only `--timeout` bounds it.
pub(super) fn configure(
    command: &str,
    fields: &mut Map<String, Value>,
    help: bool,
) -> Result<Option<u64>, CliError> {
    if help
        || !matches!(
            command,
            "agent.run"
                | "agent.status"
                | "agent.list"
                | "agent.abandon"
                | "agent.resume"
                | "human-action.resume"
        )
    {
        return Ok(None);
    }
    if matches!(command, "agent.resume" | "human-action.resume") {
        if fields.contains_key("resumeReference") == fields.contains_key("resumeToken") {
            return Err(usage("resume requires exactly one exact resume reference"));
        }
        if command == "human-action.resume" && !fields.contains_key("humanAction") {
            return Err(usage("human-action resume requires --human-action"));
        }
        if fields.contains_key("selection") && fields.contains_key("selectionFile") {
            return Err(usage("selection sources are exclusive"));
        }
        // Swift `usesRuntimeExecution`: a bare `agent resume --resume-token`
        // resumes the client-side executor's pending record
        // (`domain_leaves::resume`); with `--selection-file` or `--timeout` the
        // token is the Runtime execution's resume reference.
        let client_side = command == "agent.resume"
            && !fields.contains_key("selectionFile")
            && !fields.contains_key("timeout");
        if !client_side && let Some(token) = fields.remove("resumeToken") {
            fields.insert("resumeReference".into(), token);
        }
    } else if matches!(command, "agent.status" | "agent.abandon") {
        if !fields.contains_key("executionId") {
            return Err(usage(format!(
                "agent {} requires --execution-id",
                &command["agent.".len()..]
            )));
        }
    } else if command == "agent.list" {
        if let Some(state) = fields.get("state").and_then(Value::as_str)
            && !STATES.contains(&state)
        {
            return Err(usage(format!(
                "`--state` state must be one of {}",
                STATES.join("|")
            )));
        }
        if let Some(text) = fields.get("pageSize").and_then(Value::as_str) {
            // Swift's `positiveInteger` grammar: plain digits, no sign and
            // no leading zero.
            let size = Some(text)
                .filter(|text| {
                    !text.is_empty()
                        && !text.starts_with('0')
                        && text.bytes().all(|byte| byte.is_ascii_digit())
                })
                .and_then(|text| text.parse::<u64>().ok())
                .filter(|size| (1..=1000).contains(size))
                .ok_or_else(|| usage("page-size must be between 1 and 1000"))?;
            fields.insert("pageSize".into(), json!(size));
        }
        // The list filters the resolved target, which its request names `target`.
        if let Some(target) = fields.remove("targetId") {
            fields.insert("target".into(), target);
        }
    } else {
        if !fields.contains_key("requestFile") && !fields.contains_key("operation") {
            return Err(usage(
                "agent run requires exactly one of --request-file or --operation",
            ));
        }
        if fields.contains_key("requestFile")
            && let Some((_, option)) = REQUEST_FILE_EXCLUSIONS
                .iter()
                .find(|(key, _)| fields.contains_key(*key))
        {
            let mut names = ["--request-file", option];
            names.sort_unstable();
            return Err(usage(format!(
                "`agent run` accepts only one of {}",
                names.join(", ")
            )));
        }
        if fields
            .get("maximumWait")
            .is_some_and(|text| duration(text.as_str().unwrap_or_default()).is_none())
        {
            return Err(usage("maximum-wait must be a bounded duration"));
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
    }
    match fields.remove("timeout") {
        None => Ok(None),
        Some(text) => duration(text.as_str().unwrap_or_default())
            .map(Some)
            .ok_or_else(|| usage("timeout must be a bounded duration")),
    }
}

/// Swift's check before `agent status` or `agent abandon` sends anything: the
/// execution is named by an exact identity.
pub fn require_execution_identity(params: &Map<String, Value>) -> Result<(), CliError> {
    if params
        .get("executionId")
        .and_then(Value::as_str)
        .is_some_and(valid_identifier)
    {
        Ok(())
    } else {
        Err(invalid_input("an exact execution identity is required"))
    }
}

/// Swift `executionInputDocument`: a bounded strict UTF-8 JSON document read
/// from a path, or from standard input for `-`.
fn document(path: &str) -> Result<Value, CliError> {
    document_bounded(path, MAX_DOCUMENT)
}

fn document_bounded(path: &str, maximum: usize) -> Result<Value, CliError> {
    let unreadable = || invalid_input("cannot read a bounded strict UTF-8 JSON document");
    let mut bytes = Vec::new();
    let limit = (maximum + 1) as u64;
    let read = if path == "-" {
        std::io::stdin().lock().take(limit).read_to_end(&mut bytes)
    } else {
        std::fs::File::open(path).and_then(|file| file.take(limit).read_to_end(&mut bytes))
    };
    read.map_err(|_| unreadable())?;
    if bytes.len() > maximum {
        return Err(CliError::new(
            "inputTooLarge",
            "input document exceeds its byte bound",
        ));
    }
    strict_json(&bytes).map_err(|_| unreadable())
}

/// Physical resume supplies references only; the Runtime retains the intent
/// and deadline. A selection document is a bounded opaque JSON string.
pub fn resume_params(invocation: &Invocation) -> Result<Map<String, Value>, CliError> {
    let mut params = invocation.params.clone().unwrap_or_default();
    for key in if invocation.command == "human-action.resume" {
        &["resumeReference", "humanAction"][..]
    } else {
        &["resumeReference"][..]
    } {
        if !params
            .get(*key)
            .and_then(Value::as_str)
            .is_some_and(valid_identifier)
        {
            return Err(invalid_input(
                "an exact resume/action reference is required",
            ));
        }
    }
    if let Some(path) = params.remove("selectionFile") {
        let value = document_bounded(
            path.as_str()
                .ok_or_else(|| invalid_input("invalid selection file"))?,
            65_536,
        )?;
        if !value.is_string() {
            return Err(invalid_input("selection must be an opaque JSON string"));
        }
        params.insert("selection".into(), value);
    }
    Ok(params)
}

/// The fields of a typed operation request the intent carries (Swift
/// `RuntimeOperationCodec.decodeRequest`, whose full checks the Runtime makes
/// again when it admits the Job).
fn typed_request(document: &Map<String, Value>) -> Option<Map<String, Value>> {
    let text = |key: &str| document.get(key).and_then(Value::as_str);
    if text("documentType") != Some("runtime-operation-request")
        || text("schemaVersion") != Some("1.0.0")
    {
        return None;
    }
    let request_id = text("requestId").filter(|id| valid_identifier(id))?;
    let idempotency_key = text("idempotencyKey").filter(|key| !key.is_empty())?;
    let operation = document.get("operation")?.as_object()?;
    if !operation.keys().all(|key| key == "id" || key == "version") {
        return None;
    }
    let id = operation.get("id")?.as_str().filter(|id| !id.is_empty())?;
    let reference = match operation.get("version") {
        None => id.to_owned(),
        Some(version) => format!("{id}@{}", version.as_i64().filter(|number| *number >= 1)?),
    };
    let inputs = document.get("inputs")?.as_object()?;
    let outputs = match document.get("requestedOutputs") {
        None => vec![json!("derivedArtifacts")],
        Some(Value::Array(values))
            if values.iter().all(|value| {
                value
                    .as_str()
                    .is_some_and(|output| OUTPUTS.contains(&output))
            }) =>
        {
            values.clone()
        }
        Some(_) => return None,
    };
    let mut fields = Map::new();
    fields.insert("requestId".into(), json!(request_id));
    fields.insert("idempotencyKey".into(), json!(idempotency_key));
    fields.insert("operation".into(), json!(reference));
    fields.insert("inputs".into(), Value::Object(inputs.clone()));
    fields.insert("requestedOutputs".into(), Value::Array(outputs));
    if let Some(target) = document.get("target") {
        fields.insert("target".into(), target.clone());
    }
    match document.get("authorization") {
        None => (),
        Some(Value::Object(authorization))
            if authorization.len() == 1 && authorization.contains_key("capabilityId") =>
        {
            fields.insert(
                "capabilityReference".into(),
                authorization["capabilityId"].clone(),
            );
        }
        Some(_) => return None,
    }
    for key in ["clientContext", "reviewedPlanDigest"] {
        if let Some(value) = document.get(key) {
            fields.insert(key.into(), value.clone());
        }
    }
    Some(fields)
}

/// Swift `runtimeExecutionIntent`: the `agent.run` parameters, built before
/// any connection is made and checked as `AgentExecutionIntent` checks them.
pub fn execution_intent(invocation: &Invocation) -> Result<Map<String, Value>, CliError> {
    let options = invocation.params.clone().unwrap_or_default();
    let text = |key: &str| options.get(key).and_then(Value::as_str);
    let wait = duration(text("maximumWait").unwrap_or("5m"))
        .ok_or_else(|| invalid_input("maximum-wait must be a bounded duration"))?;
    let execution = match text("executionId") {
        Some(id) => id.to_owned(),
        None => crate::job_plan::uuid()?,
    };
    let mut fields = Map::new();
    fields.insert("schemaVersion".into(), json!(INTENT_SCHEMA));
    fields.insert("executionId".into(), json!(execution));
    fields.insert("maximumWaitMilliseconds".into(), json!(wait.to_string()));
    if let Some(path) = text("requestFile") {
        let value = document(path)?;
        let Some(request) = value.as_object().filter(|request| {
            request
                .keys()
                .all(|key| REQUEST_KEYS.contains(&key.as_str()))
        }) else {
            return Err(invalid_input(
                "request-file must be a closed typed operation request",
            ));
        };
        let typed = typed_request(request)
            .ok_or_else(|| invalid_input("request-file failed typed request validation"))?;
        fields.extend(typed);
    } else {
        if let Some(operation) = text("operation") {
            fields.insert("operation".into(), json!(operation));
        }
        let inputs = match text("inputsFile") {
            Some(path) => document(path)?,
            None => json!({}),
        };
        fields.insert("inputs".into(), inputs);
        if let Some(target) = text("targetId") {
            let mut value = json!({"targetId": target});
            if let Some(revision) =
                text("expectedBindingRevision").and_then(|text| text.parse::<i64>().ok())
            {
                value["expectedBindingRevision"] = json!(revision);
            }
            fields.insert("target".into(), value);
        } else if text("expectedBindingRevision").is_some() {
            return Err(invalid_input(
                "expected-binding-revision requires an explicit target",
            ));
        }
        for (option, key) in [
            ("requestId", "requestId"),
            ("idempotencyKey", "idempotencyKey"),
            ("capabilityId", "capabilityReference"),
            ("reviewedPlanDigest", "reviewedPlanDigest"),
        ] {
            if let Some(value) = text(option) {
                fields.insert(key.into(), json!(value));
            }
        }
    }
    validate_intent(&fields)?;
    Ok(fields)
}

/// Swift `AgentExecutionIntent.init`, in its order and with its refusals.
pub(crate) fn validate_intent(fields: &Map<String, Value>) -> Result<(), CliError> {
    let text = |key: &str| fields.get(key).and_then(Value::as_str);
    let budget = text("maximumWaitMilliseconds").and_then(|budget| {
        budget
            .parse::<u64>()
            .ok()
            .filter(|number| number.to_string() == budget && (1..=86_400_000).contains(number))
    });
    if !fields.keys().all(|key| INTENT_KEYS.contains(&key.as_str()))
        || text("schemaVersion") != Some(INTENT_SCHEMA)
        || !text("executionId").is_some_and(valid_identifier)
        || !text("operation").is_some_and(|operation| (1..=128).contains(&operation.len()))
        || !fields.get("inputs").is_some_and(Value::is_object)
        || budget.is_none()
    {
        return Err(invalid_input(
            "an exact published operation, executionId, inputs and bounded orchestration budget are required",
        ));
    }
    let binding = published_binding(text("operation").unwrap_or_default()).ok_or_else(|| {
        invalid_input("operation must be an exact token published by the current Catalog")
    })?;
    for key in ["requestId", "idempotencyKey"] {
        if fields
            .get(key)
            .is_some_and(|value| !value.as_str().is_some_and(valid_identifier))
        {
            return Err(invalid_input(format!("{key} must be a bounded identity")));
        }
    }
    if text("idempotencyKey").is_some_and(|key| key.chars().count() < 8) {
        return Err(invalid_input(
            "idempotencyKey must contain at least 8 characters",
        ));
    }
    if let Some(value) = fields.get("requestedOutputs") {
        let Some(values) = value.as_array().filter(|values| values.len() <= 4) else {
            return Err(invalid_input(
                "requestedOutputs must be a bounded typed list",
            ));
        };
        if !values.iter().all(|value| {
            value
                .as_str()
                .is_some_and(|output| OUTPUTS.contains(&output))
        }) {
            return Err(invalid_input(
                "requestedOutputs contains an unpublished value",
            ));
        }
        if values
            .iter()
            .filter_map(Value::as_str)
            .collect::<BTreeSet<_>>()
            .len()
            != values.len()
        {
            return Err(invalid_input("requestedOutputs must be unique"));
        }
    }
    if let Some(value) = fields.get("clientContext") {
        let Some(context) = value.as_object().filter(|context| {
            context
                .keys()
                .all(|key| key == "clientName" || key == "provenance")
        }) else {
            return Err(invalid_input(
                "clientContext must contain only display/audit annotations",
            ));
        };
        if context.get("clientName").is_some_and(|name| {
            !name
                .as_str()
                .is_some_and(|name| (1..=128).contains(&name.graphemes(true).count()))
        }) {
            return Err(invalid_input("invalid clientName"));
        }
        if let Some(annotations) = context.get("provenance") {
            let Some(pairs) = annotations.as_object().filter(|pairs| {
                pairs.len() <= 16
                    && pairs.iter().all(|(key, value)| {
                        (1..=64).contains(&key.graphemes(true).count())
                            && value
                                .as_str()
                                .is_some_and(|text| text.graphemes(true).count() <= 400)
                    })
            }) else {
                return Err(invalid_input("invalid provenance annotations"));
            };
            if let Some(Value::String(thread)) = pairs.get("arkdeck.threadId")
                && !thread_identity(thread)
            {
                return Err(invalid_input("invalid thread provenance identity"));
            }
        }
    }
    if let Some(target) = fields.get("target") {
        let Some(object) = target.as_object().filter(|object| {
            object
                .keys()
                .all(|key| key == "targetId" || key == "expectedBindingRevision")
                && object
                    .get("targetId")
                    .and_then(Value::as_str)
                    .is_some_and(valid_identifier)
        }) else {
            return Err(invalid_input(
                "target must be an exact durable target reference",
            ));
        };
        if object
            .get("expectedBindingRevision")
            .is_some_and(|revision| {
                !revision.as_i64().is_some_and(|revision| revision > 0) || binding == "none"
            })
        {
            return Err(invalid_input(
                "expectedBindingRevision must be positive and device-bound",
            ));
        }
    }
    if fields
        .get("capabilityReference")
        .is_some_and(|value| !value.as_str().is_some_and(valid_identifier))
    {
        return Err(invalid_input(
            "capability must be a reference, never an authority document",
        ));
    }
    if fields
        .get("reviewedPlanDigest")
        .is_some_and(|value| !value.as_str().is_some_and(digest))
    {
        return Err(invalid_input(
            "reviewedPlanDigest must be an exact lowercase SHA-256",
        ));
    }
    let canonical = canonical_json(&Value::Object(fields.clone()))
        .map_err(|_| invalid_input("execution intent must be representable as canonical I-JSON"))?;
    if canonical.len() > MAX_DOCUMENT {
        return Err(CliError::new(
            "inputTooLarge",
            "execution intent exceeds its document bound",
        ));
    }
    Ok(())
}

/// Swift `executionFields`: an `arkdeck.agent-execution/1` projection whose
/// owner, Job and next action agree, or `recordUnreadable`.
pub fn validate_execution(value: &Value) -> Result<Map<String, Value>, CliError> {
    let unreadable = || CliError::new("recordUnreadable", "invalid Runtime execution projection");
    let inconsistent = || {
        CliError::new(
            "recordUnreadable",
            "execution owner, Job or next-action projection is inconsistent",
        )
    };
    let Some(fields) = value.as_object() else {
        return Err(unreadable());
    };
    let names: BTreeSet<&str> = fields.keys().map(String::as_str).collect();
    let generation = fields["generation"].as_str().is_some_and(|text| {
        text.parse::<i64>()
            .is_ok_and(|number| number > 0 && number.to_string() == text)
    });
    let (Some(id), Some(state)) = (
        fields.get("executionId").and_then(Value::as_str),
        fields.get("state").and_then(Value::as_str),
    ) else {
        return Err(unreadable());
    };
    if fields.get("schemaVersion") != Some(&json!(PROJECTION_SCHEMA))
        || !PROJECTION_KEYS.iter().all(|key| names.contains(key))
        || !names.iter().all(|key| {
            PROJECTION_KEYS.contains(key) || ["job", "evidence", "artifacts"].contains(key)
        })
        || !valid_identifier(id)
        || !STATES.contains(&state)
        || !generation
    {
        return Err(unreadable());
    }
    if let Some(job_id) = fields["jobId"].as_str() {
        let job = fields.get("job").and_then(Value::as_object);
        let consistent = job.is_some_and(|job| {
            let raw = job.get("state").and_then(Value::as_str).unwrap_or_default();
            let outcome = if fields["outcomeUnknown"] == true {
                "outcomeUnknown"
            } else {
                raw
            };
            valid_identifier(job_id)
                && job.get("jobId") == Some(&json!(job_id))
                && job.get("state") == fields.get("jobState")
                && job.get("outcomeUnknown") == fields.get("outcomeUnknown")
                && known_job_state(raw)
                && (state == "completed") == terminal_job_state(raw)
                && keys(&Value::Object(job.clone()), &JOB_KEYS)
                && publication(&job["sessionPublication"])
                && job.get("outcome") == Some(&json!(outcome))
        });
        if !consistent {
            return Err(inconsistent());
        }
        let terminal = terminal_job_state(fields["jobState"].as_str().unwrap_or_default());
        if terminal {
            let evidence = &fields.get("evidence").cloned().unwrap_or(Value::Null);
            let blockers = evidence["blockers"].as_array();
            let artifacts = evidence["artifacts"].as_array();
            let consistent = evidence.is_object()
                && evidence["jobId"] == job_id
                && evidence["catalogDigest"] == fields["catalogDigest"]
                && blockers.is_some_and(|blockers| blockers.iter().all(Value::is_string))
                && evidence["status"]
                    == if blockers.is_some_and(Vec::is_empty) {
                        "verified"
                    } else {
                        "blocked"
                    }
                && artifacts.is_some_and(|artifacts| {
                    fields.get("artifacts") == Some(&Value::Array(artifacts.clone()))
                        && artifacts.iter().all(|row| {
                            row.is_object()
                                && row["jobId"] == job_id
                                && row["bytesVerified"] == true
                                && row["sha256"].as_str().is_some_and(digest)
                        })
                });
            if !consistent {
                return Err(inconsistent());
            }
        }
    } else if !fields["jobId"].is_null() || fields.contains_key("job") || state == "completed" {
        return Err(inconsistent());
    }
    match fields.get("nextAction") {
        Some(next) if !next.is_null() => next_action(fields, id, state, next)?,
        _ if state == "waitingForHuman" => return Err(inconsistent()),
        _ => (),
    }
    Ok(fields.clone())
}

/// Swift `executionFields`' next-action rules.
fn next_action(
    fields: &Map<String, Value>,
    id: &str,
    state: &str,
    next: &Value,
) -> Result<(), CliError> {
    let inconsistent = || {
        CliError::new(
            "recordUnreadable",
            "execution owner, Job or next-action projection is inconsistent",
        )
    };
    let (Some(action), Some(kind)) = (next.as_object(), next["kind"].as_str()) else {
        return Err(inconsistent());
    };
    let (owner, resource) = (&next["owner"], &next["resource"]);
    if !keys(owner, &["kind", "id"]) || !keys(resource, &["kind", "id"]) {
        return Err(inconsistent());
    }
    let action_keys = |extra: &[&str]| {
        let mut expected = vec!["kind", "owner", "resource", "reasonCode"];
        expected.extend_from_slice(extra);
        keys(&Value::Object(action.clone()), &expected)
    };
    let consistent = match kind {
        "humanAction" => {
            let har = &fields["humanAction"];
            action_keys(&["resumeReference", "expiresAt"])
                && state == "waitingForHuman"
                && *owner == json!({"kind": "agentExecution", "id": id})
                && har.is_object()
                && har["owner"] == *owner
                && har["schemaVersion"] == "arkdeck.human-action/1"
                && har["status"] == "waiting"
                && resource["kind"] == "humanAction"
                && resource["id"] == har["actionId"]
                && next["resumeReference"] == har["resumeReference"]
                && next["expiresAt"] == har["expiresAt"]
                && next["reasonCode"] == har["reasonCode"]
        }
        "wait" | "reconcile" | "readResult" => {
            let expected = if fields["jobId"].is_null() {
                json!({"kind": "agentExecution", "id": id})
            } else {
                json!({"kind": "job", "id": fields["jobId"]})
            };
            let shaped = *owner == expected
                && resource == owner
                && action_keys(if kind == "wait" { &["retryAfter"] } else { &[] });
            shaped
                && if kind == "wait" {
                    next["retryAfter"]
                        .as_str()
                        .is_some_and(|hint| duration(hint).is_some())
                        && next["reasonCode"]
                            == if fields["jobId"].is_null() {
                                "agent.orchestrationPending"
                            } else {
                                "job.running"
                            }
                } else if kind == "reconcile" && next["reasonCode"] == "job.finalizationPending" {
                    state == "jobOwned"
                        && !fields["jobId"].is_null()
                        && fields["operation"] == "debug.hap@1"
                        && fields["jobState"] == "finalizing"
                        && fields["outcomeUnknown"] == false
                        && fields["job"]["waitingForHuman"] == false
                } else {
                    !fields["jobId"].is_null()
                        && next["reasonCode"]
                            == if kind == "reconcile" {
                                "recovery.outcomeUnknown"
                            } else {
                                "job.resultAvailable"
                            }
                }
        }
        _ => false,
    };
    if consistent {
        Ok(())
    } else {
        Err(inconsistent())
    }
}

/// Where a checked execution leaves a run.
#[derive(Debug, PartialEq)]
pub enum Settlement {
    /// The run is over: its result is the one document the invocation
    /// emits, and `agent_exit` gives the status it then exits with.
    Settled(Value),
    /// The execution or its Job is still moving: read its status again.
    Pending,
}

/// Swift `emitSettledExecution`. A failure here is raised before anything is
/// emitted and carries the execution; a settled result is emitted first.
pub fn settle_execution(fields: &Map<String, Value>) -> Result<Settlement, CliError> {
    let with_execution = |mut error: CliError| {
        error
            .details
            .insert("execution".into(), Value::Object(fields.clone()));
        error
    };
    if fields["state"] == "waitingForHuman" {
        if !fields["humanAction"]["resumeReference"]
            .as_str()
            .is_some_and(valid_identifier)
        {
            return Err(CliError::new(
                "recordUnreadable",
                "waiting execution has no exact physical action",
            ));
        }
        return Err(with_execution(CliError::new(
            "humanActionRequired",
            "Runtime execution is paused for the published physical action",
        )));
    }
    if fields["state"] == "abandoned" {
        let mut result = fields.clone();
        result.insert("executionOutcome".into(), json!("abandoned"));
        return Ok(Settlement::Settled(Value::Object(result)));
    }
    if let Some(code) = fields["failureCode"].as_str().and_then(cli_code) {
        return Err(with_execution(CliError::new(
            code,
            "execution stopped before Job creation",
        )));
    }
    if fields["outcomeUnknown"] == true {
        return Ok(Settlement::Settled(Value::Object(fields.clone())));
    }
    if fields["nextAction"]["kind"] == "reconcile"
        && fields["nextAction"]["reasonCode"] == "job.finalizationPending"
        && let Some(job) = fields["jobId"].as_str()
    {
        return Err(with_execution(CliError::new(
            "resultNotReady",
            format!(
                "Job failure finalization requires reconciliation. Run: arkdeck job reconcile --job {job}"
            ),
        )));
    }
    if fields["state"] == "completed" {
        if !fields.contains_key("job") || !fields.contains_key("evidence") {
            return Err(CliError::new(
                "recordUnreadable",
                "terminal execution lacks its bounded Job result and evidence",
            ));
        }
        return Ok(Settlement::Settled(Value::Object(fields.clone())));
    }
    if fields["job"]["waitingForHuman"] == true {
        return Err(with_execution(CliError::new(
            "humanActionRequired",
            "the existing Job requires its Runtime-owned physical assistance",
        )));
    }
    Ok(Settlement::Pending)
}

/// Swift's line for a person when an execution waits for them.
pub fn human_action_progress(error: &CliError) -> Option<String> {
    let execution = error.details.get("execution")?;
    if error.code != "humanActionRequired" || execution["state"] != "waitingForHuman" {
        return None;
    }
    let reference = execution["humanAction"]["resumeReference"].as_str()?;
    Some(format!(
        "Physical assistance required. Resume with: arkdeck agent resume --resume-reference {reference}"
    ))
}

/// The status a settled run exits with once its result is emitted, and the
/// diagnostic that goes with it: an abandoned execution, an unknown outcome,
/// evidence that could not be verified (Swift `evidenceIntegrityExit`) and
/// then the Job's terminal state (Swift `terminalJobExit`).
pub fn agent_exit(result: &Value) -> Option<(u8, String)> {
    if result["schemaVersion"] == "arkdeck.control-action/1" {
        return crate::console_approval::control_action_exit(result);
    }
    if result["executionOutcome"] == "abandoned" {
        return Some((1, "execution was abandoned; no Job was cancelled".into()));
    }
    if result["outcomeUnknown"] == true {
        return Some((
            75,
            "inspect and reconcile the existing Job; its intent must not be replayed".into(),
        ));
    }
    if let Some(blockers) = result["evidence"]["blockers"]
        .as_array()
        .filter(|blockers| !blockers.is_empty())
    {
        let named: Vec<&str> = blockers.iter().filter_map(Value::as_str).collect();
        return Some((
            2,
            format!(
                "required evidence could not be verified: {}",
                named.join(", ")
            ),
        ));
    }
    crate::run_exit(&result["job"]).map(|(code, reason)| (code, reason.to_owned()))
}
