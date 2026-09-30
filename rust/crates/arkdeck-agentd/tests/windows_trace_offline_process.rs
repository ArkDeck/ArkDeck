//! The offline Trace surface of the Windows daemon (TASK-XPA-021, decision
//! 5), as the real daemon serves it over an isolated development root with
//! no ArkTrace distribution, which is every Windows host today: this
//! repository pins only a macOS arm64 `trace_streamer`
//! (`Packages/ArkDeckKit/ThirdParty/TraceStreamer/macx`).
//!
//! * `trace.inspect` is Swift's owner composed without a Trace inspector:
//!   every request of the recorded oracle
//!   (`rust/tests/fixtures/trace-inspect-unavailable`,
//!   `TraceInspectOracleContractTests`) gets Swift's refusal, byte for byte,
//!   before a parameter is read — nothing dispatched and no device
//!   evidence created;
//! * `trace.cache.status` and `trace.cache.purge` are refused as the macOS
//!   daemon refuses them without its Trace cache owner (`rejected`, nothing
//!   removed);
//! * `operation.list` names both ArkTrace analyzers unavailable, with a
//!   typed reason code (`provider_not_registered`: the Windows daemon
//!   composes no analyzer provider);
//! * a development root that names an ArkTrace descriptor is refused before
//!   anything is opened, read or started: the Windows daemon loads no
//!   distribution, pinned or not.
//!
//! Every daemon runs with every `ARKDECK_` and `OHOS_HDC_` input removed but
//! the ones named here; nothing installed is read or written and no HDC is
//! configured. The pipe is reached with a plain handle, as the lifecycle
//! test reaches it: the product client's daemon identity check is not what
//! this proves, and nothing here relaxes it. Each daemon is stopped by its
//! own stop request, and every wait is on the daemon's own output or exit,
//! never on time.
#![cfg(windows)]

use arkdeck_platform::StateRoot;
use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc::{self, Receiver};
use std::sync::{Mutex, MutexGuard, PoisonError};
use std::time::{Duration, Instant};

/// One test at a time: a child spawned while another test spawns inherits
/// that test's inheritable handles.
static TURN: Mutex<()> = Mutex::new(());
fn turn() -> MutexGuard<'static, ()> {
    TURN.lock().unwrap_or_else(PoisonError::into_inner)
}

const DEADLINE: Duration = Duration::from_secs(60);

fn fixture(path: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/fixtures")
        .join(path)
}

/// A fresh development root, removed afterwards.
struct Root(PathBuf);
impl Root {
    fn new() -> Self {
        let nonce = u64::from_ne_bytes(arkdeck_platform::random_bytes::<8>().unwrap());
        let path = std::env::temp_dir().join(format!("ad-wintrace-{nonce:016x}"));
        std::fs::create_dir(&path).unwrap();
        Self(path)
    }
}
impl Drop for Root {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn daemon(root: &Path) -> Command {
    let mut command = Command::new(env!("CARGO_BIN_EXE_arkdeck-agentd"));
    for (key, _) in std::env::vars_os() {
        let key = key.to_string_lossy().into_owned();
        if key.to_ascii_uppercase().starts_with("ARKDECK_")
            || key.to_ascii_uppercase().starts_with("OHOS_HDC_")
        {
            command.env_remove(key);
        }
    }
    command
        .env("ARKDECK_DEVELOPMENT_STATE_ROOT", root)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    command
}

/// A running daemon, its stdout read line by line as it comes.
struct Daemon {
    child: Option<Child>,
    lines: Receiver<String>,
}

impl Daemon {
    fn start(root: &Path) -> Self {
        let mut child = daemon(root).spawn().unwrap();
        let stdout = child.stdout.take().unwrap();
        let (sender, lines) = mpsc::channel();
        std::thread::spawn(move || {
            for line in BufReader::new(stdout).lines() {
                let Ok(line) = line else { break };
                if sender.send(line).is_err() {
                    break;
                }
            }
        });
        Self {
            child: Some(child),
            lines,
        }
    }

    /// The first line that starts with `prefix`.
    fn line_starting(&mut self, prefix: &str) -> String {
        let deadline = Instant::now() + DEADLINE;
        loop {
            let left = deadline.saturating_duration_since(Instant::now());
            match self.lines.recv_timeout(left) {
                Ok(line) if line.starts_with(prefix) => return line,
                Ok(_) => {}
                Err(error) => panic!("no line starting {prefix:?}: {error}"),
            }
        }
    }

    /// Its pipe, from the line it announces it with.
    fn serving(&mut self) -> String {
        self.line_starting("arkdeck-agentd listening on ")
            .trim_start_matches("arkdeck-agentd listening on ")
            .to_owned()
    }

    /// Asks it to stop by its root's scope and waits for its end.
    fn stop(&mut self, root: &Path) {
        let child = self.child.take().unwrap();
        let scope = StateRoot::development(root).unwrap().scope().unwrap();
        scope.request_stop(child.id()).unwrap();
        self.line_starting("arkdeck-agentd stopped");
        let status = wait(child);
        assert!(status.success(), "{status:?}");
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        if let Some(mut child) = self.child.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}

/// The child's end, within the deadline.
fn wait(mut child: Child) -> std::process::ExitStatus {
    let (sender, receiver) = mpsc::channel();
    let waiter = std::thread::spawn(move || {
        let status = child.wait();
        let _ = sender.send(());
        (child, status)
    });
    receiver
        .recv_timeout(DEADLINE)
        .expect("the daemon did not end within the deadline");
    waiter.join().unwrap().1.unwrap()
}

/// One connection to the daemon's pipe, exchanging one frame at a time.
struct Connection(std::fs::File);

impl Connection {
    fn open(pipe: &str) -> Self {
        Self(
            std::fs::OpenOptions::new()
                .read(true)
                .write(true)
                .open(pipe)
                .unwrap(),
        )
    }

    fn exchange(&mut self, id: &str, method: &str, params: Option<&Value>) -> Value {
        let mut request = json!({
            "protocolVersion": arkdeck_contract::PROTOCOL_VERSION,
            "contractIdentity": arkdeck_contract::CONTRACT_IDENTITY,
            "id": id,
            "method": method,
        });
        if let Some(params) = params {
            request["params"] = params.clone();
        }
        let mut frame = serde_json::to_vec(&request).unwrap();
        frame.push(b'\n');
        self.0.write_all(&frame).unwrap();
        let mut reply = Vec::new();
        let mut byte = [0u8; 1];
        while byte[0] != b'\n' {
            assert_eq!(self.0.read(&mut byte).unwrap(), 1, "the reply ended early");
            reply.push(byte[0]);
        }
        let reply: Value = serde_json::from_slice(&reply).unwrap();
        assert_eq!(reply["id"], id, "{reply}");
        reply
    }

    /// The reply as the oracle records an answer: `ok` and `error`.
    fn answer(&mut self, id: &str, method: &str, params: Option<&Value>) -> Value {
        let reply = self.exchange(id, method, params);
        assert_eq!(reply["ok"], false, "{reply}");
        json!({"ok": false, "error": reply["error"]})
    }
}

#[test]
fn the_windows_daemon_answers_the_offline_trace_surface_without_a_distribution() {
    let _turn = turn();
    let root = Root::new();
    let mut daemon = Daemon::start(&root.0);
    let pipe = daemon.serving();
    let mut connection = Connection::open(&pipe);
    let health = connection.exchange("health", "health", None);
    assert_eq!(health["ok"], true, "{health}");

    // Swift's `trace.inspect` without a Trace inspector, every recorded
    // request, then parameters the method's schema refuses: the same owner
    // refusal, before any parameter is read.
    let oracle: Value = serde_json::from_slice(
        &std::fs::read(fixture("trace-inspect-unavailable/cases.json")).unwrap(),
    )
    .unwrap();
    let exchanges = oracle["exchanges"].as_array().unwrap();
    assert_eq!(exchanges.len(), 7);
    for exchange in exchanges {
        assert_eq!(exchange["method"], "trace.inspect");
        let name = exchange["name"].as_str().unwrap();
        assert_eq!(
            connection.answer(name, "trace.inspect", Some(&exchange["params"])),
            exchange["answer"],
            "{name}"
        );
    }
    let refused = &exchanges[0]["answer"];
    for (index, params) in [
        json!({"extra": true}),
        json!({"artifactId": 1, "owner": "job", "timeoutMs": "1000"}),
        json!({"owner": {"kind": "job", "id": "job-trace-inspect", "extra": 1}}),
    ]
    .iter()
    .enumerate()
    {
        assert_eq!(
            connection.answer(&format!("schema-{index}"), "trace.inspect", Some(params)),
            *refused,
            "{params}"
        );
    }

    // The Trace cache owner is not composed: both methods are refused with
    // nothing removed, as the macOS daemon refuses them without that owner.
    for method in ["trace.cache.status", "trace.cache.purge"] {
        let answer = connection.answer(method, method, None);
        assert_eq!(answer["error"]["code"], "rejected", "{method}: {answer}");
        assert!(answer["error"]["details"].is_null(), "{method}: {answer}");
    }

    // Both ArkTrace analyzers are unavailable with a typed reason.
    let list = connection.exchange("operations", "operation.list", None);
    assert_eq!(list["ok"], true, "{list}");
    let operations = list["result"].as_array().unwrap();
    for reference in ["analyzer.summarize-trace@1", "analyzer.analyze-trace@1"] {
        let operation = operations
            .iter()
            .find(|operation| operation["reference"] == reference)
            .unwrap_or_else(|| panic!("{reference} is not listed"));
        assert_eq!(operation["availability"], "unavailable", "{operation}");
        assert_eq!(
            operation["reasonCodes"],
            json!(["provider_not_registered"]),
            "{operation}"
        );
        assert_eq!(operation["reasonOrigins"], json!(["product_build"]));
    }

    drop(connection);
    daemon.stop(&root.0);
}

#[test]
fn a_development_root_naming_an_arktrace_descriptor_starts_nothing() {
    let _turn = turn();
    let root = Root::new();
    // An existing file, the macOS loader oracle's inputs: the Windows daemon
    // refuses the setting by name, before it opens the root or reads what
    // the setting names.
    let refused = daemon(&root.0)
        .env(
            "ARKDECK_ARKTRACE_DESCRIPTOR",
            fixture("arktrace-profile-loader/inputs.json"),
        )
        .output()
        .unwrap();
    assert!(!refused.status.success(), "{refused:?}");
    let stderr = String::from_utf8_lossy(&refused.stderr);
    assert!(
        stderr.contains(
            "ARKDECK_ARKTRACE_DESCRIPTOR is not composed by the Windows development root yet; \
             nothing was started"
        ),
        "{stderr}"
    );
    assert!(refused.stdout.is_empty(), "{refused:?}");
    assert_eq!(
        std::fs::read_dir(&root.0).unwrap().count(),
        0,
        "the refused start created nothing in its root"
    );
}
