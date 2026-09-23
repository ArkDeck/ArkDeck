//! The HDC server the daemon owns, as Swift's `HeadlessHDCServerHost` starts
//! and keeps it: the verified tool launched as `hdc -s <endpoint> -m` with the
//! server port named to it, held until the loopback listener answers and
//! `checkserver` reports agreeing versions, then bound to the launched process
//! through the commandless identity proof — the listener's owner must be the
//! process this launch recorded, by PID, birth, executable path and digest.
//! A listener of any other process, however exact, never becomes this server.
use crate::{ServerCheck, parse_server_check};
use arkdeck_platform::{
    LoopbackServerLease, ManagedServer, ServerExit, ServerIdentityReceipt, ServerLaunch,
    ServerStop, ToolLimits, ToolRequest, ToolTermination, VerifiedTool,
};
use std::ffi::OsString;
use std::io;
use std::net::{Ipv4Addr, SocketAddr, SocketAddrV4, TcpStream};
use std::time::{Duration, Instant};

/// Swift `HDCServerEndpointSelection.childEnvironment`: the server port is
/// named to the foreground server and to every readiness probe.
const SERVER_PORT_VARIABLE: &str = "OHOS_HDC_SERVER_PORT";
/// Swift `executeIdentityBound(request, captureLimit: 256 * 1024)`.
const FOREGROUND_CAPTURE_BYTES: usize = 256 * 1024;
/// Swift `DescriptorBoundProcessDispatcher`'s default capture for a probe.
const PROBE_CAPTURE_BYTES: usize = 8 * 1024 * 1024;
/// Swift `loopbackListenerIsReachable`: a nonblocking connect polled 100 ms.
const REACHABILITY_PROBE: Duration = Duration::from_millis(100);

/// Swift `HDCServerEndpointSelection.defaultPort`.
const DEFAULT_PORT: u16 = 8710;

/// Swift `HDCServerEndpointSelector.select()` as the daemon's host calls it,
/// with no explicit endpoint: the inherited `OHOS_HDC_SERVER_PORT` on the
/// IPv4 loopback (`inheritedEnvironment`), else the documented default
/// `127.0.0.1:8710` (`default`). A port that is set but not an integer in
/// 1...65535 is refused (Swift `invalidInheritedPort`), never replaced by the
/// default.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct EndpointSelection {
    pub endpoint: SocketAddrV4,
    pub source: &'static str,
}

impl EndpointSelection {
    pub fn select(inherited_port: Option<&str>) -> Result<Self, String> {
        match inherited_port {
            Some(value) => crate::dispatch::valid_port(value)
                .map(|port| Self {
                    endpoint: SocketAddrV4::new(Ipv4Addr::LOCALHOST, port),
                    source: "inheritedEnvironment",
                })
                .ok_or_else(|| format!("{SERVER_PORT_VARIABLE} is not a port in 1...65535")),
            None => Ok(Self {
                endpoint: SocketAddrV4::new(Ipv4Addr::LOCALHOST, DEFAULT_PORT),
                source: "default",
            }),
        }
    }
}

/// Swift `awaitReadiness`: the whole startup within 30 s, polled every 100 ms,
/// each `checkserver` given 2 s.
#[derive(Clone, Copy, Debug)]
pub struct StartBudget {
    pub readiness: Duration,
    pub poll: Duration,
    pub probe_timeout: Duration,
}

impl Default for StartBudget {
    fn default() -> Self {
        Self {
            readiness: Duration::from_secs(30),
            poll: Duration::from_millis(100),
            probe_timeout: Duration::from_secs(2),
        }
    }
}

/// Swift `HeadlessHDCServerHostError.serverDidNotBecomeReady` and the launch
/// refusal before it.
#[derive(Debug)]
pub enum StartFailure {
    /// Something already listens on the endpoint: nothing was launched, and
    /// what listens there is named, never adopted or stopped (Swift's
    /// "managed HDC endpoint was not absent before the foreground launch").
    Occupied(String),
    /// The launch itself was refused: nothing ran.
    Refused(io::Error),
    /// The server ended before it was ready (Swift `foregroundExitReason`).
    Exited(String),
    /// The startup deadline passed with the last reason seen.
    NotReady(String),
    /// The listener answered, but it is not the process this launch recorded.
    Unbound(String),
}

/// A managed server, ready and bound to its launch.
pub struct ManagedHdcServer {
    server: ManagedServer,
    lease: LoopbackServerLease,
    check: ServerCheck,
    endpoint: SocketAddrV4,
}

impl ManagedHdcServer {
    /// Swift `HeadlessHDCServerHost.start`: the endpoint must be absent,
    /// then launch, then the loopback listener must become reachable (never
    /// `checkserver` first — an HDC client bootstraps a competing server when
    /// no listener exists), then `checkserver` must exit 0 with nothing on
    /// stderr and agreeing versions, then the listener's owner must be the
    /// launched process. The server ending at any point before that is its
    /// own failure; a launch that fails to be ready is stopped before this
    /// returns.
    ///
    /// Swift's absence gate (`authorizeManagedStart`) asks only its
    /// Supervisor's memory, which every daemon start begins empty, so Swift
    /// launches a second server beside whatever already holds the endpoint
    /// — a server a restart left, one a killed daemon orphaned, another
    /// client's — and fails only in readiness. Here the endpoint itself is
    /// asked first, by the connect alone that Swift's readiness uses (no HDC
    /// client runs): if anything answers, nothing is launched, and what
    /// holds the endpoint is named by the commandless proof and is never
    /// adopted or stopped (AC-HDC-003-02: managed only on an endpoint that had
    /// no server before the start; REQ-HDC-003). The proof after the launch
    /// still decides whatever a listener appearing in between could change.
    pub fn start(
        tool: &VerifiedTool,
        endpoint: SocketAddrV4,
        budget: StartBudget,
    ) -> Result<Self, StartFailure> {
        if reachable(endpoint) {
            return Err(StartFailure::Occupied(occupant(tool, endpoint)));
        }
        let spelled = endpoint.to_string();
        let environment = [(
            OsString::from(SERVER_PORT_VARIABLE),
            OsString::from(endpoint.port().to_string()),
        )];
        let arguments = ["-s", spelled.as_str(), "-m"].map(OsString::from);
        let mut server =
            ManagedServer::launch(tool, &arguments, &environment, FOREGROUND_CAPTURE_BYTES)
                .map_err(StartFailure::Refused)?;
        let deadline = Instant::now() + budget.readiness;
        let ended = |server: &mut ManagedServer| -> Result<(), StartFailure> {
            match server.exit() {
                Ok(None) => Ok(()),
                Ok(Some(exit)) => Err(StartFailure::Exited(exit_reason(exit))),
                Err(error) => Err(StartFailure::Exited(format!(
                    "foreground HDC server wait status was unresolved ({error})"
                ))),
            }
        };
        loop {
            ended(&mut server)?;
            if reachable(endpoint) {
                break;
            }
            if Instant::now() >= deadline {
                return Err(StartFailure::NotReady(
                    "foreground HDC loopback listener did not become reachable before startup deadline"
                        .into(),
                ));
            }
            std::thread::sleep(budget.poll);
        }
        let probe = ["-s", spelled.as_str(), "checkserver"].map(OsString::from);
        let mut last = String::from("no completed server observation");
        let check = loop {
            ended(&mut server)?;
            if Instant::now() >= deadline {
                return Err(StartFailure::NotReady(last));
            }
            let request = ToolRequest {
                arguments: &probe,
                environment: &environment,
                working_directory: None,
                limits: ToolLimits {
                    timeout: budget.probe_timeout,
                    capture_bytes: PROBE_CAPTURE_BYTES,
                },
            };
            match tool.run_tool(&request, &|| false) {
                Ok(execution) => {
                    if execution.termination == ToolTermination::Exited(0)
                        && execution.stderr.is_empty()
                        && let Ok(check) =
                            parse_server_check(&execution.stdout, execution.truncated)
                        && check.versions_agree()
                    {
                        break check;
                    }
                    last = format!(
                        "checkserver exit={} stdoutBytes={} stderrBytes={}",
                        exit_text(execution.termination),
                        execution.stdout.len(),
                        execution.stderr.len()
                    );
                }
                Err(error) => last = format!("{error:?}"),
            }
            std::thread::sleep(budget.poll);
        };
        let unbound = || {
            StartFailure::Unbound(
                "managed HDC launch could not be bound to its live process identity".into(),
            )
        };
        let lease = LoopbackServerLease::acquire(tool, endpoint).map_err(|_| unbound())?;
        if !launch_matches(server.launch_record(), lease.identity()) || !server.same_birth() {
            return Err(unbound());
        }
        Ok(Self {
            server,
            lease,
            check,
            endpoint,
        })
    }

    pub fn launch(&self) -> &ServerLaunch {
        self.server.launch_record()
    }

    pub fn identity(&self) -> &ServerIdentityReceipt {
        self.lease.identity()
    }

    pub fn check(&self) -> &ServerCheck {
        &self.check
    }

    pub fn endpoint(&self) -> SocketAddrV4 {
        self.endpoint
    }

    /// The server has ended on its own, or its wait status can no longer be
    /// read (Swift's host then holds no active launch).
    pub fn exited(&mut self) -> bool {
        !matches!(self.server.exit(), Ok(None))
    }

    /// The server is still the one started: it has not ended, its PID still
    /// has the launch's birth, and it still owns exactly one registered
    /// listener on the endpoint.
    pub fn revalidate(&mut self) -> Result<(), String> {
        match self.server.exit() {
            Ok(None) => {}
            Ok(Some(exit)) => return Err(exit_reason(exit)),
            Err(error) => {
                return Err(format!(
                    "foreground HDC server wait status was unresolved ({error})"
                ));
            }
        }
        if !self.server.same_birth() {
            return Err("managed HDC server process identity changed".into());
        }
        self.lease
            .revalidate()
            .map_err(|error| format!("managed HDC server listener identity changed: {error}"))
    }

    /// Swift `stop`: ends the server and collects what it wrote.
    pub fn stop(self) -> io::Result<ServerStop> {
        self.server.stop()
    }
}

/// Swift `HDCManagedProcessLaunch.matches`.
fn launch_matches(launch: &ServerLaunch, identity: &ServerIdentityReceipt) -> bool {
    launch.pid == identity.pid
        && launch.start_seconds == identity.start_seconds
        && launch.start_microseconds == identity.start_microseconds
        && launch.executable_path == identity.executable_path
        && launch.executable_sha256 == identity.executable_sha256
}

/// Swift `loopbackListenerIsReachable`: a listener exists; nothing about
/// what it is.
fn reachable(endpoint: SocketAddrV4) -> bool {
    TcpStream::connect_timeout(&SocketAddr::V4(endpoint), REACHABILITY_PROBE).is_ok()
}

/// What holds an endpoint a managed launch found occupied, as the
/// commandless proof can say it: a process of the configured executable that
/// this launch did not start (by its PID and generation), a listener of any
/// other executable, or one whose owner cannot be proved. Only read: nothing
/// is adopted, signalled or connected to beyond the reachability probe.
fn occupant(tool: &VerifiedTool, endpoint: SocketAddrV4) -> String {
    let holder = match LoopbackServerLease::acquire(tool, endpoint) {
        Ok(lease) => format!(
            "a server of the configured HDC executable that this launch did not start \
             listens there (pid {}, generation {})",
            lease.identity().pid,
            crate::lifecycle::generation(lease.identity())
                .map_or_else(|| "unknown".to_owned(), |generation| generation.to_string())
        ),
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            "a listener that is not the configured HDC executable holds it".to_owned()
        }
        Err(error) => format!("the owner of its listener cannot be proved ({error})"),
    };
    format!("managed HDC endpoint was not absent before the foreground launch: {holder}")
}

/// Swift `foregroundExitReason`.
fn exit_reason(exit: ServerExit) -> String {
    match exit {
        ServerExit::Exited(status) => format!("foreground HDC server exited with status {status}"),
        ServerExit::Signalled(signal) => {
            format!("foreground HDC server exited after signal {signal}")
        }
    }
}

fn exit_text(termination: ToolTermination) -> String {
    match termination {
        ToolTermination::Exited(status) => status.to_string(),
        _ => "unknown".into(),
    }
}
