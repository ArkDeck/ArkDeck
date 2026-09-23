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
struct ForegroundLifecycle {
    stopping: bool,
    expected_until: Option<Instant>,
}

impl ForegroundLifecycle {
    fn unexpected(&self, now: Instant) -> bool {
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
    fn foreground_exit(&self) -> Option<bool> {
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::{Ipv4Addr, SocketAddrV4};

    mod loopback_ports {
        include!("../../../tests/support/loopback_ports.rs");
    }
    mod fake_hdc_servers {
        include!("../../../tests/support/fake_hdc_servers.rs");
    }
    use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
    use std::path::PathBuf;
    use std::time::{Duration, Instant};

    const FAKE_HDC: &str = include_str!("../../../tests/fixtures/managed-hdc/fake-hdc.c");

    #[test]
    fn foreground_exit_window_is_bounded_and_stop_is_expected() {
        let now = Instant::now();
        let mut lifecycle = ForegroundLifecycle::default();
        assert!(lifecycle.unexpected(now));
        lifecycle.expected_until = Some(now + Duration::from_secs(20));
        assert!(!lifecycle.unexpected(now));
        assert!(!lifecycle.unexpected(now + Duration::from_secs(20)));
        assert!(lifecycle.unexpected(now + Duration::from_secs(20) + Duration::from_nanos(1)));
        lifecycle.stopping = true;
        assert!(!lifecycle.unexpected(now + Duration::from_secs(30)));
    }

    /// The fake's own directory. Dropped, even on a panic, it ends every
    /// server the fake's `kill -r` started -- nobody's child, which would
    /// otherwise listen on after the directory is gone -- then removes it.
    struct Fake(PathBuf);
    impl Drop for Fake {
        fn drop(&mut self) {
            fake_hdc_servers::tear_down(&self.0, &self.0.join("hdc"));
        }
    }

    /// The fake `hdc`, compiled into its own owner-only directory.
    fn fake() -> (Fake, VerifiedTool) {
        fake_options(false, false)
    }

    fn fake_options(restart: bool, fail: bool) -> (Fake, VerifiedTool) {
        fake_options_with_inventory(restart, fail, false)
    }

    fn fake_options_with_inventory(restart: bool, fail: bool, empty: bool) -> (Fake, VerifiedTool) {
        let directory = PathBuf::from(format!(
            "/private/tmp/arkdeck-managed-hdc-unit-{:032x}",
            u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap())
        ));
        std::fs::DirBuilder::new()
            .mode(0o700)
            .create(&directory)
            .unwrap();
        let fake = Fake(directory);
        let directory = &fake.0;
        let source = directory.join("fake-hdc.c");
        std::fs::write(&source, FAKE_HDC).unwrap();
        let binary = directory.join("hdc");
        let mut compiler = std::process::Command::new("cc");
        compiler.arg("-O0").arg("-o").arg(&binary).arg(&source);
        if restart {
            compiler
                .arg(format!("-DRESTART_DIR=\"{}\"", directory.display()))
                .arg(format!("-DSELF_PATH=\"{}\"", binary.display()))
                .arg(format!("-DRECORD_CALLS=\"{}/calls\"", directory.display()))
                .arg(format!("-DOWNER_PID={}", std::process::id()));
        }
        if fail {
            compiler.arg("-DFAIL_RESTART");
        }
        if empty {
            compiler.arg("-DLIST_EMPTY");
        }
        let output = compiler.output().unwrap();
        assert!(output.status.success(), "{output:?}");
        std::fs::set_permissions(&binary, std::fs::Permissions::from_mode(0o700)).unwrap();
        let digest = arkdeck_contract::sha256_hex(&std::fs::read(&binary).unwrap());
        let tool = VerifiedTool::open(&binary, &digest).unwrap();
        (fake, tool)
    }

    fn plan() -> ProcessPlan {
        ProcessPlan {
            arguments: vec!["list".into(), "targets".into()],
            timeout: Duration::from_secs(10),
            capture_bytes: 4096,
        }
    }

    /// Whether anything listens on the endpoint.
    fn reachable(endpoint: SocketAddrV4) -> bool {
        std::net::TcpStream::connect_timeout(&endpoint.into(), Duration::from_millis(100)).is_ok()
    }

    /// How many `-m` servers of a recording fake ever ran: those a start
    /// launched and those its `kill -r` started.
    fn launches(fake: &Fake) -> usize {
        std::fs::read_to_string(fake.0.join("calls"))
            .unwrap_or_default()
            .lines()
            .filter(|line| line.ends_with(" -m"))
            .count()
    }

    /// The servers the fake's `kill -r` started, by PID.
    fn recorded_servers(fake: &Fake) -> Vec<i32> {
        std::fs::read_to_string(fake.0.join("servers"))
            .unwrap_or_default()
            .lines()
            .map(|line| line.parse().unwrap())
            .collect()
    }

    /// Ends whatever server of this build listens on the endpoint, as an
    /// operator's `hdc -s <endpoint> kill` would (the fake's `stop` marker),
    /// then clears the marker so that the next server of this build runs.
    fn hdc_kill(fake: &Fake, endpoint: SocketAddrV4) {
        let status = std::process::Command::new(fake.0.join("hdc"))
            .args(["-s", &endpoint.to_string(), "kill"])
            .status()
            .unwrap();
        assert!(status.success());
        std::fs::remove_file(fake.0.join("stop")).unwrap();
        assert!(!reachable(endpoint), "the server did not end");
    }

    /// The managed server a daemon start composes on `endpoint`.
    fn daemon_start(tool: &VerifiedTool, endpoint: SocketAddrV4) -> Result<ManagedHdc, String> {
        ManagedHdc::start(
            tool,
            &tool.path().to_string_lossy(),
            EndpointSelection {
                endpoint,
                source: "inheritedEnvironment",
            },
        )
    }

    /// A synthetic trusted impact of the managed server as it now is. The
    /// fake's digest proves no registered HDC, so no production source
    /// observes it; only this test binary composes one.
    struct Impacts(arkdeck_hoststore::ImpactReading);
    impl arkdeck_hoststore::ImpactSource for Impacts {
        fn endpoint_reference(&self) -> String {
            self.0.impact.value()["serverEndpointRef"]
                .as_str()
                .unwrap()
                .into()
        }
        fn read_impact(&self) -> Result<arkdeck_hoststore::ImpactReading, String> {
            Ok(self.0.clone())
        }
    }

    /// The durable control-action and Job owners a restart needs.
    type Owners = (
        arkdeck_hoststore::HdcControlActions,
        arkdeck_hoststore::JobStore,
    );

    /// The owners, in the fake's directory.
    fn owners(fake: &Fake) -> Owners {
        let root = arkdeck_platform::HostDirectory::open(&fake.0).unwrap();
        root.private_child("actions").unwrap();
        root.private_child("jobs").unwrap();
        (
            arkdeck_hoststore::HdcControlActions::open(
                &fake.0.join("actions"),
                arkdeck_hoststore::OwnerContext::production().unwrap(),
            )
            .unwrap(),
            arkdeck_hoststore::JobStore::open_owner(&fake.0.join("jobs")).unwrap(),
        )
    }

    /// One restart of the managed server, confirmed as a foreground console
    /// confirms it, through the real durable owner, lifecycle driver and
    /// verified runner: its terminal projection.
    fn confirmed_restart(
        managed: &ManagedHdc,
        tool: &VerifiedTool,
        (owner, jobs): &Owners,
        request: &str,
    ) -> Value {
        use serde_json::json;
        let before = managed.state(managed.endpoint()).unwrap();
        let endpoint_ref = arkdeck_provider_hdc::server_endpoint_ref(managed.endpoint());
        let source = Impacts(arkdeck_hoststore::ImpactReading {
            impact: arkdeck_hoststore::Impact::new(json!({
                "serverEndpointRef":endpoint_ref,"endpoint":managed.endpoint(),"serverOwnership":"arkDeckManaged",
                "serverGeneration":before.generation.to_string(),"serverHealth":"healthy","serverVersion":"3.2.0d",
                "tool":{"reference":null,"executablePath":tool.path(),"source":"runtimeConfiguration","sha256":tool.sha256(),"signature":null,"version":"3.2.0d","trust":"unverified"},
                "affectedTargetIds":[],"affectedJobIds":[],"detectedOtherClientIds":[],"otherClientsMayExist":true,"affectedDeviceObservations":[],
                "criticalJobGate":{"state":"clear","blocking":[],"reasonCode":null},
                "interruption":{"kind":"hdcEndpointUnavailable","affectsAllParticipants":true},"recovery":{"kind":"statusThenReconcile","replayAllowed":false}
            }).as_object().unwrap().clone()).unwrap(),
            relations: vec![],
            blocker: None,
        });
        let preview = owner
            .preview(
                json!({"action":"restart","actionRequestId":request,"serverEndpointRef":endpoint_ref,
                    "expectedServerGeneration":before.generation.to_string()})
                .as_object()
                .unwrap(),
                &source,
            )
            .unwrap();
        let id = preview["controlActionId"].as_str().unwrap();
        let waiting = owner
            .restart(
                id,
                preview["preview"]["previewId"].as_str().unwrap(),
                preview["preview"]["previewDigest"].as_str().unwrap(),
                &source,
            )
            .unwrap();
        let human = &waiting["humanAction"];
        let reference = human["resumeReference"].as_str().unwrap();
        let challenge = owner
            .issue_interactive_challenge(human["actionId"].as_str().unwrap(), reference)
            .unwrap();
        owner
            .consume_interactive_challenge(
                id,
                reference,
                challenge["challenge"].as_str().unwrap(),
                jobs,
                &source,
                managed,
            )
            .unwrap()
    }

    /// Dispatch addresses the managed server only while it is the one
    /// launched: once it has ended, a plan is refused before anything runs,
    /// the status no longer holds its launch, and the daemon's stop is a
    /// no-op after the first.
    #[test]
    fn no_plan_is_dispatched_once_the_managed_server_is_not_the_one_launched() {
        let (_fake, tool) = fake();
        let port = loopback_ports::free_port();
        let selection = EndpointSelection {
            endpoint: SocketAddrV4::new(Ipv4Addr::LOCALHOST, port),
            source: "inheritedEnvironment",
        };
        let managed =
            Arc::new(ManagedHdc::start(&tool, &tool.path().to_string_lossy(), selection).unwrap());
        assert_eq!(
            managed.tool_facts(),
            ManagedToolFacts {
                tool_sha256: tool.sha256().to_owned(),
                client_version: "3.2.0d".into(),
                server_version: "3.2.0d".into(),
                endpoint_source: "inheritedEnvironment".into(),
            }
        );
        let launch = managed.active_launch().expect("a running server");
        assert_eq!(launch.arguments, ["-s", &format!("127.0.0.1:{port}"), "-m"]);
        let port_text = port.to_string();
        let hdc = DevelopmentHdc::new(
            ProcessDispatch::new(
                VerifiedTool::open(tool.path(), tool.sha256()).unwrap(),
                Some(&port_text),
            ),
            Some(Arc::clone(&managed)),
        );
        // The fake answers anything but its server as unregistered output.
        let receipt = hdc.dispatch(&plan()).unwrap();
        assert_eq!(receipt.exit_status, 23);
        assert!(hdc.mutation_identity_current());

        let killed = std::process::Command::new("/bin/kill")
            .args(["-KILL", &launch.pid.to_string()])
            .status()
            .unwrap();
        assert!(killed.success());
        let deadline = Instant::now() + Duration::from_secs(10);
        while managed.active_launch().is_some() {
            assert!(Instant::now() < deadline, "the server's end was not seen");
            std::thread::sleep(Duration::from_millis(10));
        }
        let Err(DispatchFailure::Refused(reason)) = hdc.dispatch(&plan()) else {
            panic!("a plan was dispatched past the managed server's end");
        };
        assert_eq!(
            reason,
            "dispatch refused: foreground HDC server exited after signal 9"
        );
        assert_eq!(managed.foreground_exit(), Some(true));
        assert!(!hdc.mutation_identity_current());
        let status = managed.status(&|| "2026-09-19T00:00:00Z".to_owned());
        assert_eq!(status["executableSHA256"], tool.sha256());
        assert!(managed.stop().is_some());
        assert!(managed.stop().is_none());
        assert_eq!(managed.foreground_exit(), Some(false));
        let Err(DispatchFailure::Refused(reason)) = hdc.dispatch(&plan()) else {
            panic!("a plan was dispatched past the managed server's stop");
        };
        assert_eq!(
            reason,
            "dispatch refused: the managed HDC server was stopped"
        );
    }

    /// Real Host/control routing and isolated fake processes, including durable
    /// audit failure after launch. This is not real-device evidence.
    #[test]
    fn host_never_claims_zero_dispatch_after_lifecycle_audit_failure() {
        use arkdeck_contract::{CONTRACT_IDENTITY, PROTOCOL_VERSION, WireError};
        use arkdeck_control::Control;
        use arkdeck_hoststore::{
            AgentExecutionStore, ControlActionResources, HdcControlActions, HumanActionResources,
            Impact, ImpactReading, ImpactSource, JobStore, OwnerContext, TargetStore,
        };
        use serde_json::json;
        use std::sync::atomic::{AtomicBool, Ordering};
        struct Source(ImpactReading);
        impl ImpactSource for Source {
            fn endpoint_reference(&self) -> String {
                self.0.impact.value()["serverEndpointRef"]
                    .as_str()
                    .unwrap()
                    .into()
            }
            fn read_impact(&self) -> Result<ImpactReading, String> {
                Ok(self.0.clone())
            }
        }
        for stage in ["launchWindowEntered", "outcome"] {
            for recovery_fails in [false, true] {
                let (fake, tool) = fake_options_with_inventory(true, false, true);
                let endpoint = SocketAddrV4::new(Ipv4Addr::LOCALHOST, loopback_ports::free_port());
                let managed = Arc::new(
                    ManagedHdc::start(
                        &tool,
                        &tool.path().to_string_lossy(),
                        EndpointSelection {
                            endpoint,
                            source: "inheritedEnvironment",
                        },
                    )
                    .unwrap(),
                );
                let root = arkdeck_platform::HostDirectory::open(&fake.0).unwrap();
                for directory in ["actions", "jobs", "targets", "agents", "human", "controls"] {
                    root.private_child(directory).unwrap();
                }
                let records = fake.0.join("actions/records");
                let mut context = OwnerContext::production().unwrap();
                let uuid = context.uuid;
                let injected = Arc::new(AtomicBool::new(false));
                let seen = injected.clone();
                context.uuid = Box::new(move || {
                    let reached = std::fs::read_dir(&records)
                        .unwrap()
                        .filter_map(Result::ok)
                        .filter_map(|entry| std::fs::read(entry.path()).ok())
                        .filter_map(|bytes| serde_json::from_slice::<Value>(&bytes).ok())
                        .any(|record| {
                            record["lifecycleAudit"]
                                .as_array()
                                .and_then(|events| events.last())
                                .is_some_and(|event| event["kind"] == stage)
                        });
                    if reached && (recovery_fails || !seen.load(Ordering::SeqCst)) {
                        seen.store(true, Ordering::SeqCst);
                        if recovery_fails {
                            std::fs::set_permissions(
                                &records,
                                std::fs::Permissions::from_mode(0o500),
                            )
                            .unwrap();
                            return uuid();
                        }
                        return Err(WireError {
                            code: "recordUnreadable".into(),
                            message: "injected durable audit identity failure".into(),
                            // Exercise sanitization of read-route error defaults.
                            details: Some(serde_json::Map::from_iter([
                                ("phase".into(), json!("preAdmission")),
                                ("newDispatchCount".into(), json!(0)),
                            ])),
                        });
                    }
                    uuid()
                });
                let owner = HdcControlActions::open(&fake.0.join("actions"), context).unwrap();
                let mut host = crate::host::Host::from_environment()
                    .with_targets(TargetStore::open(&fake.0.join("targets")).unwrap())
                    .with_jobs(JobStore::open_owner(&fake.0.join("jobs")).unwrap())
                    .with_agent_executions(
                        AgentExecutionStore::open(&fake.0.join("agents")).unwrap(),
                    )
                    .with_human_actions(HumanActionResources::open(&fake.0.join("human")).unwrap())
                    .with_control_actions(
                        ControlActionResources::open(&fake.0.join("controls"))
                            .unwrap()
                            .with_hdc(owner),
                    )
                    .with_managed_development_hdc(
                        ProcessDispatch::new(
                            VerifiedTool::open(tool.path(), tool.sha256()).unwrap(),
                            Some(&endpoint.port().to_string()),
                        ),
                        managed.clone(),
                    );
                // This injection exists only in the unit-test binary. The fake
                // executable cannot qualify as a registered HDC identity.
                host.test_hdc_impact = Some(Box::new(Source(ImpactReading {
                    impact: Impact::new(json!({
                        "serverEndpointRef":arkdeck_provider_hdc::server_endpoint_ref(&endpoint.to_string()),
                        "endpoint":endpoint.to_string(),"serverOwnership":"arkDeckManaged",
                        "serverGeneration":managed.state(&endpoint.to_string()).unwrap().generation.to_string(),
                        "serverHealth":"healthy","serverVersion":"3.2.0d",
                        "tool":{"reference":null,"executablePath":tool.path(),"source":"runtimeConfiguration","sha256":tool.sha256(),"signature":null,"version":"3.2.0d","trust":"unverified"},
                        "affectedTargetIds":[],"affectedJobIds":[],"detectedOtherClientIds":[],"otherClientsMayExist":true,"affectedDeviceObservations":[],
                        "criticalJobGate":{"state":"clear","blocking":[],"reasonCode":null},
                        "interruption":{"kind":"hdcEndpointUnavailable","affectsAllParticipants":true},
                        "recovery":{"kind":"statusThenReconcile","replayAllowed":false}
                    }).as_object().unwrap().clone()).unwrap(), relations:vec![], blocker:None,
                })));
                let control = Control::new(host).unwrap();
                let send = |method: &str, params: Value| -> Value {
                    let request = serde_json::to_vec(&json!({"protocolVersion":PROTOCOL_VERSION,
                        "contractIdentity":CONTRACT_IDENTITY,"id":"audit-fault","method":method,"params":params})).unwrap();
                    serde_json::from_slice(
                        control
                            .handle_frame_with_console(&request, true)
                            .trim_ascii_end(),
                    )
                    .unwrap()
                };
                let ready = send(
                    "runtime.hdc.impact-preview",
                    json!({"action":"restart", "actionRequestId":"audit-fault",
                    "serverEndpointRef":arkdeck_provider_hdc::server_endpoint_ref(&endpoint.to_string()),
                    "expectedServerGeneration":managed.state(&endpoint.to_string()).unwrap().generation.to_string()}),
                );
                assert_eq!(ready["result"]["state"], "previewReady", "{ready}");
                let action = &ready["result"];
                let waiting = send(
                    "runtime.hdc.restart",
                    json!({"controlAction":action["controlActionId"],
                    "previewId":action["preview"]["previewId"],"previewDigest":action["preview"]["previewDigest"]}),
                );
                assert_eq!(
                    waiting["result"]["state"], "awaitingImpactApproval",
                    "{waiting}"
                );
                let human = &waiting["result"]["humanAction"];
                let mut params = json!({"humanAction":human["actionId"],"resumeReference":human["resumeReference"]});
                let challenge = send("human-action.resume", params.clone());
                assert_eq!(challenge["ok"], true, "{challenge}");
                params["challengeResponse"] = challenge["result"]["challenge"].clone();
                let failed = send("human-action.resume", params.clone());
                // The isolated replacement is ended by `fake`'s drop, even if
                // an assertion fails.
                assert!(injected.load(Ordering::SeqCst), "{failed}");
                if recovery_fails {
                    assert_eq!(failed["error"]["code"], "recordUnreadable", "{failed}");
                    assert!(failed["error"].get("details").is_none(), "{failed}");
                    assert!(
                        failed["error"]["message"]
                            .as_str()
                            .unwrap()
                            .contains(action["controlActionId"].as_str().unwrap())
                    );
                    std::fs::set_permissions(
                        fake.0.join("actions/records"),
                        std::fs::Permissions::from_mode(0o700),
                    )
                    .unwrap();
                } else {
                    assert_eq!(failed["ok"], true, "{failed}");
                    assert_eq!(failed["result"]["state"], "outcomeUnknown");
                    assert_eq!(failed["result"]["dispatchCount"], 1);
                    assert_eq!(
                        failed["result"]["controlActionId"],
                        action["controlActionId"]
                    );
                }
                assert_eq!(send("human-action.resume", params)["ok"], false);
                let calls = std::fs::read_to_string(fake.0.join("calls")).unwrap();
                assert_eq!(
                    calls
                        .lines()
                        .filter(|line| line.ends_with(" kill -r"))
                        .count(),
                    1
                );
                // The server this uncertain restart left is unknown: the stop
                // signals nothing but the original child, and a new start
                // neither launches beside that server nor adopts it.
                let left = LoopbackServerLease::acquire(&tool, endpoint).unwrap();
                assert_eq!(recorded_servers(&fake), [left.identity().pid]);
                assert_eq!(
                    managed.stop().unwrap().replacement,
                    ReplacementStop::Uncertain
                );
                left.revalidate().unwrap();
                let launched = launches(&fake);
                let refused = daemon_start(&tool, endpoint)
                    .err()
                    .expect("a start beside the server an uncertain restart left");
                assert!(
                    refused.contains(&format!("(pid {}, generation", left.identity().pid)),
                    "{refused}"
                );
                assert_eq!(launches(&fake), launched);
                left.revalidate().unwrap();
            }
        }
    }

    /// Isolated process exercise of the production owner -> driver -> verified
    /// runner -> replacement dispatch chain. The impact source is synthetic;
    /// this is not registered HDC or real-device evidence.
    #[test]
    fn confirmed_restart_transfers_dispatch_only_after_terminal_identity_proof() {
        use arkdeck_hoststore::{
            HdcControlActions, Impact, ImpactReading, ImpactSource, JobStore, OwnerContext,
        };
        use serde_json::json;
        struct Source(ImpactReading);
        impl ImpactSource for Source {
            fn endpoint_reference(&self) -> String {
                self.0.impact.value()["serverEndpointRef"]
                    .as_str()
                    .unwrap()
                    .into()
            }
            fn read_impact(&self) -> Result<ImpactReading, String> {
                Ok(self.0.clone())
            }
        }
        for failed in [false, true] {
            // `fake`, dropped last, ends every replacement this turn starts.
            let (fake, tool) = fake_options(true, failed);
            let port = loopback_ports::free_port();
            let endpoint = SocketAddrV4::new(Ipv4Addr::LOCALHOST, port);
            let managed = Arc::new(
                ManagedHdc::start(
                    &tool,
                    &tool.path().to_string_lossy(),
                    EndpointSelection {
                        endpoint,
                        source: "inheritedEnvironment",
                    },
                )
                .unwrap(),
            );
            let root = arkdeck_platform::HostDirectory::open(&fake.0).unwrap();
            root.private_child("actions").unwrap();
            root.private_child("jobs").unwrap();
            let owner = HdcControlActions::open(
                &fake.0.join("actions"),
                OwnerContext::production().unwrap(),
            )
            .unwrap();
            let jobs = JobStore::open_owner(&fake.0.join("jobs")).unwrap();
            let hdc = DevelopmentHdc::new(
                ProcessDispatch::new(
                    VerifiedTool::open(tool.path(), tool.sha256()).unwrap(),
                    Some(&port.to_string()),
                ),
                Some(managed.clone()),
            );
            for turn in 0..if failed { 1 } else { 2 } {
                let before = managed.state(managed.endpoint()).unwrap();
                let endpoint_ref = arkdeck_provider_hdc::server_endpoint_ref(managed.endpoint());
                let source = Source(ImpactReading { impact:Impact::new(json!({
                    "serverEndpointRef":endpoint_ref,"endpoint":managed.endpoint(),"serverOwnership":"arkDeckManaged",
                    "serverGeneration":before.generation.to_string(),"serverHealth":"healthy","serverVersion":"3.2.0d",
                    "tool":{"reference":null,"executablePath":tool.path(),"source":"runtimeConfiguration","sha256":tool.sha256(),"signature":null,"version":"3.2.0d","trust":"unverified"},
                    "affectedTargetIds":[],"affectedJobIds":[],"detectedOtherClientIds":[],"otherClientsMayExist":true,"affectedDeviceObservations":[],
                    "criticalJobGate":{"state":"clear","blocking":[],"reasonCode":null},
                    "interruption":{"kind":"hdcEndpointUnavailable","affectsAllParticipants":true},"recovery":{"kind":"statusThenReconcile","replayAllowed":false}
                }).as_object().unwrap().clone()).unwrap(),relations:vec![],blocker:None });
                let preview = owner.preview(json!({"action":"restart","actionRequestId":format!("managed-restart-{turn}"),"serverEndpointRef":endpoint_ref,"expectedServerGeneration":before.generation.to_string()}).as_object().unwrap(), &source).unwrap();
                let id = preview["controlActionId"].as_str().unwrap();
                let waiting = owner
                    .restart(
                        id,
                        preview["preview"]["previewId"].as_str().unwrap(),
                        preview["preview"]["previewDigest"].as_str().unwrap(),
                        &source,
                    )
                    .unwrap();
                let human = &waiting["humanAction"];
                let challenge = owner
                    .issue_interactive_challenge(
                        human["actionId"].as_str().unwrap(),
                        human["resumeReference"].as_str().unwrap(),
                    )
                    .unwrap();
                let result = std::thread::scope(|threads| {
                    let running = threads.spawn(|| {
                        owner.consume_interactive_challenge(
                            id,
                            human["resumeReference"].as_str().unwrap(),
                            challenge["challenge"].as_str().unwrap(),
                            &jobs,
                            &source,
                            managed.as_ref(),
                        )
                    });
                    if failed {
                        // The failed process still requires a bounded probe;
                        // admission must remain frozen throughout that wait.
                        let deadline = Instant::now() + Duration::from_secs(3);
                        while !std::fs::read_to_string(fake.0.join("calls"))
                            .unwrap_or_default()
                            .lines()
                            .any(|line| line.ends_with(" kill -r"))
                        {
                            assert!(
                                Instant::now() < deadline,
                                "the lifecycle command did not enter its runner"
                            );
                            std::thread::sleep(Duration::from_millis(10));
                        }
                        assert_eq!(
                            jobs.acquire_hdc_lifecycle_interlock().err().unwrap().code,
                            "resourceConflict"
                        );
                    }
                    running.join().unwrap().unwrap()
                });
                assert_eq!(result["dispatchCount"], 1);
                assert_eq!(
                    result["state"],
                    if failed {
                        "outcomeUnknown"
                    } else {
                        "succeeded"
                    },
                    "{result}"
                );
                assert_eq!(owner.show(id).unwrap(), result);
                let replay = owner
                    .consume_interactive_challenge(
                        id,
                        human["resumeReference"].as_str().unwrap(),
                        challenge["challenge"].as_str().unwrap(),
                        &jobs,
                        &source,
                        managed.as_ref(),
                    )
                    .unwrap_err();
                assert_eq!(replay.code, "humanActionExpired");
                let calls = std::fs::read_to_string(fake.0.join("calls")).unwrap();
                assert_eq!(
                    calls
                        .lines()
                        .filter(|line| line.ends_with(" kill -r"))
                        .count(),
                    turn + 1
                );
                assert!(jobs.acquire_hdc_lifecycle_interlock().is_ok());
                if failed {
                    assert!(!hdc.mutation_identity_current());
                    assert!(hdc.dispatch(&plan()).is_err());
                    assert!(!managed.state(managed.endpoint()).unwrap().healthy);
                } else {
                    assert!(managed.active_launch().is_none());
                    assert_eq!(managed.foreground_exit(), Some(false));
                    assert!(hdc.mutation_identity_current());
                    assert!(
                        managed.state(managed.endpoint()).unwrap().generation > before.generation
                    );
                    let receipt = hdc
                        .dispatch(&ProcessPlan {
                            arguments: vec!["checkserver".into()],
                            timeout: Duration::from_secs(3),
                            capture_bytes: 4096,
                        })
                        .unwrap();
                    assert_eq!(receipt.exit_status, 0);
                }
            }
            if !failed {
                let lease = LoopbackServerLease::acquire(&tool, endpoint).unwrap();
                std::fs::write(fake.0.join("stop"), []).unwrap();
                let deadline = Instant::now() + Duration::from_secs(3);
                while lease.revalidate().is_ok() {
                    assert!(
                        Instant::now() < deadline,
                        "the synthetic replacement did not stop"
                    );
                    std::thread::sleep(Duration::from_millis(20));
                }
                std::fs::remove_file(fake.0.join("stop")).unwrap();
                let unrelated =
                    ManagedHdcServer::start(&tool, endpoint, StartBudget::default()).unwrap();
                assert!(!hdc.mutation_identity_current());
                assert!(
                    hdc.dispatch(&plan()).is_err(),
                    "a newer unrelated process cannot inherit the lifecycle proof"
                );
                unrelated.stop().unwrap();
            }
            managed.stop();
        }
    }

    /// restart -> the daemon's stop (SIGTERM or SIGINT drains the daemon,
    /// then stops its server) -> the next start on the same endpoint. The
    /// stop ends the replacement the confirmed restart proved, exactly that
    /// process, so the endpoint has no server again and the next start
    /// launches and proves its own; the restart's durable outcome, read by a
    /// new Runtime epoch, is unchanged and nothing reruns it. Isolated fake
    /// processes and a synthetic impact source: not registered-HDC or device
    /// evidence.
    #[test]
    fn a_stop_ends_the_proved_replacement_and_the_next_start_launches_its_own() {
        let (fake, tool) = fake_options(true, false);
        let endpoint = SocketAddrV4::new(Ipv4Addr::LOCALHOST, loopback_ports::free_port());
        let managed = daemon_start(&tool, endpoint).unwrap();
        let original = managed.active_launch().unwrap().pid;
        let owners = owners(&fake);
        let result = confirmed_restart(&managed, &tool, &owners, "restart-then-stop");
        assert_eq!(result["state"], "succeeded", "{result}");
        let replacement = LoopbackServerLease::acquire(&tool, endpoint).unwrap();
        assert_ne!(replacement.identity().pid, original);
        assert_eq!(recorded_servers(&fake), [replacement.identity().pid]);

        let stopped = managed.stop().unwrap();
        assert_eq!(stopped.replacement, ReplacementStop::Ended);
        assert!(stopped.server.is_ok());
        assert!(
            replacement.revalidate().is_err(),
            "the replacement still runs"
        );
        assert!(!reachable(endpoint), "a server is left on the endpoint");
        assert!(managed.stop().is_none());

        let launched = launches(&fake);
        let next = daemon_start(&tool, endpoint).unwrap();
        assert_eq!(launches(&fake), launched + 1);
        let own = LoopbackServerLease::acquire(&tool, endpoint).unwrap();
        assert_eq!(own.identity().pid, next.active_launch().unwrap().pid);
        assert!(generation(own.identity()) > generation(replacement.identity()));
        let epoch = arkdeck_hoststore::HdcControlActions::open(
            &fake.0.join("actions"),
            arkdeck_hoststore::OwnerContext::production().unwrap(),
        )
        .unwrap();
        assert_eq!(
            epoch
                .show(result["controlActionId"].as_str().unwrap())
                .unwrap(),
            result
        );
        let calls = std::fs::read_to_string(fake.0.join("calls")).unwrap();
        assert_eq!(
            calls
                .lines()
                .filter(|line| line.ends_with(" kill -r"))
                .count(),
            1
        );
        assert_eq!(next.stop().unwrap().replacement, ReplacementStop::None);
        assert!(!reachable(endpoint));
    }

    /// restart -> the daemon ends without its stop (SIGKILL, or exit 70:
    /// no drain runs) -> the next start. The replacement the ended Runtime
    /// left was not launched by the start that finds it: it is named and
    /// refused before anything is launched, neither adopted nor stopped
    /// (AC-HDC-003-02, REQ-HDC-003), and every start is refused so until that
    /// server ends; then the next start launches its own. Whether a start
    /// should instead serve beside it or claim it by a durable proof is the
    /// maintainer's to decide (hdc-replacement-lifetime-rust-run.md).
    #[test]
    fn a_crash_after_a_restart_leaves_its_replacement_and_starts_refuse_it_until_it_ends() {
        let (fake, tool) = fake_options(true, false);
        let endpoint = SocketAddrV4::new(Ipv4Addr::LOCALHOST, loopback_ports::free_port());
        let managed = daemon_start(&tool, endpoint).unwrap();
        let owners = owners(&fake);
        let result = confirmed_restart(&managed, &tool, &owners, "restart-then-crash");
        assert_eq!(result["state"], "succeeded", "{result}");
        let replacement = LoopbackServerLease::acquire(&tool, endpoint).unwrap();
        // A crash runs no stop: the Runtime's handles go as its process does.
        drop(managed);
        replacement.revalidate().unwrap();

        let launched = launches(&fake);
        for _ in 0..2 {
            let refused = daemon_start(&tool, endpoint)
                .err()
                .expect("a start beside the replacement");
            assert_eq!(
                refused,
                format!(
                    "the managed HDC server did not start: managed HDC endpoint was not absent \
                     before the foreground launch: a server of the configured HDC executable \
                     that this launch did not start listens there (pid {}, generation {}); \
                     nothing was launched, and that server is neither adopted nor stopped",
                    replacement.identity().pid,
                    generation(replacement.identity()).unwrap()
                )
            );
            assert_eq!(launches(&fake), launched, "a server was launched beside it");
            replacement.revalidate().unwrap();
        }
        hdc_kill(&fake, endpoint);
        assert!(replacement.revalidate().is_err());
        let next = daemon_start(&tool, endpoint).unwrap();
        assert_eq!(launches(&fake), launched + 1);
        assert_eq!(next.stop().unwrap().replacement, ReplacementStop::None);
    }

    /// restart -> the replacement ends and an unrelated server of the very
    /// same executable, newer and with the same argv, takes the endpoint ->
    /// the daemon's stop, then the next start. That server is not the
    /// process the restart proved: the stop signals nothing but the original
    /// child, and the next start neither launches beside it nor inherits it.
    #[test]
    fn an_unrelated_server_in_the_replacements_place_is_neither_stopped_nor_inherited() {
        let (fake, tool) = fake_options(true, false);
        let endpoint = SocketAddrV4::new(Ipv4Addr::LOCALHOST, loopback_ports::free_port());
        let managed = daemon_start(&tool, endpoint).unwrap();
        let owners = owners(&fake);
        let result = confirmed_restart(&managed, &tool, &owners, "restart-then-unrelated");
        assert_eq!(result["state"], "succeeded", "{result}");
        let replacement = LoopbackServerLease::acquire(&tool, endpoint).unwrap();
        hdc_kill(&fake, endpoint);
        assert!(replacement.revalidate().is_err());
        let unrelated = ManagedHdcServer::start(&tool, endpoint, StartBudget::default()).unwrap();
        let identity = unrelated.identity().clone();
        assert_ne!(identity.pid, replacement.identity().pid);

        let ReplacementStop::Unproved(reason) = managed.stop().unwrap().replacement else {
            panic!("the stop signalled a server the restart did not prove");
        };
        assert!(
            reason.contains(&format!("(pid {})", replacement.identity().pid))
                && reason.ends_with("nothing was signalled"),
            "{reason}"
        );
        assert_eq!(
            LoopbackServerLease::acquire(&tool, endpoint)
                .unwrap()
                .identity(),
            &identity,
            "the unrelated server was signalled"
        );
        let launched = launches(&fake);
        let refused = daemon_start(&tool, endpoint)
            .err()
            .expect("a start beside an unrelated server");
        assert!(
            refused.contains(&format!("(pid {}, generation", identity.pid)),
            "{refused}"
        );
        assert_eq!(launches(&fake), launched);
        assert_eq!(
            LoopbackServerLease::acquire(&tool, endpoint)
                .unwrap()
                .identity(),
            &identity
        );
        unrelated.stop().unwrap();
    }
}
