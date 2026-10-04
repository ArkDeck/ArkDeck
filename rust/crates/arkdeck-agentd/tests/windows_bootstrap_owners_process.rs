//! The Windows daemon's Bootstrap registry owners (`runtime.bundle.*`,
//! `runtime.tool.*`), as the real daemon composes them over an isolated
//! development root's `bootstrap` (the account's is
//! `%LOCALAPPDATA%\ArkDeck\Bootstrap\v1`).
//!
//! * Over its pipe, with a plain pipe handle (no signer needed):
//!   - the answers Swift recorded for an empty registry
//!     (`Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/
//!     ControlFrames`) are answered byte for byte, the snapshot page's
//!     revision aside: the empty bundle and tool pages, a page size out of
//!     range, an invalid tool reference to remove, a relative HDC to
//!     register, and `runtime.tool.select` with no tool-selection owner;
//!   - what Windows cannot hold is refused with zero dispatch and writes
//!     nothing: an absent package, and a package whose daemon is not signed
//!     as this (unsigned) daemon is; an absent `hdc.exe`, and a real one,
//!     since no Windows HDC tuple is registered (`WINDOWS_HDC_TUPLES` is
//!     empty, CHG-2026-078); a macOS-spelled path; and an absent bundle, tool
//!     or toolchain;
//!   - the registry reads back the same after a restart.
//! * Through the real CLI against a copy of the daemon signed with the
//!   host-trusted development signer (`ARKDECK_DEV_SIGNER_THUMBPRINT`, as
//!   `rust/scripts/check-readonly.py` signs one), the same leaves, and, when
//!   `ARKDECK_LIVE_DEVECO_ROOT` names the host's DevEco Studio directory, its
//!   registration (`runtime tool register --kind deveco`), inspection, listing
//!   and retirement, each read back across a restart. The DevEco directory is
//!   only measured, never run or written. Without the signer this test says
//!   so and checks nothing through the CLI.
//!
//! Every daemon runs with every `ARKDECK_` and `OHOS_HDC_` input removed but
//! its development root, a fresh directory below the temporary directory:
//! nothing installed is read or written, and no HDC or device is involved.
//! Each daemon is stopped by its own stop request, or ended by this test if
//! it outlives a failed assertion.
#![cfg(windows)]

use arkdeck_platform::StateRoot;
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
const BUNDLE: &str =
    "bundle:sha256:a5c9e37fa11f07cdfcdbfa5c8620683102597e3c96c1812bd1bc917b79e0fde5";
const TOOL: &str = "tool:sha256:a7171a17030617a63de7bb26b058671baa0deaa9406c37581466a79ea9802757";
const TOOLCHAIN: &str =
    "toolchain:sha256:9cee08f1e191112cb68a24ec3aa941f8d5342482224258ee3e34cdd122855e27";

/// A fresh development root, removed afterwards.
struct Root(PathBuf);
impl Root {
    fn new() -> Self {
        let temporary = std::fs::canonicalize(std::env::temp_dir()).unwrap();
        let temporary = temporary.to_str().unwrap();
        let temporary = temporary.strip_prefix(r"\\?\").unwrap_or(temporary);
        let nonce = u64::from_ne_bytes(arkdeck_platform::random_bytes::<8>().unwrap());
        let path = Path::new(temporary).join(format!("ad-winbootstrap-{nonce:016x}"));
        std::fs::create_dir(&path).unwrap();
        Self(path)
    }
    fn bootstrap(&self) -> PathBuf {
        self.0.join("bootstrap")
    }
    /// The Bootstrap store's entries and their bytes.
    fn store(&self) -> Vec<(String, Vec<u8>)> {
        let mut entries: Vec<(String, Vec<u8>)> = std::fs::read_dir(self.bootstrap())
            .unwrap()
            .map(|entry| {
                let entry = entry.unwrap();
                let bytes = if entry.file_type().unwrap().is_file() {
                    std::fs::read(entry.path()).unwrap()
                } else {
                    Vec::new()
                };
                (entry.file_name().to_string_lossy().into_owned(), bytes)
            })
            .collect();
        entries.sort();
        entries
    }
    /// A local path below the root, as the owners take one.
    fn path(&self, name: &str) -> String {
        self.0.join(name).to_str().unwrap().to_owned()
    }
}
impl Drop for Root {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// An owner-private `hdc.exe` below the root: a copy of a `System32` program,
/// never run, which no registered Windows HDC tuple names.
fn hdc(root: &Root) -> String {
    let directory = root.0.join("hdc-sdk");
    if !directory.exists() {
        arkdeck_platform::create_private_directory(&directory).unwrap();
        std::fs::copy(
            PathBuf::from(std::env::var_os("SystemRoot").unwrap()).join(r"System32\whoami.exe"),
            directory.join("hdc.exe"),
        )
        .unwrap();
    }
    directory.join("hdc.exe").to_str().unwrap().to_owned()
}

/// A release-candidate package tree below the root, owner-private, laid out as
/// `windows/scripts/package-rc.ps1` lays one out, its daemon a copy of
/// `daemon`, and its `rc-manifest.json` naming every other file.
fn package(root: &Root, name: &str, daemon: &Path) -> String {
    // Owner-private, as a package unpacked below `%LOCALAPPDATA%` is: the
    // temporary directory may grant others the right to change it, which the
    // owner refuses.
    let tree = root.0.join(name);
    if !tree.exists() {
        arkdeck_platform::create_private_directory(&tree).unwrap();
        arkdeck_platform::create_private_directory(&tree.join("bin")).unwrap();
    }
    std::fs::copy(daemon, tree.join("arkdeck-agentd.exe")).unwrap();
    std::fs::copy(
        PathBuf::from(std::env::var_os("SystemRoot").unwrap()).join(r"System32\whoami.exe"),
        tree.join(r"bin\arkdeck.exe"),
    )
    .unwrap();
    std::fs::write(tree.join("ArkDeck.exe"), b"fixture App; never run\n").unwrap();
    let files: Vec<Value> = ["ArkDeck.exe", "arkdeck-agentd.exe", "bin/arkdeck.exe"]
        .into_iter()
        .map(|relative| {
            let bytes = std::fs::read(tree.join(relative.replace('/', "\\"))).unwrap();
            json!({"path": relative, "bytes": bytes.len(),
                "sha256": arkdeck_contract::sha256_hex(&bytes)})
        })
        .collect();
    std::fs::write(
        tree.join("rc-manifest.json"),
        serde_json::to_vec_pretty(&json!({"schemaVersion": "arkdeck.windows-rc-package/1",
            "kind": "windows-rc-app-daemon-cli", "version": "0.1.0", "files": files}))
        .unwrap(),
    )
    .unwrap();
    tree.to_str().unwrap().to_owned()
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
fn request(pipe: &str, method: &str, params: &Value) -> Value {
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

/// A refusal of the Bootstrap registry owner, with the zero-dispatch proof.
fn refused(pipe: &str, method: &str, params: Value, code: &str, message: &str) {
    let reply = request(pipe, method, &params);
    assert_eq!(
        reply["error"],
        json!({"code": code, "message": message,
            "details": {"phase": "bootstrapRegistryOwner", "newDispatchCount": 0}}),
        "{method} {params}: {reply}"
    );
}

/// Swift's recorded answer for `params`, the first of `method`'s corpus
/// rows that sent exactly them and answered `answer` (a result's page kind,
/// or an error code).
fn recorded(method: &str, params: &Value, answer: &str) -> Value {
    let corpus = Path::new(env!("CARGO_MANIFEST_DIR")).join(format!(
        "../../../Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames/{method}.jsonl"
    ));
    std::fs::read_to_string(&corpus)
        .unwrap()
        .lines()
        .map(|line| serde_json::from_str::<Value>(line).unwrap())
        .find(|row| {
            row["params"] == *params
                && (row["error"]["code"] == answer
                    || (row["ok"] == true
                        && row["result"]["items"] == json!([])
                        && answer == "empty"))
        })
        .unwrap_or_else(|| panic!("no recorded {method} {params} answering {answer}"))
}

/// Our answer is Swift's recorded one, byte for byte, but for a snapshot
/// page's revision, a fresh UUID each snapshot.
fn replays(pipe: &str, method: &str, params: Value, answer: &str) {
    let swift = recorded(method, &params, answer);
    let mut ours = request(pipe, method, &params);
    if ours["ok"] == true {
        let revision = ours["result"]["snapshotRevision"].as_str().unwrap();
        assert_eq!(revision.len(), 36, "{ours}");
        ours["result"]["snapshotRevision"] = swift["result"]["snapshotRevision"].clone();
        assert_eq!(ours["result"], swift["result"], "{method} {params}");
    } else {
        assert_eq!(ours["error"], swift["error"], "{method} {params}");
    }
}

/// The recorded answers and the Windows refusals, over one daemon's pipe.
fn empty_registry_answers(pipe: &str, root: &Root) {
    for (method, params, answer) in [
        ("runtime.bundle.list", json!({}), "empty"),
        (
            "runtime.bundle.list",
            json!({"pageSize": 0}),
            "invalidInput",
        ),
        ("runtime.tool.list", json!({}), "empty"),
        ("runtime.tool.list", json!({"pageSize": 0}), "invalidInput"),
        (
            "runtime.tool.remove",
            json!({"expectedGeneration": "2", "tool": "invalid"}),
            "invalidInput",
        ),
        (
            "runtime.tool.register",
            json!({"file": "relative", "kind": "hdc"}),
            "invalidParams",
        ),
        ("runtime.tool.select", json!({}), "operationUnavailable"),
    ] {
        replays(pipe, method, params, answer);
    }
    let written = root.store();
    refused(
        pipe,
        "runtime.bundle.register",
        json!({"kind": "daemon-bundle", "file": root.path("absent-package")}),
        "fileIdentityChanged",
        "the Bundle source is absent or not a local directory",
    );
    // This daemon is not signed, so no package's signer can be pinned to it.
    let unsigned = package(
        root,
        "unsigned-package",
        Path::new(env!("CARGO_BIN_EXE_arkdeck-agentd")),
    );
    refused(
        pipe,
        "runtime.bundle.register",
        json!({"kind": "daemon-bundle", "file": unsigned}),
        "admissionDenied",
        "captured Bundle failed its native trust policy",
    );
    refused(
        pipe,
        "runtime.tool.register",
        json!({"kind": "hdc", "file": root.path("hdc.exe")}),
        "fileIdentityChanged",
        "the HDC source is absent or unreadable; nothing was captured",
    );
    refused(
        pipe,
        "runtime.tool.register",
        json!({"kind": "hdc", "file": hdc(root)}),
        "admissionDenied",
        "no registered Windows HDC tuple names this hdc.exe (CHG-2026-078); nothing was retained",
    );
    // A macOS spelling is not a local path here.
    refused(
        pipe,
        "runtime.tool.register",
        json!({"kind": "deveco", "root": "/Applications/DevEco-Studio.app/Contents"}),
        "invalidParams",
        "Tool registration requires kind and its absolute local path",
    );
    refused(
        pipe,
        "runtime.bundle.inspect",
        json!({"bundle": BUNDLE}),
        "resourceNotFound",
        "bootstrap resource reference does not exist",
    );
    for reference in [TOOL, TOOLCHAIN] {
        refused(
            pipe,
            "runtime.tool.inspect",
            json!({"tool": reference}),
            "resourceNotFound",
            "bootstrap resource reference does not exist",
        );
    }
    refused(
        pipe,
        "runtime.bundle.remove",
        json!({"bundle": BUNDLE, "expectedGeneration": "1"}),
        "resourceNotFound",
        "bundle reference does not exist",
    );
    refused(
        pipe,
        "runtime.tool.remove",
        json!({"tool": TOOL, "expectedGeneration": "1"}),
        "resourceNotFound",
        "tool reference does not exist",
    );
    refused(
        pipe,
        "runtime.tool.remove",
        json!({"tool": TOOLCHAIN, "expectedGeneration": "1"}),
        "resourceNotFound",
        "toolchain reference does not exist",
    );
    assert_eq!(root.store(), written, "a refusal wrote nothing");
}

#[test]
fn the_registry_owners_answer_over_the_pipe_and_across_a_restart() {
    let _turn = turn();
    let root = Root::new();
    let executable = Path::new(env!("CARGO_BIN_EXE_arkdeck-agentd"));

    let mut first = Daemon::start(executable, &root.0);
    let pipe = first.serving();
    assert!(
        first.seen.contains(
            &"arkdeck-agentd owners: jobs, capabilities, mutationAuthority, targets, artifacts, imports, storage, history, workspaceProjects, workspaceOperations, bootstrap, planning, agentExecutions, humanActions, controlActions, traceCache, flashHostFacts, deviceAccess, loaderBinding"
                .to_owned()
        ),
        "{:?}",
        first.seen
    );
    empty_registry_answers(&pipe, &root);
    // The first paged list published the two empty indexes under the store's
    // lock, as Swift's owner initializes a genuinely empty registry.
    let names: Vec<String> = root.store().into_iter().map(|(name, _)| name).collect();
    for name in [".lock", "bundles.json", "tools.json"] {
        assert!(names.contains(&name.to_owned()), "{names:?}");
    }
    let written = root.store();
    first.stop(&root.0);

    let mut second = Daemon::start(executable, &root.0);
    let pipe = second.serving();
    empty_registry_answers(&pipe, &root);
    assert_eq!(root.store(), written);
    second.stop(&root.0);
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

/// A CLI refusal: a non-zero exit, the owner's code on the wire, and the
/// zero-dispatch proof. The CLI's own code is the owner's where the method's
/// owner publishes it, as Swift's failure mapper reads it; an inspection has
/// no such table, so its refusal reads `internalError` with the wire code.
fn cli_refused(daemon: &Path, pin: &str, pipe: &str, arguments: &[&str], code: &str) {
    let (status, envelope) = cli(daemon, pin, pipe, arguments);
    assert_ne!(status, Some(0), "{arguments:?}: {envelope}");
    let error = &envelope["error"];
    let wire = error["details"]["wireCode"]
        .as_str()
        .unwrap_or(error["code"].as_str().unwrap());
    assert_eq!(wire, code, "{arguments:?}: {envelope}");
    assert_eq!(
        error["details"]["newDispatchCount"], 0,
        "{arguments:?}: {envelope}"
    );
}

/// A CLI answer: exit 0 and the result.
fn cli_answered(daemon: &Path, pin: &str, pipe: &str, arguments: &[&str]) -> Value {
    let (status, envelope) = cli(daemon, pin, pipe, arguments);
    assert_eq!(status, Some(0), "{arguments:?}: {envelope}");
    envelope["result"].clone()
}

#[test]
fn the_registry_leaves_run_through_the_cli_against_a_dev_signed_daemon() {
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

    let mut first = Daemon::start(&daemon, &root.0);
    let pipe = first.serving();
    for group in ["bundle", "tool"] {
        let page = cli_answered(&daemon, &pin, &pipe, &["runtime", group, "list"]);
        assert_eq!(page["items"], json!([]), "{page}");
        assert_eq!(page["hasMore"], false, "{page}");
    }
    assert_measured(&["runtime.bundle.list"]);
    cli_refused(
        &daemon,
        &pin,
        &pipe,
        &["runtime", "bundle", "inspect", "--bundle", BUNDLE],
        "resourceNotFound",
    );
    cli_refused(
        &daemon,
        &pin,
        &pipe,
        &[
            "runtime",
            "bundle",
            "remove",
            "--bundle",
            BUNDLE,
            "--expected-generation",
            "1",
        ],
        "resourceNotFound",
    );
    cli_refused(
        &daemon,
        &pin,
        &pipe,
        &["runtime", "tool", "inspect", "--tool", TOOL],
        "resourceNotFound",
    );
    // A package whose daemon is signed as this daemon is registers.
    let source = package(&root, "package", &daemon);
    let register = [
        "runtime",
        "bundle",
        "register",
        "--kind",
        "daemon-bundle",
        "--file",
        &source,
    ];
    let bundle = cli_answered(&daemon, &pin, &pipe, &register);
    assert_eq!(bundle["platform"], "windows", "{bundle}");
    assert_eq!(bundle["state"], "available", "{bundle}");
    assert_eq!(bundle["contentRetained"], true, "{bundle}");
    assert_eq!(
        bundle["trust"]["teamIdentifier"], "ArkDeck Development Daemon (host-trusted only)",
        "{bundle}"
    );
    let bundle_ref = bundle["bundleRef"].as_str().unwrap().to_owned();
    assert_eq!(cli_answered(&daemon, &pin, &pipe, &register), bundle);
    assert_eq!(
        cli_answered(
            &daemon,
            &pin,
            &pipe,
            &["runtime", "bundle", "inspect", "--bundle", &bundle_ref]
        ),
        bundle
    );
    let page = cli_answered(&daemon, &pin, &pipe, &["runtime", "bundle", "list"]);
    assert_eq!(page["items"], json!([bundle]), "{page}");
    first.stop(&root.0);
    let mut first = Daemon::start(&daemon, &root.0);
    let pipe = first.serving();
    assert_eq!(
        cli_answered(
            &daemon,
            &pin,
            &pipe,
            &["runtime", "bundle", "inspect", "--bundle", &bundle_ref]
        ),
        bundle
    );
    let retired = cli_answered(
        &daemon,
        &pin,
        &pipe,
        &[
            "runtime",
            "bundle",
            "remove",
            "--bundle",
            &bundle_ref,
            "--expected-generation",
            "1",
        ],
    );
    assert_eq!(retired["state"], "removed", "{retired}");
    assert_eq!(retired["generation"], "2", "{retired}");
    first.stop(&root.0);
    let mut first = Daemon::start(&daemon, &root.0);
    let pipe = first.serving();
    assert_eq!(
        cli_answered(
            &daemon,
            &pin,
            &pipe,
            &["runtime", "bundle", "inspect", "--bundle", &bundle_ref]
        ),
        retired
    );
    // Retired content is not registered again.
    cli_refused(&daemon, &pin, &pipe, &register, "resourceConflict");
    assert_measured(&[
        "runtime.bundle.register",
        "runtime.bundle.inspect",
        "runtime.bundle.remove",
    ]);
    let hdc_file = hdc(&root);
    cli_refused(
        &daemon,
        &pin,
        &pipe,
        &[
            "runtime", "tool", "register", "--kind", "hdc", "--file", &hdc_file,
        ],
        "admissionDenied",
    );
    cli_refused(
        &daemon,
        &pin,
        &pipe,
        &[
            "runtime",
            "tool",
            "select",
            "--tool",
            TOOL,
            "--expected-active-generation",
            "1",
            "--action-request-id",
            "select-one",
        ],
        "operationUnavailable",
    );

    let Some(deveco) = std::env::var("ARKDECK_LIVE_DEVECO_ROOT")
        .ok()
        .filter(|value| !value.is_empty())
    else {
        eprintln!(
            "ARKDECK_LIVE_DEVECO_ROOT is not set: the DevEco registration, inspection, listing \
             and retirement through the CLI were not run"
        );
        first.stop(&root.0);
        return;
    };
    // The host's DevEco Studio, measured and registered, never run.
    let registered = cli_answered(
        &daemon,
        &pin,
        &pipe,
        &[
            "runtime", "tool", "register", "--kind", "deveco", "--root", &deveco,
        ],
    );
    assert_eq!(registered["kind"], "deveco", "{registered}");
    assert_eq!(registered["platform"], "windows", "{registered}");
    assert_eq!(registered["state"], "available", "{registered}");
    assert_eq!(registered["generation"], "1", "{registered}");
    let reference = registered["toolRef"].as_str().unwrap().to_owned();
    assert!(reference.starts_with("toolchain:sha256:"), "{registered}");
    // A second registration of the same content is the same record.
    assert_eq!(
        cli_answered(
            &daemon,
            &pin,
            &pipe,
            &[
                "runtime", "tool", "register", "--kind", "deveco", "--root", &deveco
            ],
        ),
        registered
    );
    let inspected = cli_answered(
        &daemon,
        &pin,
        &pipe,
        &["runtime", "tool", "inspect", "--tool", &reference],
    );
    assert_eq!(inspected, registered);
    let page = cli_answered(&daemon, &pin, &pipe, &["runtime", "tool", "list"]);
    assert_eq!(page["items"], json!([registered]), "{page}");
    first.stop(&root.0);

    let mut second = Daemon::start(&daemon, &root.0);
    let pipe = second.serving();
    assert_eq!(
        cli_answered(
            &daemon,
            &pin,
            &pipe,
            &["runtime", "tool", "inspect", "--tool", &reference],
        ),
        registered
    );
    let retired = cli_answered(
        &daemon,
        &pin,
        &pipe,
        &[
            "runtime",
            "tool",
            "remove",
            "--tool",
            &reference,
            "--expected-generation",
            "1",
        ],
    );
    assert_eq!(retired["toolRef"], reference, "{retired}");
    assert_eq!(retired["state"], "removed", "{retired}");
    assert_eq!(retired["generation"], "2", "{retired}");
    second.stop(&root.0);

    let mut third = Daemon::start(&daemon, &root.0);
    let pipe = third.serving();
    assert_eq!(
        cli_answered(
            &daemon,
            &pin,
            &pipe,
            &["runtime", "tool", "inspect", "--tool", &reference],
        ),
        retired
    );
    // Retired content is not registered again from the same root.
    cli_refused(
        &daemon,
        &pin,
        &pipe,
        &[
            "runtime", "tool", "register", "--kind", "deveco", "--root", &deveco,
        ],
        "resourceConflict",
    );
    third.stop(&root.0);
    assert_measured(&[
        "runtime.tool.list",
        "runtime.tool.inspect",
        "runtime.tool.remove",
    ]);
}
