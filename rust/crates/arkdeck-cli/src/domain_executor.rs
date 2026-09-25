//! Swift `AgentRuntimeExecutor.run`: the client-side runner behind the domain
//! leaves (`RuntimeCLI.runDomainOperation`). It composes typed Runtime
//! requests, one connection each, and runs nothing on a device itself:
//! - the catalog digest (`health`) and the operation's scope
//!   (`operation.describe`);
//! - the target: the host scope of a host-only operation, or a device target
//!   listed, observed or adopted;
//! - `job.submit`, `job.run`, `job.evidence`, and every page of
//!   `artifact.list`.
//!
//! A person's action is a persisted pause, never a host command. The
//! decisions, requests and words follow the oracle
//! `CLIDomainExecutorOracleContractTests` records
//! (`rust/tests/fixtures/domain-executor`).
use crate::CliError;
use arkdeck_client::{Client, ClientError};
use arkdeck_contract::{ContractError, WireError};
use serde_json::{Map, Value, json};
use std::io::{Read, Write};
use std::path::PathBuf;
use std::time::{Duration, Instant};

const EXECUTOR_ID: &str = "arkdeck-device-runtime-agent";
const TERMINAL_STATES: [&str; 5] = [
    "succeeded",
    "recovered",
    "failed",
    "cancelled",
    "waitingForRecovery",
];
/// Swift `hostOnlyArtifactConsumers`: the host-only operations whose
/// imported Artifact lease keeps the lease's target as their scope.
const HOST_ONLY_ARTIFACT_CONSUMERS: [(&str, &str); 2] = [
    (
        "workspace.sign-openharmony-hap@1",
        "unsignedHapArtifactLease",
    ),
    ("workspace.apply-patch@1", "patchArtifactRef"),
];

/// Swift `RuntimeAgentExecutionRequest`.
#[derive(Clone, Debug, PartialEq)]
pub struct ExecutionRequest {
    pub operation_id: String,
    pub operation_version: Option<i64>,
    pub inputs: Map<String, Value>,
    pub capability: Option<String>,
    pub target: Option<String>,
    /// At least 1; Swift's default is 900.
    pub maximum_wait_seconds: u64,
    pub execution_id: String,
}

impl ExecutionRequest {
    fn reference(&self) -> String {
        match self.operation_version {
            Some(version) => format!("{}@{version}", self.operation_id),
            None => self.operation_id.clone(),
        }
    }

    /// Its Swift `Codable` form, as a pending record keeps it.
    pub fn encoded(&self) -> Value {
        let mut fields = Map::new();
        fields.insert("operationID".into(), json!(self.operation_id));
        if let Some(version) = self.operation_version {
            fields.insert("operationVersion".into(), json!(version));
        }
        fields.insert("inputs".into(), Value::Object(self.inputs.clone()));
        if let Some(capability) = &self.capability {
            fields.insert("capabilityReference".into(), json!(capability));
        }
        if let Some(target) = &self.target {
            fields.insert("targetID".into(), json!(target));
        }
        fields.insert(
            "maximumWaitSeconds".into(),
            json!(self.maximum_wait_seconds.max(1)),
        );
        fields.insert("executionID".into(), json!(self.execution_id));
        Value::Object(fields)
    }
}

/// Swift `AgentClientError`: how one request ended, by what it proves.
#[derive(Clone, Debug, PartialEq)]
pub enum ClientFailure {
    /// The connection never opened, so nothing was sent.
    ConnectFailed(String),
    /// The peer closed, or the frame broke its bound, before a response.
    Transport(String),
    MalformedResponse(String),
    DeadlineExceeded,
    DaemonError {
        code: String,
        message: String,
    },
    StructuredDaemonError {
        code: String,
        message: String,
        details: Map<String, Value>,
    },
}

impl ClientFailure {
    /// A connection that could not be opened.
    pub fn connect(error: ClientError) -> Self {
        match error {
            ClientError::Transport(error) => Self::ConnectFailed(match error.raw_os_error() {
                Some(number) => format!("connect failed: errno {number}"),
                None => error.to_string(),
            }),
            other => Self::ConnectFailed(other.to_string()),
        }
    }

    /// A request that ended in `error` after its connection opened.
    fn request(error: ClientError) -> Self {
        match error {
            ClientError::Transport(error) => match error.kind() {
                std::io::ErrorKind::UnexpectedEof => {
                    Self::Transport("connection closed before response".into())
                }
                std::io::ErrorKind::TimedOut | std::io::ErrorKind::WouldBlock => {
                    Self::DeadlineExceeded
                }
                std::io::ErrorKind::InvalidData => Self::Transport("oversized response".into()),
                _ => Self::Transport(error.to_string()),
            },
            ClientError::Contract(error) => Self::MalformedResponse(contract_failure(&error)),
            ClientError::Remote(WireError {
                code,
                message,
                details: Some(details),
            }) => Self::StructuredDaemonError {
                code,
                message,
                details,
            },
            ClientError::Remote(WireError { code, message, .. }) => {
                Self::DaemonError { code, message }
            }
            ClientError::ConnectionUnusable => {
                Self::Transport("the connection is unusable; no request was replayed".into())
            }
        }
    }

    /// Swift's refusal when the connected Runtime could not prove the current
    /// contract on the connection's own `health` exchange.
    fn unproven_contract() -> Self {
        Self::StructuredDaemonError {
            code: "unsupportedProtocolVersion".into(),
            message: "the connected Runtime could not prove the current contract; no business request was sent"
                .into(),
            details: Map::from_iter([
                ("phase".into(), json!("preAdmission")),
                ("newDispatchCount".into(), json!(0)),
            ]),
        }
    }

    /// Swift's `String(describing:)` of the case. Swift prints a `details`
    /// dictionary in hash order; this prints it with its keys sorted.
    pub fn description(&self) -> String {
        match self {
            Self::ConnectFailed(message) => format!("connectFailed({})", quoted(message)),
            Self::Transport(message) => format!("transport({})", quoted(message)),
            Self::MalformedResponse(message) => format!("malformedResponse({})", quoted(message)),
            Self::DeadlineExceeded => "deadlineExceeded".into(),
            Self::DaemonError { code, message } => format!(
                "daemonError(code: {}, message: {})",
                quoted(code),
                quoted(message)
            ),
            Self::StructuredDaemonError {
                code,
                message,
                details,
            } => format!(
                "structuredDaemonError(code: {}, message: {}, details: [{}])",
                quoted(code),
                quoted(message),
                details
                    .iter()
                    .map(|(key, value)| format!("{}: {value}", quoted(key)))
                    .collect::<Vec<_>>()
                    .join(", ")
            ),
        }
    }

    /// What the CLI names it: Swift `CLIRuntimeSession.mapped` of the error as
    /// `job.submit`'s, since `runDomainOperation` maps every client error the
    /// executor throws under that one method.
    pub fn cli_error(&self) -> CliError {
        let method = "job.submit";
        let transport = |code: &'static str, message: &str| {
            let mut error = CliError::new(code, message);
            error.details.insert("method".into(), json!(method));
            error
        };
        match self {
            // Nothing was sent, so nothing was accepted.
            Self::ConnectFailed(message) => transport("runtimeUnavailable", message),
            Self::DeadlineExceeded => transport("outcomeUnknown", crate::CLIENT_DEADLINE),
            Self::Transport(message) => CliError::from_client(
                ClientError::Transport(std::io::Error::other(message.clone())),
                method,
            ),
            Self::MalformedResponse(_) => {
                CliError::from_client(ClientError::Contract(ContractError::Malformed), method)
            }
            Self::DaemonError { code, message } => CliError::from_client(
                ClientError::Remote(WireError {
                    code: code.clone(),
                    message: message.clone(),
                    details: None,
                }),
                method,
            ),
            Self::StructuredDaemonError {
                code,
                message,
                details,
            } => CliError::from_client(
                ClientError::Remote(WireError {
                    code: code.clone(),
                    message: message.clone(),
                    details: Some(details.clone()),
                }),
                method,
            ),
        }
    }
}

/// Swift's name for a contract failure of a frame.
fn contract_failure(error: &ContractError) -> String {
    match error {
        ContractError::UnsupportedVersion => "unsupportedVersion".into(),
        ContractError::ContractMismatch => "contractMismatch".into(),
        ContractError::Malformed => "malformed".into(),
        other => format!("{other:?}"),
    }
}

/// A Swift string literal, as `String(describing:)` prints a `String`
/// associated value.
fn quoted(text: &str) -> String {
    let mut output = String::from("\"");
    for character in text.chars() {
        match character {
            '"' => output.push_str("\\\""),
            '\\' => output.push_str("\\\\"),
            '\n' => output.push_str("\\n"),
            '\r' => output.push_str("\\r"),
            '\t' => output.push_str("\\t"),
            '\0' => output.push_str("\\0"),
            character if character.is_control() => {
                output.push_str(&format!("\\u{{{:x}}}", character as u32))
            }
            character => output.push(character),
        }
    }
    output.push('"');
    output
}

/// Swift `RuntimeAgentExecutorError`.
#[derive(Clone, Debug, PartialEq)]
pub enum ExecutorFailure {
    DaemonUnavailable(String),
    MalformedResponse(String),
    Persistence(String),
    Timeout(String),
}

impl ExecutorFailure {
    /// Swift's `String(describing:)` of the case.
    pub fn description(&self) -> String {
        match self {
            Self::DaemonUnavailable(message) => format!("daemonUnavailable({})", quoted(message)),
            Self::MalformedResponse(message) => format!("malformedResponse({})", quoted(message)),
            Self::Persistence(message) => format!("persistence({})", quoted(message)),
            Self::Timeout(message) => format!("timeout({})", quoted(message)),
        }
    }
}

/// What a run throws, as Swift's executor throws it.
#[derive(Debug)]
pub enum ExecutorError {
    Executor(ExecutorFailure),
    /// A client error rethrown from the scope, the adoption, the submission,
    /// or an Artifact page.
    Client(ClientFailure),
    /// An Artifact page off its contract (Swift
    /// `AgentExecutionControlFailure`).
    Control(CliError),
}

impl ExecutorError {
    /// Swift's `String(describing:)` of the error, where a run embeds it in a
    /// reason or a blocker.
    pub fn description(&self) -> String {
        match self {
            Self::Executor(failure) => failure.description(),
            Self::Client(failure) => failure.description(),
            Self::Control(error) => format!(
                "AgentExecutionControlFailure(code: {}, message: {}, details: [:])",
                quoted(error.code),
                quoted(&error.message)
            ),
        }
    }
}

impl From<ExecutorFailure> for ExecutorError {
    fn from(failure: ExecutorFailure) -> Self {
        Self::Executor(failure)
    }
}

impl From<ClientFailure> for ExecutorError {
    fn from(failure: ClientFailure) -> Self {
        Self::Client(failure)
    }
}

/// How a run ended, with Swift's receipt (`RuntimeAgentExecutionReceipt`) and,
/// for a pause, its action (`RuntimeHumanActionReceipt`), both as Swift
/// encodes them.
#[derive(Clone, Debug, PartialEq)]
pub enum Outcome {
    Completed(Value),
    Paused { action: Value, receipt: Value },
    Failed { reason: String, receipt: Value },
}

/// The Runtime the executor connects to, once per request.
pub trait Runtime {
    type Stream: Read + Write;
    /// One new connection, within `remaining`.
    fn connect(&mut self, remaining: Duration) -> Result<Client<Self::Stream>, ClientFailure>;
}

/// Swift `ExecutionDeadline`: the run's budget in whole seconds.
struct Deadline {
    started: Instant,
    budget: Duration,
}

impl Deadline {
    fn new(seconds: u64) -> Self {
        Self {
            started: Instant::now(),
            budget: Duration::from_secs(seconds),
        }
    }

    fn remaining_seconds(&self) -> Result<u64, ExecutorFailure> {
        let elapsed = self.started.elapsed();
        if elapsed >= self.budget {
            return Err(ExecutorFailure::Timeout(
                "execution deadline exhausted".into(),
            ));
        }
        let remaining = self.budget - elapsed;
        Ok(remaining.as_secs() + u64::from(remaining.subsec_nanos() > 0))
    }
}

struct Target {
    id: String,
    binding_revision: Option<i64>,
}

struct Candidate {
    key: String,
    state: String,
    observation: String,
    generation: String,
    target: Option<Target>,
}

enum Scope {
    Host(String),
    Device,
}

/// Where a pause resumes: Swift `ResumeMode`.
#[derive(Clone, Copy)]
enum ResumeMode {
    RetryAdoption,
    AdoptedTarget,
    BootstrapCandidate,
    ReconnectTarget,
}

impl ResumeMode {
    fn name(self) -> &'static str {
        match self {
            Self::RetryAdoption => "retryAdoption",
            Self::AdoptedTarget => "adoptedTarget",
            Self::BootstrapCandidate => "bootstrapCandidate",
            Self::ReconnectTarget => "reconnectTarget",
        }
    }
}

/// Swift `AgentRuntimeExecutor`.
pub struct Executor<R: Runtime, C: FnMut() -> String> {
    runtime: R,
    clock: C,
    state_directory: PathBuf,
}

/// The run so far, as each receipt and pause records it.
struct Run<'a> {
    request: &'a ExecutionRequest,
    digest: String,
    started: String,
    actions: Vec<Value>,
}

impl<R: Runtime, C: FnMut() -> String> Executor<R, C> {
    /// `state_directory` holds the pending records of paused runs.
    pub fn new(runtime: R, clock: C, state_directory: PathBuf) -> Self {
        Self {
            runtime,
            clock,
            state_directory,
        }
    }

    /// Swift `run(_:)`.
    pub fn run(&mut self, request: &ExecutionRequest) -> Result<Outcome, ExecutorError> {
        if !safe_identifier(&request.execution_id) {
            return Err(
                ExecutorFailure::Persistence("execution identifier is unsafe".into()).into(),
            );
        }
        let started = (self.clock)();
        let deadline = Deadline::new(request.maximum_wait_seconds.max(1));
        let digest = self.health_digest(&deadline)?;
        let run = Run {
            request,
            digest,
            started,
            actions: Vec::new(),
        };
        self.continue_run(run, &deadline)
    }

    fn health_digest(&mut self, deadline: &Deadline) -> Result<String, ExecutorError> {
        let health = self
            .call("health", None, deadline)
            .map_err(|error| ExecutorFailure::DaemonUnavailable(error.description()))?;
        match health["catalogDigest"].as_str() {
            Some(digest) if !digest.is_empty() => Ok(digest.to_owned()),
            _ => {
                Err(ExecutorFailure::MalformedResponse("health lacks catalog digest".into()).into())
            }
        }
    }

    fn continue_run(&mut self, run: Run, deadline: &Deadline) -> Result<Outcome, ExecutorError> {
        let request = run.request;
        let reference = request.reference();
        let scope = self.operation_scope(&reference, deadline)?;
        let target = match scope {
            Scope::Host(provider) => {
                let declared = request.inputs.get("projectRef").and_then(Value::as_str);
                let keeps_artifact_scope =
                    HOST_ONLY_ARTIFACT_CONSUMERS
                        .iter()
                        .any(|(operation, input)| {
                            *operation == reference && request.inputs.contains_key(*input)
                        });
                if let (Some(requested), Some(project)) = (&request.target, declared)
                    && requested != project
                    && !keeps_artifact_scope
                {
                    let receipt = self.receipt(&run, None, None, "rejected", None, Vec::new());
                    return Ok(Outcome::Failed {
                        reason: format!(
                            "{reference} host scope {requested} does not match projectRef {project}"
                        ),
                        receipt,
                    });
                }
                let host = request
                    .target
                    .clone()
                    .or(declared.map(str::to_owned))
                    .unwrap_or_else(|| format!("{provider}-host"));
                if !safe_identifier(&host) {
                    let receipt = self.receipt(&run, None, None, "rejected", None, Vec::new());
                    return Ok(Outcome::Failed {
                        reason: format!("{reference} resolved an unsafe host scope"),
                        receipt,
                    });
                }
                Target {
                    id: host,
                    binding_revision: None,
                }
            }
            Scope::Device => match &request.target {
                Some(explicit) => {
                    let listed = self.list_targets(deadline)?;
                    if !listed.iter().any(|target| &target.id == explicit) {
                        return self.pause(
                            run,
                            "physicalReconnect",
                            "Reconnect the selected target before resuming this execution.",
                            ResumeMode::ReconnectTarget,
                            None,
                        );
                    }
                    let mut matching: Vec<Candidate> = self
                        .list_candidates(deadline)?
                        .into_iter()
                        .filter(|candidate| {
                            candidate
                                .target
                                .as_ref()
                                .is_some_and(|target| &target.id == explicit)
                        })
                        .collect();
                    if matching.len() != 1 {
                        let prompt = if matching.is_empty() {
                            "Reconnect the selected target before resuming this execution."
                        } else {
                            "The selected target has ambiguous physical routes; disconnect duplicate routes before resuming this execution."
                        };
                        return self.pause(
                            run,
                            "physicalReconnect",
                            prompt,
                            ResumeMode::ReconnectTarget,
                            None,
                        );
                    }
                    let candidate = matching.remove(0);
                    if candidate.state != "Connected" {
                        let unauthorized = candidate.state == "Unauthorized";
                        return self.pause(
                            run,
                            if unauthorized {
                                "trustDevice"
                            } else {
                                "physicalReconnect"
                            },
                            if unauthorized {
                                "Confirm the debugging trust prompt on the selected device, then resume this execution."
                            } else {
                                "Reconnect the selected target until its transport reports Connected."
                            },
                            ResumeMode::ReconnectTarget,
                            None,
                        );
                    }
                    candidate.target.ok_or_else(|| {
                        ExecutorFailure::MalformedResponse(
                            "connected candidate lost its durable target ownership".into(),
                        )
                    })?
                }
                None => {
                    let mut listed = self.list_targets(deadline)?;
                    match listed.len() {
                        1 => listed.remove(0),
                        0 => match self.adopt(deadline)? {
                            Adoption::Target(target) => target,
                            Adoption::Pause {
                                kind,
                                prompt,
                                mode,
                                options,
                            } => return self.pause(run, kind, prompt, mode, options),
                        },
                        _ => {
                            let options = listed.into_iter().map(|target| target.id).collect();
                            return self.pause(
                                run,
                                "selectTarget",
                                "Multiple adopted targets are available; select one target ID.",
                                ResumeMode::AdoptedTarget,
                                Some(options),
                            );
                        }
                    }
                }
            },
        };
        self.submit_and_run(run, target, deadline)
    }

    fn submit_and_run(
        &mut self,
        run: Run,
        target: Target,
        deadline: &Deadline,
    ) -> Result<Outcome, ExecutorError> {
        let request = run.request;
        let mut operation = Map::from_iter([("id".to_owned(), json!(request.operation_id))]);
        if let Some(version) = request.operation_version {
            operation.insert("version".into(), json!(version));
        }
        let mut target_fields = Map::from_iter([("targetId".to_owned(), json!(target.id))]);
        if let Some(revision) = target.binding_revision {
            target_fields.insert("expectedBindingRevision".into(), json!(revision));
        }
        let mut payload = Map::from_iter([
            (
                "documentType".to_owned(),
                json!("runtime-operation-request"),
            ),
            ("schemaVersion".to_owned(), json!("1.0.0")),
            (
                "requestId".to_owned(),
                json!(format!("agent-request-{}", request.execution_id)),
            ),
            (
                "idempotencyKey".to_owned(),
                json!(format!("agent-execution-{}", request.execution_id)),
            ),
            ("operation".to_owned(), Value::Object(operation)),
            ("target".to_owned(), Value::Object(target_fields)),
        ]);
        if !request.inputs.is_empty() {
            payload.insert("inputs".into(), Value::Object(request.inputs.clone()));
        }
        if let Some(capability) = &request.capability {
            payload.insert("authorization".into(), json!({"capabilityId": capability}));
        }
        let text = arkdeck_contract::canonical_json(&Value::Object(payload))
            .ok()
            .and_then(|bytes| String::from_utf8(bytes).ok())
            .ok_or_else(|| {
                ExecutorFailure::MalformedResponse("cannot encode runtime request".into())
            })?;
        let submitted = self.call(
            "job.submit",
            Some(Map::from_iter([("requestJson".to_owned(), json!(text))])),
            deadline,
        )?;
        let job = submitted["jobId"]
            .as_str()
            .filter(|job| safe_identifier(job))
            .ok_or_else(|| {
                ExecutorFailure::MalformedResponse("submit returned an unsafe job id".into())
            })?
            .to_owned();
        let job_params = || Some(Map::from_iter([("jobId".to_owned(), json!(job))]));
        let cancel_seconds = request.maximum_wait_seconds.clamp(1, 30);
        let finished = match self.call("job.run", job_params(), deadline) {
            Ok(finished) => finished,
            Err(error) => {
                let _ = self.call_within("job.cancel", job_params(), cancel_seconds);
                let receipt = self.receipt(
                    &run,
                    Some(&job),
                    Some(&target),
                    "transportFailure",
                    None,
                    Vec::new(),
                );
                return Ok(Outcome::Failed {
                    reason: format!(
                        "bounded job.run failed; typed cancellation requested: {}",
                        error.description()
                    ),
                    receipt,
                });
            }
        };
        let state = finished["state"]
            .as_str()
            .ok_or_else(|| ExecutorFailure::MalformedResponse("run returned no state".into()))?
            .to_owned();
        if !TERMINAL_STATES.contains(&state.as_str()) {
            let _ = self.call_within("job.cancel", job_params(), cancel_seconds);
            let receipt = self.receipt(&run, Some(&job), Some(&target), &state, None, Vec::new());
            return Ok(Outcome::Failed {
                reason: format!(
                    "job.run returned non-terminal state {state}; typed cancellation requested"
                ),
                receipt,
            });
        }
        let mut blockers = Vec::new();
        let facts = match self
            .call("job.evidence", job_params(), deadline)
            .map_err(|error| error.description())
            .and_then(|evidence| evidence_facts(&evidence))
        {
            Ok(facts) => Some(facts),
            Err(error) => {
                blockers.push(format!("trustedEvidenceQuery:{error}"));
                None
            }
        };
        self.artifact_inventory(&job, deadline)?;
        let receipt = self.receipt(
            &run,
            Some(&job),
            Some(&target),
            &state,
            facts.as_ref(),
            blockers,
        );
        if state == "succeeded" || state == "recovered" {
            return Ok(Outcome::Completed(receipt));
        }
        let reason = finished["failure"]["code"]
            .as_str()
            .map_or_else(|| format!("job ended in {state}"), str::to_owned);
        Ok(Outcome::Failed {
            reason: if state == "waitingForRecovery" {
                format!("job requires typed reconcile: {reason}")
            } else {
                reason
            },
            receipt,
        })
    }

    fn adopt(&mut self, deadline: &Deadline) -> Result<Adoption, ExecutorError> {
        let mut visible = self.list_candidates(deadline)?;
        if visible.len() != 1 {
            let options: Vec<String> = visible.into_iter().map(|candidate| candidate.key).collect();
            return Ok(if options.is_empty() {
                Adoption::Pause {
                    kind: "physicalReconnect",
                    prompt: "Connect the selected device, then resume this execution.",
                    mode: ResumeMode::RetryAdoption,
                    options: Some(options),
                }
            } else {
                Adoption::Pause {
                    kind: "selectTarget",
                    prompt: "Select one visible device candidate.",
                    mode: ResumeMode::BootstrapCandidate,
                    options: Some(options),
                }
            });
        }
        let selected = visible.remove(0);
        if selected.state != "Connected" {
            let unauthorized = selected.state == "Unauthorized";
            return Ok(Adoption::Pause {
                kind: if unauthorized {
                    "trustDevice"
                } else {
                    "physicalReconnect"
                },
                prompt: if unauthorized {
                    "Confirm the selected device debugging trust prompt, then resume."
                } else {
                    "Reconnect the selected device, then resume."
                },
                mode: ResumeMode::RetryAdoption,
                options: None,
            });
        }
        let adopted = self.call(
            "target.adopt",
            Some(Map::from_iter([
                ("candidate".to_owned(), json!(selected.key)),
                ("observationId".to_owned(), json!(selected.observation)),
                (
                    "observationGeneration".to_owned(),
                    json!(selected.generation),
                ),
            ])),
            deadline,
        )?;
        let malformed =
            |message: String| ExecutorError::from(ExecutorFailure::MalformedResponse(message));
        match adopted["outcome"].as_str() {
            None => Err(malformed("adopt returned no outcome".into())),
            Some("adopted") => {
                let id = adopted["targetId"]
                    .as_str()
                    .filter(|id| safe_identifier(id));
                match (id, exact_int(&adopted["bindingRevision"])) {
                    (Some(id), Some(revision)) => Ok(Adoption::Target(Target {
                        id: id.to_owned(),
                        binding_revision: Some(revision),
                    })),
                    _ => Err(malformed("adopt returned malformed target binding".into())),
                }
            }
            Some(outcome) => Err(malformed(format!(
                "adopt returned unknown outcome {outcome}"
            ))),
        }
    }

    /// Swift `pause`: a new resume token, the action raised now, the pending
    /// record persisted under the token, and a receipt awaiting a person.
    fn pause(
        &mut self,
        mut run: Run,
        kind: &str,
        prompt: &str,
        mode: ResumeMode,
        options: Option<Vec<String>>,
    ) -> Result<Outcome, ExecutorError> {
        let token = format!(
            "resume-{}",
            crate::job_plan::uuid().map_err(|error| ExecutorFailure::Persistence(error.message))?
        );
        let mut action = Map::from_iter([
            ("kind".to_owned(), json!(kind)),
            ("prompt".to_owned(), json!(prompt)),
            ("resumeToken".to_owned(), json!(token)),
        ]);
        if let Some(options) = options {
            action.insert("selectionOptions".into(), json!(options));
        }
        action.insert("raisedAtUTC".into(), json!((self.clock)()));
        let action = Value::Object(action);
        run.actions.push(action.clone());
        let pending = json!({
            "request": run.request.encoded(),
            "catalogDigest": run.digest,
            "startedAtUTC": run.started,
            "humanActions": run.actions,
            "resumeMode": mode.name(),
        });
        self.persist(&pending, &format!("{token}.json"))?;
        let receipt = self.receipt(&run, None, None, "awaitingHumanAction", None, Vec::new());
        Ok(Outcome::Paused { action, receipt })
    }

    /// Swift `persist`: pretty, sorted, unescaped solidus; written to a
    /// private temporary file and moved into place.
    fn persist(&self, value: &Value, name: &str) -> Result<(), ExecutorFailure> {
        let failure = |error: std::io::Error| ExecutorFailure::Persistence(error.to_string());
        let bytes = arkdeck_contract::foundation_json::pretty(value, false).map_err(|_| {
            ExecutorFailure::Persistence("the pending record could not be encoded".into())
        })?;
        let mut directory = std::fs::DirBuilder::new();
        directory.recursive(true);
        // Owner-only where the host has POSIX modes.
        #[cfg(unix)]
        std::os::unix::fs::DirBuilderExt::mode(&mut directory, 0o700);
        directory.create(&self.state_directory).map_err(failure)?;
        let temporary = self.state_directory.join(format!(
            ".pending-{}",
            crate::job_plan::uuid().map_err(|error| ExecutorFailure::Persistence(error.message))?
        ));
        let mut file = std::fs::File::create(&temporary).map_err(failure)?;
        file.write_all(&bytes).map_err(failure)?;
        file.sync_all().map_err(failure)?;
        drop(file);
        std::fs::rename(&temporary, self.state_directory.join(name)).map_err(failure)
    }

    /// Swift `receipt(...)`: the Runtime's snapshot when one was read, the
    /// run's own facts otherwise, with the finish read from the clock.
    fn receipt(
        &mut self,
        run: &Run,
        job: Option<&str>,
        target: Option<&Target>,
        state: &str,
        facts: Option<&Map<String, Value>>,
        blockers: Vec<String>,
    ) -> Value {
        let fact = |key: &str| facts.and_then(|facts| facts.get(key));
        let (binding_revision, started, finished) = match facts {
            Some(facts) => (
                facts.get("bindingRevision").cloned(),
                facts.get("startedAtUtc").cloned().unwrap_or(json!("")),
                facts.get("finishedAtUtc").cloned().unwrap_or(json!("")),
            ),
            None => (
                target
                    .and_then(|target| target.binding_revision)
                    .map(|revision| json!(revision)),
                json!(run.started),
                json!((self.clock)()),
            ),
        };
        let mut receipt = Map::new();
        receipt.insert("executor".into(), json!("agent"));
        receipt.insert("executorID".into(), json!(EXECUTOR_ID));
        receipt.insert(
            "operationReference".into(),
            fact("operationReference")
                .cloned()
                .unwrap_or_else(|| json!(run.request.reference())),
        );
        if let Some(job) = fact("jobId").cloned().or(job.map(|job| json!(job))) {
            receipt.insert("jobID".into(), job);
        }
        if let Some(target) = fact("targetId")
            .cloned()
            .or(target.map(|target| json!(target.id)))
        {
            receipt.insert("targetID".into(), target);
        }
        if let Some(revision) = binding_revision {
            receipt.insert("bindingRevision".into(), revision);
        }
        receipt.insert(
            "catalogDigest".into(),
            fact("catalogDigest").cloned().unwrap_or(json!(run.digest)),
        );
        receipt.insert(
            "providerID".into(),
            fact("providerId").cloned().unwrap_or(json!("")),
        );
        receipt.insert(
            "executionMode".into(),
            fact("executionMode").cloned().unwrap_or(json!("execute")),
        );
        for (from, to) in [("actualEffect", "actualEffect"), ("authority", "authority")] {
            if let Some(value) = fact(from) {
                receipt.insert(to.into(), value.clone());
            }
        }
        receipt.insert(
            "stepKinds".into(),
            fact("actualStepKinds").cloned().unwrap_or(json!([])),
        );
        if let Some(observation) = fact("observation") {
            receipt.insert("evidenceObservation".into(), observation.clone());
        }
        if let Some(first) = fact("firstEvidenceStepAtUtc") {
            receipt.insert("firstEvidenceStepAtUTC".into(), first.clone());
        }
        receipt.insert(
            "outcomeUnknown".into(),
            fact("outcomeUnknown").cloned().unwrap_or(json!(false)),
        );
        receipt.insert("runtimeFactsObserved".into(), json!(facts.is_some()));
        receipt.insert("humanActions".into(), json!(run.actions));
        receipt.insert(
            "terminalState".into(),
            fact("terminalState").cloned().unwrap_or(json!(state)),
        );
        receipt.insert(
            "artifacts".into(),
            fact("artifacts").cloned().unwrap_or(json!([])),
        );
        let mut all_blockers: Vec<Value> = blockers.into_iter().map(Value::String).collect();
        if let Some(Value::Array(theirs)) = fact("blockers") {
            all_blockers.extend(theirs.iter().cloned());
        }
        receipt.insert("evidenceBlockers".into(), Value::Array(all_blockers));
        receipt.insert("startedAtUTC".into(), started);
        receipt.insert("finishedAtUTC".into(), finished);
        Value::Object(receipt)
    }

    fn operation_scope(
        &mut self,
        reference: &str,
        deadline: &Deadline,
    ) -> Result<Scope, ExecutorError> {
        let described = self.call(
            "operation.describe",
            Some(Map::from_iter([("reference".to_owned(), json!(reference))])),
            deadline,
        )?;
        let provider = described["provider"]
            .as_str()
            .filter(|provider| safe_identifier(provider));
        match (described["binding"].as_str(), provider) {
            (Some("none"), Some(provider)) => Ok(Scope::Host(provider.to_owned())),
            (Some("confirmedDevice"), Some(_)) => Ok(Scope::Device),
            _ => Err(ExecutorFailure::MalformedResponse(
                "operation.describe returned no recognized operation scope".into(),
            )
            .into()),
        }
    }

    fn list_targets(&mut self, deadline: &Deadline) -> Result<Vec<Target>, ExecutorError> {
        let listed = self.call("target.list", None, deadline)?;
        let rows = listed.as_array().ok_or_else(|| {
            ExecutorFailure::MalformedResponse("target.list is not an array".into())
        })?;
        rows.iter()
            .map(|row| {
                let id = row["targetId"].as_str().filter(|id| safe_identifier(id));
                match (id, exact_int(&row["bindingRevision"])) {
                    (Some(id), Some(revision)) => Ok(Target {
                        id: id.to_owned(),
                        binding_revision: Some(revision),
                    }),
                    _ => Err(ExecutorFailure::MalformedResponse(
                        "target.list contains malformed binding".into(),
                    )
                    .into()),
                }
            })
            .collect()
    }

    fn list_candidates(&mut self, deadline: &Deadline) -> Result<Vec<Candidate>, ExecutorError> {
        let listed = self.call("device.observations", None, deadline)?;
        let malformed = |message: &str| {
            ExecutorError::from(ExecutorFailure::MalformedResponse(message.to_owned()))
        };
        let generation = listed["snapshotGeneration"].as_str().filter(|text| {
            text.parse::<i64>()
                .is_ok_and(|value| value > 0 && value.to_string() == *text)
        });
        let (Some(generation), Some(rows)) = (generation, listed["observations"].as_array()) else {
            return Err(malformed("device observations is not a current snapshot"));
        };
        if listed["schemaVersion"] != "arkdeck.device-observations/1"
            || listed["health"] != "current"
        {
            return Err(malformed("device observations is not a current snapshot"));
        }
        rows.iter()
            .map(|row| {
                let key = row["candidateKey"]
                    .as_str()
                    .filter(|key| safe_selection(key));
                let state = row["authorizationState"]
                    .as_str()
                    .filter(|state| safe_selection(state));
                let observation = row["observationId"]
                    .as_str()
                    .filter(|observation| safe_identifier(observation));
                let (Some(key), Some(state), Some(observation)) = (key, state, observation) else {
                    return Err(malformed(
                        "device.observations contains malformed transport facts",
                    ));
                };
                let target = match (row.get("adoptedTargetId"), row.get("bindingRevision")) {
                    (Some(Value::String(id)), revision) => {
                        let revision = revision
                            .and_then(exact_int)
                            .filter(|revision| *revision > 0);
                        match revision {
                            Some(revision) if safe_identifier(id) => Some(Target {
                                id: id.clone(),
                                binding_revision: Some(revision),
                            }),
                            _ => {
                                return Err(malformed(
                                    "device.observations contains malformed target ownership",
                                ));
                            }
                        }
                    }
                    (Some(Value::Null), Some(Value::Null)) => None,
                    _ => {
                        return Err(malformed(
                            "device.observations contains incomplete target ownership",
                        ));
                    }
                };
                Ok(Candidate {
                    key: key.to_owned(),
                    state: state.to_owned(),
                    observation: observation.to_owned(),
                    generation: generation.to_owned(),
                    target,
                })
            })
            .collect()
    }

    /// Swift `CurrentRuntimeResourceReads.artifactInventory`: every page of
    /// the Job's Artifacts, each checked, one snapshot, no cursor twice.
    fn artifact_inventory(&mut self, job: &str, deadline: &Deadline) -> Result<(), ExecutorError> {
        let seconds = deadline.remaining_seconds()?.min(86_400);
        let owner = json!({"kind": "job", "id": job});
        let malformed = |message: &str| {
            ExecutorError::from(ExecutorFailure::MalformedResponse(message.to_owned()))
        };
        let mut cursor: Option<String> = None;
        let mut revision: Option<Value> = None;
        let mut cursors = std::collections::BTreeSet::new();
        let mut previous: Option<(f64, String)> = None;
        loop {
            let mut params = Map::from_iter([
                ("owner".to_owned(), owner.clone()),
                ("pageSize".to_owned(), json!(1000)),
            ]);
            if let Some(cursor) = &cursor {
                params.insert("cursor".into(), json!(cursor));
            }
            let page = self.call_as_client("artifact.list", Some(params), seconds)?;
            crate::artifact_resources::validate_artifact_page(&page, &owner, 1000)
                .map_err(ExecutorError::Control)?;
            if revision
                .as_ref()
                .is_some_and(|revision| *revision != page["snapshotRevision"])
            {
                return Err(malformed("Artifact snapshot changed between pages"));
            }
            revision = Some(page["snapshotRevision"].clone());
            for row in page["items"].as_array().into_iter().flatten() {
                let id = row["artifactId"].as_str().unwrap_or_default().to_owned();
                let created =
                    crate::job_resources::date_seconds(&row["createdAtUtc"]).unwrap_or_default();
                if previous.as_ref().is_some_and(|(time, before)| {
                    !(*time > created || (*time == created && before.as_bytes() < id.as_bytes()))
                }) {
                    return Err(malformed("Artifact inventory order or identity repeated"));
                }
                previous = Some((created, id));
            }
            match page["nextCursor"].as_str() {
                Some(next) => {
                    if !cursors.insert(next.to_owned()) {
                        return Err(malformed("Artifact inventory repeated a cursor"));
                    }
                    cursor = Some(next.to_owned());
                }
                None => return Ok(()),
            }
        }
    }

    /// One request on a new connection: Swift `call(method:params:deadline:)`.
    /// The executor's own requests carry `agent-<uuid>` identities.
    fn call(
        &mut self,
        method: &str,
        params: Option<Map<String, Value>>,
        deadline: &Deadline,
    ) -> Result<Value, ExecutorError> {
        let seconds = deadline.remaining_seconds()?;
        Ok(self.call_within(method, params, seconds)?)
    }

    fn call_within(
        &mut self,
        method: &str,
        params: Option<Map<String, Value>>,
        seconds: u64,
    ) -> Result<Value, ClientFailure> {
        let id = format!("agent-{}", identity());
        self.exchange(method, params, seconds, &id)
    }

    /// A request with the client's own identity, as Swift's client assigns
    /// one when its caller names none (the Artifact pages).
    fn call_as_client(
        &mut self,
        method: &str,
        params: Option<Map<String, Value>>,
        seconds: u64,
    ) -> Result<Value, ClientFailure> {
        let id = identity().to_uppercase();
        self.exchange(method, params, seconds, &id)
    }

    /// Swift's client: each request proves the contract with `health` on its
    /// own connection first, except `health` itself, and a failed proof sends
    /// no business request.
    fn exchange(
        &mut self,
        method: &str,
        params: Option<Map<String, Value>>,
        seconds: u64,
        id: &str,
    ) -> Result<Value, ClientFailure> {
        let mut client = self.runtime.connect(Duration::from_secs(seconds))?;
        if method == "health" {
            return client.health(id).map_err(ClientFailure::request);
        }
        client
            .health(&identity().to_uppercase())
            .map_err(|_| ClientFailure::unproven_contract())?;
        client
            .request(id, method, params)
            .map_err(ClientFailure::request)
    }
}

enum Adoption {
    Target(Target),
    Pause {
        kind: &'static str,
        prompt: &'static str,
        mode: ResumeMode,
        options: Option<Vec<String>>,
    },
}

/// A random version 4 UUID in lowercase text.
fn identity() -> String {
    crate::job_plan::uuid().unwrap_or_else(|_| "00000000-0000-4000-8000-000000000000".into())
}

/// Swift `isSafeIdentifier`: `^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$` as ICU
/// matches it, where `$` also matches before one line terminator that ends
/// the text.
fn safe_identifier(value: &str) -> bool {
    let body = [
        "\r\n", "\n", "\r", "\u{b}", "\u{c}", "\u{85}", "\u{2028}", "\u{2029}",
    ]
    .iter()
    .find_map(|terminator| value.strip_suffix(terminator))
    .unwrap_or(value);
    (1..=128).contains(&body.len())
        && body.as_bytes()[0].is_ascii_alphanumeric()
        && body
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || b"._-".contains(&byte))
}

/// Swift `isSafeSelection`: 1…255 UTF-8 bytes, no NUL and no newline.
fn safe_selection(value: &str) -> bool {
    (1..=255).contains(&value.len())
        && !value.chars().any(|character| {
            matches!(
                character,
                '\0' | '\n' | '\u{b}' | '\u{c}' | '\r' | '\u{85}' | '\u{2028}' | '\u{2029}'
            )
        })
}

/// Swift `exactInt`: a JSON integer that fits.
fn exact_int(value: &Value) -> Option<i64> {
    value.as_i64()
}

/// A field of a Swift `Codable` evidence type.
struct Field {
    key: &'static str,
    kind: Kind,
    required: bool,
}

enum Kind {
    Text,
    Integer,
    Boolean,
    Texts,
    OneOf(&'static [&'static str]),
    Object(&'static [Field]),
    Objects(&'static [Field]),
}

const fn field(key: &'static str, kind: Kind, required: bool) -> Field {
    Field {
        key,
        kind,
        required,
    }
}

const STEP: &[Field] = &[
    field("stepId", Kind::Text, true),
    field("stepKind", Kind::Text, true),
    field("outcomeAtUtc", Kind::Text, true),
];

const OBSERVATION: &[Field] = &[
    field("targetId", Kind::Text, false),
    field("bindingRevision", Kind::Integer, false),
    field("stableIdentitySha256", Kind::Text, false),
    field("model", Kind::Text, false),
    field("firmware", Kind::Text, false),
    field("transport", Kind::OneOf(&["usb", "tcp", "uart"]), false),
    field("providerId", Kind::Text, true),
    field("toolVersion", Kind::Text, true),
    field("toolSha256", Kind::Text, true),
    field("confirmedAtUtc", Kind::Text, false),
    field("confirmationMethod", Kind::Text, true),
    field("preflightSteps", Kind::Objects(STEP), true),
];

const ARTIFACT: &[Field] = &[
    field("reference", Kind::Text, true),
    field("sha256", Kind::Text, true),
    field("jobId", Kind::Text, true),
    field("targetId", Kind::Text, true),
    field("bindingRevision", Kind::Integer, false),
    field("stableIdentitySha256", Kind::Text, false),
    field("providerId", Kind::Text, true),
    field("byteCount", Kind::Integer, true),
    field("bytesVerified", Kind::Boolean, true),
];

const INTENT: &[Field] = &[
    field("jobId", Kind::Text, true),
    field("intentEventId", Kind::Text, true),
    field("operationReference", Kind::Text, true),
    field("profileReference", Kind::Text, true),
    field("observedAtUtc", Kind::Text, true),
    field("possibleEffects", Kind::Texts, true),
];

const EPOCH: &[Field] = &[
    field("epochId", Kind::Text, true),
    field("source", Kind::Text, true),
    field("stableTargetIdentitySha256", Kind::Text, true),
    field("bindingRevision", Kind::Integer, true),
    field("coveredIntents", Kind::Objects(INTENT), true),
    field("uncertainEffectSetSha256", Kind::Text, true),
    field("coverageContractVersion", Kind::Text, true),
    field("coveredEffectSetSha256", Kind::Text, true),
    field("recoveryJobId", Kind::Text, true),
    field("recoveryIntentEventId", Kind::Text, true),
    field("operationReference", Kind::Text, true),
    field("profileReference", Kind::Text, true),
    field("materializedPlanDigestSha256", Kind::Text, true),
    field("artifactSha256", Kind::Text, true),
    field("providerExecutableSha256", Kind::Text, true),
    field("confirmedStepIds", Kind::Texts, true),
    field("resultingTargetEpochSha256", Kind::Text, true),
    field("establishedAtUtc", Kind::Text, true),
    field("epochSha256", Kind::Text, true),
];

const AUTHORITY: &[Field] = &[
    field(
        "kind",
        Kind::OneOf(&[
            "defaultReadOnlyPolicy",
            "runtimeCapability",
            "standingAuthorization",
            "evolutionCampaignConfirmation",
        ]),
        true,
    ),
    field("reference", Kind::Text, true),
    field("admittedAtUtc", Kind::Text, true),
    field("validUntilUtc", Kind::Text, false),
    field("consumptionFingerprintSha256", Kind::Text, false),
    field("reservationId", Kind::Text, false),
    field("useOrdinal", Kind::Integer, false),
    field("stepSetDigest", Kind::Text, false),
    field("artifactDigest", Kind::Text, false),
    field("planDigest", Kind::Text, false),
    field("targetBindingDigest", Kind::Text, false),
    field("recoveryEpoch", Kind::Object(EPOCH), false),
];

const TRUSTED_FACTS: &[Field] = &[
    field("jobId", Kind::Text, true),
    field("operationReference", Kind::Text, true),
    field("catalogDigest", Kind::Text, true),
    field("targetId", Kind::Text, true),
    field("bindingRevision", Kind::Integer, false),
    field("providerId", Kind::Text, true),
    field(
        "actualEffect",
        Kind::OneOf(&["hostOnly", "readOnly", "deviceMutation", "destructive"]),
        false,
    ),
    field("authority", Kind::Object(AUTHORITY), false),
    field("observation", Kind::Object(OBSERVATION), false),
    field("actualStepKinds", Kind::Texts, false),
    field("executionMode", Kind::Text, true),
    field("terminalState", Kind::Text, true),
    field("outcomeUnknown", Kind::Boolean, true),
    field("startedAtUtc", Kind::Text, false),
    field("firstEvidenceStepAtUtc", Kind::Text, false),
    field("finishedAtUtc", Kind::Text, false),
    field("recoveryEpoch", Kind::Object(EPOCH), false),
    field("artifacts", Kind::Objects(ARTIFACT), true),
    field("blockers", Kind::Texts, true),
];

/// Swift's `JSONDecoder` of a `Codable` type and its encoding back: known
/// keys only, an absent or null optional left out, a required field present
/// and of its type, and an unknown key ignored.
fn decoded(value: &Value, fields: &[Field]) -> Option<Map<String, Value>> {
    let object = value.as_object()?;
    let mut output = Map::new();
    for field in fields {
        let member = match object.get(field.key) {
            None | Some(Value::Null) if !field.required => continue,
            None | Some(Value::Null) => return None,
            Some(member) => member,
        };
        let encoded = match &field.kind {
            Kind::Text => json!(member.as_str()?),
            Kind::Integer => json!(member.as_i64()?),
            Kind::Boolean => json!(member.as_bool()?),
            Kind::Texts => json!(
                member
                    .as_array()?
                    .iter()
                    .map(|text| text.as_str().map(str::to_owned))
                    .collect::<Option<Vec<String>>>()?
            ),
            Kind::OneOf(values) => json!(member.as_str().filter(|text| values.contains(text))?),
            Kind::Object(inner) => Value::Object(decoded(member, inner)?),
            Kind::Objects(inner) => Value::Array(
                member
                    .as_array()?
                    .iter()
                    .map(|item| decoded(item, inner).map(Value::Object))
                    .collect::<Option<Vec<Value>>>()?,
            ),
        };
        output.insert(field.key.to_owned(), encoded);
    }
    Some(output)
}

/// Swift `CurrentRuntimeResourceReads.evidence`: the current evidence
/// resource, its Artifact counts from their canonical decimal text, decoded as
/// Swift's `RuntimeHardwareEvidenceTrustedFacts`. The error is Swift's
/// description where Swift's is fixed; a decoding failure is described here in
/// this CLI's words.
pub fn evidence_facts(evidence: &Value) -> Result<Map<String, Value>, String> {
    let malformed =
        |message: &str| ExecutorFailure::MalformedResponse(message.into()).description();
    let (Some(fields), Some(artifacts)) = (evidence.as_object(), evidence["artifacts"].as_array())
    else {
        return Err(malformed("Job evidence is not the current resource"));
    };
    if evidence["schemaVersion"] != "arkdeck.job-evidence/1" {
        return Err(malformed("Job evidence is not the current resource"));
    }
    let mut fields = fields.clone();
    let counted = artifacts
        .iter()
        .map(|item| {
            let mut row = item.as_object()?.clone();
            let text = row.get("byteCount")?.as_str()?;
            let count = text
                .parse::<i64>()
                .ok()
                .filter(|count| *count >= 0 && count.to_string() == text)?;
            row.insert("byteCount".into(), json!(count));
            Some(Value::Object(row))
        })
        .collect::<Option<Vec<Value>>>()
        .ok_or_else(|| malformed("Evidence Artifact count is not canonical"))?;
    fields.insert("artifacts".into(), Value::Array(counted));
    decoded(&Value::Object(fields), TRUSTED_FACTS)
        .ok_or_else(|| "the Job evidence did not decode as the Runtime's trusted facts".into())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn identifiers_are_judged_as_swifts_expression_matches_them() {
        assert!(safe_identifier("exec-1"));
        assert!(safe_identifier(&"a".repeat(128)));
        assert!(!safe_identifier(&"a".repeat(129)));
        assert!(!safe_identifier(".exec"));
        assert!(!safe_identifier("exec 1"));
        assert!(!safe_identifier(""));
        // ICU's `$` matches before a final line terminator.
        assert!(safe_identifier("exec-1\n"));
        assert!(!safe_identifier("exec-1\n\n"));
        assert!(safe_selection("5SM0125725000252"));
        assert!(!safe_selection(""));
        assert!(!safe_selection("a\u{2028}b"));
        assert!(!safe_selection(&"a".repeat(256)));
    }

    #[test]
    fn a_description_is_swifts_for_each_case() {
        assert_eq!(
            ClientFailure::Transport("connection closed before response".into()).description(),
            r#"transport("connection closed before response")"#
        );
        assert_eq!(
            ClientFailure::DaemonError {
                code: "internalError".into(),
                message: "the Runtime failed".into()
            }
            .description(),
            r#"daemonError(code: "internalError", message: "the Runtime failed")"#
        );
        assert_eq!(
            ExecutorFailure::DaemonUnavailable(
                ClientFailure::ConnectFailed("connect failed: errno 2".into()).description()
            )
            .description(),
            r#"daemonUnavailable("connectFailed(\"connect failed: errno 2\")")"#
        );
        assert_eq!(
            ClientFailure::DeadlineExceeded.description(),
            "deadlineExceeded"
        );
    }
}
