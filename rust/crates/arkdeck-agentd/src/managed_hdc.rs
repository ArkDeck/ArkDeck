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
use arkdeck_control::ManagedToolFacts;
use arkdeck_platform::{LoopbackServerLease, ServerStop, VerifiedTool};
use arkdeck_provider_hdc::{
    CommandlessIdentity, DispatchFailure, EndpointSelection, HdcDispatch, HdcStatusObserver,
    ManagedHdcServer, ManagedLaunch, NativeSignature, ProcessDispatch, ProcessPlan, Receipt,
    StartBudget, StartFailure, StartupDiagnostics, StatusExecutable, SupervisedServer,
    SupervisorState, SystemManagedProcess, generation,
};
use serde_json::Value;
use std::io;
use std::sync::{Arc, Mutex};

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
    pub(crate) fn stop(&self) -> Option<io::Result<ServerStop>> {
        *self.ownership.lock().ok()? = DispatchOwnership::Stopped;
        *self.supervisor.lock().ok()? = None;
        let server = self.server.lock().ok()?.take()?;
        Some(server.stop())
    }
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
    use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
    use std::path::PathBuf;
    use std::time::{Duration, Instant};

    const FAKE_HDC: &str = include_str!("../../../tests/fixtures/managed-hdc/fake-hdc.c");

    struct Fake(PathBuf);
    impl Drop for Fake {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    /// The fake `hdc`, compiled into its own owner-only directory.
    fn fake() -> (Fake, VerifiedTool) {
        fake_options(false, false)
    }

    fn fake_options(restart: bool, fail: bool) -> (Fake, VerifiedTool) {
        let directory = PathBuf::from(format!(
            "/private/tmp/arkdeck-managed-hdc-unit-{:032x}",
            u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap())
        ));
        std::fs::DirBuilder::new()
            .mode(0o700)
            .create(&directory)
            .unwrap();
        let source = directory.join("fake-hdc.c");
        std::fs::write(&source, FAKE_HDC).unwrap();
        let binary = directory.join("hdc");
        let mut compiler = std::process::Command::new("cc");
        compiler.arg("-O0").arg("-o").arg(&binary).arg(&source);
        if restart {
            compiler
                .arg(format!("-DRESTART_DIR=\"{}\"", directory.display()))
                .arg(format!("-DSELF_PATH=\"{}\"", binary.display()))
                .arg(format!("-DRECORD_CALLS=\"{}/calls\"", directory.display()));
        }
        if fail {
            compiler.arg("-DFAIL_RESTART");
        }
        let output = compiler.output().unwrap();
        assert!(output.status.success(), "{output:?}");
        std::fs::set_permissions(&binary, std::fs::Permissions::from_mode(0o700)).unwrap();
        let digest = arkdeck_contract::sha256_hex(&std::fs::read(&binary).unwrap());
        let tool = VerifiedTool::open(&binary, &digest).unwrap();
        (Fake(directory), tool)
    }

    fn plan() -> ProcessPlan {
        ProcessPlan {
            arguments: vec!["list".into(), "targets".into()],
            timeout: Duration::from_secs(10),
            capture_bytes: 4096,
        }
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
        assert!(!hdc.mutation_identity_current());
        let status = managed.status(&|| "2026-09-19T00:00:00Z".to_owned());
        assert_eq!(status["executableSHA256"], tool.sha256());
        assert!(managed.stop().is_some());
        assert!(managed.stop().is_none());
        let Err(DispatchFailure::Refused(reason)) = hdc.dispatch(&plan()) else {
            panic!("a plan was dispatched past the managed server's stop");
        };
        assert_eq!(
            reason,
            "dispatch refused: the managed HDC server was stopped"
        );
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
        struct Cleanup {
            root: PathBuf,
            tool: VerifiedTool,
            endpoint: SocketAddrV4,
        }
        impl Drop for Cleanup {
            fn drop(&mut self) {
                let _ = std::fs::write(self.root.join("stop"), []);
                let deadline = Instant::now() + Duration::from_secs(3);
                while LoopbackServerLease::acquire(&self.tool, self.endpoint).is_ok()
                    && Instant::now() < deadline
                {
                    std::thread::sleep(Duration::from_millis(20));
                }
            }
        }
        for failed in [false, true] {
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
            let _cleanup = Cleanup {
                root: fake.0.clone(),
                tool: VerifiedTool::open(tool.path(), tool.sha256()).unwrap(),
                endpoint,
            };
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
}
