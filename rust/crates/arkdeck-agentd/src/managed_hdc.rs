//! The isolated owner's managed HDC server (TASK-XPA-016 R2), composed as
//! Swift's daemon composes `HeadlessHDCServerHost`: started before the
//! daemon serves, on the endpoint Swift's selector picks, ready and bound to
//! its own launch by the commandless identity proof (`ManagedHdcServer`).
//! Its startup facts answer `target.availability`'s tool leg, its launch
//! record feeds `runtime.hdc.status`, and the daemon stops it once it has
//! drained.
//!
//! Swift's daemon exits 70 when the server ends unexpectedly, for launchd to
//! start a fresh daemon and server (restart and recovery wait for design
//! §L.1 item 13). Nothing restarts it here; instead no HDC plan is
//! dispatched once the server is no longer the one launched, so a client can
//! neither bootstrap a server of its own on the endpoint nor address one
//! another process started there.
use arkdeck_control::ManagedToolFacts;
use arkdeck_platform::{ServerStop, VerifiedTool};
use arkdeck_provider_hdc::{
    CommandlessIdentity, DispatchFailure, EndpointSelection, HdcDispatch, HdcStatusObserver,
    ManagedHdcServer, ManagedLaunch, NativeSignature, ProcessDispatch, ProcessPlan, Receipt,
    StartBudget, StartFailure, StartupDiagnostics, StatusExecutable, SystemManagedProcess,
};
use serde_json::Value;
use std::io;
use std::sync::{Arc, Mutex};

/// The managed server and the facts its startup established.
pub(crate) struct ManagedHdc {
    /// The running server; `None` once the daemon has stopped it.
    server: Mutex<Option<ManagedHdcServer>>,
    executable: StatusExecutable,
    startup: StartupDiagnostics,
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
        Ok(Self {
            server: Mutex::new(Some(server)),
            executable: StatusExecutable {
                path: configured_path.to_owned(),
                sha256: tool.sha256().to_owned(),
            },
            startup,
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
    /// production identity observer, signature inspection and process
    /// verification. This daemon has no supervisor, and as a bare binary no
    /// bundle version (Swift's SwiftPM daemon reports none either).
    pub(crate) fn status(&self, now_utc: &dyn Fn() -> String) -> Value {
        let launches = || self.active_launch();
        HdcStatusObserver::new(
            self.executable.clone(),
            self.startup.clone(),
            None,
            &launches,
            None,
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

    /// The server is still the one launched: running, with the launch's
    /// birth, and still the one listener on its endpoint.
    fn current(&self) -> Result<(), String> {
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
        let server = self.server.lock().ok()?.take()?;
        Some(server.stop())
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
        let output = std::process::Command::new("cc")
            .arg("-O0")
            .arg("-o")
            .arg(&binary)
            .arg(&source)
            .output()
            .unwrap();
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
}
