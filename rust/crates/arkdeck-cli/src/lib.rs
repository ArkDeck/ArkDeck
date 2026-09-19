//! Current Rust CLI leaves; machine envelopes follow the current contract.
use arkdeck_client::ClientError;
use arkdeck_contract::{ContractError, PROTOCOL_VERSION, canonical_json};
use serde_json::{Map, Value, json};
mod artifact_resources;
mod import_resources;
pub use artifact_resources::{
    artifact_bytes, artifact_export_params, validate_artifact_export, validate_artifact_metadata,
    validate_artifact_read,
};
pub use import_resources::execute_import;
mod bootstrap_resources;
mod read_only_resources;
pub use read_only_resources::{
    evidence_exit, project_read_only_response, result_exit, validate_read_only_request,
    validate_read_only_response,
};
mod job_events;
mod job_plan;
mod job_resources;
pub use job_plan::{
    generates_identity, job_plan_params, job_submit_params, run_exit, validate_acceptance,
    validate_cancellation, validate_plan,
};
mod session_resources;
pub use bootstrap_resources::{validate_bootstrap_request, validate_bootstrap_response};
pub use session_resources::validate_session_response;
mod workspace_projects;
pub use workspace_projects::validate_workspace_project_response;
mod target_resources;
pub use target_resources::validate_target_response;
mod hdc_control;
pub use hdc_control::hdc_control_action_params;
mod trace_cache;
pub use trace_cache::validate_trace_cache_response;
mod agent_executions;
mod human_action_resources;
pub use agent_executions::{
    Settlement, agent_exit, execution_intent, human_action_progress, require_execution_identity,
    resume_params, settle_execution, validate_execution,
};
pub use artifact_resources::validate_artifact_page;

#[derive(Debug, Clone, PartialEq)]
pub struct Invocation {
    pub command: &'static str,
    pub method: &'static str,
    pub params: Option<Map<String, Value>>,
    pub json: bool,
    pub raw: bool,
    pub help: bool,
    pub require_healthy: bool,
    pub control_request_id: Option<String>,
    pub socket: Option<String>,
    pub timeout_ms: Option<u64>,
}

#[derive(Debug, Clone)]
pub struct CliError {
    pub code: &'static str,
    pub message: String,
    pub details: Map<String, Value>,
}
impl CliError {
    pub fn new(code: &'static str, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
            details: Map::new(),
        }
    }
    pub fn exit_code(&self) -> u8 {
        match self.code {
            "invalidCommand" | "invalidOption" => 64,
            "invalidInput"
            | "invalidCursor"
            | "inputTooLarge"
            | "resourceConflict"
            | "idempotencyConflict"
            | "resourceNotFound"
            | "workspaceReferenceNotFound"
            | "reviewedPlanMismatch" => 65,
            "runtimeUnavailable"
            | "unsupportedOnPlatform"
            | "protocolVersionUnsupported"
            | "controlMethodUnavailable"
            | "healthRequirementFailed" => 69,
            "operationUnavailable" => 69,
            "recordUnreadable" | "artifactIntegrityFailed" => 2,
            "ioFailure" => 74,
            "outcomeUnknown" | "resultNotReady" => 75,
            "quotaExceeded" => 69,
            "operationFailed" => 1,
            "clientTimeout" => 75,
            "admissionDenied" | "fileIdentityChanged" | "sensitiveAccessDenied" => 77,
            "orchestrationClockUntrusted"
            | "bindingRevisionStale"
            | "factsDrifted"
            | "previewDrifted" => 77,
            "humanActionRequired"
            | "humanActionExpired"
            | "orchestrationBudgetExpired"
            | "reconcileRequired"
            | "targetSelectionRequired"
            | "targetAmbiguous"
            | "targetTrustPending"
            | "previewExpired" => 75,
            "clientInterrupted" => 130,
            _ => 70,
        }
    }
    pub fn from_client(error: ClientError, method: &str) -> Self {
        if method == "workspace.project.register" && !matches!(error, ClientError::Remote(_)) {
            return CliError::new(
                "outcomeUnknown",
                "workspace registration response is unconfirmed; no request was replayed",
            );
        }
        if matches!(
            method,
            "job.submit"
                | "job.run"
                | "job.cancel"
                | "agent.run"
                | "agent.abandon"
                | "agent.resume"
                | "human-action.resume"
                | "target.adopt"
                | "runtime.hdc.impact-preview"
                | "runtime.hdc.restart"
                | "control-action.list"
                | "control-action.show"
                | "control-action.reconcile"
        ) {
            return job_plan::mutation_error(error, method);
        }
        if matches!(
            method,
            "agent.status" | "agent.list" | "human-action.list" | "human-action.show"
        ) {
            return agent_executions::read_error(error, method);
        }
        if matches!(
            method,
            "artifact.import.begin"
                | "artifact.import.append"
                | "artifact.import.abort"
                | "artifact.import.commit"
                | "artifact.import.release"
        ) && !matches!(error, ClientError::Remote(_))
        {
            let mut result = Self::new(
                "outcomeUnknown",
                "Import response is unconfirmed; inspect the same request identity before continuing",
            );
            result.details.insert("method".into(), json!(method));
            return result;
        }

        if target_resources::is_mutation(method) {
            return target_resources::client_error(error, method);
        }
        if method == "artifact.export" && !matches!(error, ClientError::Remote(_)) {
            let mut result = Self::new(
                "outcomeUnknown",
                "Artifact export response is unconfirmed; inspect the exact destination before retrying",
            );
            result.details.insert("method".into(), json!(method));
            return result;
        }
        if matches!(method, "runtime.bundle.remove" | "runtime.tool.remove") {
            return bootstrap_resources::retirement_error(error, method);
        }
        if matches!(method, "session.cleanup.apply" | "trace.cache.purge")
            && matches!(
                error,
                ClientError::Transport(_)
                    | ClientError::Contract(_)
                    | ClientError::ConnectionUnusable
            )
        {
            let mut result = Self::new(
                "outcomeUnknown",
                if method == "trace.cache.purge" {
                    "Trace cache purge response is unconfirmed; no request was replayed"
                } else {
                    "Session cleanup response is unconfirmed; no request was replayed"
                },
            );
            result
                .details
                .insert("method".into(), Value::String(method.into()));
            return result;
        }
        let mut result = match error {
            ClientError::Transport(error) => Self::new(
                if matches!(
                    method,
                    "runtime.tool.register"
                        | "runtime.bundle.register"
                        | "trace.cache.purge"
                        | "history.filter.save"
                        | "history.filter.delete"
                        | "runtime.storage.policy"
                        | "runtime.storage.root"
                        | "session.pin"
                        | "session.unpin"
                ) {
                    "outcomeUnknown"
                } else if matches!(
                    error.kind(),
                    std::io::ErrorKind::TimedOut | std::io::ErrorKind::WouldBlock
                ) {
                    "clientTimeout"
                } else {
                    "runtimeUnavailable"
                },
                error.to_string(),
            ),
            ClientError::Contract(
                ContractError::UnsupportedVersion | ContractError::ContractMismatch,
            ) => Self::new(
                "protocolVersionUnsupported",
                "client and Runtime must use the same current control contract",
            ),
            ClientError::Contract(_) => Self::new(
                "protocolMalformed",
                "the local Runtime response does not conform to the current contract",
            ),
            ClientError::ConnectionUnusable => Self::new(
                "runtimeUnavailable",
                "the connection is unusable; no request was replayed",
            ),
            ClientError::Remote(error) => {
                let proof = error.details.as_ref().is_some_and(|d| {
                    d.get("phase") == Some(&json!("preAdmission"))
                        && d.get("newDispatchCount") == Some(&json!(0))
                });
                let host_proof = matches!(
                    method,
                    "history.filter.list" | "history.filter.save" | "history.filter.delete"
                ) && error.details.as_ref().is_some_and(|d| {
                    d.get("phase") == Some(&json!("historyFilterOwner"))
                        && d.get("newDispatchCount") == Some(&json!(0))
                });
                let host_proof = host_proof
                    || (matches!(
                        method,
                        "runtime.storage.status"
                            | "runtime.storage.policy"
                            | "runtime.storage.root"
                    ) && error.details.as_ref().is_some_and(|d| {
                        d.get("phase") == Some(&json!("runtimeStorageOwner"))
                            && d.get("newDispatchCount") == Some(&json!(0))
                    }));
                let host_proof = host_proof
                    || (matches!(
                        method,
                        "session.list"
                            | "session.show"
                            | "session.pin"
                            | "session.unpin"
                            | "session.cleanup.preview"
                            | "session.cleanup.apply"
                            | "session.export.preview"
                            | "session.export.apply"
                    ) && error.details.as_ref().is_some_and(|details| {
                        details.get("phase") == Some(&json!("sessionOwner"))
                            && details.get("newDispatchCount") == Some(&json!(0))
                    }));
                let bootstrap_proof = matches!(
                    method,
                    "runtime.tool.inspect"
                        | "runtime.bundle.inspect"
                        | "runtime.tool.register"
                        | "runtime.bundle.register"
                        | "runtime.bundle.list"
                        | "runtime.tool.list"
                ) && error.details.as_ref().is_some_and(|details| {
                    details.get("phase") == Some(&json!("bootstrapRegistryOwner"))
                        && details.get("newDispatchCount") == Some(&json!(0))
                });
                let artifact_proof = matches!(
                    method,
                    "artifact.list" | "artifact.inspect" | "artifact.read" | "artifact.export"
                ) && error.details.as_ref().is_some_and(|d| {
                    d.get("phase") == Some(&json!("artifactOwner"))
                        && d.get("newDispatchCount") == Some(&json!(0))
                });
                let import_proof = method.starts_with("artifact.import.")
                    && error.details.as_ref().is_some_and(|d| {
                        d.get("phase") == Some(&json!("importOwner"))
                            && d.get("newDispatchCount") == Some(&json!(0))
                    });
                let trace_proof = matches!(method, "trace.cache.status" | "trace.cache.purge")
                    && error.details.as_ref().is_some_and(|d| {
                        d.get("phase") == Some(&json!("traceCacheOwner"))
                            && d.get("newDispatchCount") == Some(&json!(0))
                            && d.get("purgeScope") == Some(&json!("inactiveDerivedDatabases"))
                    });
                let workspace_proof = matches!(
                    method,
                    "workspace.project.register"
                        | "workspace.project.list"
                        | "workspace.project.show"
                ) && error.details.as_ref().is_some_and(|d| {
                    d.get("phase") == Some(&json!("workspaceProjectOwner"))
                        && d.get("newDispatchCount") == Some(&json!(0))
                });
                let host_proof = host_proof
                    || bootstrap_proof
                    || artifact_proof
                    || import_proof
                    || trace_proof
                    || workspace_proof;
                let code = match error.code.as_str() {
                    "artifactIntegrityFailed" if artifact_proof || import_proof => {
                        "artifactIntegrityFailed"
                    }
                    "operationFailed" if artifact_proof => "operationFailed",
                    "sensitiveAccessDenied" if artifact_proof => "sensitiveAccessDenied",
                    "admissionDenied" if bootstrap_proof => "admissionDenied",
                    "fileIdentityChanged"
                        if bootstrap_proof
                            && matches!(
                                method,
                                "runtime.tool.register"
                                    | "runtime.bundle.register"
                                    | "runtime.tool.list"
                            ) =>
                    {
                        "fileIdentityChanged"
                    }
                    "idempotencyConflict" if import_proof || workspace_proof => {
                        "idempotencyConflict"
                    }
                    "factsDrifted" if workspace_proof => "factsDrifted",
                    "invalidInput" if host_proof => "invalidInput",
                    "resourceConflict" if host_proof => "resourceConflict",
                    "resourceNotFound" if host_proof => "resourceNotFound",
                    "ioFailure" if host_proof => "ioFailure",
                    "outcomeUnknown" if host_proof => "outcomeUnknown",
                    "quotaExceeded" if host_proof => "quotaExceeded",
                    "invalidCursor" if host_proof => "invalidCursor",
                    "inputTooLarge" if host_proof => "inputTooLarge",
                    "operationUnavailable" if host_proof => "operationUnavailable",
                    "unsupportedProtocolVersion" => "protocolVersionUnsupported",
                    "malformedFrame" => "protocolMalformed",
                    "unknownMethod" => "controlMethodUnavailable",
                    "invalidParams" => "invalidInput",
                    "conflict" => "resourceConflict",
                    "notFound" => "resourceNotFound",
                    // A Job read before its terminal result: read it again
                    // later, as the Swift CLI tells its caller.
                    "resultNotReady" => "resultNotReady",
                    "recordUnreadable" if method == "runtime.tool.list" && !bootstrap_proof => {
                        "internalError"
                    }
                    "recordUnreadable" => "recordUnreadable",
                    "workspaceReferenceNotFound" => "workspaceReferenceNotFound",
                    // A plan's typed refusals carry the same pre-admission
                    // proof as the Swift CLI requires before keeping them.
                    "operationUnavailable" if proof && method == "job.plan" => {
                        "operationUnavailable"
                    }
                    "inputTooLarge"
                        if proof
                            && matches!(method, "job.plan" | "job.result" | "job.evidence") =>
                    {
                        "inputTooLarge"
                    }
                    "admissionDenied" if proof && method == "job.plan" => "admissionDenied",
                    "invalidInput" if proof => "invalidInput",
                    "invalidCursor"
                        if proof
                            && matches!(method, "job.list" | "job.timeline" | "job.events") =>
                    {
                        "invalidCursor"
                    }
                    "resourceConflict" if proof => "resourceConflict",
                    "rejected" if proof => "admissionDenied",
                    "rejected" => "operationFailed",
                    _ => "internalError",
                };
                let mut result = Self::new(code, error.message);
                result.details = error.details.unwrap_or_default();
                result
                    .details
                    .insert("wireCode".into(), Value::String(error.code));
                result
            }
        };
        result
            .details
            .insert("method".into(), Value::String(method.into()));
        result
    }
}

pub fn valid_correlation(id: &str) -> bool {
    (1..=128).contains(&id.len())
        && id.as_bytes()[0].is_ascii_alphanumeric()
        && id
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || b"._:-".contains(&c))
}

pub fn parse(argv: &[String]) -> Result<Invocation, CliError> {
    let mut positional = Vec::new();
    let mut method_options = Map::new();
    let mut seen = std::collections::BTreeSet::new();
    let (mut mode, mut id, mut socket) = (None, None, None);
    let (mut deep, mut require_healthy, mut help) = (false, false, false);
    let mut raw = false;
    let mut index = 0;
    while index < argv.len() {
        let argument = &argv[index];
        if argument.starts_with('-') {
            if !seen.insert(argument.as_str()) {
                return Err(CliError::new(
                    "invalidOption",
                    "an option was supplied more than once",
                ));
            }
            match argument.as_str() {
                "--help" | "-h" => help = true,
                "--deep" => deep = true,
                "--raw" => raw = true,
                "--overwrite" => {
                    method_options.insert("overwrite".into(), json!(true));
                }
                "--require-healthy" => require_healthy = true,
                "--allow-sensitive" => {
                    method_options.insert("allowSensitive".into(), json!(true));
                }
                "--include-current" | "--include-timeline" => {
                    let key = if argument == "--include-current" {
                        "includeCurrent"
                    } else {
                        "includeTimeline"
                    };
                    method_options.insert(key.into(), json!(true));
                }
                "--default" => {
                    method_options.insert("resetToDefault".into(), json!(true));
                }
                "--import-request-id"
                | "--device-profile"
                | "--name"
                | "--candidate"
                | "--observation"
                | "--observation-generation"
                | "--generation"
                | "--expected-generation"
                | "--page-size"
                | "--cursor"
                | "--root"
                | "--destination"
                | "--preview-id"
                | "--preview-digest"
                | "--action"
                | "--server-endpoint-ref"
                | "--expected-server-generation"
                | "--action-request-id"
                | "--control-action"
                | "--total-quota-bytes"
                | "--safety-margin-bytes"
                | "--retention-days"
                | "--search"
                | "--status"
                | "--mode"
                | "--session"
                | "--target"
                | "--time"
                | "--activity"
                | "--registration-request-id"
                | "--project"
                | "--kind"
                | "--file"
                | "--tool"
                | "--bundle"
                | "--operation"
                | "--artifact"
                | "--import"
                | "--offset"
                | "--max-bytes"
                | "--job"
                | "--capability"
                | "--order"
                | "--state"
                | "--thread"
                | "--after-cursor"
                | "--request-file"
                | "--inputs-file"
                | "--expected-binding-revision"
                | "--request-id"
                | "--idempotency-key"
                | "--execution-id"
                | "--resume-reference"
                | "--resume-token"
                | "--human-action"
                | "--selection"
                | "--selection-file"
                | "--owner-kind"
                | "--owner"
                | "--maximum-wait"
                | "--reviewed-plan-digest"
                | "--timeout" => {
                    index += 1;
                    let value = argv
                        .get(index)
                        .filter(|v| !v.starts_with("--"))
                        .ok_or_else(|| {
                            CliError::new("invalidOption", "the option requires a value")
                        })?;
                    let key = match argument.as_str() {
                        "--observation" => "observationId",
                        "--observation-generation" => "observationGeneration",
                        "--expected-generation" => "expectedGeneration",
                        "--import-request-id" => "importRequestId",
                        "--device-profile" => "deviceProfile",
                        "--page-size" => "pageSize",
                        "--root" => "rootPath",
                        "--destination" => "destinationPath",
                        "--preview-id" => "previewId",
                        "--preview-digest" => "previewDigest",
                        "--server-endpoint-ref" => "serverEndpointRef",
                        "--expected-server-generation" => "expectedServerGeneration",
                        "--action-request-id" => "actionRequestId",
                        "--control-action" => "controlAction",
                        "--total-quota-bytes" => "totalQuotaBytes",
                        "--safety-margin-bytes" => "safetyMarginBytes",
                        "--retention-days" => "retentionDays",
                        "--job" => "jobId",
                        "--capability" => "capabilityId",
                        "--after-cursor" => "afterCursor",
                        "--artifact" => "artifactId",
                        "--max-bytes" => "maxBytes",
                        "--session" => "sessionId",
                        "--target" => "targetId",
                        "--time" => "timeRange",
                        "--request-file" => "requestFile",
                        "--inputs-file" => "inputsFile",
                        "--expected-binding-revision" => "expectedBindingRevision",
                        "--request-id" => "requestId",
                        "--idempotency-key" => "idempotencyKey",
                        "--execution-id" => "executionId",
                        "--resume-reference" => "resumeReference",
                        "--resume-token" => "resumeToken",
                        "--human-action" => "humanAction",
                        "--selection-file" => "selectionFile",
                        "--owner-kind" => "ownerKind",
                        "--maximum-wait" => "maximumWait",
                        "--reviewed-plan-digest" => "reviewedPlanDigest",
                        "--registration-request-id" => "registrationRequestId",
                        "--project" => "projectRef",
                        other => &other[2..],
                    };
                    method_options.insert(key.to_owned(), json!(value));
                }
                "--output" | "--control-request-id" | "--socket" => {
                    index += 1;
                    let value =
                        argv.get(index)
                            .filter(|v| !v.starts_with('-'))
                            .ok_or_else(|| {
                                CliError::new("invalidOption", "the option requires a value")
                            })?;
                    match argument.as_str() {
                        "--output" => {
                            if !["human", "json"].contains(&value.as_str()) {
                                return Err(CliError::new(
                                    "invalidOption",
                                    "--output must be human or json",
                                ));
                            }
                            mode = Some(value.clone());
                        }
                        "--control-request-id" => {
                            if !valid_correlation(value) {
                                return Err(CliError::new(
                                    "invalidOption",
                                    "--control-request-id must match ^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$",
                                ));
                            }
                            id = Some(value.clone());
                        }
                        _ => {
                            if !cfg!(target_os = "macos") {
                                return Err(CliError::new(
                                    "unsupportedOnPlatform",
                                    "--socket is only available on macOS",
                                ));
                            }
                            socket = Some(value.clone());
                        }
                    }
                }
                _ => {
                    return Err(CliError::new(
                        "invalidOption",
                        "the option is not available for this command",
                    ));
                }
            }
        } else {
            positional.push(argument.as_str());
        }
        index += 1;
    }
    let command = match positional.as_slice() {
        ["workspace", "project", "register"] => "workspace.project.register",
        ["workspace", "project", "list"] => "workspace.project.list",
        ["workspace", "project", "show"] => "workspace.project.show",
        ["artifact", "import", "hap"] => "artifact.import.hap",
        ["artifact", "import", "workspace-patch"] => "artifact.import.workspace-patch",
        ["artifact", "import", "native-library"] => "artifact.import.native-library",
        ["artifact", "import", "flash-bundle"] => "artifact.import.flash-bundle",
        ["artifact", "import", "abort"] => "artifact.import.abort",
        ["artifact", "import", "inspect"] => "artifact.import.inspect",
        ["artifact", "import", "list"] => "artifact.import.list",
        ["artifact", "import", "release"] => "artifact.import.release",
        ["artifact", "inspect"] => "artifact.inspect",
        ["artifact", "read"] => "artifact.read",
        ["artifact", "export"] => "artifact.export",
        ["artifact", "quota"] => "artifact.quota",
        ["artifact", "list"] => "artifact.list",
        ["agent", "run"] => "agent.run",
        ["agent", "status"] => "agent.status",
        ["agent", "list"] => "agent.list",
        ["agent", "abandon"] => "agent.abandon",
        ["agent", "resume"] => "agent.resume",
        ["human-action", "resume"] => "human-action.resume",
        ["human-action", "list"] => "human-action.list",
        ["human-action", "show"] => "human-action.show",
        ["doctor"] => "doctor",
        ["operation", "list"] => "operation.list",
        ["operation", "describe"] => "operation.describe",
        ["operation", "example"] => "operation.example",
        ["job", "status"] => "job.status",
        ["job", "list"] => "job.list",
        ["job", "show"] => "job.show",
        ["job", "evidence"] => "job.evidence",
        ["job", "result"] => "job.result",
        ["job", "timeline"] => "job.timeline",
        ["job", "events"] => "job.events",
        ["job", "plan"] => "job.plan",
        ["job", "submit"] => "job.submit",
        ["job", "run"] => "job.run",
        ["job", "cancel"] => "job.cancel",
        ["capability", "list"] => "capability.list",
        ["capability", "inspect"] => "capability.inspect",
        ["device", "candidates"] => "device.candidates",
        ["target", "adopt"] => "target.adopt",
        ["target", "list"] => "target.list",
        ["target", "show"] => "target.show",
        ["target", "availability"] => "target.availability",
        ["target", "display-name", "set"] => "target.display-name.set",
        ["target", "display-name", "clear"] => "target.display-name.clear",
        ["device", "display-name", "set"] => "device.display-name.set",
        ["device", "display-name", "clear"] => "device.display-name.clear",
        ["trace", "cache", "status"] => "trace.cache.status",
        ["trace", "cache", "purge"] => "trace.cache.purge",
        ["runtime", "tool", "register"] => "runtime.tool.register",
        ["runtime", "tool", "list"] => "runtime.tool.list",
        ["runtime", "tool", "remove"] => "runtime.tool.remove",
        ["runtime", "tool", "inspect"] => "runtime.tool.inspect",
        ["runtime", "bundle", "register"] => "runtime.bundle.register",
        ["runtime", "bundle", "inspect"] => "runtime.bundle.inspect",
        ["runtime", "bundle", "list"] => "runtime.bundle.list",
        ["runtime", "bundle", "remove"] => "runtime.bundle.remove",
        ["runtime", "hdc", "status"] => "runtime.hdc.status",
        ["runtime", "hdc", "impact-preview"] => "runtime.hdc.impact-preview",
        ["runtime", "hdc", "restart"] => "runtime.hdc.restart",
        ["control-action", "list"] => "control-action.list",
        ["control-action", "show"] => "control-action.show",
        ["control-action", "reconcile"] => "control-action.reconcile",
        ["runtime", "storage", "status"] => "runtime.storage.status",
        ["runtime", "storage", "policy"] => "runtime.storage.policy",
        ["runtime", "storage", "root"] => "runtime.storage.root",
        ["session", "list"] => "session.list",
        ["session", "show"] => "session.show",
        ["session", "pin"] => "session.pin",
        ["session", "unpin"] => "session.unpin",
        ["session", "cleanup", "preview"] => "session.cleanup.preview",
        ["session", "cleanup", "apply"] => "session.cleanup.apply",
        ["session", "export", "preview"] => "session.export.preview",
        ["session", "export", "apply"] => "session.export.apply",
        ["history", "filter", "list"] => "history.filter.list",
        ["history", "filter", "save"] => "history.filter.save",
        ["history", "filter", "delete"] => "history.filter.delete",
        [] if help => "help",
        _ => {
            return Err(CliError::new(
                "invalidCommand",
                "available commands: doctor, operation list, target adopt|list|show|availability, target display-name set|clear, device display-name set|clear, device candidates, trace cache status|purge, history filter list|save|delete, runtime storage status|policy|root, session list|show|pin|unpin, session cleanup preview|apply, session export preview|apply",
            ));
        }
    };
    if raw && command != "artifact.read" {
        return Err(CliError::new(
            "invalidOption",
            "--raw belongs to artifact read",
        ));
    }
    if command != "doctor" && (deep || require_healthy) {
        return Err(CliError::new(
            "invalidOption",
            "--deep and --require-healthy belong to doctor",
        ));
    }
    let allowed: &[&str] = match command {
        "artifact.import.hap"
        | "artifact.import.native-library"
        | "artifact.import.workspace-patch" => &["importRequestId", "targetId", "file", "timeout"],
        "artifact.import.flash-bundle" => &[
            "importRequestId",
            "targetId",
            "file",
            "deviceProfile",
            "timeout",
        ],
        "artifact.import.abort" => &["importRequestId", "expectedGeneration", "timeout"],
        "artifact.import.release" => &["import", "generation", "timeout"],
        "artifact.import.inspect" => &["importRequestId", "import", "timeout"],
        "artifact.import.list" => &["targetId", "state", "pageSize", "cursor", "timeout"],

        "target.adopt" => &[
            "candidate",
            "observationId",
            "observationGeneration",
            "timeout",
        ],
        "runtime.hdc.impact-preview" => &[
            "action",
            "serverEndpointRef",
            "expectedServerGeneration",
            "actionRequestId",
            "timeout",
        ],
        "runtime.hdc.restart" => &["controlAction", "previewId", "previewDigest", "timeout"],
        "control-action.list" => &["pageSize", "cursor", "kind", "state", "timeout"],
        "control-action.show" | "control-action.reconcile" => &["controlAction", "timeout"],
        "target.list" => &["timeout"],
        "target.show" | "target.availability" => &["targetId", "timeout"],
        "target.display-name.set" => &["targetId", "expectedGeneration", "name", "timeout"],
        "target.display-name.clear" => &["targetId", "expectedGeneration", "timeout"],
        "device.display-name.set" => &[
            "candidate",
            "observationId",
            "observationGeneration",
            "name",
            "timeout",
        ],
        "device.display-name.clear" => &[
            "candidate",
            "observationId",
            "observationGeneration",
            "timeout",
        ],
        "artifact.inspect" => &["jobId", "import", "artifactId", "timeout"],
        "artifact.export" => &[
            "jobId",
            "import",
            "artifactId",
            "destinationPath",
            "overwrite",
            "allowSensitive",
            "timeout",
        ],
        "artifact.read" => &[
            "jobId",
            "import",
            "artifactId",
            "offset",
            "maxBytes",
            "allowSensitive",
            "timeout",
        ],
        "agent.run" => &[
            "requestFile",
            "targetId",
            "operation",
            "inputsFile",
            "expectedBindingRevision",
            "requestId",
            "idempotencyKey",
            "capabilityId",
            "reviewedPlanDigest",
            "executionId",
            "maximumWait",
            "timeout",
        ],
        "agent.resume" => &[
            "resumeReference",
            "resumeToken",
            "selection",
            "selectionFile",
            "timeout",
        ],
        "human-action.resume" => &[
            "resumeReference",
            "humanAction",
            "selection",
            "selectionFile",
            "timeout",
        ],
        "agent.status" => &["executionId", "timeout"],
        "human-action.list" => &["ownerKind", "owner", "pageSize", "cursor", "timeout"],
        "human-action.show" => &["humanAction", "timeout"],
        "agent.list" => &[
            "state",
            "operation",
            "targetId",
            "pageSize",
            "cursor",
            "timeout",
        ],
        "agent.abandon" => &["executionId", "expectedGeneration", "timeout"],
        "workspace.project.register" => &["registrationRequestId", "kind", "rootPath", "timeout"],
        "workspace.project.list" => &["timeout"],
        "workspace.project.show" => &["projectRef", "timeout"],
        "artifact.list" => &[
            "jobId",
            "import",
            "pageSize",
            "cursor",
            "artifactId",
            "allowSensitive",
            "timeout",
        ],
        "history.filter.save" => &[
            "expectedGeneration",
            "search",
            "status",
            "mode",
            "sessionId",
            "targetId",
            "timeRange",
            "activity",
        ],
        "history.filter.delete" => &["expectedGeneration"],
        "runtime.storage.policy" => &[
            "expectedGeneration",
            "totalQuotaBytes",
            "safetyMarginBytes",
            "retentionDays",
        ],
        "runtime.storage.root" => &["expectedGeneration", "rootPath", "resetToDefault"],
        "runtime.tool.remove" => &["tool", "expectedGeneration"],
        "runtime.tool.inspect" => &["tool"],
        "runtime.tool.register" => &["kind", "rootPath", "file"],
        "runtime.bundle.register" => &["kind", "file"],
        "runtime.bundle.inspect" => &["bundle"],
        "operation.describe" | "operation.example" => &["operation"],
        "job.plan" | "job.submit" => &[
            "requestFile",
            "targetId",
            "operation",
            "inputsFile",
            "expectedBindingRevision",
            "requestId",
            "idempotencyKey",
            "timeout",
        ],
        "job.status" | "job.show" | "job.evidence" | "job.result" | "job.run" => {
            &["jobId", "timeout"]
        }
        "job.cancel" => &["jobId"],
        "capability.inspect" => &["capabilityId"],
        "job.timeline" => &["jobId", "pageSize", "cursor", "timeout"],
        "job.events" => &["jobId", "pageSize", "afterCursor", "timeout"],
        "job.list" => &[
            "pageSize",
            "cursor",
            "order",
            "includeCurrent",
            "includeTimeline",
            "timeout",
            "state",
            "operation",
            "targetId",
            "thread",
        ],
        "runtime.bundle.list" | "runtime.tool.list" => &["pageSize", "cursor"],
        "runtime.bundle.remove" => &["bundle", "expectedGeneration"],
        "session.list" => &["pageSize", "cursor"],
        "session.show" => &["sessionId"],
        "session.export.preview" => &["sessionId", "destinationPath", "allowSensitive"],
        "session.export.apply" | "session.cleanup.apply" => &["previewId", "previewDigest"],
        "session.pin" | "session.unpin" => &["sessionId", "expectedGeneration"],
        _ => &[],
    };
    if method_options
        .keys()
        .any(|key| !allowed.contains(&key.as_str()))
    {
        return Err(CliError::new(
            "invalidOption",
            "the option does not belong to this command",
        ));
    }
    if !help
        && allowed.contains(&"expectedGeneration")
        && !method_options.contains_key("expectedGeneration")
    {
        return Err(CliError::new(
            "invalidOption",
            "the mutation requires --expected-generation",
        ));
    }
    if !help && command == "capability.inspect" && !method_options.contains_key("capabilityId") {
        return Err(CliError::new(
            "invalidOption",
            "capability inspect requires --capability",
        ));
    }
    if !help
        && matches!(command, "session.show" | "session.pin" | "session.unpin")
        && !method_options.contains_key("sessionId")
    {
        return Err(CliError::new(
            "invalidOption",
            "Session command requires --session",
        ));
    }
    if !help
        && matches!(command, "session.export.apply" | "session.cleanup.apply")
        && (!method_options
            .get("previewId")
            .and_then(Value::as_str)
            .is_some_and(session_resources::uuid)
            || !method_options
                .get("previewDigest")
                .is_some_and(session_resources::digest))
    {
        return Err(CliError::new(
            "invalidInput",
            "Session apply requires an exact preview tuple",
        ));
    }
    if !help && command == "session.export.preview" {
        if !method_options.contains_key("sessionId")
            || !method_options.contains_key("destinationPath")
        {
            return Err(CliError::new(
                "invalidOption",
                "Session export preview requires --session and --destination",
            ));
        }
        method_options
            .entry("allowSensitive")
            .or_insert(json!(false));
    }
    if !help
        && matches!(
            command,
            "session.list" | "runtime.bundle.list" | "runtime.tool.list"
        )
    {
        let size = method_options
            .get("pageSize")
            .map_or(Some(100), |value| {
                value.as_str().and_then(|text| text.parse::<u64>().ok())
            })
            .filter(|size| (1..=1000).contains(size))
            .ok_or_else(|| {
                CliError::new("invalidOption", "page-size must be between 1 and 1000")
            })?;
        method_options.insert("pageSize".into(), json!(size));
    }
    if !help
        && command == "runtime.storage.policy"
        && allowed.iter().any(|key| !method_options.contains_key(*key))
    {
        return Err(CliError::new(
            "invalidOption",
            "Storage policy requires all policy fields",
        ));
    }
    if !help
        && command == "runtime.storage.root"
        && (method_options.contains_key("rootPath")
            == method_options.contains_key("resetToDefault"))
    {
        return Err(CliError::new(
            "invalidOption",
            "Storage root requires exactly one of --root and --default",
        ));
    }
    for key in ["totalQuotaBytes", "safetyMarginBytes", "retentionDays"] {
        if !help
            && method_options.get(key).is_some_and(|v| {
                !v.as_str().unwrap_or("").parse::<u64>().is_ok_and(|n| {
                    n > 0 && n <= i64::MAX as u64 && n.to_string() == v.as_str().unwrap_or("")
                })
            })
        {
            return Err(CliError::new(
                "invalidOption",
                "Storage policy requires canonical positive integers",
            ));
        }
    }
    if !help {
        if let Some(generation) = method_options.get("expectedGeneration") {
            let text = generation.as_str().expect("option text");
            if !text.parse::<u64>().is_ok_and(|n| {
                (n > 0 || matches!(command, "session.pin" | "session.unpin"))
                    && n <= i64::MAX as u64
                    && n.to_string() == text
            }) {
                return Err(CliError::new(
                    "invalidOption",
                    "--expected-generation must be a canonical positive integer",
                ));
            }
        }
        for (key, allowed) in [
            (
                "status",
                &[
                    "all",
                    "active",
                    "needsAttention",
                    "succeeded",
                    "failed",
                    "interrupted",
                    "cancelled",
                ][..],
            ),
            (
                "mode",
                &["all", "execute", "planned", "simulated", "unknown"][..],
            ),
            (
                "timeRange",
                &["anyTime", "lastHour", "lastDay", "lastWeek"][..],
            ),
            (
                "activity",
                &[
                    "all",
                    "flash",
                    "viewer",
                    "trace",
                    "diagnostics",
                    "debug",
                    "device",
                    "other",
                ][..],
            ),
        ] {
            if method_options
                .get(key)
                .is_some_and(|v| !allowed.contains(&v.as_str().expect("option text")))
            {
                return Err(CliError::new(
                    "invalidOption",
                    "unsupported History filter option value",
                ));
            }
        }
    }
    if command == "history.filter.save" {
        for (key, value) in [
            ("search", json!("")),
            ("status", json!("all")),
            ("mode", json!("all")),
            ("sessionId", Value::Null),
            ("targetId", Value::Null),
            ("timeRange", json!("anyTime")),
            ("activity", json!("all")),
        ] {
            method_options.entry(key).or_insert(value);
        }
    }
    if help && mode.is_some() {
        return Err(CliError::new(
            "invalidOption",
            "help renders human text only",
        ));
    }
    bootstrap_resources::configure(command, &mut method_options, help)?;
    let import_timeout = import_resources::configure(command, &mut method_options, help)?;
    let artifact_timeout = artifact_resources::configure(command, &mut method_options, help)?;
    let workspace_timeout = workspace_projects::configure(command, &mut method_options, help)?;
    let target_timeout = target_resources::configure(command, &mut method_options, help)?;
    let plan_timeout = job_plan::configure(command, &mut method_options, help)?;
    let human_action_timeout =
        human_action_resources::configure(command, &mut method_options, help)?;
    let agent_timeout = agent_executions::configure(command, &mut method_options, help)?;
    let hdc_timeout = hdc_control::configure(command, &mut method_options, help)?;
    let timeout_ms = read_only_resources::configure(command, &mut method_options, help)?
        .or(import_timeout)
        .or(artifact_timeout)
        .or(target_timeout)
        .or(workspace_timeout)
        .or(plan_timeout)
        .or(agent_timeout)
        .or(human_action_timeout)
        .or(hdc_timeout);
    Ok(Invocation {
        command,
        method: if command == "device.candidates" {
            "device.observations"
        } else if command == "artifact.import.inspect" {
            "artifact.import.inspection"
        } else if matches!(
            command,
            "artifact.import.hap"
                | "artifact.import.native-library"
                | "artifact.import.workspace-patch"
                | "artifact.import.flash-bundle"
        ) {
            "artifact.import.begin"
        } else if command == "operation.example" {
            "operation.describe"
        } else {
            command
        },
        params: if command == "doctor" {
            Some(serde_json::from_value(json!({"deep":deep})).unwrap())
        } else if command.starts_with("workspace.project.")
            || command.starts_with("history.filter.")
            || command.starts_with("runtime.storage.")
            || matches!(
                command,
                "runtime.tool.inspect"
                    | "runtime.bundle.inspect"
                    | "runtime.tool.register"
                    | "runtime.bundle.register"
                    | "runtime.tool.remove"
                    | "runtime.bundle.list"
                    | "runtime.tool.list"
                    | "runtime.bundle.remove"
            )
            // Swift sends a quota request without parameters.
            || (command.starts_with("artifact.") && command != "artifact.quota")
            || command.starts_with("target.")
            || command.starts_with("device.display-name.")
            || command.starts_with("session.")
            || command.starts_with("human-action.")
            || matches!(
                command,
                "operation.describe"
                    | "operation.example"
                    | "job.status"
                    | "job.list"
                    | "job.show"
                    | "job.evidence"
                    | "job.timeline"
                    | "job.events"
                    | "job.plan"
                    | "job.submit"
                    | "job.run"
                    | "job.cancel"
                    | "job.result"
                    | "capability.inspect"
                    | "agent.run"
                    | "agent.status"
                    | "agent.list"
                    | "agent.abandon"
                    | "agent.resume"
                    | "human-action.resume"
                    | "runtime.hdc.impact-preview"
                    | "runtime.hdc.restart"
                    | "control-action.list"
                    | "control-action.show"
                    | "control-action.reconcile"
            )
        {
            Some(method_options)
        } else {
            None
        },
        json: mode.as_deref() == Some("json"),
        raw,
        help,
        require_healthy,
        control_request_id: id,
        socket,
        timeout_ms,
    })
}

pub fn success_envelope(command: &str, result: Value, id: &str) -> Value {
    json!({"schemaVersion":"arkdeck.cli.result/1","command":command,"ok":true,"result":result,
        "meta":{"controlRequestId":id,"cliVersion":"0.1.0","controlProtocolVersion":PROTOCOL_VERSION}})
}

pub fn failure_envelope(command: &str, error: &CliError, id: &str, protocol: bool) -> Value {
    let mut details = json!({"code":error.code,"message":error.message,
        "controlRequestRetryable":matches!(error.code,"clientTimeout"|"resultNotReady"|"runtimeUnavailable"),
        "attentionRequired":matches!(error.exit_code(),2|75|77)});
    if !error.details.is_empty() {
        details["details"] = json!(error.details);
    }
    let mut result = json!({"schemaVersion":"arkdeck.cli.result/1","command":command,"ok":false,"error":details,
        "meta":{"controlRequestId":id,"cliVersion":"0.1.0"}});
    if protocol {
        result["meta"]["controlProtocolVersion"] = json!(PROTOCOL_VERSION);
    }
    result
}

pub fn render(value: &Value) -> Result<Vec<u8>, ContractError> {
    let mut bytes = canonical_json(value)?;
    bytes.push(b'\n');
    Ok(bytes)
}
