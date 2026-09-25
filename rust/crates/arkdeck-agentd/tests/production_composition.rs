//! The production composition (TASK-XPA-017), as the real daemon runs it
//! when `ARKDECK_RUNTIME_COMPOSITION=production` asks for it: every root in
//! Swift's layout below the account home, every owner composed there, the
//! installed socket served, one authority among Swift's daemon, the facade
//! and itself, and each unproved precondition refused with its reason before
//! anything serves.
//!
//! Every daemon here runs with its environment cleared and
//! `CFFIXED_USER_HOME` naming a temporary home below `/private/tmp`, and every
//! test asserts that what the daemon created is below that home. Over an
//! overridden home the daemon registers no Mach service, so the account's
//! `com.arkdeck.agentd` is never touched; no LaunchAgent, installed state or
//! device is either, and no HDC server is started (the one configured HDC is
//! refused before its launch). Swift's daemon and the facade are represented
//! by the very locks they take (`instance.lock` with its document, and the
//! transport directory's lock with its socket).
//!
//! So no daemon here reads the host's USB relations: the Runtime's own reader
//! is composed only beside the registered HDC the composition starts as its
//! managed server, which needs a published HDC executable no test starts.
//! That the reader is composed there, and only there, is
//! `production::tests`'s, over a census the test hands it.
#![cfg(target_os = "macos")]

use arkdeck_hoststore::{
    AnalyzerProfile, ArtifactReadStore, JobAdmitter, JobPlanner, JobRunner, JobStore,
};
use arkdeck_platform::{HostDirectory, LocalEndpoint, LocalListener};
use serde_json::{Map, Value, json};
use std::fs;
use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::fs::{DirBuilderExt, MetadataExt, PermissionsExt};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, ExitStatus, Output, Stdio};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError, mpsc};
use std::time::{Duration, Instant};

/// One test at a time. Each takes kernel locks in this process that another
/// test's spawned child would share until it execs, so a lock released here
/// could still read as held.
static TURN: Mutex<()> = Mutex::new(());
fn turn() -> MutexGuard<'static, ()> {
    TURN.lock().unwrap_or_else(PoisonError::into_inner)
}

const DEADLINE: Duration = Duration::from_secs(30);

/// A temporary account home: physical, owner-only, short enough for the
/// installed socket's `sun_path`, and removed afterwards.
struct Home(PathBuf);
impl Home {
    fn new() -> Self {
        let nonce = u64::from_ne_bytes(arkdeck_platform::random_bytes::<8>().unwrap());
        let path = PathBuf::from(format!("/private/tmp/adp-{nonce:016x}"));
        fs::DirBuilder::new().mode(0o700).create(&path).unwrap();
        Self(path)
    }
    fn support(&self) -> PathBuf {
        self.0.join("Library/Application Support/ArkDeck")
    }
    fn state(&self) -> PathBuf {
        self.support().join("Agentd")
    }
    fn socket(&self) -> PathBuf {
        self.state().join("agentd.sock")
    }
    /// Creates the state directory as Swift's server does, owner-only.
    fn state_directory(&self) -> HostDirectory {
        fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(self.state())
            .unwrap();
        HostDirectory::open(&self.state()).unwrap()
    }
    /// Every entry below the home, relative, with what identifies it.
    fn tree(&self) -> Vec<(String, u64, u64, i64)> {
        let mut entries = Vec::new();
        let mut pending = vec![self.0.clone()];
        while let Some(directory) = pending.pop() {
            for entry in fs::read_dir(&directory).unwrap() {
                let path = entry.unwrap().path();
                let metadata = fs::symlink_metadata(&path).unwrap();
                if metadata.is_dir() {
                    pending.push(path.clone());
                }
                entries.push((
                    path.strip_prefix(&self.0).unwrap().display().to_string(),
                    metadata.ino(),
                    metadata.len(),
                    metadata.mtime_nsec() + metadata.mtime() * 1_000_000_000,
                ));
            }
        }
        entries.sort();
        entries
    }
    fn names(&self) -> Vec<String> {
        self.tree().into_iter().map(|entry| entry.0).collect()
    }
}
impl Drop for Home {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

/// The daemon in the production composition over `home`, with nothing else
/// from this process's environment.
fn production(home: &Home) -> Command {
    let mut command = Command::new(env!("CARGO_BIN_EXE_arkdeck-agentd"));
    command
        .env_clear()
        .env("CFFIXED_USER_HOME", &home.0)
        .env("HOME", &home.0)
        .env("ARKDECK_RUNTIME_COMPOSITION", "production");
    command
}

/// A daemon that should end on its own: its output, or a failure if it is
/// still running at the deadline (and then it is killed).
fn finished(command: &mut Command) -> Output {
    let mut child = command
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let deadline = Instant::now() + DEADLINE;
    while child.try_wait().unwrap().is_none() {
        if Instant::now() > deadline {
            let _ = child.kill();
            let output = child.wait_with_output().unwrap();
            panic!(
                "the daemon kept running: {}",
                String::from_utf8_lossy(&output.stdout)
            );
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    child.wait_with_output().unwrap()
}

/// A serving daemon, its stdout read line by line as it writes them.
struct Daemon {
    child: Child,
    lines: mpsc::Receiver<String>,
    stdout: Vec<String>,
    stderr: Arc<Mutex<String>>,
}

impl Daemon {
    fn start(command: &mut Command) -> Self {
        let mut child = command
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        let (send, lines) = mpsc::channel();
        let stdout = child.stdout.take().unwrap();
        std::thread::spawn(move || {
            for line in BufReader::new(stdout).lines() {
                let Ok(line) = line else { return };
                if send.send(line).is_err() {
                    return;
                }
            }
        });
        let stderr = Arc::new(Mutex::new(String::new()));
        let written = Arc::clone(&stderr);
        let mut error = child.stderr.take().unwrap();
        std::thread::spawn(move || {
            let mut text = String::new();
            let _ = error.read_to_string(&mut text);
            written.lock().unwrap().push_str(&text);
        });
        Self {
            child,
            lines,
            stdout: Vec::new(),
            stderr,
        }
    }

    fn pid(&self) -> u32 {
        self.child.id()
    }

    /// The first line starting with `prefix`, waiting for it.
    fn line(&mut self, prefix: &str) -> String {
        if let Some(line) = self.stdout.iter().find(|line| line.starts_with(prefix)) {
            return line.clone();
        }
        let deadline = Instant::now() + DEADLINE;
        loop {
            let left = deadline.saturating_duration_since(Instant::now());
            match self.lines.recv_timeout(left.max(Duration::from_millis(1))) {
                Ok(line) => {
                    self.stdout.push(line.clone());
                    if line.starts_with(prefix) {
                        return line;
                    }
                }
                Err(_) => panic!(
                    "no line {prefix:?}: stdout {:?}, exited {:?}, stderr {}",
                    self.stdout,
                    self.child.try_wait(),
                    self.stderr.lock().unwrap()
                ),
            }
        }
    }

    /// Serving: the installed socket accepts, as the listening line says.
    fn serving(mut self, home: &Home) -> Self {
        assert_eq!(
            self.line("arkdeck-agentd listening on "),
            format!("arkdeck-agentd listening on {}", home.socket().display())
        );
        self
    }

    /// SIGTERM, then Swift's drain: the stop line, exit 0.
    fn stop(mut self) -> ExitStatus {
        let signalled = Command::new("/bin/kill")
            .arg("-TERM")
            .arg(self.pid().to_string())
            .status()
            .unwrap();
        assert!(signalled.success());
        self.line("arkdeck-agentd stopped");
        let deadline = Instant::now() + DEADLINE;
        loop {
            if let Some(status) = self.child.try_wait().unwrap() {
                return status;
            }
            assert!(Instant::now() < deadline, "the daemon did not end");
            std::thread::sleep(Duration::from_millis(10));
        }
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        if self.child.try_wait().ok().flatten().is_none() {
            let _ = self.child.kill();
            let _ = self.child.wait();
        }
    }
}

/// One control frame over the installed socket, answered.
fn request(home: &Home, method: &str, params: Value) -> Value {
    let mut stream = UnixStream::connect(home.socket()).unwrap();
    stream
        .set_read_timeout(Some(Duration::from_secs(60)))
        .unwrap();
    let mut frame = serde_json::to_vec(&json!({
        "protocolVersion": arkdeck_contract::PROTOCOL_VERSION,
        "contractIdentity": arkdeck_contract::CONTRACT_IDENTITY,
        "id": "production-composition", "method": method, "params": params}))
    .unwrap();
    frame.push(b'\n');
    stream.write_all(&frame).unwrap();
    let mut line = String::new();
    BufReader::new(stream).read_line(&mut line).unwrap();
    serde_json::from_str(&line).unwrap()
}

fn answered(home: &Home, method: &str, params: Value) -> Value {
    let answer = request(home, method, params);
    assert_eq!(answer["ok"], true, "{method}: {answer}");
    answer["result"].clone()
}

#[test]
fn production_composes_every_owner_below_the_home_and_serves_the_installed_socket() {
    let _turn = turn();
    let home = Home::new();
    // As Swift's LaunchAgent configures its daemon.
    let mut daemon =
        Daemon::start(production(&home).env("ARKDECK_WORKSPACE_INSPECTOR", "/usr/bin/grep"));
    assert_eq!(
        daemon.line("arkdeck-agentd production composition over "),
        format!(
            "arkdeck-agentd production composition over {}",
            home.state().display()
        )
    );
    assert_eq!(
        daemon.line("arkdeck-agentd composes no HDC"),
        "arkdeck-agentd composes no HDC: no executable is configured (set ARKDECK_HDC_PATH); \
         dispatch stays fail-closed"
    );
    assert!(
        daemon
            .line("arkdeck-agentd composes no Trace cache ")
            .starts_with(&format!(
                "arkdeck-agentd composes no Trace cache {}: ",
                home.0
                    .join("Library/Containers/com.arkdeck.desktop/Data/Library/Caches/ArkDeck/Trace/traces")
                    .display()
            ))
    );
    assert_eq!(
        daemon.line("arkdeck-agentd composes no App ingress"),
        "arkdeck-agentd composes no App ingress com.arkdeck.agentd: the account home is \
         overridden (CFFIXED_USER_HOME), so the account's Mach service is not this Runtime's"
    );
    assert_eq!(
        daemon.line("arkdeck-agentd owners: "),
        "arkdeck-agentd owners: jobs, capabilities, mutationAuthority, targets, artifacts, \
         imports, storage, history, workspaceProjects, workspaceOperations, bootstrap, planning, \
         agentExecutions, humanActions, controlActions, flashAliasReconciler, flashInvocations, \
         flashHostFacts, deviceAccess, loaderBinding"
    );
    let daemon = daemon.serving(&home);
    // The configured inspector is composed, as Swift composes it: nothing
    // is reported as left unread.
    assert!(
        !daemon
            .stdout
            .iter()
            .any(|line| line.contains("workspace source inspector")),
        "{:?}",
        daemon.stdout
    );
    assert!(
        !daemon
            .stdout
            .iter()
            .any(|line| line.starts_with("arkdeck-agentd App ingress:")),
        "{:?}",
        daemon.stdout
    );
    // Without an HDC no USB relation reader is composed (none is named among
    // the owners above), and nothing claims one is missing: nothing is
    // observed at all.
    assert!(
        !daemon.stdout.iter().any(|line| line.contains("USB")),
        "{:?}",
        daemon.stdout
    );
    // Swift's instance document names this daemon.
    let instance: Value =
        serde_json::from_slice(&fs::read(home.state().join("instance.json")).unwrap()).unwrap();
    assert_eq!(
        instance,
        json!({"pid": daemon.pid(), "protocolVersion": "1.0.0",
            "socketPath": home.socket(), "startedAtUTC": instance["startedAtUTC"]})
    );

    // Each owner answers from its root in Swift's layout.
    assert_eq!(answered(&home, "health", json!({}))["status"], "ok");
    for method in [
        "job.list",
        "target.list",
        "artifact.quota",
        "capability.list",
        "agent.list",
        "human-action.list",
        "control-action.list",
        "workspace.project.list",
        "artifact.import.list",
        "history.filter.list",
        "runtime.hdc.status",
        "operation.list",
        "doctor",
    ] {
        answered(&home, method, json!({}));
    }
    let storage = answered(&home, "runtime.storage.status", json!({}));
    assert!(
        storage.to_string().contains(&format!(
            "\"{}\"",
            home.support().join("Sessions").display()
        )),
        "{storage}"
    );
    // Without an HDC nothing is observed, as Swift's refusing dispatcher, and
    // nothing is adopted.
    assert_eq!(
        request(&home, "device.observations", json!({}))["error"]["code"],
        "rejected"
    );
    assert_eq!(
        request(
            &home,
            "target.adopt",
            json!({"candidate": "0123456789ABCDEF", "observationGeneration": "1",
                "observationId": "obs-00000000-0000-4000-8000-000000000000"})
        )["error"]["code"],
        "rejected"
    );
    assert_eq!(
        answered(
            &home,
            "history.filter.save",
            json!({"expectedGeneration": "1", "search": "production", "status": "failed",
                "mode": "all", "sessionId": null, "targetId": null, "timeRange": "lastDay",
                "activity": "all"})
        )["generation"],
        "2"
    );
    // Swift's Job index is at the state root, beside every other owner.
    let state = home.state();
    for name in [
        "instance.lock",
        "instance.json",
        "agentd.sock",
        "runtime-jobs.sqlite3",
        "cli-job-snapshots",
        "capabilities",
        "targets",
        "artifacts",
        "agent-executions",
        "human-action-snapshots",
        "control-action-snapshots",
        "workspace-projects",
        "history-filter.json",
    ] {
        assert!(fs::symlink_metadata(state.join(name)).is_ok(), "{name}");
    }
    for root in [
        home.support().join("Sessions"),
        home.support().join("Bootstrap/v1"),
    ] {
        assert_eq!(
            fs::metadata(&root).unwrap().mode() & 0o777,
            0o700,
            "{root:?}"
        );
    }
    assert!(!home.0.join("Library/Containers").exists());
    assert!(daemon.stop().success());
    assert!(!home.socket().exists());

    // A new start owns the same durable state.
    let daemon = Daemon::start(&mut production(&home)).serving(&home);
    assert_eq!(
        answered(&home, "history.filter.list", json!({}))["generation"],
        "2"
    );
    assert!(daemon.stop().success());
    // Everything below the home is the account's own: owned, owner-only.
    for (name, _, _, _) in home.tree() {
        let metadata = fs::symlink_metadata(home.0.join(&name)).unwrap();
        assert_eq!(metadata.uid(), arkdeck_platform::effective_user_id());
        assert_eq!(metadata.mode() & 0o077, 0, "{name}");
    }
}

/// The Rust CLI built beside this daemon.
fn cli(arguments: &[&str]) -> Output {
    Command::new(Path::new(env!("CARGO_BIN_EXE_arkdeck-agentd")).with_file_name("arkdeck"))
        .args(arguments)
        .env_remove("ARKDECK_ENDPOINT")
        .output()
        .unwrap()
}

#[test]
fn the_deep_doctor_reports_the_production_owners_as_they_are() {
    let _turn = turn();
    let home = Home::new();
    let daemon = Daemon::start(&mut production(&home)).serving(&home);
    let socket = home.socket();
    let socket = socket.to_str().unwrap();
    let output = cli(&["doctor", "--deep", "--output", "json", "--socket", socket]);
    assert_eq!(
        output.status.code(),
        Some(0),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let envelope: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(envelope["ok"], true, "{envelope}");
    let report = &envelope["result"];
    arkdeck_contract::validate_method_value("doctor", "result", report).unwrap();
    assert_eq!(report["mode"], "deep");
    // No HDC is composed here (none is registered), so the deep report says
    // so rather than claiming a live identity: a blocker, never
    // `hdc.identityReady`.
    assert_eq!(
        report["checks"]["hdc"],
        json!({"checked": true, "configured": false, "availability": "unavailable",
            "ownership": "unknown", "serverHealth": "unknown", "reasonCode": "hdc.notConfigured"})
    );
    let codes: Vec<&str> = report["findings"]
        .as_array()
        .unwrap()
        .iter()
        .map(|finding| finding["code"].as_str().unwrap())
        .collect();
    assert!(codes.contains(&"hdc.notConfigured"), "{codes:?}");
    assert!(!codes.contains(&"hdc.identityReady"), "{codes:?}");
    assert_eq!(report["ready"], false);
    // Every deep leg read the production owners below the home.
    let artifacts = &report["checks"]["storage"]["runtimeArtifacts"];
    assert_eq!(artifacts["checked"], true);
    assert_eq!(artifacts["configured"], true);
    assert!(artifacts["totalBytes"].is_u64(), "{artifacts}");
    assert_eq!(artifacts["usedBytes"], 0);
    assert_eq!(
        report["checks"]["recovery"],
        json!({"checked": true, "outstandingCleanupCount": 0})
    );
    assert_eq!(report["checks"]["target"]["configured"], true);
    assert_eq!(report["checks"]["target"]["adoptedTargetCount"], 0);
    assert!(codes.contains(&"storage.artifactStoreReady"), "{codes:?}");
    assert!(codes.contains(&"recovery.noCleanupDebt"), "{codes:?}");
    assert!(
        !codes.contains(&"runtime.durableRecordsUnreadable"),
        "{codes:?}"
    );
    // The CLI's gate: a deep report with a blocker is not healthy.
    let output = cli(&[
        "doctor",
        "--deep",
        "--require-healthy",
        "--output",
        "json",
        "--socket",
        socket,
    ]);
    assert_eq!(output.status.code(), Some(69));
    let envelope: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(envelope["error"]["code"], "healthRequirementFailed");
    assert!(daemon.stop().success());
}

#[test]
fn the_trace_cache_the_app_created_is_composed_where_it_is() {
    let _turn = turn();
    let home = Home::new();
    let trace = home
        .0
        .join("Library/Containers/com.arkdeck.desktop/Data/Library/Caches/ArkDeck/Trace");
    for name in ["traces", "staging"] {
        fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(trace.join(name))
            .unwrap();
    }
    let mut daemon = Daemon::start(&mut production(&home));
    assert!(daemon.line("arkdeck-agentd owners: ").ends_with(
        ", controlActions, traceCache, flashAliasReconciler, flashInvocations, \
                 flashHostFacts, deviceAccess, loaderBinding"
    ));
    let daemon = daemon.serving(&home);
    answered(&home, "trace.cache.status", json!({}));
    assert!(daemon.stop().success());
    // Nothing was added beside what the App created.
    let mut names: Vec<_> = fs::read_dir(&trace)
        .unwrap()
        .map(|entry| entry.unwrap().file_name().into_string().unwrap())
        .collect();
    names.sort();
    assert_eq!(names, ["staging", "traces"]);
}

#[test]
fn a_second_production_daemon_answers_already_running_and_touches_nothing() {
    let _turn = turn();
    let home = Home::new();
    let daemon = Daemon::start(&mut production(&home)).serving(&home);
    let before = home.tree();
    let output = finished(&mut production(&home));
    assert!(output.status.success(), "{output:?}");
    assert!(output.stderr.is_empty(), "{output:?}");
    assert_eq!(
        String::from_utf8(output.stdout).unwrap(),
        format!(
            "arkdeck-agentd already running: pid {}, socket {}, protocol 1.0.0\n",
            daemon.pid(),
            home.socket().display()
        )
    );
    assert_eq!(home.tree(), before);
    answered(&home, "job.list", json!({}));
    assert!(daemon.stop().success());
}

#[test]
fn swifts_held_instance_lock_refuses_the_start_before_anything_is_created() {
    let _turn = turn();
    let home = Home::new();
    let state = home.state_directory();
    // A Swift daemon holds its lock, and wrote its document with Foundation's
    // escaped slashes.
    let swift = state.lock_document("instance.lock").unwrap();
    let document = format!(
        "{{\"pid\":{},\"protocolVersion\":\"1.0.0\",\"socketPath\":\"{}\",\
         \"startedAtUTC\":\"2026-09-24T00:00:00Z\"}}",
        std::process::id(),
        home.socket().display().to_string().replace('/', "\\/")
    );
    fs::write(home.state().join("instance.json"), document).unwrap();
    let before = home.names();
    let output = finished(&mut production(&home));
    assert!(output.status.success(), "{output:?}");
    assert_eq!(
        String::from_utf8(output.stdout).unwrap(),
        format!(
            "arkdeck-agentd already running: pid {}, socket {}, protocol 1.0.0\n",
            std::process::id(),
            home.socket().display()
        )
    );
    assert_eq!(home.names(), before);
    assert_eq!(
        before,
        [
            "Library",
            "Library/Application Support",
            "Library/Application Support/ArkDeck",
            "Library/Application Support/ArkDeck/Agentd",
            "Library/Application Support/ArkDeck/Agentd/instance.json",
            "Library/Application Support/ArkDeck/Agentd/instance.lock",
        ]
    );
    // Held without its document, the lock refuses the start outright.
    fs::remove_file(home.state().join("instance.json")).unwrap();
    let output = finished(&mut production(&home));
    assert_eq!(output.status.code(), Some(69), "{output:?}");
    assert!(output.stdout.is_empty());
    assert!(
        String::from_utf8_lossy(&output.stderr).contains("left no instance document"),
        "{output:?}"
    );
    assert_eq!(home.names().len(), before.len() - 1);
    // Once Swift lets go of it, the account is this Runtime's.
    drop(swift);
    let daemon = Daemon::start(&mut production(&home)).serving(&home);
    assert!(daemon.stop().success());
}

#[test]
fn the_facades_transport_lock_refuses_the_start_and_the_daemon_refuses_the_facade() {
    let _turn = turn();
    let home = Home::new();
    let state = home.state_directory();
    // The installed facade holds the transport directory and its socket.
    let facade = LocalListener::bind_facade(&LocalEndpoint::new(home.socket())).unwrap();
    let socket = fs::symlink_metadata(home.socket()).unwrap().ino();
    let output = finished(&mut production(&home));
    assert_eq!(output.status.code(), Some(69), "{output:?}");
    assert!(output.stdout.is_empty());
    assert!(
        String::from_utf8_lossy(&output.stderr)
            .contains("another facade owns the public transport directory"),
        "{output:?}"
    );
    assert_eq!(fs::symlink_metadata(home.socket()).unwrap().ino(), socket);
    // Only Swift's lock file was created, and it was let go of.
    let mut names: Vec<_> = fs::read_dir(home.state())
        .unwrap()
        .map(|entry| entry.unwrap().file_name().into_string().unwrap())
        .collect();
    names.sort();
    assert_eq!(names, ["agentd.sock", "instance.lock"]);
    drop(state.lock_document("instance.lock").unwrap());
    drop(facade);

    // While this Runtime serves, neither the facade nor Swift's daemon can
    // take the account: their own locks are held.
    let daemon = Daemon::start(&mut production(&home)).serving(&home);
    let refused = LocalListener::bind_facade(&LocalEndpoint::new(home.socket()))
        .err()
        .unwrap();
    assert!(
        refused
            .to_string()
            .contains("another facade owns the public transport directory"),
        "{refused}"
    );
    assert_eq!(
        state.lock_document("instance.lock").err().unwrap().kind(),
        std::io::ErrorKind::WouldBlock
    );
    answered(&home, "health", json!({}));
    assert!(daemon.stop().success());
}

#[test]
fn a_live_listener_on_the_installed_socket_refuses_the_start_and_a_stale_one_is_reclaimed() {
    let _turn = turn();
    let home = Home::new();
    home.state_directory();
    let foreign = UnixListener::bind(home.socket()).unwrap();
    fs::set_permissions(home.socket(), fs::Permissions::from_mode(0o600)).unwrap();
    let output = finished(&mut production(&home));
    assert_eq!(output.status.code(), Some(69), "{output:?}");
    assert!(
        String::from_utf8_lossy(&output.stderr).contains("already occupied"),
        "{output:?}"
    );
    assert!(UnixStream::connect(home.socket()).is_ok());
    // Its process gone, the socket it left is reclaimed.
    drop(foreign);
    assert!(home.socket().exists());
    let daemon = Daemon::start(&mut production(&home)).serving(&home);
    answered(&home, "health", json!({}));
    assert!(daemon.stop().success());
}

#[test]
fn other_composition_inputs_and_an_unregistered_hdc_are_refused_with_their_reasons() {
    let _turn = turn();
    let home = Home::new();
    let elsewhere = home.0.join("elsewhere");
    for (name, value, reason) in [
        (
            "ARKDECK_DEVELOPMENT_STATE_ROOT",
            elsewhere.to_str().unwrap(),
            "ARKDECK_DEVELOPMENT_STATE_ROOT",
        ),
        (
            "ARKDECK_ENDPOINT",
            "/private/tmp/adp-endpoint.sock",
            "ARKDECK_ENDPOINT",
        ),
        (
            "ARKDECK_SWIFT_DAEMON",
            "/nonexistent/arkdeck-agentd",
            "ARKDECK_SWIFT_DAEMON",
        ),
        ("ARKDECK_SWIFT_SHA256", "0000", "ARKDECK_SWIFT_SHA256"),
        (
            "ARKDECK_PRIVATE_SOCKET",
            "/private/tmp/adp-private.sock",
            "ARKDECK_PRIVATE_SOCKET",
        ),
        ("ARKDECK_HDC_SHA256", "0000", "ARKDECK_HDC_SHA256"),
        ("ARKDECK_APP_INGRESS", "history", "ARKDECK_APP_INGRESS"),
        (
            "ARKDECK_DEVELOPMENT_HDC_PATH",
            "/nonexistent/hdc",
            "development HDC",
        ),
        (
            "ARKDECK_DEVELOPMENT_HDC_SERVER",
            "managed",
            "development HDC",
        ),
        (
            "ARKDECK_DEVELOPMENT_USB_RELATIONS",
            "/nonexistent/usb.json",
            "development USB relations",
        ),
        (
            "ARKDECK_DEVELOPMENT_CODE_SIGN_HELPER",
            "/nonexistent/helper",
            "development code-sign helper",
        ),
        (
            "ARKDECK_DEVELOPMENT_MUTATION_AUTHORITY",
            "acknowledged",
            "development mutation authority",
        ),
        (
            "ARKDECK_RUNTIME_COMPOSITION",
            "installed",
            "accepts only production",
        ),
        (
            "ARKDECK_HDC_PATH",
            "relative/hdc",
            "ARKDECK_HDC_PATH must be an explicit absolute path",
        ),
        (
            "ARKDECK_ANALYZER_PATH",
            "relative/analyzer",
            "ARKDECK_ANALYZER_PATH must be an explicit absolute path",
        ),
    ] {
        let output = finished(production(&home).env(name, value));
        assert_eq!(output.status.code(), Some(69), "{name}: {output:?}");
        assert!(output.stdout.is_empty(), "{name}: {output:?}");
        assert!(
            String::from_utf8_lossy(&output.stderr).contains(reason),
            "{name}: {output:?}"
        );
        assert!(home.names().is_empty(), "{name}: {:?}", home.names());
    }

    // An HDC the account's registry cannot select is refused before any
    // server is launched: the file is never executed.
    let sources = home.0.join("sources");
    fs::DirBuilder::new().mode(0o700).create(&sources).unwrap();
    let executed = home.0.join("executed");
    let hdc = sources.join("hdc");
    fs::write(
        &hdc,
        format!("#!/bin/sh\nprintf x >> '{}'\nexit 0\n", executed.display()),
    )
    .unwrap();
    fs::set_permissions(&hdc, fs::Permissions::from_mode(0o700)).unwrap();
    let output = finished(production(&home).env("ARKDECK_HDC_PATH", &hdc));
    assert_eq!(output.status.code(), Some(69), "{output:?}");
    assert!(
        String::from_utf8_lossy(&output.stderr).contains("the registered HDC is unavailable"),
        "{output:?}"
    );
    assert!(!executed.exists());
    assert!(!home.socket().exists());
    // Its locks went with it.
    drop(
        home.state_directory()
            .lock_document("instance.lock")
            .unwrap(),
    );
}

fn fixture(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/fixtures")
        .join(name)
}

/// A Job admitted and run at the home's state root before a start, parked by
/// its analyzer's signal death: the durable state a cutover takes over. The
/// analyzer counts each of its starts in `dispatches`, and has started once.
/// Answers the Job, the analyzer and `dispatches`.
fn parked_job(home: &Home) -> (String, PathBuf, PathBuf) {
    let state = home.state();
    // An analyzer whose every start is counted, and dies by a signal.
    let dispatches = home.0.join("dispatches");
    let analyzer = home.0.join("analyzer");
    fs::write(
        &analyzer,
        format!(
            "#!/bin/sh\n[ \"$#\" -eq 2 ] && [ \"$1\" = --analyze-crash-ledger ] || exit 64\n\
             printf x >> '{}'\nkill -KILL \"$$\"\n",
            dispatches.display()
        ),
    )
    .unwrap();
    fs::set_permissions(&analyzer, fs::Permissions::from_mode(0o700)).unwrap();
    let artifacts = state.join("artifacts");
    let source = artifacts.join("job-oracle-source");
    fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(&source)
        .unwrap();
    for file in fs::read_dir(fixture(
        "job-reconcile-analyzer/artifacts/job-oracle-source",
    ))
    .unwrap()
    {
        let file = file.unwrap().path();
        let name = file.file_name().unwrap();
        fs::copy(&file, source.join(name)).unwrap();
        let mode = if name == "index.json" { 0o600 } else { 0o400 };
        fs::set_permissions(source.join(name), fs::Permissions::from_mode(mode)).unwrap();
    }
    let job = {
        let jobs = JobStore::open_state_root_owner(&state).unwrap();
        let store = ArtifactReadStore::open(&artifacts).unwrap();
        let profile = AnalyzerProfile::crash_signature(&analyzer).unwrap();
        let recorded: Value =
            serde_json::from_slice(&fs::read(fixture("job-reconcile-analyzer/jobs.json")).unwrap())
                .unwrap();
        let accepted = JobAdmitter {
            planner: JobPlanner {
                imports: None,
                artifacts: Some(&store),
                analyzer: Some(&profile),
                state_root: &state,
                hdc: None,
                workspace: None,
            },
            jobs: &jobs,
            now: arkdeck_hoststore::runtime_now,
            authority: None,
        }
        .handle(recorded[0]["submit"].as_object().unwrap())
        .unwrap();
        let job = accepted["jobId"].as_str().unwrap().to_owned();
        let parked = JobRunner {
            imports: None,
            mutation: None,
            jobs: &jobs,
            artifacts: &store,
            analyzer: Some(&profile),
            quota: 8 << 30,
            home: "/nonexistent",
            now: arkdeck_hoststore::runtime_now,
            precise_now: arkdeck_hoststore::runtime_precise_now,
            sessions: None,
            cancellation: None,
            after_commit: None,
            hdc: None,
            workspace: None,
        }
        .handle(&Map::from_iter([("jobId".into(), json!(job))]))
        .unwrap();
        assert_eq!(parked["state"], "waitingForRecovery");
        job
    };
    assert_eq!(fs::read(&dispatches).unwrap(), b"x");
    (job, analyzer, dispatches)
}

#[test]
fn start_up_recovery_carries_a_parked_job_over_and_reconcile_publishes_below_the_home() {
    let _turn = turn();
    let home = Home::new();
    home.state_directory();
    let (job, analyzer, dispatches) = parked_job(&home);

    let mut daemon = Daemon::start(production(&home).env("ARKDECK_ANALYZER_PATH", &analyzer));
    assert_eq!(
        daemon.line("recovered "),
        "recovered 1 active job(s); unknown outcomes parked"
    );
    assert!(
        daemon
            .line("arkdeck-agentd owners: ")
            .contains(", analyzer, ")
    );
    let daemon = daemon.serving(&home);
    let params = json!({"jobId": job});
    let shown = answered(&home, "job.show", params.clone());
    assert_eq!(shown["job"]["state"], "waitingForRecovery");
    assert_eq!(shown["job"]["outcomeUnknown"], true);
    assert_eq!(
        shown["timeline"]["entries"]
            .as_array()
            .unwrap()
            .last()
            .unwrap(),
        "recovered: outstanding intents or unknown outcomes; no redispatch"
    );
    let reconciled = answered(&home, "job.reconcile", params.clone());
    let status = answered(&home, "job.status", params);
    assert_eq!(status, reconciled);
    assert_eq!(status["state"], "failed");
    assert_eq!(status["failure"]["code"], "executionConfirmedNotPerformed");
    assert_eq!(status["sessionPublication"]["state"], "published");
    assert!(daemon.stop().success());
    // Its Session is in the account's default Session root.
    let sessions = home.support().join("Sessions");
    assert!(
        home.names().iter().any(|name| {
            name.starts_with("Library/Application Support/ArkDeck/Sessions/")
                && name.ends_with("/manifest.json")
        }),
        "{:?}",
        fs::read_dir(&sessions).map(|entries| entries.count())
    );
    // The analyzer never ran again.
    assert_eq!(fs::read(&dispatches).unwrap(), b"x");
}

/// A publication a crash stopped before its rename left its Session staged
/// in the Sessions root (TASK-XPA-014). The next start removes it once it is
/// proved this Runtime's, naming it on its standard output, and publishes
/// nothing again; what nothing proves is kept as it is and named on its
/// standard error and in every doctor report.
#[test]
fn the_start_removes_a_stopped_publications_staged_session_and_keeps_what_nothing_proves() {
    let _turn = turn();
    let home = Home::new();
    home.state_directory();
    let (job, analyzer, _) = parked_job(&home);
    let sessions = home.support().join("Sessions");
    let staging = sessions.join(".staging");
    fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(&staging)
        .unwrap();
    // The Job's Session as its publication staged it, stopped with its
    // Journal copied in part; and an entry nothing proves this Runtime's.
    let own = "7E7CC05A-7463-4C0E-80B2-23FBF9C481B8";
    let foreign = "00000000-0000-4000-8000-000000000000";
    for (name, files) in [
        (
            own,
            vec![
                (
                    ".session-identity.json",
                    format!(
                        r#"{{"jobId":"{job}","schemaVersion":"1.0.0","sessionId":"session-{job}"}}"#
                    ),
                ),
                ("journal.jsonl", String::new()),
            ],
        ),
        (foreign, Vec::new()),
    ] {
        let directory = staging.join(name);
        fs::DirBuilder::new()
            .mode(0o700)
            .create(&directory)
            .unwrap();
        for (file, text) in files {
            fs::write(directory.join(file), text).unwrap();
            fs::set_permissions(directory.join(file), fs::Permissions::from_mode(0o600)).unwrap();
        }
    }

    let mut daemon = Daemon::start(production(&home).env("ARKDECK_ANALYZER_PATH", &analyzer));
    assert_eq!(
        daemon.line("removed staged Session "),
        format!("removed staged Session {own} of job {job}, which a stopped publication left")
    );
    let daemon = daemon.serving(&home);
    assert!(!staging.join(own).exists());
    assert!(staging.join(foreign).is_dir());
    for deep in [false, true] {
        let report = answered(&home, "doctor", json!({"deep": deep}));
        let kept: Vec<&Value> = report["findings"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|finding| finding["code"] == "storage.stagedSessionQuarantined")
            .collect();
        assert_eq!(
            kept,
            [
                &json!({"code": "storage.stagedSessionQuarantined", "severity": "warning",
                "scope": "storage",
                "summary": format!("a staged Session entry in the active Sessions root's .staging was kept as it is at the Runtime's start: {foreign} — it holds no readable Session identity. No admission or answer reads it")})
            ],
            "{report}"
        );
    }
    // Nothing was published: the Job keeps no publication and no Session.
    let shown = answered(&home, "job.show", json!({"jobId": job}));
    assert_eq!(
        shown["job"]["sessionPublication"],
        json!({"catalogGeneration": null, "manifestSha256": null,
            "reasonCode": "noCurrentPublicationRecord", "state": "unavailable"}),
        "{shown}"
    );
    let names = fs::read_dir(&sessions)
        .unwrap()
        .map(|entry| entry.unwrap().file_name().into_string().unwrap())
        .filter(|name| name.len() == 4)
        .collect::<Vec<_>>();
    assert!(names.is_empty(), "{names:?}");
    let stderr = Arc::clone(&daemon.stderr);
    assert!(daemon.stop().success());
    // Written whole once the daemon's standard error ends.
    let deadline = Instant::now() + DEADLINE;
    let written = loop {
        let written = stderr.lock().unwrap().clone();
        if !written.is_empty() || Instant::now() > deadline {
            break written;
        }
        std::thread::sleep(Duration::from_millis(10));
    };
    assert!(
        written.contains(&format!(
            "arkdeck-agentd: staged Session {foreign} is kept as it is: it holds no readable \
             Session identity\n"
        )),
        "{written}"
    );
    assert!(!written.contains(own), "{written}");
}

/// One scenario of Swift's start-up oracle (`rust/tests/fixtures/
/// rockchip-startup`), its `ArkDeck` root laid out as the home's Application
/// Support with Swift's modes: what Swift's first start printed, and the
/// Target document it left.
fn rockchip_scenario(home: &Home, name: &str) -> (Value, PathBuf) {
    let oracle = fixture("rockchip-startup");
    let cases: Value =
        serde_json::from_slice(&fs::read(oracle.join("cases.json")).unwrap()).unwrap();
    let scenario = cases["scenarios"]
        .as_array()
        .unwrap()
        .iter()
        .find(|scenario| scenario["name"] == name)
        .unwrap();
    // Swift's engine indexes every Job it writes; the oracle wrote its Jobs'
    // directories alone, which only the reconciler reads. So the index comes
    // first, as a start creates it before any Job: Job history without one
    // is refused rather than hidden behind a fresh index.
    home.state_directory();
    drop(JobStore::open_state_root_owner(&home.state()).unwrap());
    for input in scenario["inputs"].as_array().unwrap() {
        let path = input["path"].as_str().unwrap();
        let file = home.support().join(path);
        fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(file.parent().unwrap())
            .unwrap();
        fs::copy(oracle.join("inputs").join(name).join(path), &file).unwrap();
        let mode = u32::from_str_radix(input["mode"].as_str().unwrap(), 8).unwrap();
        fs::set_permissions(&file, fs::Permissions::from_mode(mode)).unwrap();
    }
    let first = scenario["runs"][0].clone();
    let targets = oracle.join(first["targets"].as_str().unwrap());
    (first, targets)
}

#[test]
fn the_start_carries_the_target_along_its_loader_binding_and_proves_the_post_flash_alias() {
    let _turn = turn();
    for name in ["lineage.advanced", "alias.complete"] {
        let home = Home::new();
        let (first, targets) = rockchip_scenario(&home, name);
        let mut daemon = Daemon::start(&mut production(&home));
        for line in first["lines"].as_array().unwrap() {
            let line = line.as_str().unwrap();
            assert_eq!(daemon.line(line), line, "{name}");
        }
        assert!(daemon.serving(&home).stop().success(), "{name}");
        assert_eq!(
            String::from_utf8(fs::read(home.state().join("targets/targets.json")).unwrap())
                .unwrap(),
            String::from_utf8(fs::read(targets).unwrap()).unwrap(),
            "{name}"
        );
    }
}

#[test]
fn a_rockchip_binding_the_start_cannot_read_refuses_the_start() {
    let _turn = turn();
    let home = Home::new();
    let (first, _) = rockchip_scenario(&home, "lineage.bindingShared");
    let output = finished(&mut production(&home));
    assert_eq!(output.status.code(), Some(69), "{output:?}");
    assert!(
        String::from_utf8_lossy(&output.stderr).contains(first["failure"].as_str().unwrap()),
        "{output:?}"
    );
    assert!(!home.socket().exists());
}

/// A DAYU200 Flash Job for `target` at revision 1, parked in
/// `waitingForRecovery` with its outcome unknown at its enter-Loader intent,
/// as a Runtime leaves one: admitted with its journal's `jobCreated` and
/// `queued -> preflight`, then running, its write-ahead intent for the
/// enter-Loader transition journaled and no outcome, and parked. The start
/// recovers it as the Job it is before naming it.
fn park_loader_transition(state: &Path, id: &str, target: &str) {
    use arkdeck_hoststore::job_journal_events::{self as events, Envelope, Target};
    let jobs = JobStore::open_state_root_owner(state).unwrap();
    let base = arkdeck_hoststore::JobRecord::decode(
        &fs::read(fixture(
            "job-reconcile-analyzer/before/jobs/job-082b8363fce0462b4571a62147751099/job-record.json",
        ))
        .unwrap(),
    )
    .unwrap();
    let mut value = base.value().unwrap();
    value["jobID"] = json!(id);
    value["operationReference"] = json!("flash.full-restore@1");
    value["request"]["operation"] = json!({"id": "flash.full-restore", "version": 1});
    value["request"]["target"] = json!({"targetId": target, "expectedBindingRevision": 1});
    value["request"]["idempotencyKey"] = json!(format!("idem-{id}"));
    value["request"]["requestId"] = json!(format!("req-{id}"));
    value["originalSubmissionRequest"] = value["request"].clone();
    let admitted =
        arkdeck_hoststore::JobRecord::decode(&serde_json::to_vec(&value).unwrap()).unwrap();
    jobs.admit(&admitted, &"a".repeat(64)).unwrap();
    let directory = state.join("jobs").join(id);
    fs::DirBuilder::new()
        .mode(0o700)
        .recursive(true)
        .create(&directory)
        .unwrap();
    let mut journal = arkdeck_hoststore::JournalWriter::open(&directory, true).unwrap();
    let envelope = |event: &str, sequence: i64| Envelope {
        event_id: event.into(),
        sequence,
        session_id: format!("session-{id}"),
        job_id: id.into(),
        timestamp: "2026-09-25T00:00:00Z".into(),
    };
    journal
        .append(&events::job_created(
            &envelope("job-created", 0),
            "execute",
            "standardAgent",
            "CORE-2.0.0",
        ))
        .unwrap();
    journal
        .append(&events::state_transition(
            &envelope("to-preflight", 1),
            "queued",
            "preflight",
            "admitted",
            None,
        ))
        .unwrap();
    jobs.persist(&admitted, "2026-09-25T00:00:00Z").unwrap();
    journal
        .append(&events::state_transition(
            &envelope("t-2", 2),
            "preflight",
            "running",
            "steps-start",
            None,
        ))
        .unwrap();
    let step = json!({"id": "enter-loader-mode", "kind": "enterUpdater",
        "effect": "deviceMutation", "bindingRequirement": "confirmedDevice",
        "cancellation": "atSafeBoundary", "compensationDescriptors": [],
        "arguments": {"expectedMode": "loader", "providerOperationId": "enterLoaderMode",
            "reconnectDeadlineMilliseconds": 60000}});
    let device = Target {
        scope: "device".into(),
        target_id: target.into(),
        connect_key: Some("fixture-connect-key".into()),
        identity_snapshot_hash: Some("0".repeat(64)),
    };
    journal
        .append(
            &events::step_intent(
                &envelope("intent-enter-loader-mode", 3),
                &step,
                &device,
                1,
                Some(1),
            )
            .unwrap(),
        )
        .unwrap();
    journal
        .append(&events::state_transition(
            &envelope("t-4", 4),
            "running",
            "waitingForRecovery",
            "outcomeUnknown: the enter-Loader transition's outcome was lost",
            None,
        ))
        .unwrap();
    value["state"] = json!("waitingForRecovery");
    value["outcomeUnknown"] = json!(true);
    value["recoveryStepID"] = json!("enter-loader-mode");
    value["recoveryIntentEventID"] = json!("intent-enter-loader-mode");
    let parked =
        arkdeck_hoststore::JobRecord::decode(&serde_json::to_vec(&value).unwrap()).unwrap();
    jobs.persist(&parked, "2026-09-25T00:00:00Z").unwrap();
}

#[test]
fn an_enter_loader_transition_awaiting_the_binding_is_named_and_two_refuse_the_start() {
    let _turn = turn();
    let home = Home::new();
    rockchip_scenario(&home, "lineage.advanced");
    let target = "TGT-8b3d0a34cf32";
    let first = "job-00000000000000000000000000000a01";
    park_loader_transition(&home.state(), first, target);
    let mut daemon = Daemon::start(&mut production(&home));
    assert_eq!(
        daemon.line("advanced runtime target "),
        format!("advanced runtime target {target} to Rockchip binding revision 2")
    );
    assert_eq!(
        daemon.line("Loader transition "),
        format!(
            "Loader transition {first} awaits settlement at Rockchip binding revision 2, which \
             this Runtime does not settle yet; its outcome stays unknown"
        )
    );
    let daemon = daemon.serving(&home);
    // Named, never settled: the Job still waits with its outcome unknown.
    let status = answered(&home, "job.status", json!({"jobId": first}));
    assert_eq!(status["state"], "waitingForRecovery");
    assert!(daemon.stop().success());

    // Swift's engine refuses two as ambiguous, and so does this start.
    park_loader_transition(
        &home.state(),
        "job-00000000000000000000000000000a02",
        target,
    );
    let output = finished(&mut production(&home));
    assert_eq!(output.status.code(), Some(69), "{output:?}");
    assert!(
        String::from_utf8_lossy(&output.stderr).contains(&format!(
            "jobNotRunnable(\"multiple unresolved Loader transitions cover target {target}\")"
        )),
        "{output:?}"
    );
}
