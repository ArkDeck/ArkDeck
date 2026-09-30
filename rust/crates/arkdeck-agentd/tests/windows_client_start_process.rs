//! The Windows daemon started by its client (TASK-XPA-002, CHG-2026-074 r12
//! decision 11), with the real daemon over isolated development roots: the
//! client start path (`arkdeck_client::start`) and the CLI's Windows
//! `runtime service verify|status|restart` leaves.
//!
//! * A daemon whose identity is configured by package family only is started
//!   (a package family is proved on the running process, never on a file)
//!   and then refused: this daemon has no package, so what serves the pipe
//!   is reported with the process id the client started and never trusted.
//! * Without any configured identity nothing is started.
//! * With a development signer (`ARKDECK_DEV_SIGNER_THUMBPRINT`, a
//!   certificate trusted only on this host; the test is skipped, saying so,
//!   without one): a signed copy of the daemon is started once on demand and
//!   then found serving; `verify` and `status` prove the running daemon's
//!   identity and start nothing; `restart` asks it to stop, sees its guard
//!   released after a complete drain and proves a new process with the same
//!   catalog; a connection the restart ended is not replayed to the
//!   successor; and concurrent starters produce one daemon.
//!
//! Every daemon here runs with every `ARKDECK_` and `OHOS_HDC_` input removed
//! but its development root; nothing installed is read or written. Each
//! daemon is stopped by its own stop request, and the test waits on its
//! single-instance guard, never on time; no other process is touched.
#![cfg(windows)]

use arkdeck_cli::runtime_service_windows::{self as service, ServiceTarget};
use arkdeck_client::Client;
use arkdeck_client::start::{StartRefusal, StartTarget, Started, ensure_running};
use arkdeck_platform::{
    GuardAcquisition, GuardObject, InstanceScope, LocalConnection, LocalEndpoint, ServerIdentity,
    StateRoot, await_pipe_instance, pipe_present,
};
use serde_json::{Map, Value};
use std::ffi::OsString;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::{Mutex, MutexGuard, PoisonError};
use std::time::Duration;

static TURN: Mutex<()> = Mutex::new(());
fn turn() -> MutexGuard<'static, ()> {
    TURN.lock().unwrap_or_else(PoisonError::into_inner)
}

const WAIT: Duration = Duration::from_secs(60);
const DAEMON: &str = env!("CARGO_BIN_EXE_arkdeck-agentd");

/// A fresh directory below the temporary directory, removed afterwards.
struct Directory(PathBuf);
impl Directory {
    fn new(prefix: &str) -> Self {
        let nonce = u64::from_ne_bytes(arkdeck_platform::random_bytes::<8>().unwrap());
        let path = std::env::temp_dir().join(format!("{prefix}-{nonce:016x}"));
        std::fs::create_dir(&path).unwrap();
        Self(path)
    }
    fn instance(&self) -> Value {
        serde_json::from_slice(&std::fs::read(self.0.join("instance.json")).unwrap()).unwrap()
    }

    /// The instance document once the daemon on `endpoint` serves. A daemon
    /// opens its pipe before it publishes `instance.json` and serves only
    /// after publishing it, so a client start (which returns once the pipe
    /// exists and its server's identity was checked) says nothing about the
    /// document; a `health` answer on the pipe does. The probe is a plain
    /// pipe handle, as `windows_lifecycle_process.rs` uses: it observes the
    /// daemon and trusts it with nothing.
    fn instance_once_serving(&self, endpoint: &LocalEndpoint) -> Value {
        let answer = health_on(endpoint);
        assert_eq!(answer["ok"], true, "{answer}");
        self.instance()
    }
}

/// One `health` exchange over a plain handle on `endpoint`, waiting (bounded,
/// on the kernel's pipe wait) while every instance is busy.
fn health_on(endpoint: &LocalEndpoint) -> Value {
    let mut pipe = loop {
        assert!(
            await_pipe_instance(endpoint, WAIT).unwrap(),
            "no instance of {} became free",
            endpoint.as_path().display()
        );
        match std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .open(endpoint.as_path())
        {
            Ok(pipe) => break pipe,
            // Another client took the instance offered meanwhile.
            Err(error) if error.raw_os_error() == Some(231) => {}
            Err(error) => panic!("{error}"),
        }
    };
    let request = serde_json::json!({
        "protocolVersion": arkdeck_contract::PROTOCOL_VERSION,
        "contractIdentity": arkdeck_contract::CONTRACT_IDENTITY,
        "id": "readiness",
        "method": "health",
    });
    let mut frame = serde_json::to_vec(&request).unwrap();
    frame.push(b'\n');
    pipe.write_all(&frame).unwrap();
    let mut reply = Vec::new();
    let mut byte = [0u8; 1];
    while byte[0] != b'\n' {
        assert_eq!(pipe.read(&mut byte).unwrap(), 1, "the reply ended early");
        reply.push(byte[0]);
    }
    serde_json::from_slice(&reply).unwrap()
}
impl Drop for Directory {
    /// A daemon a failed assertion left serving this root is asked to stop
    /// (its stop event, never a kill) and its guard awaited. The directory
    /// is then removed; a daemon image in it stays open for a moment after
    /// its guard is released, so removal is tried a bounded number of times
    /// (cleanup only, nothing is asserted on it).
    fn drop(&mut self) {
        if let Ok(bytes) = std::fs::read(self.0.join("instance.json"))
            && let Ok(instance) = serde_json::from_slice::<Value>(&bytes)
            && let Some(pid) = instance["pid"]
                .as_u64()
                .and_then(|pid| u32::try_from(pid).ok())
            && let Ok(opened) = StateRoot::development(&self.0)
            && let Ok(scope) = opened.scope()
        {
            drop(opened);
            if scope.request_stop(pid).is_ok()
                && let Ok(guard) = GuardObject::open(&scope)
            {
                let _ = guard.acquire(WAIT);
            }
        }
        for _ in 0..100 {
            if std::fs::remove_dir_all(&self.0).is_ok() || !self.0.exists() {
                return;
            }
            std::thread::sleep(Duration::from_millis(100));
        }
    }
}

/// This process's environment without any ArkDeck or HDC input, and the
/// development root.
fn environment(root: &Path) -> Vec<(OsString, OsString)> {
    std::env::vars_os()
        .filter(|(name, _)| {
            let name = name.to_string_lossy().to_ascii_uppercase();
            !name.starts_with("ARKDECK_") && !name.starts_with("OHOS_HDC_")
        })
        .chain([(
            OsString::from("ARKDECK_DEVELOPMENT_STATE_ROOT"),
            root.as_os_str().to_owned(),
        )])
        .collect()
}

fn target(root: &Path, identity: ServerIdentity) -> StartTarget {
    let mut target = StartTarget::resolve(None, Some(root.as_os_str()), identity)
        .unwrap()
        .expect("a development root's daemon is started by its client");
    target.environment = Some(environment(root));
    target
}

fn scope(root: &Path) -> InstanceScope {
    StateRoot::development(root).unwrap().scope().unwrap()
}

/// Asks the daemon `pid` of `root` to stop and waits for its guard: `true`
/// if it drained completely (released the guard), `false` if it ended
/// holding it.
fn stop(root: &Path, pid: u32) -> bool {
    let scope = scope(root);
    scope.request_stop(pid).unwrap();
    released(&scope)
}

fn released(scope: &InstanceScope) -> bool {
    match GuardObject::open(scope).unwrap().acquire(WAIT).unwrap() {
        GuardAcquisition::Owned { guard, abandoned } => {
            drop(guard);
            !abandoned
        }
        GuardAcquisition::Held => panic!("the daemon did not let its guard go"),
    }
}

#[test]
fn a_started_daemon_that_fails_its_identity_is_reported_and_not_trusted() {
    let _turn = turn();
    let root = Directory::new("ad-start-refused");
    let identity = ServerIdentity {
        package_family: Some("ArkDeck.NotThisDaemon_0000000000000".into()),
        ..ServerIdentity::new(DAEMON)
    };
    let target = target(&root.0, identity);
    let refused = ensure_running(&target, WAIT).unwrap_err();
    assert_eq!(refused.refusal, StartRefusal::IdentityRefused, "{refused}");
    let pid = refused.pid.expect("the process this client started");
    assert!(
        refused
            .message
            .contains("did not prove the installed identity"),
        "{refused}"
    );
    // It is the daemon this client started, serving the root's pipe; it is
    // left to its own stop request, never used.
    assert_eq!(root.instance_once_serving(&target.endpoint)["pid"], pid);
    assert!(pipe_present(&target.endpoint).unwrap());
    assert!(LocalConnection::connect(&target.endpoint, &target.identity).is_err());
    assert!(stop(&root.0, pid), "a clean drain");
    assert!(!pipe_present(&target.endpoint).unwrap());
}

#[test]
fn without_a_configured_identity_nothing_is_started() {
    let _turn = turn();
    let root = Directory::new("ad-start-none");
    let target = target(&root.0, ServerIdentity::new(DAEMON));
    let refused = ensure_running(&target, WAIT).unwrap_err();
    assert_eq!(refused.refusal, StartRefusal::LaunchRefused, "{refused}");
    assert_eq!(refused.pid, None);
    assert!(!pipe_present(&target.endpoint).unwrap());
    assert!(!root.0.join("instance.json").exists());
    // `verify` says why the service is not ready, and starts nothing.
    let service = ServiceTarget::new(
        None,
        Some(root.0.clone().into_os_string()),
        ServerIdentity::new(DAEMON),
    )
    .unwrap();
    let answer = service::verify_leaf(&service, "verify-none", &Map::new());
    let document = answer.document.unwrap();
    assert_eq!(document["runtimeVerified"], false);
    assert_eq!(document["daemonService"]["daemonImage"]["verified"], false);
    assert_eq!(document["daemonService"]["ready"], false);
    assert_eq!(answer.failure.unwrap().exit_code, 69);
    assert!(!root.0.join("instance.json").exists());
}

/// Where PowerShell 7 is, as `check-readonly.py` finds it.
fn pwsh() -> PathBuf {
    std::env::var_os("PATH")
        .into_iter()
        .flat_map(|path| std::env::split_paths(&path).collect::<Vec<_>>())
        .map(|directory| directory.join("pwsh.exe"))
        .find(|candidate| candidate.is_file())
        .unwrap_or_else(|| {
            PathBuf::from(std::env::var_os("LOCALAPPDATA").expect("LOCALAPPDATA"))
                .join(r"Microsoft\WindowsApps\pwsh.exe")
        })
}

/// A copy of the daemon signed with the host-trusted development signer,
/// and its signer pin; `None` without a signer.
fn signed_daemon(directory: &Path) -> Option<(PathBuf, String)> {
    let Some(thumbprint) = std::env::var_os("ARKDECK_DEV_SIGNER_THUMBPRINT") else {
        eprintln!(
            "skipped: ARKDECK_DEV_SIGNER_THUMBPRINT names no host-trusted development signer \
             (rust/scripts/windows-dev-identity.ps1 create)"
        );
        return None;
    };
    let copy = directory.join("arkdeck-agentd.exe");
    std::fs::copy(DAEMON, &copy).unwrap();
    let script =
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../../scripts/windows-dev-identity.ps1");
    let output = std::process::Command::new(pwsh())
        .args(["-NoProfile", "-NonInteractive", "-File"])
        .arg(script)
        .arg("sign")
        .arg("-Thumbprint")
        .arg(thumbprint)
        .arg("-Path")
        .arg(&copy)
        .stdin(std::process::Stdio::null())
        .output()
        .unwrap();
    assert!(output.status.success(), "{output:?}");
    let signed: Value = serde_json::from_slice(&output.stdout).unwrap();
    Some((copy, signed["pin"].as_str().unwrap().to_owned()))
}

#[test]
fn a_signed_daemon_is_started_once_verified_restarted_and_started_once_by_concurrent_clients() {
    let _turn = turn();
    let installed = Directory::new("ad-start-signed");
    let Some((image, pin)) = signed_daemon(&installed.0) else {
        return;
    };
    let identity = ServerIdentity {
        authenticode_sha256: Some(pin),
        ..ServerIdentity::new(&image)
    };
    let root = Directory::new("ad-start-root");
    let target = target(&root.0, identity.clone());

    // Started on demand once; then found serving.
    let Started::Launched { pid: first } = ensure_running(&target, WAIT).unwrap() else {
        panic!("the absent daemon was not launched");
    };
    assert_eq!(root.instance_once_serving(&target.endpoint)["pid"], first);
    assert_eq!(
        ensure_running(&target, WAIT).unwrap(),
        Started::AlreadyServing
    );
    let mut client = Client::connect(&target.endpoint, &identity, WAIT).unwrap();
    assert_eq!(client.health("start-health").unwrap()["status"], "ok");

    // `verify` and `status` prove the running daemon and start nothing.
    let mut service = ServiceTarget::new(
        None,
        Some(root.0.clone().into_os_string()),
        identity.clone(),
    )
    .unwrap();
    service.start.environment = target.environment.clone();
    let verified = service::verify_leaf(&service, "verify-signed", &Map::new());
    assert_eq!(verified.failure, None, "{verified:?}");
    let document = verified.document.unwrap();
    assert_eq!(document["runtimeVerified"], true, "{document}");
    assert_eq!(document["runtime"]["pid"], first);
    assert_eq!(document["daemonService"]["daemonImage"]["pin"], "signer");
    assert_eq!(
        document["daemonService"]["stateRoot"]["kind"],
        "development"
    );
    assert_eq!(document["daemonService"]["instance"]["pid"], first);
    let status = service::status_leaf(&service, "status-signed")
        .document
        .unwrap();
    assert_eq!(status["daemonHealth"]["status"], "ok", "{status}");
    assert_eq!(status["daemonService"]["socketPresent"], true);

    // Restart: the stop request drains the daemon (the idle connection above
    // is ended), and the successor is a new, verified process.
    let restarted = service::restart_leaf(&service, "restart-signed", Some(60));
    assert_eq!(restarted.failure, None, "{restarted:?}");
    let document = restarted.document.unwrap();
    assert_eq!(document["restart"]["stoppedPid"], first, "{document}");
    assert_eq!(document["restart"]["drain"], "complete");
    assert_eq!(document["restart"]["start"], "launched");
    let second = u32::try_from(document["restart"]["startedPid"].as_u64().unwrap()).unwrap();
    assert_ne!(second, first);
    let proof = &document["restartProof"];
    assert_eq!(proof["beforeInstance"]["pid"], first);
    assert_eq!(proof["afterInstance"]["pid"], second);
    assert_eq!(proof["catalogDigestBefore"], proof["catalogDigestAfter"]);
    // The daemon composes the Job store (TASK-XPA-005), whose one-page
    // `job.list` the restart read the current Jobs from: there are none.
    assert_eq!(proof["jobOwner"], true, "{proof}");
    assert_eq!(document["daemonHealth"]["status"], "ok");
    assert_eq!(root.instance()["pid"], second);

    // No replay: the connection the restart ended fails; nothing it asked is
    // sent again, to the successor or anyone.
    let lost = client.request("after-restart", "doctor", None).unwrap_err();
    assert!(
        matches!(
            lost,
            arkdeck_client::ClientError::Transport(_)
                | arkdeck_client::ClientError::ConnectionUnusable
        ),
        "{lost}"
    );
    assert!(matches!(
        client.request("after-restart-again", "doctor", None),
        Err(arkdeck_client::ClientError::ConnectionUnusable)
    ));

    // Out of range, as on macOS.
    let out_of_range = service::restart_leaf(&service, "restart-range", Some(0));
    assert_eq!(out_of_range.failure.unwrap().exit_code, 64);

    // Concurrent starters, the daemon stopped: one daemon is started.
    assert!(stop(&root.0, second), "a clean drain");
    let outcomes: Vec<Started> = std::thread::scope(|threads| {
        let starters: Vec<_> = (0..4)
            .map(|_| threads.spawn(|| ensure_running(&target, WAIT).unwrap()))
            .collect();
        starters
            .into_iter()
            .map(|starter| starter.join().unwrap())
            .collect()
    });
    let launched: Vec<u32> = outcomes
        .iter()
        .filter_map(|outcome| match outcome {
            Started::Launched { pid } => Some(*pid),
            _ => None,
        })
        .collect();
    assert_eq!(launched.len(), 1, "{outcomes:?}");
    assert_eq!(
        root.instance_once_serving(&target.endpoint)["pid"],
        launched[0]
    );
    assert!(
        outcomes
            .iter()
            .all(|outcome| !matches!(outcome, Started::AlreadyServing)
                || pipe_present(&target.endpoint).unwrap())
    );
    assert!(stop(&root.0, launched[0]), "a clean drain");
}
