//! Swift `HDCProcessLifecycleExecutor`'s process part: the confirmed
//! lifecycle commands of the HDC server the daemon owns — `hdc -s <endpoint>
//! kill -r` (restart) and `hdc -s <endpoint> kill` (stop) — as the exact
//! argv, the executable identity a launch-window audit records before the
//! child starts, one launch per preparation through the verified tool
//! runner, and the post-dispatch re-observation that alone decides the
//! outcome: a restart succeeded only when a strictly newer server generation
//! owns the endpoint, a stop only when nothing does; anything else — a
//! nonzero exit, a registered failure, stderr, a server state that cannot be
//! re-proved — is an unknown outcome that the control-action owner reconciles
//! and never replays. The durable preview, confirmation and intent
//! authorization, the dispatch lease and the audit records themselves are that
//! owner's (lane A); this type hands it the facts in the order Swift persists
//! them: the actual command before anything is prepared, the executable
//! identity before the launch.
use crate::{CommandOutcome, SemanticOutputParser};
use arkdeck_platform::{
    LoopbackServerLease, ServerIdentityReceipt, ToolLaunchIdentity, ToolLimits, ToolRequest,
    ToolTermination, VerifiedTool,
};
use std::ffi::OsString;
use std::io;
use std::net::SocketAddrV4;
use std::path::PathBuf;
use std::time::{Duration, Instant};

/// Swift `HDCServerEndpointSelection.childEnvironment`.
const SERVER_PORT_VARIABLE: &str = "OHOS_HDC_SERVER_PORT";
/// Swift `DescriptorBoundProcessDispatcher`'s default capture.
const CAPTURE_BYTES: usize = 8 * 1024 * 1024;

/// Swift `HDCServerLifecycleAction` as the executor lowers it; `startManaged`
/// has its own absent-endpoint gate (`ManagedHdcServer`) and is never a
/// command.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LifecycleAction {
    Restart,
    Stop,
}

impl LifecycleAction {
    /// The exact argv, which the lifecycle audit schema pins.
    pub fn arguments(self, endpoint: SocketAddrV4) -> Vec<String> {
        let mut arguments = vec!["-s".to_owned(), endpoint.to_string(), "kill".to_owned()];
        if self == Self::Restart {
            arguments.push("-r".to_owned());
        }
        arguments
    }
}

/// Swift `HDCServerLifecycleActualCommand`: what the audit records before any
/// preparation — the executable's authorized path, the exact argv and the
/// endpoint.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LifecycleCommand {
    pub action: LifecycleAction,
    pub endpoint: SocketAddrV4,
    pub executable: PathBuf,
    pub arguments: Vec<String>,
}

impl LifecycleCommand {
    pub fn new(action: LifecycleAction, endpoint: SocketAddrV4, tool: &VerifiedTool) -> Self {
        Self {
            action,
            endpoint,
            executable: tool.path().to_path_buf(),
            arguments: action.arguments(endpoint),
        }
    }
}

/// Swift's budgets: 15 s for the command, then 12 s of re-observation every
/// 100 ms.
#[derive(Clone, Copy, Debug)]
pub struct LifecycleBudget {
    pub command_timeout: Duration,
    pub probe_deadline: Duration,
    pub probe_poll: Duration,
}

impl Default for LifecycleBudget {
    fn default() -> Self {
        Self {
            command_timeout: Duration::from_secs(15),
            probe_deadline: Duration::from_secs(12),
            probe_poll: Duration::from_millis(100),
        }
    }
}

/// Swift `HDCServerLifecyclePostDispatchObservation`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PostDispatchObservation {
    Generation(u64),
    Unavailable,
}

/// Swift `HDCServerLifecycleExecutionOutcome` after a launch: only these
/// three, since a refusal before the launch is a preparation error.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum LifecycleOutcome {
    Succeeded { resulting_generation: u64 },
    Stopped,
    OutcomeUnknown(String),
}

/// Swift `HDCServerLifecycleExecutorResult`, with the process facts kept.
#[derive(Debug)]
pub struct LifecycleReceipt {
    pub outcome: LifecycleOutcome,
    pub observation: Option<PostDispatchObservation>,
    pub termination: Option<ToolTermination>,
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
}

/// Swift `HDCPreparedProcessCommand`: the tool verified for this command and
/// its identity for the launch-window record; launched at most once.
pub struct PreparedLifecycle<'a> {
    tool: &'a VerifiedTool,
    command: LifecycleCommand,
    identity: ToolLaunchIdentity,
    expected_generation: u64,
}

impl<'a> PreparedLifecycle<'a> {
    /// Swift `runner.prepare`: after the actual command is durable. The
    /// expected generation is the confirmed server's, which a restart must
    /// strictly exceed.
    pub fn prepare(
        tool: &'a VerifiedTool,
        command: LifecycleCommand,
        expected_generation: u64,
    ) -> io::Result<Self> {
        let identity = tool.launch_identity()?;
        Ok(Self {
            tool,
            command,
            identity,
            expected_generation,
        })
    }

    pub fn command(&self) -> &LifecycleCommand {
        &self.command
    }

    /// Swift `HDCServerLifecycleExecutableIdentityReceipt`, for the
    /// `launchWindowEntered` record the owner writes before calling `launch`.
    pub fn identity(&self) -> &ToolLaunchIdentity {
        &self.identity
    }

    /// Swift `executePrepared` and the executor's classification: the one
    /// launch of this preparation, then the post-dispatch re-observation.
    pub fn launch(self, budget: &LifecycleBudget) -> LifecycleReceipt {
        let environment = [(
            OsString::from(SERVER_PORT_VARIABLE),
            OsString::from(self.command.endpoint.port().to_string()),
        )];
        let arguments: Vec<OsString> = self.command.arguments.iter().map(OsString::from).collect();
        let request = ToolRequest {
            arguments: &arguments,
            environment: &environment,
            working_directory: None,
            limits: ToolLimits {
                timeout: budget.command_timeout,
                capture_bytes: CAPTURE_BYTES,
            },
        };
        let probe = || {
            probe(
                self.tool,
                self.command.action,
                self.command.endpoint,
                self.expected_generation,
                budget,
            )
        };
        let unknown = |reason: &str, observation, termination, stdout, stderr| LifecycleReceipt {
            outcome: LifecycleOutcome::OutcomeUnknown(reason.to_owned()),
            observation,
            termination,
            stdout,
            stderr,
        };
        let execution = match self.tool.run_tool(&request, &|| false) {
            Ok(execution) => execution,
            Err(_) => {
                let observation = probe();
                return unknown(
                    "lifecycle launch window was entered but process execution could not be classified; post-dispatch state requires reconciliation",
                    observation,
                    None,
                    Vec::new(),
                    Vec::new(),
                );
            }
        };
        let observation = probe();
        let (termination, stdout, stderr) = (
            Some(execution.termination),
            execution.stdout,
            execution.stderr,
        );
        if termination != Some(ToolTermination::Exited(0)) {
            return unknown(
                "lifecycle launch window was entered and the process did not exit zero; post-dispatch state requires reconciliation",
                observation,
                termination,
                stdout,
                stderr,
            );
        }
        let mut parser = SemanticOutputParser::new();
        parser.consume(&stdout);
        parser.consume(&stderr);
        if let CommandOutcome::Failure(_) = parser.finish(0) {
            return unknown(
                "lifecycle launch window was entered and the process emitted a registered failure result; post-dispatch state requires reconciliation",
                observation,
                termination,
                stdout,
                stderr,
            );
        }
        if !stderr.is_empty() {
            return unknown(
                "lifecycle process emitted unregistered stderr; post-dispatch state is not trusted",
                observation,
                termination,
                stdout,
                stderr,
            );
        }
        let Some(observed) = observation else {
            return unknown(
                "lifecycle process completed but server state could not be re-probed",
                None,
                termination,
                stdout,
                stderr,
            );
        };
        let outcome = match (self.command.action, observed) {
            (LifecycleAction::Restart, PostDispatchObservation::Generation(generation)) => {
                if generation > self.expected_generation {
                    LifecycleOutcome::Succeeded {
                        resulting_generation: generation,
                    }
                } else {
                    LifecycleOutcome::OutcomeUnknown(
                        "restart completed but did not establish a strictly newer server generation"
                            .to_owned(),
                    )
                }
            }
            (LifecycleAction::Stop, PostDispatchObservation::Unavailable) => {
                LifecycleOutcome::Stopped
            }
            (LifecycleAction::Restart, PostDispatchObservation::Unavailable)
            | (LifecycleAction::Stop, PostDispatchObservation::Generation(_)) => {
                LifecycleOutcome::OutcomeUnknown(
                    "post-dispatch server state does not match lifecycle action".to_owned(),
                )
            }
        };
        LifecycleReceipt {
            outcome,
            observation: Some(observed),
            termination,
            stdout,
            stderr,
        }
    }
}

/// Swift `HDCServerProcessIdentityReceipt.stableGeneration`: the birth as
/// microseconds, never zero.
pub fn generation(identity: &ServerIdentityReceipt) -> Option<u64> {
    identity
        .start_seconds
        .checked_mul(1_000_000)?
        .checked_add(identity.start_microseconds)
        .filter(|generation| *generation > 0)
}

/// Swift `postDispatchProbe`: the commandless identity read again until the
/// deadline — a restart is observed only as a strictly newer generation, a
/// stop only as no server at the endpoint; anything else keeps looking, and
/// the deadline reports nothing.
fn probe(
    tool: &VerifiedTool,
    action: LifecycleAction,
    endpoint: SocketAddrV4,
    expected_generation: u64,
    budget: &LifecycleBudget,
) -> Option<PostDispatchObservation> {
    let deadline = Instant::now() + budget.probe_deadline;
    while Instant::now() < deadline {
        match (action, LoopbackServerLease::acquire(tool, endpoint)) {
            (LifecycleAction::Restart, Ok(lease)) => {
                if let Some(generation) = generation(lease.identity())
                    && generation > expected_generation
                {
                    return Some(PostDispatchObservation::Generation(generation));
                }
            }
            (LifecycleAction::Stop, Err(error)) if error.kind() == io::ErrorKind::NotFound => {
                return Some(PostDispatchObservation::Unavailable);
            }
            _ => {}
        }
        std::thread::sleep(budget.probe_poll);
    }
    None
}
