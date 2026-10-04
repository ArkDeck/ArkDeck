//! The Windows daemon's History filter owner (TASK-XPA-012 on Windows), as
//! the real daemon composes it over an isolated development root.
//!
//! * Over its pipe, with a plain pipe handle (no signer needed): the
//!   committed control-frame corpus's `history.filter.list|save|delete`
//!   answers (`Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/
//!   ControlFrames`) are replayed in the order that reaches each recorded
//!   generation, across restarts: every result is the recorded one but the
//!   time the daemon's own clock writes, every refusal its code and details.
//!   The document is `history-filter\history-filter.json` under
//!   `.history-filter.lock`, the macOS store's frozen encoding; a document
//!   Swift wrote reads as Swift answered it; another holder of the lock
//!   refuses a save and nothing is written; a directory that is not
//!   owner-only refuses the start.
//! * Through the real CLI against a copy of the daemon signed with the
//!   host-trusted development signer (`ARKDECK_DEV_SIGNER_THUMBPRINT`, as
//!   `rust/scripts/check-readonly.py` signs one): `history filter
//!   list|save|delete` across a restart, which then count as Windows
//!   `implemented`. Without that variable this test says so and checks
//!   nothing.
//!
//! Every daemon runs with every `ARKDECK_` and `OHOS_HDC_` input removed but
//! its development root, a fresh directory below the temporary directory:
//! nothing installed is read or written, and no HDC or device is involved.
//! Each daemon is stopped by its own stop request, or ended by this test if
//! it outlives a failed assertion.
#![cfg(windows)]

use arkdeck_platform::{HostDirectory, StateRoot};
use serde_json::{Map, Value, json};
use std::io::{BufRead, BufReader, Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc::{self, Receiver};
use std::sync::{Mutex, MutexGuard, PoisonError};
use std::time::{Duration, Instant};

/// One test at a time: a child spawned while another test's daemon starts
/// would inherit that daemon's inheritable handles.
static TURN: Mutex<()> = Mutex::new(());
fn turn() -> MutexGuard<'static, ()> {
    TURN.lock().unwrap_or_else(PoisonError::into_inner)
}

const DEADLINE: Duration = Duration::from_secs(60);
const DOCUMENT: &str = "history-filter.json";
const LOCK: &str = ".history-filter.lock";
/// The document Swift wrote for the corpus's recorded `flash` filter.
const SWIFT_DOCUMENT: &[u8] = b"{\"generation\":2,\"query\":{\"activity\":\"flash\",\"mode\":\"execute\",\"search\":\"flash failure\",\"sessionID\":\"session-1\",\"status\":\"needsAttention\",\"targetID\":\"target-1\",\"timeRange\":\"lastWeek\"},\"schemaVersion\":\"arkdeck.history-filter-store/1\",\"updatedAtUTC\":\"2026-09-01T08:30:00.000Z\"}\n";

/// A fresh development root, removed afterwards.
struct Root(PathBuf);
impl Root {
    fn new() -> Self {
        let nonce = u64::from_ne_bytes(arkdeck_platform::random_bytes::<8>().unwrap());
        let path = std::env::temp_dir()
            .canonicalize()
            .unwrap()
            .join(format!("ad-winhistory-{nonce:016x}"));
        std::fs::create_dir(&path).unwrap();
        Self(path)
    }
    fn store(&self) -> PathBuf {
        self.0.join("history-filter")
    }
    fn document(&self) -> Vec<u8> {
        std::fs::read(self.store().join(DOCUMENT)).unwrap()
    }
    /// The store Swift left: its document, in a private `history-filter` the
    /// store itself creates.
    fn with_swift_document(self) -> Self {
        let directory = HostDirectory::open_or_create_private(&self.store()).unwrap();
        directory.create_document(DOCUMENT, SWIFT_DOCUMENT).unwrap();
        self
    }
}
impl Drop for Root {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn daemon(executable: &Path, root: &Path) -> Command {
    let mut command = Command::new(executable);
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
    seen: Vec<String>,
}

impl Daemon {
    fn start(executable: &Path, root: &Path) -> Self {
        let mut child = daemon(executable, root).spawn().unwrap();
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
            seen: Vec::new(),
        }
    }

    fn pid(&self) -> u32 {
        self.child.as_ref().unwrap().id()
    }

    /// Every line up to the first that starts with `prefix`, which is returned.
    fn line_starting(&mut self, prefix: &str) -> String {
        let deadline = Instant::now() + DEADLINE;
        loop {
            let left = deadline.saturating_duration_since(Instant::now());
            match self.lines.recv_timeout(left) {
                Ok(line) => {
                    self.seen.push(line.clone());
                    if line.starts_with(prefix) {
                        return line;
                    }
                }
                Err(error) => panic!(
                    "no line starting {prefix:?} ({error}); stdout so far {:?}",
                    self.seen
                ),
            }
        }
    }

    /// Serving: its pipe, from the line it announces it with.
    fn serving(&mut self) -> String {
        self.line_starting("arkdeck-agentd listening on ")
            .trim_start_matches("arkdeck-agentd listening on ")
            .to_owned()
    }

    /// Asks it to stop, by its root's scope and its pid, and waits for its end.
    fn stop(&mut self, root: &Path) {
        let scope = StateRoot::development(root).unwrap().scope().unwrap();
        scope.request_stop(self.pid()).unwrap();
        self.line_starting("arkdeck-agentd stopped");
        let status = wait(self.child.take().unwrap());
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

/// One request on a fresh plain handle of the daemon's pipe.
fn request(pipe: &str, method: &str, params: Value) -> Value {
    let mut connection = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open(pipe)
        .unwrap();
    let mut frame = serde_json::to_vec(&json!({
        "protocolVersion": arkdeck_contract::PROTOCOL_VERSION,
        "contractIdentity": arkdeck_contract::CONTRACT_IDENTITY,
        "id": method,
        "method": method,
        "params": params,
    }))
    .unwrap();
    frame.push(b'\n');
    connection.write_all(&frame).unwrap();
    let mut reply = Vec::new();
    let mut byte = [0u8; 1];
    while byte[0] != b'\n' {
        assert_eq!(
            connection.read(&mut byte).unwrap(),
            1,
            "the reply ended early"
        );
        reply.push(byte[0]);
    }
    serde_json::from_slice(&reply).unwrap()
}

fn corpus(method: &str) -> Vec<Value> {
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join(format!(
        "../../../Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames/{method}.jsonl"
    ));
    std::fs::read_to_string(&path)
        .unwrap_or_else(|error| panic!("{path:?}: {error}"))
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect()
}

fn params(frame: &Value) -> Value {
    Value::Object(frame["params"].as_object().cloned().unwrap_or_default())
}

/// `value` without the times the daemon's own clock writes: every
/// `updatedAtUtc` that is not null becomes `"<now>"`.
fn untimed(value: &Value) -> Value {
    match value {
        Value::Object(map) => Value::Object(
            map.iter()
                .map(|(key, value)| {
                    let value = if key == "updatedAtUtc" && !value.is_null() {
                        json!("<now>")
                    } else {
                        untimed(value)
                    };
                    (key.clone(), value)
                })
                .collect::<Map<_, _>>(),
        ),
        Value::Array(items) => Value::Array(items.iter().map(untimed).collect()),
        other => other.clone(),
    }
}

/// The daemon's answer to a recorded frame: the recorded result but the
/// daemon's own time, or the recorded refusal's code and details (its
/// message is not compared). The answer is returned.
fn replay(pipe: &str, frame: &Value) -> Value {
    let method = frame["method"].as_str().unwrap();
    let reply = request(pipe, method, params(frame));
    assert_eq!(reply["ok"], frame["ok"], "{frame}: answered {reply}");
    if reply["ok"] == true {
        assert_eq!(
            untimed(&reply["result"]),
            untimed(&frame["result"]),
            "{frame}"
        );
    } else {
        assert_eq!(reply["error"]["code"], frame["error"]["code"], "{frame}");
        assert_eq!(
            reply["error"]["details"], frame["error"]["details"],
            "{frame}"
        );
    }
    reply
}

/// The store's document after a write at the daemon's time `at`, which the
/// answer carried: the frozen encoding with that time.
fn written(generation: u64, query: Option<&str>, at: &Value) -> Vec<u8> {
    let query = query.map_or(String::new(), |query| format!(",\"query\":{query}"));
    format!(
        "{{\"generation\":{generation}{query},\"schemaVersion\":\"arkdeck.history-filter-store/1\",\"updatedAtUTC\":{at}}}\n"
    )
    .into_bytes()
}

#[test]
fn the_recorded_history_filter_frames_replay_over_the_pipe_across_restarts() {
    let _turn = turn();
    let (list, saves, deletes) = (
        corpus("history.filter.list"),
        corpus("history.filter.save"),
        corpus("history.filter.delete"),
    );
    let root = Root::new();
    let executable = Path::new(env!("CARGO_BIN_EXE_arkdeck-agentd"));

    let mut first = Daemon::start(executable, &root.0);
    let pipe = first.serving();
    assert!(
        first.seen.contains(
            &"arkdeck-agentd owners: jobs, capabilities, mutationAuthority, targets, artifacts, imports, storage, history, workspaceProjects, workspaceOperations, bootstrap, planning, agentExecutions, humanActions, controlActions, traceCache, flashAliasReconciler, flashInvocations, flashHostFacts, deviceAccess, loaderBinding"
                .to_owned(),
        ),
        "{:?}",
        first.seen
    );
    // The empty store, then the recorded `compile` filter at generation 2.
    replay(&pipe, &list[2]);
    let compile = json!({"expectedGeneration": "1", "search": "compile", "status": "all",
        "mode": "all", "timeRange": "anyTime", "activity": "all", "sessionId": null,
        "targetId": null});
    let saved = request(&pipe, "history.filter.save", compile);
    assert_eq!(saved["ok"], true, "{saved}");
    assert_eq!(
        root.document(),
        written(
            2,
            Some(
                r#"{"activity":"all","mode":"all","search":"compile","status":"all","timeRange":"anyTime"}"#
            ),
            &saved["result"]["updatedAtUtc"],
        )
    );
    replay(&pipe, &list[4]);
    first.stop(&root.0);

    // Restarted: read back, then saved at 2 and 3.
    let mut second = Daemon::start(executable, &root.0);
    let pipe = second.serving();
    replay(&pipe, &list[4]);
    replay(&pipe, &saves[1]);
    let saved = replay(&pipe, &saves[2]);
    let before = root.document();
    assert_eq!(
        before,
        written(
            4,
            Some(
                r#"{"activity":"all","mode":"all","search":"build","sessionID":"s1","status":"failed","targetID":"t1","timeRange":"lastDay"}"#
            ),
            &saved["result"]["updatedAtUtc"],
        )
    );
    // Another holder of the store's lock: the save is refused and nothing
    // is written.
    {
        let other = HostDirectory::open(&root.store()).unwrap();
        let _held = other.lock_document(LOCK).unwrap();
        replay(&pipe, &saves[0]);
    }
    assert_eq!(root.document(), before);
    second.stop(&root.0);

    // Restarted: saved to 5, where a stale generation's delete is refused,
    // deleted to 6, and then nothing is left to delete.
    let mut third = Daemon::start(executable, &root.0);
    let pipe = third.serving();
    let saved = request(&pipe, "history.filter.save", params(&saves[0]));
    assert_eq!(saved["result"]["generation"], "5", "{saved}");
    replay(&pipe, &deletes[3]);
    let deleted = replay(&pipe, &deletes[1]);
    assert_eq!(
        root.document(),
        written(6, None, &deleted["result"]["updatedAtUtc"])
    );
    third.stop(&root.0);

    let mut fourth = Daemon::start(executable, &root.0);
    let pipe = fourth.serving();
    replay(&pipe, &list[3]);
    replay(&pipe, &deletes[0]);
    fourth.stop(&root.0);
    assert!(
        !std::fs::read_dir(root.store()).unwrap().any(|entry| entry
            .unwrap()
            .file_name()
            .to_string_lossy()
            .ends_with(".part")),
        "no staged document is left"
    );
}

#[test]
fn a_document_swift_wrote_reads_as_swift_answered_it() {
    let _turn = turn();
    let list = corpus("history.filter.list");
    let root = Root::new().with_swift_document();
    let executable = Path::new(env!("CARGO_BIN_EXE_arkdeck-agentd"));
    let mut daemon = Daemon::start(executable, &root.0);
    let pipe = daemon.serving();
    // The recorded answer exactly, Swift's milliseconds included.
    let reply = request(&pipe, "history.filter.list", json!({}));
    assert_eq!(reply["result"], list[5]["result"], "{reply}");
    // A document the owner cannot read refuses that request only.
    std::fs::remove_file(root.store().join(DOCUMENT)).unwrap();
    HostDirectory::open(&root.store())
        .unwrap()
        .create_document(DOCUMENT, b"corrupt")
        .unwrap();
    replay(&pipe, &list[0]);
    let save = request(
        &pipe,
        "history.filter.save",
        params(&corpus("history.filter.save")[1]),
    );
    assert_eq!(save["error"], list[0]["error"], "{save}");
    assert_eq!(root.document(), b"corrupt");
    let health = request(&pipe, "health", json!({}));
    assert_eq!(health["ok"], true, "{health}");
    daemon.stop(&root.0);
}

#[test]
fn a_history_filter_directory_that_is_not_owner_only_refuses_the_start() {
    let _turn = turn();
    let root = Root::new();
    // Created as any directory below the temporary directory is: it
    // inherits grants to others, which the store refuses and never rewrites.
    std::fs::create_dir(root.store()).unwrap();
    let output = daemon(Path::new(env!("CARGO_BIN_EXE_arkdeck-agentd")), &root.0)
        .output()
        .unwrap();
    assert_eq!(output.status.code(), Some(69), "{output:?}");
    let stderr = String::from_utf8(output.stderr).unwrap();
    assert!(
        stderr.contains("the History filter store") && stderr.contains("nothing was started"),
        "{stderr}"
    );
    assert!(
        !String::from_utf8(output.stdout)
            .unwrap()
            .contains("listening on"),
        "nothing served"
    );
    assert!(!root.store().join(DOCUMENT).exists());
}

/// PowerShell 7, which signs the development daemon.
fn pwsh() -> PathBuf {
    if let Some(found) = std::env::var_os("PATH").and_then(|path| {
        std::env::split_paths(&path)
            .map(|directory| directory.join("pwsh.exe"))
            .find(|candidate| candidate.exists())
    }) {
        return found;
    }
    let alias = PathBuf::from(std::env::var_os("LOCALAPPDATA").expect("LOCALAPPDATA"))
        .join("Microsoft/WindowsApps/pwsh.exe");
    assert!(
        alias.exists(),
        "PowerShell 7 is required to sign the development daemon"
    );
    alias
}

/// The real CLI beside the daemon, against `pipe`, verifying `daemon` and
/// its signer `pin` as it verifies an installed daemon.
fn cli(daemon: &Path, pin: &str, pipe: &str, arguments: &[&str]) -> (Option<i32>, Value) {
    let cli = Path::new(env!("CARGO_BIN_EXE_arkdeck-agentd")).with_file_name("arkdeck.exe");
    let mut command = Command::new(&cli);
    for (key, _) in std::env::vars_os() {
        if key
            .to_string_lossy()
            .to_ascii_uppercase()
            .starts_with("ARKDECK_")
        {
            command.env_remove(key);
        }
    }
    let output = command
        .args(arguments)
        .args(["--output", "json"])
        .env("ARKDECK_ENDPOINT", pipe)
        .env("ARKDECK_DAEMON_PATH", daemon)
        .env("ARKDECK_DAEMON_SIGNER_SHA256", pin)
        .stdin(Stdio::null())
        .output()
        .unwrap_or_else(|error| {
            panic!(
                "the arkdeck CLI beside the daemon ({}): {error}; run the workspace tests, or \
                 `cargo build -p arkdeck-cli` before testing this crate alone",
                cli.display()
            )
        });
    let envelope = serde_json::from_slice(&output.stdout)
        .unwrap_or_else(|_| panic!("{arguments:?}: {output:?}"));
    (output.status.code(), envelope)
}

/// Every coverage entry for each of `leaves` is Windows `implemented` in the
/// manifest this CLI renders.
fn assert_measured(leaves: &[&str]) {
    let product = arkdeck_cli::machine_contracts::contract_products()
        .into_iter()
        .find(|product| product.relative_path == "cli-feature-coverage.json")
        .expect("the CLI renders its feature coverage");
    let coverage: Value = serde_json::from_slice(&product.bytes).unwrap();
    for leaf in leaves {
        let statuses: Vec<&Value> = coverage["entries"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|entry| entry["feature"] == *leaf)
            .map(|entry| &entry["implementationStatusByPlatform"]["windows"])
            .collect();
        assert!(
            !statuses.is_empty() && statuses.iter().all(|status| *status == "implemented"),
            "{leaf}: {statuses:?}"
        );
    }
}

#[test]
fn history_filters_run_through_the_cli_against_a_dev_signed_daemon() {
    let Some(thumbprint) =
        std::env::var_os("ARKDECK_DEV_SIGNER_THUMBPRINT").filter(|value| !value.is_empty())
    else {
        eprintln!(
            "SKIPPED: ARKDECK_DEV_SIGNER_THUMBPRINT is not set (or empty), so no host-trusted development \
             signer can sign the daemon the CLI must verify (rust/scripts/windows-dev-identity.ps1 \
             create); nothing was checked"
        );
        return;
    };
    let _turn = turn();
    let root = Root::new().with_swift_document();
    let signed = root.0.join("signed-bin");
    std::fs::create_dir(&signed).unwrap();
    let daemon = signed.join("arkdeck-agentd.exe");
    std::fs::copy(env!("CARGO_BIN_EXE_arkdeck-agentd"), &daemon).unwrap();
    let script =
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../../scripts/windows-dev-identity.ps1");
    let signing = Command::new(pwsh())
        .args(["-NoProfile", "-NonInteractive", "-File"])
        .arg(&script)
        .arg("sign")
        .arg("-Thumbprint")
        .arg(&thumbprint)
        .arg("-Path")
        .arg(&daemon)
        .stdin(Stdio::null())
        .output()
        .unwrap();
    assert!(signing.status.success(), "{signing:?}");
    let pin: Value = serde_json::from_slice(&signing.stdout).unwrap();
    let pin = pin["pin"].as_str().unwrap().to_owned();
    let list = corpus("history.filter.list");

    let mut first = Daemon::start(&daemon, &root.0);
    let pipe = first.serving();
    let (status, envelope) = cli(&daemon, &pin, &pipe, &["history", "filter", "list"]);
    assert_eq!(status, Some(0), "{envelope}");
    assert_eq!(envelope["result"], list[5]["result"], "{envelope}");
    let (status, envelope) = cli(
        &daemon,
        &pin,
        &pipe,
        &[
            "history",
            "filter",
            "save",
            "--expected-generation",
            "2",
            "--search",
            "build",
            "--status",
            "failed",
            "--time",
            "lastDay",
            "--session",
            "s1",
            "--target",
            "t1",
        ],
    );
    assert_eq!(status, Some(0), "{envelope}");
    // The recorded save of this query, at the generation after Swift's.
    let mut recorded = untimed(&corpus("history.filter.save")[2]["result"]);
    recorded["generation"] = json!("3");
    assert_eq!(untimed(&envelope["result"]), recorded, "{envelope}");
    // A stale generation is refused and changes nothing.
    let before = root.document();
    let (status, envelope) = cli(
        &daemon,
        &pin,
        &pipe,
        &["history", "filter", "delete", "--expected-generation", "2"],
    );
    assert_ne!(status, Some(0), "{envelope}");
    assert_eq!(envelope["error"]["code"], "resourceConflict", "{envelope}");
    assert_eq!(root.document(), before);
    first.stop(&root.0);

    let mut second = Daemon::start(&daemon, &root.0);
    let pipe = second.serving();
    let (status, envelope) = cli(&daemon, &pin, &pipe, &["history", "filter", "list"]);
    assert_eq!(status, Some(0), "{envelope}");
    assert_eq!(envelope["result"]["generation"], "3", "{envelope}");
    assert_eq!(
        envelope["result"]["filters"][0]["query"]["sessionId"], "s1",
        "{envelope}"
    );
    let (status, envelope) = cli(
        &daemon,
        &pin,
        &pipe,
        &["history", "filter", "delete", "--expected-generation", "3"],
    );
    assert_eq!(status, Some(0), "{envelope}");
    assert_eq!(envelope["result"]["generation"], "4", "{envelope}");
    assert!(envelope["result"]["query"].is_null(), "{envelope}");
    second.stop(&root.0);

    let mut third = Daemon::start(&daemon, &root.0);
    let pipe = third.serving();
    let (status, envelope) = cli(&daemon, &pin, &pipe, &["history", "filter", "list"]);
    assert_eq!(status, Some(0), "{envelope}");
    assert_eq!(envelope["result"]["generation"], "4", "{envelope}");
    assert_eq!(envelope["result"]["filters"], json!([]), "{envelope}");
    third.stop(&root.0);
    assert_measured(&[
        "history.filter.list",
        "history.filter.save",
        "history.filter.delete",
    ]);
}
