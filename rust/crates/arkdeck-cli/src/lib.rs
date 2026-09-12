//! Current Rust CLI leaves; machine envelopes follow the current contract.
use arkdeck_client::ClientError;
use arkdeck_contract::{ContractError, PROTOCOL_VERSION, canonical_json};
use serde_json::{Map, Value, json};
mod artifact_resources;
pub use artifact_resources::{artifact_bytes, validate_artifact_metadata, validate_artifact_read};
mod bootstrap_resources;
mod read_only_resources;
pub use read_only_resources::{
    project_read_only_response, validate_read_only_request, validate_read_only_response,
};
mod job_events;
mod job_resources;
mod session_resources;
pub use bootstrap_resources::{validate_bootstrap_request, validate_bootstrap_response};
pub use session_resources::validate_session_response;
mod trace_cache;
pub use trace_cache::validate_trace_cache_response;

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
            | "resourceNotFound"
            | "workspaceReferenceNotFound" => 65,
            "runtimeUnavailable"
            | "unsupportedOnPlatform"
            | "protocolVersionUnsupported"
            | "controlMethodUnavailable"
            | "healthRequirementFailed" => 69,
            "operationUnavailable" => 69,
            "recordUnreadable" | "artifactIntegrityFailed" => 2,
            "ioFailure" => 74,
            "outcomeUnknown" => 75,
            "quotaExceeded" => 69,
            "operationFailed" => 1,
            "clientTimeout" => 75,
            "admissionDenied" | "fileIdentityChanged" | "sensitiveAccessDenied" => 77,
            _ => 70,
        }
    }
    pub fn from_client(error: ClientError, method: &str) -> Self {
        if matches!(method, "runtime.bundle.remove" | "runtime.tool.remove") {
            return bootstrap_resources::retirement_error(error, method);
        }
        let mut result = match error {
            ClientError::Transport(error) => Self::new(
                if matches!(
                    method,
                    "runtime.tool.register"
                        | "runtime.bundle.register"
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
                let artifact_proof = matches!(method, "artifact.inspect" | "artifact.read")
                    && error.details.as_ref().is_some_and(|d| {
                        d.get("phase") == Some(&json!("artifactOwner"))
                            && d.get("newDispatchCount") == Some(&json!(0))
                    });
                let host_proof = host_proof || bootstrap_proof || artifact_proof;
                let code = match error.code.as_str() {
                    "artifactIntegrityFailed" if artifact_proof => "artifactIntegrityFailed",
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
                    "recordUnreadable" if method == "runtime.tool.list" && !bootstrap_proof => {
                        "internalError"
                    }
                    "recordUnreadable" => "recordUnreadable",
                    "workspaceReferenceNotFound" => "workspaceReferenceNotFound",
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
                "--expected-generation"
                | "--page-size"
                | "--cursor"
                | "--root"
                | "--destination"
                | "--preview-id"
                | "--preview-digest"
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
                | "--order"
                | "--state"
                | "--thread"
                | "--after-cursor"
                | "--timeout" => {
                    index += 1;
                    let value = argv
                        .get(index)
                        .filter(|v| !v.starts_with("--"))
                        .ok_or_else(|| {
                            CliError::new("invalidOption", "the option requires a value")
                        })?;
                    let key = match argument.as_str() {
                        "--expected-generation" => "expectedGeneration",
                        "--page-size" => "pageSize",
                        "--root" => "rootPath",
                        "--destination" => "destinationPath",
                        "--preview-id" => "previewId",
                        "--preview-digest" => "previewDigest",
                        "--total-quota-bytes" => "totalQuotaBytes",
                        "--safety-margin-bytes" => "safetyMarginBytes",
                        "--retention-days" => "retentionDays",
                        "--job" => "jobId",
                        "--after-cursor" => "afterCursor",
                        "--artifact" => "artifactId",
                        "--max-bytes" => "maxBytes",
                        "--session" => "sessionId",
                        "--target" => "targetId",
                        "--time" => "timeRange",
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
        ["artifact", "inspect"] => "artifact.inspect",
        ["artifact", "read"] => "artifact.read",
        ["doctor"] => "doctor",
        ["operation", "list"] => "operation.list",
        ["operation", "describe"] => "operation.describe",
        ["operation", "example"] => "operation.example",
        ["job", "status"] => "job.status",
        ["job", "list"] => "job.list",
        ["job", "show"] => "job.show",
        ["job", "evidence"] => "job.evidence",
        ["job", "timeline"] => "job.timeline",
        ["job", "events"] => "job.events",
        ["device", "candidates"] => "device.candidates",
        ["trace", "cache", "status"] => "trace.cache.status",
        ["runtime", "tool", "register"] => "runtime.tool.register",
        ["runtime", "tool", "list"] => "runtime.tool.list",
        ["runtime", "tool", "remove"] => "runtime.tool.remove",
        ["runtime", "tool", "inspect"] => "runtime.tool.inspect",
        ["runtime", "bundle", "register"] => "runtime.bundle.register",
        ["runtime", "bundle", "inspect"] => "runtime.bundle.inspect",
        ["runtime", "bundle", "list"] => "runtime.bundle.list",
        ["runtime", "bundle", "remove"] => "runtime.bundle.remove",
        ["runtime", "storage", "status"] => "runtime.storage.status",
        ["runtime", "storage", "policy"] => "runtime.storage.policy",
        ["runtime", "storage", "root"] => "runtime.storage.root",
        ["session", "list"] => "session.list",
        ["session", "show"] => "session.show",
        ["session", "pin"] => "session.pin",
        ["session", "unpin"] => "session.unpin",
        ["session", "cleanup", "preview"] => "session.cleanup.preview",
        ["session", "export", "preview"] => "session.export.preview",
        ["session", "export", "apply"] => "session.export.apply",
        ["history", "filter", "list"] => "history.filter.list",
        ["history", "filter", "save"] => "history.filter.save",
        ["history", "filter", "delete"] => "history.filter.delete",
        [] if help => "help",
        _ => {
            return Err(CliError::new(
                "invalidCommand",
                "available commands: doctor, operation list, device candidates, trace cache status, history filter list|save|delete, runtime storage status|policy|root, session list|show|pin|unpin, session cleanup preview, session export preview|apply",
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
        "artifact.inspect" => &["jobId", "import", "artifactId", "timeout"],
        "artifact.read" => &[
            "jobId",
            "import",
            "artifactId",
            "offset",
            "maxBytes",
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
        "job.status" | "job.show" | "job.evidence" => &["jobId", "timeout"],
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
        "session.export.apply" => &["previewId", "previewDigest"],
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
        && command == "session.export.apply"
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
            "Session export apply requires an exact preview tuple",
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
    let artifact_timeout = artifact_resources::configure(command, &mut method_options, help)?;
    let timeout_ms =
        read_only_resources::configure(command, &mut method_options, help)?.or(artifact_timeout);
    Ok(Invocation {
        command,
        method: if command == "device.candidates" {
            "device.observations"
        } else if command == "operation.example" {
            "operation.describe"
        } else {
            command
        },
        params: if command == "doctor" {
            Some(serde_json::from_value(json!({"deep":deep})).unwrap())
        } else if command.starts_with("history.filter.")
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
            || command.starts_with("artifact.")
            || command.starts_with("session.")
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
        "controlRequestRetryable":matches!(error.code,"clientTimeout"|"runtimeUnavailable"),
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
