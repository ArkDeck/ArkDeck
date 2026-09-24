//! The isolated owner's managed HDC server (TASK-XPA-016 R2), composed as
//! Swift's daemon composes `HeadlessHDCServerHost`: started before the
//! daemon serves, on the endpoint Swift's selector picks, ready and bound to
//! its own launch by the commandless identity proof (`ManagedHdcServer`).
//! Its startup facts answer `target.availability`'s tool leg, its launch
//! record feeds `runtime.hdc.status`, and the daemon stops it once it has
//! drained.
//!
//! A foreground-console-approved restart transfers dispatch ownership only
//! after the durable lifecycle chain and a fresh identity proof establish a
//! strictly newer server. An uncertain launch never falls back to the old
//! child. Neither an unrelated process on the endpoint nor an unproved
//! replacement may receive an HDC plan. The shared Supervisor supplies the
//! same ownership fallback to status and impact observations as Swift does.
//! The process owner exits 70 on an unexpected foreground-child exit so
//! launchd can rebuild the provider graph. Confirmed execution has Swift's
//! bounded expected-exit window; no uncertain replacement is adopted here.
//!
//! The replacement a confirmed restart proved outlives this Runtime unless
//! it is ended: `kill -r` starts it in a session of its own, as HDC does, so
//! it is no child here or in Swift. The daemon's stop ends it as it ends the
//! original child (TASK-XPA-014), only while a fresh proof still names that
//! very process, so a normal stop leaves the endpoint as a stop without a
//! restart does. An uncertain outcome's server, and whatever else holds the
//! endpoint, is never signalled. A start never adopts a server it finds on
//! the endpoint: it refuses before launching anything (`StartFailure::
//! Occupied`), so a replacement a crashed Runtime left keeps the next start
//! refused until that server ends.
use arkdeck_control::ManagedToolFacts;
use arkdeck_platform::{LoopbackServerLease, ServerStop, VerifiedTool, end_proved_process};
use arkdeck_provider_hdc::{
    CommandlessIdentity, DispatchFailure, EndpointSelection, HdcDispatch, HdcStatusObserver,
    ManagedHdcServer, ManagedLaunch, NativeSignature, ProcessDispatch, ProcessPlan, Receipt,
    StartBudget, StartFailure, StartupDiagnostics, StatusExecutable, SupervisedServer,
    SupervisorState, SystemManagedProcess, generation,
};
use serde_json::Value;
use std::io;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

#[derive(Default)]
pub(crate) struct ForegroundLifecycle {
    pub(crate) stopping: bool,
    pub(crate) expected_until: Option<Instant>,
}

impl ForegroundLifecycle {
    pub(crate) fn unexpected(&self, now: Instant) -> bool {
        !self.stopping && self.expected_until.is_none_or(|deadline| now > deadline)
    }
}

#[path = "managed_hdc_lifecycle.rs"]
mod lifecycle;

/// The managed server and the facts its startup established.
pub(crate) struct ManagedHdc {
    /// The running server; `None` once the daemon has stopped it.
    server: Mutex<Option<ManagedHdcServer>>,
    executable: StatusExecutable,
    startup: StartupDiagnostics,
    tool: VerifiedTool,
    supervisor: Mutex<Option<SupervisedServer>>,
    ownership: Mutex<DispatchOwnership>,
    foreground: Mutex<ForegroundLifecycle>,
}

/// A replacement is owned only after an audited restart and a fresh kernel
/// identity proof. A launch window with no terminal proof never falls back
/// to the original child, even if that child still appears to be running.
enum DispatchOwnership {
    Original,
    Pending,
    Replacement(LoopbackServerLease),
    Unknown,
    Stopped,
}

impl ManagedHdc {
    /// Swift `HeadlessHDCServerHost.start`: the verified tool launched as
    /// `hdc -s <endpoint> -m`, reachable, `checkserver` agreeing, and the
    /// listener's owner proved to be this launch; the startup diagnostics are
    /// that `checkserver`'s versions and the selection. `configured_path` is
    /// the path the tool was configured by, as the status reports it.
    pub(crate) fn start(
        tool: &VerifiedTool,
        configured_path: &str,
        selection: EndpointSelection,
    ) -> Result<Self, String> {
        let retained = VerifiedTool::open(tool.path(), tool.sha256()).map_err(|e| e.to_string())?;
        let server = ManagedHdcServer::start(tool, selection.endpoint, StartBudget::default())
            .map_err(|failure| match failure {
                StartFailure::Occupied(reason) => format!(
                    "the managed HDC server did not start: {reason}; nothing was launched, and \
                     that server is neither adopted nor stopped"
                ),
                StartFailure::Refused(error) => {
                    format!("the managed HDC server launch was refused: {error}")
                }
                StartFailure::Exited(reason)
                | StartFailure::NotReady(reason)
                | StartFailure::Unbound(reason) => {
                    format!("the managed HDC server did not start: {reason}")
                }
            })?;
        let startup = StartupDiagnostics {
            executable_sha256: tool.sha256().to_owned(),
            client_version: server.check().client_version.clone(),
            server_version: server.check().server_version.clone(),
            endpoint: selection.endpoint.to_string(),
            endpoint_source: selection.source.to_owned(),
        };
        let generation = generation(server.identity())
            .and_then(|g| i64::try_from(g).ok())
            .ok_or("the managed HDC server generation is unrepresentable")?;
        let supervised = SupervisedServer {
            endpoint: startup.endpoint.clone(),
            healthy: true,
            generation,
            ark_deck_managed: true,
        };
        Ok(Self {
            server: Mutex::new(Some(server)),
            executable: StatusExecutable {
                path: configured_path.to_owned(),
                sha256: tool.sha256().to_owned(),
            },
            startup,
            tool: retained,
            supervisor: Mutex::new(Some(supervised)),
            ownership: Mutex::new(DispatchOwnership::Original),
            foreground: Mutex::default(),
        })
    }

    /// The configured executable, by the path it was configured with.
    pub(crate) fn executable(&self) -> &StatusExecutable {
        &self.executable
    }

    /// The endpoint the server was started on, as its selection spells it.
    pub(crate) fn endpoint(&self) -> &str {
        &self.startup.endpoint
    }

    /// Only the process composition arms this crash boundary. An in-process
    /// test owning a server must not terminate its own runner.
    pub(crate) fn monitor_foreground_exit(self: &Arc<Self>) -> io::Result<()> {
        let managed = Arc::downgrade(self);
        std::thread::Builder::new()
            .name("hdc-foreground-exit".into())
            .spawn(move || loop {
                let Some(managed) = managed.upgrade() else { return };
                match managed.foreground_exit() {
                    Some(true) => {
                        eprintln!("arkdeck-agentd: foreground HDC exited unexpectedly; Runtime restart required");
                        std::process::exit(70);
                    }
                    Some(false) => return,
                    None => {}
                }
                drop(managed);
                std::thread::sleep(Duration::from_millis(50));
            })?;
        Ok(())
    }

    /// None while running; once ended, whether the original child's exit is
    /// unexpected. Replacement processes are not children observed by this
    /// monitor, matching the accepted Swift lifecycle.
    pub(crate) fn foreground_exit(&self) -> Option<bool> {
        let Ok(lifecycle) = self.foreground.lock() else {
            return Some(true);
        };
        if lifecycle.stopping {
            return Some(false);
        }
        let Ok(mut server) = self.server.lock() else {
            return Some(true);
        };
        let Some(server) = server.as_mut() else {
            return Some(false);
        };
        server
            .exited()
            .then(|| lifecycle.unexpected(Instant::now()))
    }

    /// Called after the durable launch marker, with the launch lease held.
    /// Swift allows the original foreground child's exit for twenty seconds.
    fn expect_confirmed_exit(&self) -> Result<(), String> {
        let mut lifecycle = self
            .foreground
            .lock()
            .map_err(|_| "HDC foreground lifecycle is unavailable")?;
        lifecycle.expected_until = Instant::now().checked_add(Duration::from_secs(20));
        Ok(())
    }

    /// Swift `activeLaunch()`: the spawn record while the server runs and is
    /// not being stopped.
    pub(crate) fn active_launch(&self) -> Option<ManagedLaunch> {
        let mut server = self.server.lock().ok()?;
        let server = server.as_mut()?;
        if server.exited() {
            return None;
        }
        let launch = server.launch();
        Some(ManagedLaunch {
            pid: launch.pid,
            start_seconds: launch.start_seconds,
            start_microseconds: launch.start_microseconds,
            executable_path: launch.executable_path.to_string_lossy().into_owned(),
            executable_sha256: launch.executable_sha256.clone(),
            arguments: launch
                .arguments
                .iter()
                .map(|argument| argument.to_string_lossy().into_owned())
                .collect(),
        })
    }

    /// Swift `statusObserver(daemonVersion:)` and its snapshot, with the
    /// production identity observer, signature inspection, process
    /// verification and the shared Supervisor. As a bare binary it has no
    /// bundle version (Swift's SwiftPM daemon reports none either).
    pub(crate) fn status(&self, now_utc: &dyn Fn() -> String) -> Value {
        let launches = || self.active_launch();
        HdcStatusObserver::new(
            self.executable.clone(),
            self.startup.clone(),
            None,
            &launches,
            Some(self),
            &CommandlessIdentity::default(),
            &NativeSignature,
            &SystemManagedProcess,
            now_utc,
        )
        .snapshot()
    }

    /// Swift `hdcRuntimeDiagnostics` as `target.availability` encodes it: set
    /// at startup and never refreshed.
    pub(crate) fn tool_facts(&self) -> ManagedToolFacts {
        ManagedToolFacts {
            tool_sha256: self.startup.executable_sha256.clone(),
            client_version: self.startup.client_version.clone(),
            server_version: self.startup.server_version.clone(),
            endpoint_source: self.startup.endpoint_source.clone(),
        }
    }

    /// The original launch or its durably confirmed replacement still has
    /// the exact retained birth and listener identity.
    fn current(&self) -> Result<(), String> {
        let ownership = self
            .ownership
            .lock()
            .map_err(|_| "HDC dispatch ownership is unavailable")?;
        self.revalidate_ownership(&ownership)
    }

    fn revalidate_ownership(&self, ownership: &DispatchOwnership) -> Result<(), String> {
        match ownership {
            DispatchOwnership::Replacement(lease) => {
                self.tool.revalidate().map_err(|e| e.to_string())?;
                return lease.revalidate().map_err(|e| e.to_string());
            }
            DispatchOwnership::Original => {}
            DispatchOwnership::Stopped => return Err("the managed HDC server was stopped".into()),
            _ => return Err("HDC lifecycle ownership requires reconciliation".into()),
        }
        let mut server = self
            .server
            .lock()
            .map_err(|_| "the managed HDC server state is unavailable".to_owned())?;
        match server.as_mut() {
            Some(server) => server.revalidate(),
            None => Err("the managed HDC server was stopped".into()),
        }
    }

    /// Swift `HeadlessHDCServerHost.stop`: TERM to the server's process
    /// group, KILL after its grace, and what it wrote. Once only.
    ///
    /// Beyond Swift, it also ends the replacement a confirmed restart proved:
    /// Swift's stop reaches only its original child, so after a restart it
    /// left the listener its own contract says a stop drains
    /// (`testColdStartReturnsOnlyAfterTheForegroundListenerIsReachable`), and
    /// the next start could not launch beside it.
    pub(crate) fn stop(&self) -> Option<Stop> {
        self.foreground.lock().ok()?.stopping = true;
        let ownership = std::mem::replace(
            &mut *self.ownership.lock().ok()?,
            DispatchOwnership::Stopped,
        );
        *self.supervisor.lock().ok()? = None;
        let server = self.server.lock().ok()?.take()?;
        let server = server.stop();
        let replacement = match ownership {
            DispatchOwnership::Replacement(lease) => self.end_replacement(&lease),
            DispatchOwnership::Pending | DispatchOwnership::Unknown => ReplacementStop::Uncertain,
            DispatchOwnership::Original | DispatchOwnership::Stopped => ReplacementStop::None,
        };
        Some(Stop {
            server,
            replacement,
        })
    }

    /// The replacement a confirmed restart proved is this Runtime's managed
    /// server, as its original child was (REQ-HDC-003 forbids an automatic
    /// stop only of an external or unknown server), so it is ended as that
    /// child is — SIGTERM, then SIGKILL after the same grace — but only while
    /// the tool still verifies, the retained proof still holds, and a fresh
    /// two-scan proof names exactly that process as the endpoint's owner.
    /// Anything else there is left as it is.
    fn end_replacement(&self, lease: &LoopbackServerLease) -> ReplacementStop {
        let proved = || -> Result<(), String> {
            let endpoint = self
                .endpoint()
                .parse()
                .map_err(|_| "the selected endpoint is unavailable".to_owned())?;
            self.tool.revalidate().map_err(|error| error.to_string())?;
            lease.revalidate().map_err(|error| error.to_string())?;
            let fresh =
                LoopbackServerLease::acquire(&self.tool, endpoint).map_err(|e| e.to_string())?;
            if fresh.identity() != lease.identity() {
                return Err("another process now owns the endpoint".into());
            }
            Ok(())
        };
        let pid = lease.identity().pid;
        if let Err(reason) = proved() {
            return ReplacementStop::Unproved(format!(
                "the replacement HDC server a confirmed restart proved (pid {pid}) is no longer \
                 proved ({reason}); nothing was signalled"
            ));
        }
        // Ended politely, killed, or gone on its own since the proof.
        match end_proved_process(lease.identity(), TERMINATION_GRACE, KILL_GRACE) {
            Ok(_) => ReplacementStop::Ended,
            Err(error) => ReplacementStop::Survived(format!(
                "the replacement HDC server a confirmed restart proved (pid {pid}) did not end: \
                 {error}"
            )),
        }
    }
}

/// Swift's process-group drain: the grace SIGTERM has before SIGKILL, and
/// how long the end after SIGKILL is waited for.
const TERMINATION_GRACE: Duration = Duration::from_millis(250);
const KILL_GRACE: Duration = Duration::from_secs(1);

/// What the daemon's stop ended.
#[derive(Debug)]
pub(crate) struct Stop {
    /// The original foreground child, as its stop collected it.
    pub(crate) server: io::Result<ServerStop>,
    /// What became of a server a confirmed restart started.
    pub(crate) replacement: ReplacementStop,
}

/// What the daemon's stop did about a server a confirmed restart started.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum ReplacementStop {
    /// No confirmed restart transferred ownership in this Runtime.
    None,
    /// The proved replacement has ended.
    Ended,
    /// A restart's outcome was uncertain: whatever it left is unknown and
    /// was not signalled (REQ-HDC-003).
    Uncertain,
    /// The endpoint no longer holds the proved replacement, or the proof
    /// could not be read again: nothing was signalled.
    Unproved(String),
    /// Signalled, it did not end.
    Survived(String),
}

impl SupervisorState for ManagedHdc {
    fn state(&self, endpoint: &str) -> Option<SupervisedServer> {
        self.supervisor
            .lock()
            .ok()?
            .as_ref()
            .filter(|state| state.endpoint == endpoint)
            .cloned()
    }
}

/// The isolated owner's development HDC: the process dispatch every
/// device-bound plan takes and, when the owner started one, the managed
/// server that dispatch addresses.
pub(crate) struct DevelopmentHdc {
    dispatch: ProcessDispatch,
    managed: Option<Arc<ManagedHdc>>,
}

impl DevelopmentHdc {
    pub(crate) fn new(dispatch: ProcessDispatch, managed: Option<Arc<ManagedHdc>>) -> Self {
        Self { dispatch, managed }
    }

    pub(crate) fn tool_sha256(&self) -> &str {
        self.dispatch.tool_sha256()
    }

    /// The executable still verifies, without launching anything.
    pub(crate) fn tool_identity_current(&self) -> bool {
        self.dispatch.tool_identity_current()
    }

    pub(crate) fn managed(&self) -> Option<&ManagedHdc> {
        self.managed.as_deref()
    }
}

impl HdcDispatch for DevelopmentHdc {
    fn mutation_identity_current(&self) -> bool {
        self.dispatch.mutation_identity_current()
            && self
                .managed
                .as_ref()
                .is_none_or(|managed| managed.current().is_ok())
    }

    /// Swift's dispatcher checks only the executable's identity; with a
    /// managed server this also refuses, before anything runs, once that
    /// server is not the one launched.
    fn dispatch(&self, plan: &ProcessPlan) -> Result<Receipt, DispatchFailure> {
        if let Some(managed) = &self.managed {
            managed.current().map_err(|reason| {
                DispatchFailure::Refused(format!("dispatch refused: {reason}"))
            })?;
        }
        self.dispatch.dispatch(plan)
    }
}
