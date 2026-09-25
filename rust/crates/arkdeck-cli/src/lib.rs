//! Current Rust CLI leaves; machine envelopes follow the current contract.
use arkdeck_client::ClientError;
use arkdeck_contract::{ContractError, PROTOCOL_VERSION, canonical_json};
use serde_json::{Map, Value, json};
mod artifact_resources;
mod import_resources;
pub use artifact_resources::{
    artifact_bytes, artifact_export_params, require_diagnostics_artifact, require_trace_artifact,
    validate_artifact_export, validate_artifact_metadata, validate_artifact_read,
};
pub use import_resources::execute_import;
mod bootstrap_resources;
mod failure_mapping;
use failure_mapping::Transport;
pub use failure_mapping::{BOUNDED_READ_ONLY_METHODS, bounded_read_only};
pub mod blocked_leaves;
mod debug_probe;
mod debug_templates;
pub mod domain_executor;
pub mod domain_leaves;
pub mod error_registry;
mod feature_coverage;
mod flash_leaves;
pub mod support_bundle;
mod trace_inspect;
pub mod ui_dump;
pub mod update_feed;
pub use debug_templates::debug_template_list;
pub use flash_leaves::{broker_params, is_broker_leaf};
mod device_wait;
pub mod diagnostics_resources;
pub use debug_probe::validate_debug_probe;
pub use trace_inspect::{
    MACHINE_QUALITY_SCOPES, inspection_projection, inspection_request, validate_inspection,
};
mod operation_validation;
mod read_only_resources;
pub use read_only_resources::{
    evidence_exit, project_read_only_response, result_exit, validate_read_only_request,
    validate_read_only_response,
};
mod job_events;
mod job_plan;
mod job_resources;
mod job_wait;
pub mod machine_contracts;
pub mod maintainer_contracts;
pub use job_plan::{
    announces_generated_identity, generates_identity, job_plan_params, job_submit_params, run_exit,
    validate_acceptance, validate_cancellation, validate_plan,
};
mod session_resources;
pub use bootstrap_resources::{validate_bootstrap_request, validate_bootstrap_response};
pub use session_resources::{validate_session_request, validate_session_response};
mod workspace_continuation;
mod workspace_projects;
pub use workspace_continuation::{
    Draft, continue_workspace, request_json, requires_current_target,
};
pub use workspace_projects::validate_workspace_project_response;
mod target_resources;
pub use target_resources::validate_target_response;
mod console_approval;
mod hdc_control;
pub use console_approval::{read_console_challenge, validate_control_action_result};
pub use hdc_control::hdc_control_action_params;
mod trace_cache;
pub use trace_cache::validate_trace_cache_response;
mod agent_executions;
mod command_registry;
mod human_action_resources;
mod registry_parse;
pub use agent_executions::{
    Settlement, agent_exit, execution_intent, human_action_progress, require_execution_identity,
    resume_params, settle_execution, validate_execution,
};
pub use artifact_resources::validate_artifact_page;
pub use command_registry::{
    command_registry, command_registry_human, completion_script, help_text, is_node, output_modes,
};
pub use device_wait::{proved_row, wait_document, wait_request, wait_timeout};
pub use job_events::{EventStream, event_line, terminal_line};
pub use job_wait::{Poll, follows_events, observed, poll, stopped_waiting};
pub use operation_validation::{
    bounded_input_document, input_findings, validation_attention, validation_document,
};
#[cfg(target_os = "macos")]
#[cfg(target_os = "macos")]
pub mod runtime_service;
#[cfg(target_os = "macos")]
pub mod runtime_service_install;
#[cfg(target_os = "macos")]
pub mod runtime_service_verify;
pub mod signing_leaves;

/// This CLI's product version (Swift `CLIProductVersion.product`).
pub const CLI_VERSION: &str = "0.1.0";

#[derive(Debug, Clone, PartialEq)]
pub struct Invocation {
    pub command: &'static str,
    pub method: &'static str,
    pub params: Option<Map<String, Value>>,
    pub json: bool,
    /// The one stream mode the registry publishes, for the two leaves that
    /// follow durable events rather than answering one document.
    pub jsonl: bool,
    pub raw: bool,
    /// Legacy raw JSON reply for debug probe; distinct from Artifact bytes.
    pub legacy_json: bool,
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
    /// The leaf a refusal belongs to once its path resolved (Swift
    /// `CLIRegistryError.command`); a machine answer names it instead of
    /// `registry.parse`.
    pub command: Option<&'static str>,
}
impl CliError {
    pub fn new(code: &'static str, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
            details: Map::new(),
            command: None,
        }
    }
    /// §9: the exit status of the code's category in the error registry; a
    /// code the registry does not have is an internal failure.
    pub fn exit_code(&self) -> u8 {
        error_registry::category(self.code).map_or(70, error_registry::ExitCategory::exit_code)
    }
    /// Swift `CLIRuntimeSession.mapped` of a connection that did not open for
    /// `method`: nothing was sent, so nothing was accepted, whatever the
    /// method (`runtimeUnavailable`, in Swift's words for an OS error). The
    /// client's own deadline is the exception: it says nothing about the
    /// request.
    pub fn from_connect(error: ClientError, method: &str) -> Self {
        let mut result = match &error {
            ClientError::Transport(error) if client_deadline(error) => Self::new(
                failure_mapping::transport_code(Transport::ClientTimeout, method),
                CLIENT_DEADLINE,
            ),
            ClientError::Transport(error) => Self::new(
                failure_mapping::transport_code(Transport::ConnectFailed, method),
                match error.raw_os_error() {
                    Some(number) => format!("connect failed: errno {number}"),
                    None => error.to_string(),
                },
            ),
            other => Self::new(
                failure_mapping::transport_code(Transport::ConnectFailed, method),
                other.to_string(),
            ),
        };
        result
            .details
            .insert("method".into(), Value::String(method.into()));
        result
    }

    /// Swift `CLIRuntimeSession.mapped` of a request to `method` that went
    /// out. The code is Swift's mapper's (`failure_mapping`), and the details
    /// are Swift's: the Runtime's own, if it gave any, with the method and
    /// the wire code. A reply that did not come back whole leaves a
    /// mutation-capable method's outcome unknown, in this CLI's words for
    /// what to read next; Swift passes the transport's own text.
    pub fn from_client(error: ClientError, method: &str) -> Self {
        let mut result = match error {
            ClientError::Remote(wire) => {
                let mut result = Self::new(
                    failure_mapping::wire_code(&wire.code, method, wire.details.as_ref()),
                    wire.message,
                );
                result.details = wire.details.unwrap_or_default();
                result
                    .details
                    .insert("wireCode".into(), Value::String(wire.code));
                result
            }
            ClientError::Transport(error) if client_deadline(&error) => Self::new(
                failure_mapping::transport_code(Transport::ClientTimeout, method),
                CLIENT_DEADLINE,
            ),
            // Proved before the business request left: this client's own
            // request check or the health preflight.
            ClientError::Contract(
                ContractError::UnsupportedVersion | ContractError::ContractMismatch,
            ) => Self::new(
                "protocolVersionUnsupported",
                "client and Runtime must use the same current control contract",
            ),
            error if !failure_mapping::bounded_read_only(method) => {
                Self::new("outcomeUnknown", unconfirmed(method, &error))
            }
            ClientError::Transport(error) => Self::new(
                failure_mapping::transport_code(Transport::LostResponse, method),
                error.to_string(),
            ),
            ClientError::Contract(_) => Self::new(
                failure_mapping::transport_code(Transport::MalformedResponse, method),
                "the local Runtime response does not conform to the current contract",
            ),
            ClientError::ConnectionUnusable => Self::new(
                "runtimeUnavailable",
                "the connection is unusable; no request was replayed",
            ),
        };
        result
            .details
            .insert("method".into(), Value::String(method.into()));
        result
    }
}

/// Swift's words when the client stops waiting.
pub const CLIENT_DEADLINE: &str = "the client wait deadline expired; no cancellation was requested";

/// Whether a transport failure is the client's own deadline, which Swift's
/// client names `deadlineExceeded`.
fn client_deadline(error: &std::io::Error) -> bool {
    matches!(
        error.kind(),
        std::io::ErrorKind::TimedOut | std::io::ErrorKind::WouldBlock
    )
}

/// This CLI's words for a mutation-capable request whose reply did not come
/// back whole: what the caller reads next instead of repeating it.
fn unconfirmed(method: &str, error: &ClientError) -> String {
    match method {
        "job.submit" => {
            "the Job submission reply is unconfirmed; submit the same request again to learn its Job"
        }
        "job.run" => {
            "the Job run reply is unconfirmed; read the Job with job status instead of running it again"
        }
        "job.cancel" => {
            "the Job cancellation reply is unconfirmed; read the Job with job status to learn whether it was cancelled"
        }
        "job.reconcile" => {
            "the Job reconcile reply is unconfirmed; read the Job with job status to learn what it settled; the original effect is never replayed"
        }
        "agent.run" => {
            "the agent run reply is unconfirmed; read the execution with agent status, or run the same execution again, instead of starting a new one"
        }
        "agent.resume" => {
            "the agent resume reply is unconfirmed; read the execution with agent status instead of resuming it again"
        }
        "agent.abandon" => {
            "the agent abandon reply is unconfirmed; read the execution with agent status to learn whether it was abandoned"
        }
        "human-action.resume" => {
            "the human-action resume reply is unconfirmed; read the action with human-action show instead of resuming it again"
        }
        "target.adopt" => {
            "the target adoption reply is unconfirmed; read the device candidates and the target list to learn whether it was adopted"
        }
        "runtime.hdc.impact-preview"
        | "runtime.hdc.restart"
        | "control-action.list"
        | "control-action.show"
        | "control-action.reconcile" => {
            "the HDC control-action reply is unconfirmed; no request was replayed"
        }
        "runtime.tool.select" => {
            "the tool-selection reply is unconfirmed; select again with the same action request ID to read the same control action, never a new one"
        }
        "runtime.tool.register" | "runtime.bundle.register" => {
            "Runtime mutation response is unconfirmed; no request was replayed"
        }
        "runtime.tool.remove" | "runtime.bundle.remove" => {
            return format!("{method} has no verified receipt: {error}");
        }
        "workspace.project.register"
        | "workspace.project.update"
        | "workspace.project.remove"
        | "workspace.preset.register"
        | "workspace.preset.update"
        | "workspace.preset.remove" => {
            "workspace registration response is unconfirmed; no request was replayed"
        }
        "artifact.import.begin"
        | "artifact.import.append"
        | "artifact.import.abort"
        | "artifact.import.commit"
        | "artifact.import.release" => {
            "Import response is unconfirmed; inspect the same request identity before continuing"
        }
        "artifact.export" => {
            "Artifact export response is unconfirmed; inspect the exact destination before retrying"
        }
        "target.display-name.set"
        | "target.display-name.clear"
        | "device.display-name.set"
        | "device.display-name.clear" => {
            "Display-name response is unconfirmed; read current state before another update; no request was replayed"
        }
        "session.cleanup.apply" => {
            "Session cleanup response is unconfirmed; no request was replayed"
        }
        "trace.cache.purge" => "Trace cache purge response is unconfirmed; no request was replayed",
        _ => return format!("the {method} reply is unconfirmed; no request was replayed"),
    }
    .to_owned()
}

/// Swift `ISO8601Timestamps.string(from:)`: whole seconds, UTC, `Z`.
pub(crate) fn utc_now() -> String {
    utc_now_at(
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs(),
    )
}

/// `utc_now` of the instant `seconds` after the epoch.
pub(crate) fn utc_now_at(seconds: u64) -> String {
    let days = (seconds / 86_400) as i64 + 719_468;
    let era = days / 146_097;
    let day_of_era = days - era * 146_097;
    let year_of_era =
        (day_of_era - day_of_era / 1460 + day_of_era / 36524 - day_of_era / 146_096) / 365;
    let year = year_of_era + era * 400;
    let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    let month_index = (5 * day_of_year + 2) / 153;
    let day = day_of_year - (153 * month_index + 2) / 5 + 1;
    let month = month_index + if month_index < 10 { 3 } else { -9 };
    let year = year + i64::from(month <= 2);
    let time = seconds % 86_400;
    format!(
        "{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}Z",
        time / 3600,
        time % 3600 / 60,
        time % 60
    )
}

/// A frame identity as Swift's `AgentClient` assigns one when its caller
/// names none: a random UUID in uppercase text.
pub fn client_frame_id() -> String {
    job_plan::uuid()
        .unwrap_or_else(|_| "00000000-0000-4000-8000-000000000000".into())
        .to_uppercase()
}

pub fn valid_correlation(id: &str) -> bool {
    (1..=128).contains(&id.len())
        && id.as_bytes()[0].is_ascii_alphanumeric()
        && id
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || b"._:-".contains(&c))
}

/// Parse `argv`. A leaf that is not executable is answered by name, as Swift
/// answers it; everything else is this parser's to accept or refuse.
///
/// A refusal is reported as Swift's CLI reports it (TASK-XPA-018 a3): where
/// Swift's registry pass (`registry_parse`) refuses the argv too, which Swift
/// would have done before any handler ran, its answer is the one given, with
/// Swift's words, `details` and leaf. Otherwise this parser's own refusal
/// names the leaf the path resolved to, as Swift's handler failures do. A
/// path the registry names but this CLI does not serve keeps its own
/// refusal, and so does an option this platform does not offer (`--socket`
/// off macOS): Swift's parser only ever judged macOS. Neither pass widens or
/// narrows what is accepted.
pub fn parse(argv: &[String]) -> Result<Invocation, CliError> {
    if let Some(answer) = command_registry::answer_by_name(argv) {
        return answer;
    }
    if let Some(answer) = blocked_leaves::answer(argv) {
        return answer;
    }
    if let Some(answer) = update_feed::answer(argv) {
        return answer;
    }
    parse_argv(argv).map_err(|error| reported(argv, error))
}

/// The refusal `parse` reports for `argv`, given this parser's own.
fn reported(argv: &[String], error: CliError) -> CliError {
    let leaf = registry_parse::leaf(argv);
    if error.code == "invalidCommand" && leaf.is_some() {
        return error;
    }
    match registry_parse::check(argv) {
        Err(swift) if error.code != "unsupportedOnPlatform" => swift,
        _ => {
            let mut error = error;
            if error.command.is_none() && error.code != "invalidCommand" {
                error.command = leaf;
            }
            error
        }
    }
}

fn parse_argv(argv: &[String]) -> Result<Invocation, CliError> {
    let mut positional = Vec::new();
    let mut method_options = Map::new();
    let mut seen = std::collections::BTreeSet::new();
    let (mut mode, mut id, mut socket) = (None, None, None);
    let (mut deep, mut require_healthy, mut help) = (false, false, false);
    let mut raw = false;
    let mut legacy_json = false;
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
                "--json" => legacy_json = true,
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
                | "--x"
                | "--y"
                | "--destination"
                | "--preview-id"
                | "--preview-digest"
                | "--action"
                | "--server-endpoint-ref"
                | "--expected-server-generation"
                | "--expected-active-generation"
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
                | "--mutation-request-id"
                | "--project"
                | "--preset"
                | "--template"
                | "--toolchain"
                | "--toolchain-generation"
                | "--credential"
                | "--timeout-seconds"
                | "--module"
                | "--product"
                | "--build-mode"
                | "--relative-source-map"
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
                | "--action-file"
                | "--source-sha256"
                | "--build-sha256"
                | "--archive-sha256"
                | "--inputs-file"
                | "--expected-binding-revision"
                | "--request-id"
                | "--idempotency-key"
                | "--execution-id"
                | "--resume-reference"
                | "--resume-token"
                | "--human-action"
                | "--invocation"
                | "--selection"
                | "--selection-file"
                | "--owner-kind"
                | "--owner"
                | "--maximum-wait"
                | "--maximum-wait-seconds"
                | "--reviewed-plan-digest"
                | "--daemon"
                | "--hdc"
                | "--workspace-project"
                | "--deveco-sdk"
                | "--arktrace-descriptor"
                | "--arkforge-bundle"
                | "--arkforge-campaign"
                | "--sensitive-evidence"
                | "--harness-model-provider"
                | "--harness-model-name"
                | "--harness-cli"
                | "--harness-cli-timeout-seconds"
                | "--arkforged"
                | "--arkforged-sha256"
                | "--arkforge-profile"
                | "--bundle-generation"
                | "--tool-generation"
                | "--source-job"
                | "--continuation-request-id"
                | "--remote-path"
                | "--max-characters"
                | "--contracts-directory"
                | "--fixtures-directory"
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
                        "--contracts-directory" => "contractsDirectory",
                        "--fixtures-directory" => "fixturesDirectory",
                        "--observation-generation" => "observationGeneration",
                        "--expected-generation" => "expectedGeneration",
                        "--import-request-id" => "importRequestId",
                        "--device-profile" => "deviceProfile",
                        "--page-size" => "pageSize",
                        "--root" => "rootPath",
                        "--x" => "x",
                        "--y" => "y",
                        "--destination" => "destinationPath",
                        "--preview-id" => "previewId",
                        "--preview-digest" => "previewDigest",
                        "--server-endpoint-ref" => "serverEndpointRef",
                        "--expected-server-generation" => "expectedServerGeneration",
                        "--expected-active-generation" => "expectedActiveGeneration",
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
                        "--max-characters" => "maxCharacters",
                        "--session" => "sessionId",
                        "--target" => "targetId",
                        "--time" => "timeRange",
                        "--request-file" => "requestFile",
                        "--action-file" => "actionFile",
                        "--source-sha256" => "sourceSha256",
                        "--build-sha256" => "buildSha256",
                        "--archive-sha256" => "archiveSha256",
                        "--inputs-file" => "inputsFile",
                        "--expected-binding-revision" => "expectedBindingRevision",
                        "--request-id" => "requestId",
                        "--idempotency-key" => "idempotencyKey",
                        "--execution-id" => "executionId",
                        "--resume-reference" => "resumeReference",
                        "--resume-token" => "resumeToken",
                        "--human-action" => "humanAction",
                        "--invocation" => "invocationId",
                        "--selection-file" => "selectionFile",
                        "--owner-kind" => "ownerKind",
                        "--maximum-wait" => "maximumWait",
                        "--maximum-wait-seconds" => "maximumWaitSeconds",
                        "--reviewed-plan-digest" => "reviewedPlanDigest",
                        "--registration-request-id" => "registrationRequestId",
                        "--mutation-request-id" => "mutationRequestId",
                        "--project" => "projectRef",
                        "--preset" => "presetRef",
                        "--template" => "templateRef",
                        "--toolchain" => "toolchainRef",
                        "--toolchain-generation" => "toolchainGeneration",
                        "--credential" => "credentialRef",
                        "--timeout-seconds" => "timeoutSeconds",
                        "--build-mode" => "buildMode",
                        "--relative-source-map" => "relativeSourceMap",
                        "--workspace-project" => "workspaceProject",
                        "--deveco-sdk" => "devecoSdk",
                        "--arktrace-descriptor" => "arktraceDescriptor",
                        "--arkforge-bundle" => "arkforgeBundle",
                        "--arkforge-campaign" => "arkforgeCampaign",
                        "--sensitive-evidence" => "sensitiveEvidence",
                        "--harness-model-provider" => "harnessModelProvider",
                        "--harness-model-name" => "harnessModelName",
                        "--harness-cli" => "harnessCli",
                        "--harness-cli-timeout-seconds" => "harnessCliTimeoutSeconds",
                        "--arkforged-sha256" => "arkforgedSha256",
                        "--arkforge-profile" => "arkforgeProfile",
                        "--bundle-generation" => "bundleGeneration",
                        "--tool-generation" => "toolGeneration",
                        "--source-job" => "sourceJob",
                        "--continuation-request-id" => "continuationRequestId",
                        "--remote-path" => "remotePath",
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
                            // The option's own grammar is the registry's
                            // enumeration; which of them this leaf serves is
                            // its `outputModes`, judged once the path resolves.
                            if !["human", "json", "jsonl"].contains(&value.as_str()) {
                                return Err(CliError::new(
                                    "invalidOption",
                                    "--output must be human, json or jsonl",
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
        ["workspace", "project", "update"] => "workspace.project.update",
        ["workspace", "project", "remove"] => "workspace.project.remove",
        ["workspace", "preset", "list"] => "workspace.preset.list",
        ["workspace", "preset", "show"] => "workspace.preset.show",
        ["workspace", "preset", "register"] => "workspace.preset.register",
        ["workspace", "preset", "update"] => "workspace.preset.update",
        ["workspace", "preset", "remove"] => "workspace.preset.remove",
        ["workspace", "continuation", "inspect"] => "workspace.continuation.inspect",
        ["workspace", "continuation", "submit"] => "workspace.continuation.submit",
        ["workspace", "continuation", "run"] => "workspace.continuation.run",
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
        ["trace", "export"] => "trace.export",
        ["diagnostics", "export"] => "diagnostics.export",
        ["diagnostics", "inspect"] => "diagnostics.inspect",
        ["diagnostics", "preview"] => "diagnostics.preview",
        ["recovery", "cleanup", "list"] => "recovery.cleanup.list",
        ["cleanup-debt", "list"] => "cleanup-debt.list",
        ["recovery", "cleanup", "continue"] => "recovery.cleanup.continue",
        ["cleanup-debt", "continue"] => "cleanup-debt.continue",
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
        ["operation", "validate"] => "operation.validate",
        ["operation", "example"] => "operation.example",
        ["job", "status"] => "job.status",
        ["job", "list"] => "job.list",
        ["job", "show"] => "job.show",
        ["job", "evidence"] => "job.evidence",
        ["job", "result"] => "job.result",
        ["job", "timeline"] => "job.timeline",
        ["job", "events"] => "job.events",
        ["debug", "probe"] => "debug.probe",
        ["trace", "probe"] => "trace.probe",
        ["trace", "inspect"] => "trace.inspect",
        ["ui-dump", "inspect"] => "ui-dump.inspect",
        ["ui-dump", "hit-test"] => "ui-dump.hit-test",
        ["debug", "start"] => "debug.start",
        ["debug", "evaluate"] => "debug.evaluate",
        ["debug", "status"] => "debug.status",
        ["flash", "reconcile-alias"] => "flash.reconcile-alias",
        ["flash", "bind-loader"] => "flash.bind-loader",
        ["flash", "bootloader-status"] => "flash.bootloader-status",
        ["flash", "device-access"] => "flash.device-access",
        ["flash", "prerequisites"] => "flash.prerequisites",
        ["flash", "lane-preview"] => "flash.lane-preview",
        ["recovery", "flash-invocation", "list"] => "recovery.flash-invocation.list",
        ["recovery", "flash-invocation", "start"] => "recovery.flash-invocation.start",
        ["recovery", "flash-invocation", "evaluate"] => "recovery.flash-invocation.evaluate",
        ["recovery", "flash-invocation", "status"] => "recovery.flash-invocation.status",
        ["debug", "template", "list"] => "debug.template.list",
        ["job", "watch"] => "job.watch",
        ["job", "wait"] => "job.wait",
        ["job", "plan"] => "job.plan",
        ["job", "submit"] => "job.submit",
        ["job", "run"] => "job.run",
        ["job", "cancel"] => "job.cancel",
        ["job", "reconcile"] => "job.reconcile",
        ["capability", "list"] => "capability.list",
        ["capability", "inspect"] => "capability.inspect",
        ["device", "candidates"] => "device.candidates",
        // Legacy spellings: both read the target list (Swift `runDevice`).
        ["device", "list"] => "device.list",
        ["device", "show"] => "device.show",
        // Domain leaves (CLI spec §6.2): each submits its declared Catalog
        // operation through the client-side executor (`domain_leaves`).
        ["workspace", "status"] => "workspace.status",
        ["workspace", "diff"] => "workspace.diff",
        ["workspace", "inspect"] => "workspace.inspect",
        ["workspace", "read"] => "workspace.read",
        ["analyze", "trace"] => "analyze.trace",
        ["analyze", "trace-summary"] => "analyze.trace-summary",
        ["analyze", "hilog-summary"] => "analyze.hilog-summary",
        ["analyze", "crash-signature"] => "analyze.crash-signature",
        ["target", "observe"] => "target.observe",
        ["input", "tap"] => "input.tap",
        ["input", "long-press"] => "input.long-press",
        ["input", "swipe"] => "input.swipe",
        ["port-forward", "create"] => "port-forward.create",
        ["port-forward", "remove"] => "port-forward.remove",
        ["screen", "record"] => "screen.record",
        ["diagnostics", "capture"] => "diagnostics.capture",
        ["workspace", "isolate"] => "workspace.isolate",
        ["workspace", "checkpoint"] => "workspace.checkpoint",
        ["workspace", "patch"] => "workspace.patch",
        ["workspace", "revert"] => "workspace.revert",
        ["workspace", "build"] => "workspace.build",
        ["workspace", "test"] => "workspace.test",
        ["workspace", "sign"] => "workspace.sign",
        ["workspace", "symbolize"] => "workspace.symbolize",
        ["workspace", "sweep"] => "workspace.sweep",
        ["debug", "hap"] => "debug.hap",
        ["debug", "template", "run"] => "debug.template.run",
        ["debug", "native", "deploy"] => "debug.native.deploy",
        ["screen", "capture"] => "screen.capture",
        ["ui-dump", "capture"] => "ui-dump.capture",
        ["ui-dump", "component-detail"] => "ui-dump.component-detail",
        ["debug", "logs"] => "debug.logs",
        ["trace", "capture"] => "trace.capture",
        ["device", "wait"] => "device.wait",
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
        ["runtime", "tool", "select"] => "runtime.tool.select",
        ["runtime", "bundle", "register"] => "runtime.bundle.register",
        ["runtime", "bundle", "inspect"] => "runtime.bundle.inspect",
        ["runtime", "bundle", "list"] => "runtime.bundle.list",
        ["runtime", "bundle", "remove"] => "runtime.bundle.remove",
        ["runtime", "health"] => "runtime.health",
        ["runtime", "hdc", "status"] => "runtime.hdc.status",
        ["runtime", "hdc", "impact-preview"] => "runtime.hdc.impact-preview",
        ["runtime", "hdc", "restart"] => "runtime.hdc.restart",
        ["runtime", "service", "install"] => "runtime.service.install",
        ["runtime", "service", "update"] => "runtime.service.update",
        ["runtime", "service", "restart"] => "runtime.service.restart",
        ["runtime", "service", "status"] => "runtime.service.status",
        ["runtime", "service", "verify"] => "runtime.service.verify",
        ["runtime", "service", "uninstall"] => "runtime.service.uninstall",
        ["runtime", "support-bundle", "preview"] => "runtime.support-bundle.preview",
        ["runtime", "support-bundle", "export"] => "runtime.support-bundle.export",
        // §12's superseded spelling of `runtime service`: the same handler,
        // reporting the name the caller typed (Swift `runAgentDaemon`).
        ["runtime", "signing", "status"] => "runtime.signing.status",
        ["signing", "status"] => "signing.status",
        ["agentd", "install"] => "agentd.install",
        ["agentd", "update"] => "agentd.update",
        ["agentd", "restart"] => "agentd.restart",
        ["agentd", "status"] => "agentd.status",
        ["agentd", "verify"] => "agentd.verify",
        ["agentd", "uninstall"] => "agentd.uninstall",
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
        ["commands"] => "commands",
        ["maintainer", "contracts", "export"] => "maintainer.contracts.export",
        ["maintainer", "contracts", "check"] => "maintainer.contracts.check",
        ["completion", _] => "completion",
        ["completion"] => "completion",
        ["help", ..] => "help",
        // Answered by name before any flag (`command_registry::answer_by_name`).
        ["agent", "chat"] => "agent.chat",
        ["capability", "draft"] => "capability.draft",
        ["capability", "install"] => "capability.install",
        ["capability", "revoke"] => "capability.revoke",
        ["flash", "plan"] => "flash.plan",
        ["flash", "preview"] => "flash.preview",
        ["flash", "execute"] => "flash.execute",
        ["flash", "continue"] => "flash.continue",
        ["flash", "postflight"] => "flash.postflight",
        [] if help => "help",
        // `arkdeck <node> --help` is that node's help, as Swift answers it.
        path if help && command_registry::is_node(path) => "help",
        _ => {
            return Err(CliError::new(
                "invalidCommand",
                "available commands: doctor, operation list, target adopt|list|show|availability, target display-name set|clear, device display-name set|clear, device candidates, trace cache status|purge, history filter list|save|delete, runtime storage status|policy|root, session list|show|pin|unpin, session cleanup preview|apply, session export preview|apply",
            ));
        }
    };
    // The LaunchAgent leaves connect to no caller-named Runtime and take no
    // correlation identity.
    let service = is_runtime_service(command);
    // The legacy `--json` is the leaf's where the registry declares it, as
    // Swift's registry does on nearly every leaf, and never beside `--output`.
    if legacy_json && (!command_registry::declares(command, "--json") || mode.is_some()) {
        let mut error = CliError::new(
            "invalidOption",
            "--json belongs only to the leaves that declare it and excludes --output",
        );
        error.command = Some(command);
        return Err(error);
    }
    // Neither do the signing leaves: Swift's registry declares no
    // correlation identity for them, and its refusal is the one reported.
    if signing_leaves::serves(command) && (id.is_some() || socket.is_some()) {
        let mut error = CliError::new(
            "invalidOption",
            "the signing leaves take no --control-request-id or --socket",
        );
        error.command = Some(command);
        return Err(error);
    }
    if service && (id.is_some() || socket.is_some()) {
        let mut error = CliError::new(
            "invalidOption",
            "the runtime service leaves take no --control-request-id or --socket",
        );
        error.command = Some(command);
        return Err(error);
    }
    // Swift's parser takes `--socket` on the shared registration leaf only for
    // the DevEco kind, and so does this one. This CLI sends an HDC
    // registration to the Runtime too; `ARKDECK_ENDPOINT` names another one.
    if command == "runtime.tool.register"
        && socket.is_some()
        && method_options.get("kind") != Some(&json!("deveco"))
    {
        let mut error = CliError::new("invalidOption", "HDC registration does not accept --socket");
        error.details = Map::from_iter([
            ("command".to_owned(), json!(command)),
            ("option".to_owned(), json!("--socket")),
        ]);
        error.command = Some(command);
        return Err(error);
    }
    // Neither local leaf reaches a Runtime, and `completion` writes a script
    // to stdout, so it takes no output mode at all (CLI spec §8.1).
    if command == "completion"
        && (mode.is_some()
            || id.is_some()
            || socket.is_some()
            || !(help
                || matches!(
                    positional.as_slice(),
                    ["completion", "bash" | "zsh" | "fish" | "powershell"]
                )))
    {
        return Err(CliError::new(
            "invalidOption",
            "completion takes one shell: bash, zsh, fish or powershell",
        ));
    }
    if command == "help" && (mode.is_some() || id.is_some() || socket.is_some()) {
        return Err(CliError::new(
            "invalidOption",
            "help renders human text only",
        ));
    }
    // Each leaf publishes the modes it serves, and the registry's `--output`
    // enumeration is wider than any one of them (CLI spec §8.1).
    if let Some(mode) = mode.as_deref()
        && !help
        && !command_registry::output_modes(command)
            .iter()
            .any(|published| published == mode)
    {
        let mut error = CliError::new(
            "invalidOption",
            format!(
                "`{}` --output must be one of {}",
                positional.join(" "),
                command_registry::output_modes(command).join("|")
            ),
        );
        error.command = Some(command);
        return Err(error);
    }
    // The contract bundle's leaves take their two directories and `--output`,
    // and never reach a Runtime.
    if command.starts_with("maintainer.contracts.")
        && (id.is_some()
            || socket.is_some()
            || (!help
                && !(method_options.contains_key("contractsDirectory")
                    && method_options.contains_key("fixturesDirectory"))))
    {
        return Err(CliError::new(
            "invalidOption",
            "the contract bundle's leaves take --contracts-directory, --fixtures-directory and --output",
        ));
    }
    // The support bundle is local: it reaches no Runtime, so it takes no
    // `--socket`, and its registry requires the destination and, to export,
    // the lowercase digest of an approved preview.
    if command.starts_with("runtime.support-bundle.")
        && !help
        && (socket.is_some()
            || !method_options.contains_key("destinationPath")
            || (command.ends_with(".export")
                && !method_options
                    .get("previewDigest")
                    .and_then(Value::as_str)
                    .is_some_and(|digest| {
                        digest.len() == 64
                            && digest
                                .bytes()
                                .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
                    })))
    {
        let mut error = CliError::new(
            "invalidOption",
            "runtime support-bundle takes --destination, and to export --preview-digest",
        );
        error.command = Some(command);
        return Err(error);
    }
    // Swift's `commands` leaf takes only `--output`: it never reaches a Runtime.
    if command == "commands" && (id.is_some() || socket.is_some()) {
        return Err(CliError::new(
            "invalidOption",
            "the option is not available for this command",
        ));
    }
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
        "debug.probe" | "trace.probe" => &["targetId"],
        "maintainer.contracts.export" | "maintainer.contracts.check" => {
            &["contractsDirectory", "fixturesDirectory"]
        }
        "trace.inspect" => &["jobId", "artifactId", "allowSensitive", "timeout"],
        "diagnostics.inspect" => &["jobId", "timeout"],
        "diagnostics.preview" => &[
            "jobId",
            "artifactId",
            "maxCharacters",
            "allowSensitive",
            "timeout",
        ],
        "ui-dump.inspect" => &["jobId"],
        "ui-dump.hit-test" => &["jobId", "x", "y", "rootPath"],
        "flash.reconcile-alias" | "flash.bind-loader" => &["targetId", "expectedBindingRevision"],
        "flash.prerequisites" => &["targetId", "deviceProfile"],
        "flash.lane-preview" => &["targetId", "deviceProfile", "archiveSha256"],
        "recovery.flash-invocation.list" => &["pageSize", "cursor"],
        "recovery.flash-invocation.status" | "debug.status" => &["invocationId"],
        "recovery.flash-invocation.start" | "debug.start" => &["requestFile"],
        "recovery.flash-invocation.evaluate" | "debug.evaluate" => {
            &["invocationId", "actionFile", "sourceSha256", "buildSha256"]
        }
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
        "runtime.tool.select" => &[
            "tool",
            "expectedActiveGeneration",
            "actionRequestId",
            "timeout",
        ],
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
        // Swift's registry gives the trace and diagnostics leaves a Job owner
        // only.
        "trace.export" | "diagnostics.export" => &[
            "jobId",
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
        "workspace.project.update" => &[
            "projectRef",
            "expectedGeneration",
            "kind",
            "rootPath",
            "timeout",
        ],
        "workspace.project.remove" => &["projectRef", "expectedGeneration", "timeout"],
        "workspace.preset.list" => &["projectRef", "kind", "timeout"],
        "workspace.preset.show" => &["projectRef", "presetRef", "timeout"],
        "workspace.preset.register" => &[
            "registrationRequestId",
            "projectRef",
            "kind",
            "templateRef",
            "toolchainRef",
            "toolchainGeneration",
            "credentialRef",
            "timeoutSeconds",
            "module",
            "product",
            "buildMode",
            "relativeSourceMap",
            "timeout",
        ],
        "workspace.preset.update" => &[
            "mutationRequestId",
            "projectRef",
            "presetRef",
            "expectedGeneration",
            "kind",
            "templateRef",
            "toolchainRef",
            "toolchainGeneration",
            "credentialRef",
            "timeoutSeconds",
            "module",
            "product",
            "buildMode",
            "relativeSourceMap",
            "timeout",
        ],
        "workspace.preset.remove" => &[
            "mutationRequestId",
            "projectRef",
            "presetRef",
            "expectedGeneration",
            "timeout",
        ],
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
        "operation.validate" => &["operation", "inputsFile"],
        "device.wait" => &[
            "candidate",
            "observationId",
            "observationGeneration",
            "state",
            "timeout",
        ],
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
        "job.cancel" | "job.reconcile" => &["jobId"],
        "capability.inspect" => &["capabilityId"],
        "job.timeline" => &["jobId", "pageSize", "cursor", "timeout"],
        "job.events" => &["jobId", "pageSize", "afterCursor", "timeout"],
        "job.watch" => &["jobId", "pageSize", "afterCursor", "timeout"],
        "job.wait" => &["jobId", "timeout", "afterCursor", "pageSize"],
        "workspace.continuation.inspect" => &["sourceJob", "timeout"],
        "workspace.continuation.submit" | "workspace.continuation.run" => {
            &["sourceJob", "continuationRequestId", "timeout"]
        }
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
        "runtime.support-bundle.preview" => &["destinationPath"],
        "runtime.support-bundle.export" => &["destinationPath", "previewDigest"],
        "session.pin" | "session.unpin" => &["sessionId", "expectedGeneration"],
        "runtime.service.verify" | "agentd.verify" => {
            &["targetId", "maximumWaitSeconds", "executionId", "jobId"]
        }
        "runtime.service.restart" | "agentd.restart" => &["maximumWaitSeconds"],
        command if domain_leaves::serves(command) => {
            &["targetId", "inputsFile", "capabilityId", "executionId"]
        }
        "recovery.cleanup.continue" | "cleanup-debt.continue" => &["jobId", "remotePath", "bundle"],
        "runtime.service.install" => &["bundle", "bundleGeneration", "tool", "toolGeneration"],
        // `agentd install` is Swift's compatibility install from path inputs:
        // `update`'s options, never the typed bootstrap's.
        "runtime.service.update" | "agentd.install" | "agentd.update" => &[
            "daemon",
            "hdc",
            "workspaceProject",
            "devecoSdk",
            "arktraceDescriptor",
            "arkforgeBundle",
            "arkforgeCampaign",
            // Refused by name when the command runs, as Swift reads them.
            "sensitiveEvidence",
            "harnessModelProvider",
            "harnessModelName",
            "harnessCli",
            "harnessCliTimeoutSeconds",
            "arkforged",
            "arkforgedSha256",
            "arkforgeProfile",
        ],
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
    // The registry's grammar of the LaunchAgent leaves: `--maximum-wait-seconds`
    // is a plain positive integer within 1…300, and `verify --job` excludes the
    // three options of a fresh run.
    if !help && service {
        let refuse = |message: &str| {
            let mut error = CliError::new("invalidOption", message);
            error.command = Some(command);
            error
        };
        if let Some(seconds) = method_options.get("maximumWaitSeconds") {
            let text = seconds.as_str().expect("option text");
            if text.starts_with('0')
                || !text.bytes().all(|byte| byte.is_ascii_digit())
                || !text
                    .parse::<u64>()
                    .is_ok_and(|seconds| (1..=300).contains(&seconds))
            {
                return Err(refuse("--maximum-wait-seconds must be between 1 and 300"));
            }
        }
        if method_options.contains_key("jobId")
            && ["targetId", "maximumWaitSeconds", "executionId"]
                .iter()
                .any(|key| method_options.contains_key(*key))
        {
            return Err(refuse(
                "--job excludes --target, --maximum-wait-seconds and --execution-id",
            ));
        }
        // The typed install names four exact registry values, its two
        // generations canonical positive integers.
        if command == "runtime.service.install" {
            if ["bundle", "bundleGeneration", "tool", "toolGeneration"]
                .iter()
                .any(|key| !method_options.contains_key(*key))
            {
                return Err(refuse(
                    "runtime service install requires --bundle, --bundle-generation, --tool \
                     and --tool-generation",
                ));
            }
            for key in ["bundleGeneration", "toolGeneration"] {
                let text = method_options[key].as_str().expect("option text");
                if !text
                    .parse::<u64>()
                    .is_ok_and(|n| n > 0 && n <= i64::MAX as u64 && n.to_string() == text)
                {
                    return Err(refuse(
                        "--bundle-generation and --tool-generation must be canonical positive \
                         integers",
                    ));
                }
            }
        }
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
        && matches!(
            command,
            "recovery.cleanup.continue" | "cleanup-debt.continue"
        )
        && (!method_options.contains_key("jobId")
            || method_options.contains_key("remotePath") == method_options.contains_key("bundle"))
    {
        return Err(CliError::new(
            "invalidOption",
            "cleanup continue requires --job <id> and one of --remote-path <recorded path> / \
             --bundle <recorded bundle>",
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
    // The registry's grammar: both options required, the digest lowercase
    // hex; the preview identity is judged before any request.
    if !help
        && matches!(command, "session.export.apply" | "session.cleanup.apply")
        && (!method_options.contains_key("previewId")
            || !method_options
                .get("previewDigest")
                .is_some_and(session_resources::digest))
    {
        return Err(CliError::new(
            "invalidOption",
            "Session apply requires --preview-id and a lowercase SHA-256 --preview-digest",
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
    let device_wait_timeout = if command == "device.wait" && !help {
        device_wait::configure(&mut method_options)?
    } else {
        None
    };
    let watch_timeout = if command == "job.watch" && !help {
        job_events::configure_watch(&mut method_options)?
    } else {
        None
    };
    let continuation_timeout =
        workspace_continuation::configure(command, &mut method_options, help)?;
    let wait_timeout = if command == "job.wait" && !help {
        job_wait::configure(&mut method_options, mode.as_deref() == Some("jsonl"))?
    } else {
        None
    };
    debug_probe::configure(command, &method_options, help)?;
    trace_inspect::configure(command, &method_options, help)?;
    let diagnostics_timeout = diagnostics_resources::configure(command, &mut method_options, help)?;
    ui_dump::configure(command, &method_options, help)?;
    // Swift's parser names the leaf a refused option belongs to.
    flash_leaves::configure(command, &mut method_options, help).map_err(|mut error| {
        error.command = Some(command);
        error
    })?;
    let timeout_ms = read_only_resources::configure(command, &mut method_options, help)?
        .or(device_wait_timeout)
        .or(watch_timeout)
        .or(wait_timeout)
        .or(import_timeout)
        .or(artifact_timeout)
        .or(diagnostics_timeout)
        .or(target_timeout)
        .or(workspace_timeout)
        .or(plan_timeout)
        .or(agent_timeout)
        .or(human_action_timeout)
        .or(hdc_timeout)
        .or(continuation_timeout);
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
        } else if matches!(command, "operation.example" | "operation.validate") {
            // `operation validate` reads the descriptor first and judges the
            // inputs against it here; `health` follows on the same connection.
            "operation.describe"
        } else if command == "runtime.health" {
            "health"
        } else if command == "device.wait" {
            "device.observations"
        } else if command == "job.watch" {
            "job.events"
        } else if command == "job.wait" {
            // Its polling path reads the status; its event path the stream,
            // then the status (`main.rs` `wait_for_job`).
            "job.status"
        } else if command == "recovery.flash-invocation.status" {
            // Swift's handler reads the invocation through `debug.status`, the
            // wire method `debug status` also sends.
            "debug.status"
        } else if command == "recovery.flash-invocation.start" {
            "debug.start"
        } else if command == "recovery.flash-invocation.evaluate" {
            "debug.evaluate"
        } else if command == "flash.bind-loader" {
            "flash.bind-current-loader"
        } else if matches!(command, "device.list" | "device.show") {
            // Swift's `runDevice` answers both legacy leaves with the target
            // list, without parameters.
            "target.list"
        } else if domain_leaves::serves(command) {
            // `runDomainOperation` maps every client error the executor throws
            // under this one method.
            "job.submit"
        } else if matches!(command, "recovery.cleanup.list" | "cleanup-debt.list") {
            // Both spellings share Swift's one handler and its one method.
            "cleanupDebt.list"
        } else if matches!(
            command,
            "recovery.cleanup.continue" | "cleanup-debt.continue"
        ) {
            "cleanupDebt.continue"
        } else if matches!(command, "trace.export" | "diagnostics.export") {
            // `artifact export` of what a diagnostics capture published: the
            // one Trace, or any of its Artifacts, after its `artifact.inspect`
            // (`main.rs`).
            "artifact.export"
        } else if command == "flash.lane-preview" {
            // Swift's handler keeps the 1.x wire spelling: CLI spec §12
            // freezes the method tokens, so the command name is a mapping.
            "flash.lanePlanPreview"
        } else {
            command
        },
        params: if matches!(command, "help" | "completion") {
            // The path this help renders, or the shell this script is for;
            // neither leaf sends a request. `arkdeck help <path>` and
            // `arkdeck completion <shell>` drop the leaf's own token, while
            // `arkdeck <node> --help` is already the path.
            let tokens: &[&str] = match positional.first() {
                Some(&"help" | &"completion") => &positional[1..],
                Some(_) => &positional[..],
                None => &[],
            };
            Some(Map::from_iter([(
                "path".to_owned(),
                json!(tokens.iter().map(|token| json!(token)).collect::<Vec<_>>()),
            )]))
        } else if command == "doctor" {
            Some(serde_json::from_value(json!({"deep":deep})).unwrap())
        } else if matches!(
            command,
            "recovery.cleanup.continue" | "cleanup-debt.continue"
        ) {
            // Swift's `emitCleanupDebt`: the Job and the one recorded residue
            // it names, a remote path or an installed bundle.
            Some(
                method_options
                    .into_iter()
                    .map(|(key, value)| match key.as_str() {
                        "bundle" => ("bundleName".to_owned(), value),
                        _ => (key, value),
                    })
                    .collect(),
            )
        } else if command.starts_with("workspace.project.")
            || command.starts_with("workspace.preset.")
            || command.starts_with("workspace.continuation.")
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
            || command == "trace.export"
            || command.starts_with("diagnostics.")
            || command.starts_with("target.")
            || matches!(command, "ui-dump.inspect" | "ui-dump.hit-test")
            || command.starts_with("device.display-name.")
            || command.starts_with("session.")
            || command.starts_with("human-action.")
            || is_runtime_service(command)
            || domain_leaves::serves(command)
            || command.starts_with("maintainer.contracts.")
            || command.starts_with("runtime.support-bundle.")
            || matches!(
                command,
                "operation.describe"
                    | "operation.example"
                    | "operation.validate"
                    | "device.wait"
                    | "debug.probe"
                    | "trace.probe"
                    | "trace.inspect"
                    | "job.status"
                    | "job.list"
                    | "job.show"
                    | "job.evidence"
                    | "job.timeline"
                    | "job.events"
                    | "job.watch"
                    | "job.wait"
                    | "job.plan"
                    | "job.submit"
                    | "job.run"
                    | "job.cancel"
                    | "job.reconcile"
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
                    | "runtime.tool.select"
                    | "control-action.list"
                    | "control-action.show"
                    | "control-action.reconcile"
                    | "flash.reconcile-alias"
                    | "flash.bind-loader"
                    | "flash.prerequisites"
                    | "flash.lane-preview"
                    | "recovery.flash-invocation.list"
                    | "recovery.flash-invocation.start"
                    | "recovery.flash-invocation.evaluate"
                    | "recovery.flash-invocation.status"
                    | "debug.start"
                    | "debug.evaluate"
                    | "debug.status"
            )
        {
            Some(method_options)
        } else {
            None
        },
        json: mode.as_deref() == Some("json"),
        jsonl: mode.as_deref() == Some("jsonl"),
        raw,
        legacy_json,
        help,
        require_healthy,
        control_request_id: id,
        socket,
        timeout_ms,
    })
}

/// Whether `command` is a LaunchAgent leaf: `runtime service …`, or its
/// superseded `agentd …` spelling.
pub fn is_runtime_service(command: &str) -> bool {
    command.starts_with("runtime.service.") || command.starts_with("agentd.")
}

/// Swift `CLIResultEnvelope.withLifecycle`: a leaf the registry does not
/// publish as current says so in `meta.lifecycle` of every machine answer, so
/// a caller can tell it is driving a compatibility surface.
pub fn with_lifecycle(mut envelope: Value, command: &str) -> Value {
    if let Some((status, replacement)) = command_registry::lifecycle(command) {
        envelope["meta"]["lifecycle"] = json!({
            "status": status,
            "replacementArgvPattern": replacement,
            "removalVersion": null,
        });
    }
    envelope
}

/// Swift `CLIRuntimeSession.warnIfLegacy`: the human rendering's warning for
/// a leaf the registry does not publish as current, on stderr.
pub fn legacy_warning(command: &str) -> Option<String> {
    let (status, replacement) = command_registry::lifecycle(command)?;
    let mut text = format!("warning: `{}` is {status}", command.replace('.', " "));
    if let Some(replacement) = replacement {
        text.push_str(&format!("; use `{replacement}`"));
    }
    Some(text)
}

/// A result no Runtime answered (Swift `CLIResultEnvelope.success`): its
/// meta names no control protocol.
pub fn local_success_envelope(command: &str, result: Value, id: &str) -> Value {
    json!({"schemaVersion":"arkdeck.cli.result/1","command":command,"ok":true,"result":result,
        "meta":{"controlRequestId":id,"cliVersion":"0.1.0"}})
}

pub fn success_envelope(command: &str, result: Value, id: &str) -> Value {
    json!({"schemaVersion":"arkdeck.cli.result/1","command":command,"ok":true,"result":result,
        "meta":{"controlRequestId":id,"cliVersion":"0.1.0","controlProtocolVersion":PROTOCOL_VERSION}})
}

pub fn failure_envelope(command: &str, error: &CliError, id: &str, protocol: bool) -> Value {
    let mut details = json!({"code":error.code,"message":error.message,
        "controlRequestRetryable":error_registry::control_request_retryable(error.code),
        "attentionRequired":error_registry::requires_attention(error.code)});
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

/// Swift `CLIRuntimeSession.legacyDocument`: the legacy `--json` rendering of
/// a result, or of a failure (`legacy_failure`), as
/// `CanonicalJSONEncoders.canonicalPretty()` writes it, then one LF. Not the
/// versioned envelope, and never carrying `meta`.
pub fn legacy_document(value: &Value) -> Vec<u8> {
    match arkdeck_contract::foundation_json::pretty(value, false) {
        Ok(mut bytes) => {
            bytes.push(b'\n');
            bytes
        }
        Err(_) => b"{\"error\":{\"code\":\"internalError\",\"message\":\"the daemon reply could not be encoded as JSON\"}}\n".to_vec(),
    }
}

/// Swift `CLIResultEnvelope.legacyFailure`: a failure in the legacy `--json`
/// rendering carries only its code and words.
/// Swift `RuntimeCLI.humanRendering(of:)`: a document as `key: value` lines
/// in key order, an array as `- item` lines or `(none)`, null as `-`, each
/// nested rendering indented two spaces a level and trimmed of spaces at its
/// ends (Swift's `.whitespaces`, which spares line breaks).
pub fn human_rendering(value: &Value) -> String {
    fn trimmed(text: &str) -> &str {
        text.trim_matches(|c: char| {
            matches!(
                c,
                '\t' | ' ' | '\u{a0}' | '\u{1680}' | '\u{2000}'
                    ..='\u{200a}' | '\u{202f}' | '\u{205f}' | '\u{3000}'
            )
        })
    }
    fn render(value: &Value, indent: usize) -> String {
        let pad = "  ".repeat(indent);
        match value {
            Value::Object(fields) => {
                let mut keys: Vec<&String> = fields.keys().collect();
                keys.sort();
                keys.into_iter()
                    .map(|key| {
                        format!("{pad}{key}: {}", trimmed(&render(&fields[key], indent + 1)))
                    })
                    .collect::<Vec<_>>()
                    .join("\n")
            }
            Value::Array(items) if items.is_empty() => format!("{pad}(none)"),
            Value::Array(items) => items
                .iter()
                .map(|item| format!("{pad}- {}", trimmed(&render(item, indent + 1))))
                .collect::<Vec<_>>()
                .join("\n"),
            Value::String(text) => format!("{pad}{text}"),
            Value::Number(number) => format!("{pad}{number}"),
            Value::Bool(flag) => format!("{pad}{flag}"),
            Value::Null => format!("{pad}-"),
        }
    }
    render(value, 0)
}

pub fn legacy_failure(error: &CliError) -> Value {
    json!({"error": {"code": error.code, "message": error.message}})
}

/// Whether a refusal of `argv` is answered in the legacy `--json` rendering:
/// Swift's registry accepts the argv, so its handler, not its parser, would
/// refuse it, and the handler's session renders what `--json` asks for.
/// Swift's parser refuses in prose on stderr, as this CLI does then.
pub fn legacy_refusal(argv: &[String]) -> bool {
    argv.iter().any(|argument| argument == "--json") && registry_parse::check(argv).is_ok()
}

pub fn render(value: &Value) -> Result<Vec<u8>, ContractError> {
    let mut bytes = canonical_json(value)?;
    bytes.push(b'\n');
    Ok(bytes)
}

#[cfg(test)]
mod tests {
    use super::{CliError, human_rendering, reported};
    use serde_json::json;

    /// Swift `RuntimeCLI.humanRendering(of:)`, whose nested renderings keep
    /// their inner indentation: only the spaces at their two ends are trimmed.
    #[test]
    fn the_human_rendering_is_swifts_generic_one() {
        let document = json!({
            "name": "  padded  ",
            "count": 3,
            "flag": false,
            "none": null,
            "empty": [],
            "list": ["a", {"k": "v", "j": 1}],
            "nested": {"b": [], "a": {"deep": true}},
        });
        assert_eq!(
            human_rendering(&document),
            "count: 3\nempty: (none)\nflag: false\nlist: - a\n  - j: 1\n    k: v\nname: padded\nnested: a: deep: true\n  b: (none)\nnone: -"
        );
        assert_eq!(human_rendering(&json!("text")), "text");
        assert_eq!(human_rendering(&json!([])), "(none)");
    }

    /// Off macOS this parser refuses `--socket` as the platform's
    /// (`unsupportedOnPlatform`), and that stands where Swift's registry pass
    /// refuses the same argv, as it does an HDC registration's `--socket`.
    #[test]
    fn a_platform_refusal_stands_where_swift_refuses_too() {
        let argv = [
            "runtime", "tool", "register", "--kind", "hdc", "--socket", "/tmp/s",
        ]
        .map(String::from);
        let error = reported(
            &argv,
            CliError::new(
                "unsupportedOnPlatform",
                "--socket is only available on macOS",
            ),
        );
        assert_eq!(
            (error.code, error.command),
            ("unsupportedOnPlatform", Some("runtime.tool.register"))
        );
        // Any other refusal of that argv is reported in Swift's words.
        let error = reported(&argv, CliError::new("invalidOption", "refused"));
        assert_eq!(error.message, "HDC registration does not accept --socket");
    }
}
