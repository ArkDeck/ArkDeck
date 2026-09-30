//! The Windows daemon's Import owner (TASK-XPA-008), as the real daemon
//! composes it over an isolated development root: in the Artifact root's
//! private `.imports-v1`, beside the Target owners holding the recorded
//! Swift Target store of one adopted Target
//! (`rust/tests/fixtures/import-target-current/direct`):
//!
//! * over its pipe, with a plain pipe handle (no signer needed): a HAP is
//!   begun against the adopted Target, appended and committed, and published
//!   as an Artifact the Import owns with its exact bytes; its Artifact is read
//!   through the Import owner; a flash bundle that does not read as one is
//!   refused at publication by the Flash archive reader, as Swift's
//!   production policy refuses it (TASK-XPA-010), and nothing is published. After a restart the Import is listed and inspected with the
//!   same receipt, released, and its Artifact stays readable;
//! * through the real CLI against a copy of the daemon signed with the
//!   host-trusted development signer (`ARKDECK_DEV_SIGNER_THUMBPRINT`):
//!   `artifact import hap`, `native-library` (the recorded code-signed ELF of
//!   `rust/tests/fixtures/deploy-native-library`) and `workspace-patch` upload
//!   and commit their exact bytes; `inspect`, `list` and `release` answer for
//!   them; `abort` ends an Import begun and not committed; `flash-bundle`
//!   commits the Flash archive reader's recorded DAYU200 archive, judged by
//!   reading it, and refuses one that is no archive with nothing published.
//!   The measured
//!   leaves are Windows `implemented` in the coverage manifest the CLI renders
//!   (`WINDOWS_MEASURED_LEAVES`). Without that variable this test says so and
//!   checks nothing.
//!
//! Every daemon runs with every `ARKDECK_` and `OHOS_HDC_` input removed but
//! its development root, a fresh directory below the temporary directory:
//! nothing installed is read or written, no HDC is configured, and no device
//! or `hdc` is involved. Each daemon is stopped by its own stop request, or
//! ended by this test if it outlives a failed assertion.
#![cfg(windows)]

use arkdeck_platform::{HostDirectory, StateRoot};
use serde_json::{Value, json};
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

const TARGET: &str = "TGT-dddddddddddd";
/// A HAP the owner validates: the ZIP magic, then bytes.
const HAP: &[u8] = b"PK\x03\x04windows-import-owner-hap";

/// A fresh development root in the plain spelling the owners compare,
/// holding the recorded Swift Target store of one adopted Target
/// (`rust/tests/fixtures/import-target-current/direct`); removed afterwards.
struct Root(PathBuf);
impl Root {
    fn new() -> Self {
        let nonce = u64::from_ne_bytes(arkdeck_platform::random_bytes::<8>().unwrap());
        let temporary = std::env::temp_dir().canonicalize().unwrap();
        let temporary = match temporary
            .to_str()
            .and_then(|text| text.strip_prefix(r"\\?\"))
        {
            Some(plain) => PathBuf::from(plain),
            None => temporary,
        };
        let path = temporary.join(format!("ad-winimports-{nonce:016x}"));
        std::fs::create_dir(&path).unwrap();
        let targets = path.join("targets-state");
        HostDirectory::open_or_create_private(&targets).unwrap();
        let source = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../tests/fixtures/import-target-current/direct");
        for name in ["targets.json", "target-display-names.json"] {
            std::fs::copy(source.join(name), targets.join(name)).unwrap();
        }
        Self(path)
    }
    fn artifacts(&self) -> PathBuf {
        self.0.join("artifacts")
    }
    fn file(&self, name: &str, bytes: &[u8]) -> PathBuf {
        let path = self.0.join(name);
        std::fs::write(&path, bytes).unwrap();
        path
    }
}
impl Drop for Root {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn sha256(bytes: &[u8]) -> String {
    arkdeck_contract::sha256_hex(bytes)
}

fn intent(request: &str, kind: &str, bytes: &[u8]) -> Value {
    json!({"schemaVersion": "arkdeck.import-intent/1", "importRequestId": request,
        "kind": kind, "targetId": TARGET, "bindingRevision": "1",
        "deviceProfile": if kind == "flash-bundle" { json!("dayu200") } else { Value::Null },
        "name": if kind == "flash-bundle" { "images.tar.gz".to_owned() } else { format!("fixture.{kind}") }, "byteCount": bytes.len().to_string(),
        "sha256": sha256(bytes)})
}

/// One request's result, schema-checked; a refusal fails the test.
fn answered(pipe: &str, method: &str, params: Value) -> Value {
    let reply = request(pipe, method, params.clone());
    assert_eq!(reply["ok"], true, "{method} {params}: {reply}");
    arkdeck_contract::validate_method_value(method, "result", &reply["result"])
        .unwrap_or_else(|error| panic!("{method}: {error}: {reply}"));
    reply["result"].clone()
}

/// An Import begun, appended whole and committed over the pipe.
fn upload(pipe: &str, request_id: &str, kind: &str, bytes: &[u8]) -> (String, Value) {
    let begun = answered(
        pipe,
        "artifact.import.begin",
        intent(request_id, kind, bytes),
    );
    let id = begun["importId"].as_str().unwrap().to_owned();
    answered(
        pipe,
        "artifact.import.append",
        json!({"importId": id, "generation": begun["generation"], "offset": "0",
            "byteCount": bytes.len().to_string(), "sha256": sha256(bytes),
            "base64": arkdeck_contract::encode_import_chunk(bytes).unwrap()}),
    );
    let reply = request(
        pipe,
        "artifact.import.commit",
        json!({"importId": id, "generation": begun["generation"]}),
    );
    (id, reply)
}

#[test]
fn an_import_is_uploaded_committed_read_and_released_across_a_restart() {
    let _turn = turn();
    let root = Root::new();
    let executable = Path::new(env!("CARGO_BIN_EXE_arkdeck-agentd"));
    let mut daemon = Daemon::start(executable, &root.0);
    let pipe = daemon.serving();
    assert!(
        daemon
            .seen
            .iter()
            .any(|line| line.starts_with("arkdeck-agentd owners: ")
                && line.contains("artifacts, imports, ")),
        "{:?}",
        daemon.seen
    );

    // A HAP: begun against the adopted Target, appended, committed and
    // published as an Artifact the Import owns.
    let (id, committed) = upload(&pipe, "windows-hap", "hap", HAP);
    assert_eq!(committed["ok"], true, "{committed}");
    let committed = committed["result"].clone();
    arkdeck_contract::validate_method_value("artifact.import.commit", "result", &committed)
        .unwrap();
    assert_eq!(committed["state"], "committed");
    let receipt = &committed["receipt"];
    let artifact = receipt["artifactId"].as_str().unwrap().to_owned();
    assert_eq!(receipt["artifactDigest"], sha256(HAP));
    assert_eq!(
        std::fs::read(root.artifacts().join(&id).join(&artifact)).unwrap(),
        HAP
    );
    // Its Artifact, read through the Import owner.
    let owner = json!({"kind": "import", "id": id});
    let inspected = answered(
        &pipe,
        "artifact.inspect",
        json!({"owner": owner, "artifactId": artifact}),
    );
    assert_eq!(inspected["artifactDigest"], sha256(HAP));
    // A flash bundle that is no gzip archive is refused at publication by
    // its registered validator, the Flash archive reader, as Swift's
    // production policy refuses it: nothing is published.
    let (flash, refused) = upload(&pipe, "windows-flash", "flash-bundle", &[0x46; 64]);
    assert_eq!(refused["ok"], false, "{refused}");
    assert_eq!(
        refused["error"]["message"], "Import content failed its registered format validator",
        "{refused}"
    );
    assert!(!root.artifacts().join(&flash).exists());
    daemon.stop(&root.0);

    // After a restart: the same Import, listed and inspected, then released.
    let mut daemon = Daemon::start(executable, &root.0);
    let pipe = daemon.serving();
    let listed = answered(&pipe, "artifact.import.list", json!({}));
    let ids: Vec<&str> = listed["items"]
        .as_array()
        .unwrap()
        .iter()
        .map(|item| item["importId"].as_str().unwrap())
        .collect();
    assert!(ids.contains(&id.as_str()), "{listed}");
    let shown = answered(&pipe, "artifact.import.inspect", json!({"importId": id}));
    assert_eq!(shown["state"], "committed");
    assert_eq!(shown["receipt"], *receipt);
    let released = answered(
        &pipe,
        "artifact.import.release",
        json!({"importId": id, "generation": shown["generation"]}),
    );
    assert_eq!(released["state"], "released", "{released}");
    // The released Import's Artifact stays readable as history.
    let inspected = answered(
        &pipe,
        "artifact.inspect",
        json!({"owner": owner, "artifactId": artifact}),
    );
    assert_eq!(inspected["artifactDigest"], sha256(HAP));
    daemon.stop(&root.0);
}

#[test]
fn gj1_import_commands_run_through_the_cli_against_a_dev_signed_daemon() {
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
    let root = Root::new();
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
    let hap = root.file("app.hap", HAP);
    let hap = hap.to_str().unwrap().to_owned();

    let mut running = Daemon::start(&daemon, &root.0);
    let pipe = running.serving();
    let run = |arguments: &[&str]| {
        let (status, envelope) = cli(&daemon, &pin, &pipe, arguments);
        assert_eq!(status, Some(0), "{arguments:?}: {envelope}");
        envelope["result"].clone()
    };
    let committed = run(&[
        "artifact",
        "import",
        "hap",
        "--import-request-id",
        "windows-cli-hap",
        "--target",
        TARGET,
        "--file",
        &hap,
    ]);
    assert_eq!(committed["state"], "committed", "{committed}");
    assert_eq!(committed["receipt"]["artifactDigest"], sha256(HAP));
    let id = committed["importId"].as_str().unwrap().to_owned();
    let shown = run(&["artifact", "import", "inspect", "--import", &id]);
    assert_eq!(shown["import"]["receipt"], committed["receipt"], "{shown}");
    let listed = run(&["artifact", "import", "list"]);
    assert!(
        listed["items"]
            .as_array()
            .unwrap()
            .iter()
            .any(|item| item["importId"] == id.as_str()),
        "{listed}"
    );
    let generation = shown["import"]["generation"].as_str().unwrap().to_owned();
    let released = run(&[
        "artifact",
        "import",
        "release",
        "--import",
        &id,
        "--generation",
        &generation,
    ]);
    assert_eq!(released["state"], "released", "{released}");

    // The other published kinds the Windows owner validates: each committed
    // with its exact bytes and listed.
    let native = std::fs::read(Path::new(env!("CARGO_MANIFEST_DIR")).join(
        "../../tests/fixtures/deploy-native-library/artifacts/job-input-native-library/ART-469c10579b3c5461ab4d0a891c316397",
    ))
    .unwrap();
    let patch: &[u8] = b"diff --git a/a.txt b/a.txt\n--- a/a.txt\n+++ b/a.txt\n+line\n";
    for (kind, name, bytes) in [
        ("native-library", "libentry.so", native.as_slice()),
        ("workspace-patch", "change.patch", patch),
    ] {
        let file = root.file(name, bytes);
        let committed = run(&[
            "artifact",
            "import",
            kind,
            "--import-request-id",
            &format!("windows-cli-{kind}"),
            "--target",
            TARGET,
            "--file",
            file.to_str().unwrap(),
        ]);
        assert_eq!(committed["state"], "committed", "{kind}: {committed}");
        assert_eq!(
            committed["receipt"]["artifactDigest"],
            sha256(bytes),
            "{kind}: {committed}"
        );
        let id = committed["importId"].as_str().unwrap();
        let shown = run(&["artifact", "import", "inspect", "--import", id]);
        assert_eq!(shown["import"]["receipt"], committed["receipt"], "{shown}");
    }
    // A DAYU200 flash bundle (the Flash archive reader's recorded complete
    // archive) is judged by reading it, on Windows too, and committed with
    // its exact digest; one that is no gzip archive is refused at
    // publication and nothing is published.
    let bundle = std::fs::read(
        Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../tests/fixtures/flash-archive/archives/complete.tar.gz"),
    )
    .unwrap();
    let flash = |request: &str, bytes: &[u8]| {
        let file = root.file(&format!("{request}.tar.gz"), bytes);
        cli(
            &daemon,
            &pin,
            &pipe,
            &[
                "artifact",
                "import",
                "flash-bundle",
                "--import-request-id",
                request,
                "--target",
                TARGET,
                "--file",
                file.to_str().unwrap(),
                "--device-profile",
                "dayu200",
            ],
        )
    };
    let (status, envelope) = flash("windows-cli-flash-bundle", &bundle);
    assert_eq!(status, Some(0), "{envelope}");
    let committed = &envelope["result"];
    assert_eq!(committed["state"], "committed", "{envelope}");
    assert_eq!(committed["receipt"]["artifactDigest"], sha256(&bundle));
    assert_eq!(
        committed["receipt"]["validation"],
        json!({"kind": "flash-bundle", "deviceProfile": "dayu200"}),
        "{envelope}"
    );
    let shown = run(&[
        "artifact",
        "import",
        "inspect",
        "--import",
        committed["importId"].as_str().unwrap(),
    ]);
    assert_eq!(shown["import"]["receipt"], committed["receipt"], "{shown}");
    let (status, envelope) = flash("windows-cli-flash-garbage", b"\x1f\x8bnot-an-archive");
    assert_ne!(status, Some(0), "{envelope}");
    assert_eq!(
        envelope["error"]["message"], "Import content failed its registered format validator",
        "{envelope}"
    );
    // The four committed Imports, and the refused one with no receipt.
    let listed = run(&["artifact", "import", "list"]);
    let items = listed["items"].as_array().unwrap();
    assert_eq!(items.len(), 5, "{listed}");
    let unpublished: Vec<&Value> = items
        .iter()
        .filter(|item| item["receipt"].is_null())
        .map(|item| &item["importRequestId"])
        .collect();
    assert_eq!(
        unpublished,
        [&json!("windows-cli-flash-garbage")],
        "{listed}"
    );

    // An Import begun and not committed is aborted through the CLI.
    let begun = answered(
        &pipe,
        "artifact.import.begin",
        intent("windows-cli-abort", "hap", HAP),
    );
    let aborted = run(&[
        "artifact",
        "import",
        "abort",
        "--import-request-id",
        "windows-cli-abort",
        "--expected-generation",
        begun["generation"].as_str().unwrap(),
    ]);
    assert_eq!(aborted["importId"], begun["importId"], "{aborted}");
    assert_eq!(aborted["state"], "aborted", "{aborted}");
    running.stop(&root.0);
    assert_measured(&[
        "artifact.import.flash-bundle",
        "artifact.import.workspace-patch",
        "artifact.import.begin",
        "artifact.import.append",
        "artifact.import.commit",
        "artifact.import.inspection",
        "artifact.import.inspect",
        "artifact.import.list",
        "artifact.import.release",
        "artifact.import.abort",
    ]);
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

/// What this test measured is what the coverage manifest counts: each
/// leaf's entries are Windows `implemented` in the manifest the CLI renders
/// (`maintainer contracts export`'s product, held to the committed
/// `openspec/contracts/cli-feature-coverage.json` by the CLI's own tests).
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
