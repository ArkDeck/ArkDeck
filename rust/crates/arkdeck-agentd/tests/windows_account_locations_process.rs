//! The installed (account) daemon's Sessions root and Trace cache on Windows
//! (TASK-XPA-002/005): `%LOCALAPPDATA%\ArkDeck\Sessions` and
//! `%LOCALAPPDATA%\ArkDeck\Trace\traces` beside the state directory
//! `%LOCALAPPDATA%\ArkDeck\Agentd`, as macOS keeps `ArkDeck/Sessions` and the
//! App's `ArkDeck/Trace/traces`, with the one-time move of an earlier build's
//! `Agentd\sessions`.
//!
//! The real daemon runs its account composition (no development root) over a
//! fake account: `%LOCALAPPDATA%` is the Known Folder `FOLDERID_LocalAppData`,
//! which the Shell expands from the process's `USERPROFILE`, so a daemon
//! started with `USERPROFILE` naming a fresh directory below the temporary
//! directory owns `<it>\AppData\Local\ArkDeck` and nothing of the account's
//! own. Its single-instance guard and pipe are still the account's (they are
//! named after the user and logon SIDs), so the test refuses to run while an
//! account daemon serves. Each scenario runs with the fake account spelled
//! as the file system spells it and with its 8.3 short name (as a hosted
//! runner's `TEMP`, `C:\Users\RUNNER~1\…`, spells it):
//!
//! * an earlier build's layout (its settings selecting the default root at
//!   `Agentd\sessions`, holding a retained Session) is moved at the start:
//!   the Session is read from `ArkDeck\Sessions` over the pipe, the settings
//!   select it one generation on, `Agentd\sessions` is gone, and the Trace
//!   cache owner answers over `ArkDeck\Trace\traces`; a restart reads the
//!   same and moves nothing;
//! * an earlier root that is empty beside an existing `Sessions` is removed;
//!   one holding a Session beside an existing `Sessions` refuses the start
//!   and neither is changed;
//! * through the real CLI against a copy of the daemon signed with the
//!   host-trusted development signer (`ARKDECK_DEV_SIGNER_THUMBPRINT`):
//!   `runtime storage status` names the same Sessions root and `trace cache
//!   status` answers the same inventory. Without that variable this part says
//!   so and checks nothing.
#![cfg(windows)]

use arkdeck_hoststore::SessionStore;
use arkdeck_platform::{HostDirectory, InstanceScope, default_user_endpoint, pipe_present};
use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Read, Write};
use std::os::windows::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc::{self, Receiver};
use std::sync::{Mutex, MutexGuard, PoisonError};
use std::time::{Duration, Instant};

/// One test at a time: they share the account's guard and pipe.
static TURN: Mutex<()> = Mutex::new(());
fn turn() -> MutexGuard<'static, ()> {
    TURN.lock().unwrap_or_else(PoisonError::into_inner)
}

const DEADLINE: Duration = Duration::from_secs(60);
const SESSION: &str = "session-fixture";

fn oracle() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/fixtures/storage-lock-wait-oracle")
}

fn plain(path: PathBuf) -> PathBuf {
    match path.to_str().and_then(|text| text.strip_prefix(r"\\?\")) {
        Some(text) => PathBuf::from(text),
        None => path,
    }
}

/// The 8.3 short spelling of an existing path, as `cmd` names it.
fn short(path: &Path) -> PathBuf {
    let output = Command::new("cmd")
        .raw_arg(format!(
            "/d /c for %I in (\"{}\") do @echo %~sI",
            path.display()
        ))
        .stdin(Stdio::null())
        .output()
        .unwrap();
    assert!(output.status.success(), "{output:?}");
    PathBuf::from(String::from_utf8(output.stdout).unwrap().trim())
}

/// A fake account below the temporary directory: its profile (under a name
/// long enough to have an 8.3 alias) and `AppData\Local`, removed afterwards.
struct Account {
    profile: PathBuf,
    /// The spelling the daemon and the CLI are given.
    spelled: PathBuf,
}

impl Account {
    fn new(short_name: bool) -> Self {
        let nonce = u64::from_ne_bytes(arkdeck_platform::random_bytes::<8>().unwrap());
        let temporary = plain(std::env::temp_dir().canonicalize().unwrap());
        let profile = temporary.join(format!("ad-fake-account-{nonce:016x}"));
        std::fs::create_dir_all(profile.join("AppData").join("Local")).unwrap();
        let spelled = if short_name {
            short(&profile)
        } else {
            profile.clone()
        };
        Self { profile, spelled }
    }
    fn product(&self) -> PathBuf {
        self.profile.join("AppData").join("Local").join("ArkDeck")
    }
    fn state(&self) -> PathBuf {
        self.product().join("Agentd")
    }
    fn sessions(&self) -> PathBuf {
        self.product().join("Sessions")
    }

    /// The oracle's retained Session in a new private Session root at `path`.
    fn session_root(path: &Path) {
        let session = HostDirectory::open_or_create_private(path)
            .unwrap()
            .create_private_child("2026")
            .unwrap()
            .create_private_child("09")
            .unwrap()
            .create_private_child(SESSION)
            .unwrap();
        session
            .create_document(
                ".session-identity.json",
                br#"{"jobId":"job-fixture","schemaVersion":"1.0.0","sessionId":"session-fixture"}"#,
            )
            .unwrap();
        session
            .create_document(
                "manifest.json",
                &std::fs::read(oracle().join("manifest.json")).unwrap(),
            )
            .unwrap();
        session.create_document("payload.bin", &[0x53; 48]).unwrap();
    }

    /// An earlier build's layout: the product directory and state directory
    /// owner-only, the settings in `Agentd\session-state` selecting the
    /// default root at `Agentd\sessions` (published by the Session owner
    /// itself, one policy update on), and the retained Session in it.
    fn with_earlier_layout(self) -> Self {
        HostDirectory::open_or_create_private(&self.product()).unwrap();
        let state = HostDirectory::open_or_create_private(&self.state()).unwrap();
        state.create_private_child("session-state").unwrap();
        Self::session_root(&self.state().join("sessions"));
        let store = SessionStore::open(
            &self.state().join("session-state"),
            &self.state().join("sessions"),
        )
        .unwrap();
        let policy = json!({"expectedGeneration": "1", "retentionDays": "30",
            "safetyMarginBytes": "1000", "totalQuotaBytes": "500000"});
        store
            .handle("runtime.storage.policy", policy.as_object().unwrap())
            .unwrap();
        self
    }

    fn settings(&self) -> Value {
        serde_json::from_slice(
            &std::fs::read(
                self.state()
                    .join("session-state")
                    .join("session-storage.json"),
            )
            .unwrap(),
        )
        .unwrap()
    }

    /// Every entry below `path` with its bytes, but the retention catalog,
    /// which the Session owner reconciles with the settings' generation
    /// whenever it reads the root.
    fn tree(path: &Path) -> Vec<(String, Option<Vec<u8>>)> {
        let mut entries = Vec::new();
        let mut pending = vec![path.to_path_buf()];
        while let Some(directory) = pending.pop() {
            for entry in std::fs::read_dir(&directory).unwrap() {
                let entry = entry.unwrap().path();
                let relative = entry.strip_prefix(path).unwrap().display().to_string();
                if relative.starts_with(".arkdeck-retention-catalog") {
                    continue;
                }
                if entry.is_dir() {
                    pending.push(entry);
                    entries.push((relative, None));
                } else {
                    entries.push((relative, Some(std::fs::read(&entry).unwrap())));
                }
            }
        }
        entries.sort();
        entries
    }

    fn daemon(&self, executable: &Path) -> Command {
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
            .env("USERPROFILE", &self.spelled)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        command
    }
}

impl Drop for Account {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.profile);
    }
}

/// No account daemon of this user serves: the test's daemon takes its guard
/// and pipe.
fn account_free() -> bool {
    let endpoint = default_user_endpoint().unwrap();
    if pipe_present(&endpoint).unwrap() {
        eprintln!(
            "SKIPPED: an account daemon serves {} on this host, and a daemon over a fake \
             account takes the same guard and pipe; nothing was checked",
            endpoint.as_path().display()
        );
        return false;
    }
    true
}

/// A running daemon, its stdout read line by line as it comes.
struct Daemon {
    child: Option<Child>,
    lines: Receiver<String>,
    seen: Vec<String>,
}

impl Daemon {
    fn start(account: &Account, executable: &Path) -> Self {
        let mut child = account.daemon(executable).spawn().unwrap();
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

    fn serving(&mut self) -> String {
        self.line_starting("arkdeck-agentd listening on ")
            .trim_start_matches("arkdeck-agentd listening on ")
            .to_owned()
    }

    fn stop(&mut self) {
        let pid = self.child.as_ref().unwrap().id();
        InstanceScope::account().unwrap().request_stop(pid).unwrap();
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

fn answered(pipe: &str, method: &str, params: Value) -> Value {
    let reply = request(pipe, method, params);
    assert_eq!(reply["ok"], true, "{method}: {reply}");
    reply["result"].clone()
}

const EMPTY_TRACE_CACHE: &str = r#"{"schemaVersion": "arkdeck.trace-cache-status/1",
    "purgeScope": "inactiveDerivedDatabases", "entryCount": 0, "activeEntryCount": 0,
    "inactiveEntryCount": 0, "totalByteCount": "0"}"#;

/// What the daemon serving `pipe` answers about the Sessions root and the
/// Trace cache: the default root in `ArkDeck\Sessions` holding the retained
/// Session, and the empty Trace cache.
fn assert_account_locations(account: &Account, pipe: &str, generation: &str) {
    let status = answered(pipe, "runtime.storage.status", json!({}));
    let domain = &status["sessionDomain"];
    assert_eq!(
        domain["rootPath"],
        account.sessions().to_str().unwrap(),
        "{status}"
    );
    assert_eq!(domain["rootKind"], "default", "{status}");
    assert_eq!(domain["generation"], generation, "{status}");
    let sessions = answered(pipe, "session.list", json!({}));
    let listed: Vec<&str> = sessions["items"]
        .as_array()
        .unwrap_or_else(|| panic!("{sessions}"))
        .iter()
        .filter_map(|row| row["sessionId"].as_str())
        .collect();
    assert_eq!(listed, [SESSION], "{sessions}");
    assert_eq!(
        answered(pipe, "trace.cache.status", json!({})),
        serde_json::from_str::<Value>(EMPTY_TRACE_CACHE).unwrap()
    );
}

fn earlier_layout_moves_once_and_reads_back(short_name: bool) {
    let _turn = turn();
    if !account_free() {
        return;
    }
    let account = Account::new(short_name).with_earlier_layout();
    let earlier = Account::tree(&account.state().join("sessions"));
    let executable = Path::new(env!("CARGO_BIN_EXE_arkdeck-agentd"));

    let mut first = Daemon::start(&account, executable);
    let pipe = first.serving();
    for line in [
        format!(
            "arkdeck-agentd moved the default Sessions root from {} to {}",
            account.state().join("sessions").display(),
            account.sessions().display()
        ),
        format!(
            "arkdeck-agentd recorded the default Sessions root {} in the Session settings",
            account.sessions().display()
        ),
    ] {
        assert!(first.seen.contains(&line), "{line}: {:?}", first.seen);
    }
    let owners = first
        .seen
        .iter()
        .find(|line| line.starts_with("arkdeck-agentd owners: "))
        .unwrap()
        .clone();
    assert!(
        owners.contains("storage")
            && owners.ends_with("traceCache, flashHostFacts, deviceAccess, loaderBinding"),
        "{owners}"
    );
    // Moved, not copied: the same tree, byte for byte, and nothing left.
    assert!(!account.state().join("sessions").exists());
    assert_eq!(Account::tree(&account.sessions()), earlier);
    for child in ["traces", "staging"] {
        assert!(
            account.product().join("Trace").join(child).is_dir(),
            "{child}"
        );
    }
    // The policy update made generation 2; the move one more.
    assert_eq!(account.settings()["generation"], 3);
    assert_eq!(
        account.settings()["rootPath"],
        account.sessions().to_str().unwrap()
    );
    assert_eq!(account.settings()["policy"]["totalQuotaBytes"], 500000);
    assert_account_locations(&account, &pipe, "3");
    first.stop();

    let mut second = Daemon::start(&account, executable);
    let pipe = second.serving();
    assert!(
        !second.seen.iter().any(|line| line.contains("moved the default")
            || line.contains("recorded the default")),
        "{:?}",
        second.seen
    );
    assert_account_locations(&account, &pipe, "3");
    second.stop();
    assert_eq!(Account::tree(&account.sessions()), earlier);
}

#[test]
fn an_earlier_sessions_root_moves_once_and_reads_back() {
    earlier_layout_moves_once_and_reads_back(false);
}

#[test]
fn an_earlier_sessions_root_moves_once_under_a_short_name_profile() {
    earlier_layout_moves_once_and_reads_back(true);
}

#[test]
fn an_earlier_root_beside_sessions_is_removed_when_empty_and_refuses_otherwise() {
    let _turn = turn();
    if !account_free() {
        return;
    }
    let executable = Path::new(env!("CARGO_BIN_EXE_arkdeck-agentd"));
    for short_name in [false, true] {
        // Empty: removed, and the start goes on over `Sessions`.
        let account = Account::new(short_name);
        HostDirectory::open_or_create_private(&account.product()).unwrap();
        HostDirectory::open_or_create_private(&account.state())
            .unwrap()
            .create_private_child("sessions")
            .unwrap();
        Account::session_root(&account.sessions());
        let mut daemon = Daemon::start(&account, executable);
        let pipe = daemon.serving();
        assert!(
            daemon.seen.contains(&format!(
                "arkdeck-agentd removed the empty earlier Sessions root {}",
                account.state().join("sessions").display()
            )),
            "{:?}",
            daemon.seen
        );
        assert!(!account.state().join("sessions").exists());
        let status = answered(&pipe, "runtime.storage.status", json!({}));
        assert_eq!(
            status["sessionDomain"]["rootPath"],
            account.sessions().to_str().unwrap(),
            "{status}"
        );
        daemon.stop();

        // Both hold a Session: refused, and neither changes.
        let account = Account::new(short_name);
        HostDirectory::open_or_create_private(&account.product()).unwrap();
        HostDirectory::open_or_create_private(&account.state()).unwrap();
        Account::session_root(&account.state().join("sessions"));
        Account::session_root(&account.sessions());
        let before = (
            Account::tree(&account.state().join("sessions")),
            Account::tree(&account.sessions()),
        );
        let output = account.daemon(executable).output().unwrap();
        assert_ne!(output.status.code(), Some(0), "{output:?}");
        let stderr = String::from_utf8(output.stderr).unwrap();
        assert!(
            stderr.contains("hold Sessions") && stderr.contains("never merged"),
            "{stderr}"
        );
        assert!(
            !String::from_utf8(output.stdout)
                .unwrap()
                .contains("listening on"),
            "nothing served"
        );
        assert_eq!(
            (
                Account::tree(&account.state().join("sessions")),
                Account::tree(&account.sessions()),
            ),
            before
        );
    }
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

#[test]
fn the_cli_reads_the_same_account_locations_from_a_dev_signed_daemon() {
    let Some(thumbprint) =
        std::env::var_os("ARKDECK_DEV_SIGNER_THUMBPRINT").filter(|value| !value.is_empty())
    else {
        eprintln!(
            "SKIPPED: ARKDECK_DEV_SIGNER_THUMBPRINT is not set (or empty), so no host-trusted \
             development signer can sign the daemon the CLI must verify \
             (rust/scripts/windows-dev-identity.ps1 create); nothing was checked"
        );
        return;
    };
    let _turn = turn();
    if !account_free() {
        return;
    }
    for short_name in [false, true] {
        let account = Account::new(short_name).with_earlier_layout();
        let signed = account.profile.join("signed-bin");
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

        let mut running = Daemon::start(&account, &daemon);
        let pipe = running.serving();
        let cli = |arguments: &[&str]| -> (Option<i32>, Value) {
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
                .env("USERPROFILE", &account.spelled)
                .env("ARKDECK_ENDPOINT", &pipe)
                .env("ARKDECK_DAEMON_PATH", &daemon)
                .env("ARKDECK_DAEMON_SIGNER_SHA256", &pin)
                .stdin(Stdio::null())
                .output()
                .unwrap_or_else(|error| {
                    panic!(
                        "the arkdeck CLI beside the daemon ({}): {error}; run the workspace \
                         tests, or `cargo build -p arkdeck-cli` before testing this crate alone",
                        cli.display()
                    )
                });
            let envelope = serde_json::from_slice(&output.stdout)
                .unwrap_or_else(|_| panic!("{arguments:?}: {output:?}"));
            (output.status.code(), envelope)
        };
        let (status, envelope) = cli(&["runtime", "storage", "status"]);
        assert_eq!(status, Some(0), "{envelope}");
        let over_pipe = answered(&pipe, "runtime.storage.status", json!({}));
        assert_eq!(
            envelope["result"]["sessionDomain"]["rootPath"],
            account.sessions().to_str().unwrap(),
            "{envelope}"
        );
        assert_eq!(
            envelope["result"]["sessionDomain"], over_pipe["sessionDomain"],
            "{envelope}"
        );
        let (status, envelope) = cli(&["trace", "cache", "status"]);
        assert_eq!(status, Some(0), "{envelope}");
        assert_eq!(
            envelope["result"],
            serde_json::from_str::<Value>(EMPTY_TRACE_CACHE).unwrap(),
            "{envelope}"
        );
        running.stop();
    }
}
