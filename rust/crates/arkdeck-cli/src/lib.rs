//! The first three current CLI leaves; machine envelopes follow the Swift v1 contract.
use arkdeck_client::ClientError;
use arkdeck_contract::{ContractError, PROTOCOL_VERSION, canonical_json};
use serde_json::{Map, Value, json};

#[derive(Debug, Clone, PartialEq)]
pub struct Invocation {
    pub command: &'static str,
    pub method: &'static str,
    pub params: Option<Map<String, Value>>,
    pub json: bool,
    pub help: bool,
    pub require_healthy: bool,
    pub control_request_id: Option<String>,
    pub socket: Option<String>,
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
            | "resourceConflict"
            | "resourceNotFound"
            | "workspaceReferenceNotFound" => 65,
            "runtimeUnavailable"
            | "unsupportedOnPlatform"
            | "protocolVersionUnsupported"
            | "controlMethodUnavailable"
            | "healthRequirementFailed" => 69,
            "recordUnreadable" => 2,
            "operationFailed" => 1,
            "clientTimeout" => 75,
            "admissionDenied" => 77,
            _ => 70,
        }
    }
    pub fn from_client(error: ClientError, method: &str) -> Self {
        let mut result = match error {
            ClientError::Transport(error) => Self::new(
                if matches!(
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
                let code = match error.code.as_str() {
                    "unsupportedProtocolVersion" => "protocolVersionUnsupported",
                    "malformedFrame" => "protocolMalformed",
                    "unknownMethod" => "controlMethodUnavailable",
                    "invalidParams" => "invalidInput",
                    "conflict" => "resourceConflict",
                    "notFound" => "resourceNotFound",
                    "recordUnreadable" => "recordUnreadable",
                    "workspaceReferenceNotFound" => "workspaceReferenceNotFound",
                    "invalidInput" if proof => "invalidInput",
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
    let mut seen = std::collections::BTreeSet::new();
    let (mut mode, mut id, mut socket) = (None, None, None);
    let (mut deep, mut require_healthy, mut help) = (false, false, false);
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
                "--require-healthy" => require_healthy = true,
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
                        "the option is not available for this read-only command",
                    ));
                }
            }
        } else {
            positional.push(argument.as_str());
        }
        index += 1;
    }
    let command = match positional.as_slice() {
        ["doctor"] => "doctor",
        ["operation", "list"] => "operation.list",
        ["device", "candidates"] => "device.candidates",
        [] if help => "help",
        _ => {
            return Err(CliError::new(
                "invalidCommand",
                "available commands: doctor, operation list, device candidates",
            ));
        }
    };
    if command != "doctor" && (deep || require_healthy) {
        return Err(CliError::new(
            "invalidOption",
            "--deep and --require-healthy belong to doctor",
        ));
    }
    if help && mode.is_some() {
        return Err(CliError::new(
            "invalidOption",
            "help renders human text only",
        ));
    }
    Ok(Invocation {
        command,
        method: if command == "device.candidates" {
            "device.observations"
        } else {
            command
        },
        params: if command == "doctor" {
            Some(serde_json::from_value(json!({"deep":deep})).unwrap())
        } else {
            None
        },
        json: mode.as_deref() == Some("json"),
        help,
        require_healthy,
        control_request_id: id,
        socket,
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
