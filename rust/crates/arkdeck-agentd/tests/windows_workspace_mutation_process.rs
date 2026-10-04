//! The installed (account) Windows daemon applies a patch to a Runtime-owned
//! copy of a registered workspace project, reverts it and checkpoints the
//! copy (TASK-XPA-011, GJ-5), as the macOS production daemon does
//! (`workspace_patch_process.rs`), through the code-owned patch (the
//! daemon's own image) and the trusted `System32\tar.exe`:
//!
//! * the copy is made; the patch — imported for the host target the Jobs
//!   name — plans under the standing-capability policy, is admitted under the
//!   capability the Runtime issues for the copy, runs and publishes its
//!   product; the same patch against the person's own tree is refused
//!   before admission;
//! * a restarted daemon adopts the patched copy through its durable patch
//!   lineage, the copy is checkpointed by the archive writer into the
//!   provider-owned attempt store under the Runtime's own capability, and
//!   the exact attempt is reverted.
//!
//! * through the real CLI against a copy of the daemon signed with the
//!   host-trusted development signer (`ARKDECK_DEV_SIGNER_THUMBPRINT`):
//!   `workspace isolate`, `workspace patch`, `workspace checkpoint` and
//!   `workspace revert` run to their verified products, and their coverage
//!   entries are Windows `implemented`. Without that variable this part
//!   says so and checks nothing.
//!
//! The daemon runs its account composition over a fake account
//! (`USERPROFILE` naming a fresh directory below the temporary directory, as
//! `windows_account_locations_process.rs` runs it), so it owns that
//! account's `AppData\Local\ArkDeck` and nothing of the real account's. Its
//! single-instance guard and pipe are still the account's, so the test says
//! so and checks nothing while an account daemon serves. No HDC, device,
//! DevEco or credential is involved.
#![cfg(windows)]

use arkdeck_contract::{ImportIntent, WireError, encode_import_chunk, sha256_hex};
use arkdeck_hoststore::{ArtifactReadStore, ImportBinding, ImportUploadStore};
use arkdeck_platform::{InstanceScope, default_user_endpoint, pipe_present};
use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc::{self, Receiver};
use std::sync::{Mutex, MutexGuard, PoisonError};
use std::time::{Duration, Instant};

const DEADLINE: Duration = Duration::from_secs(60);
const PROFILE: &str = "waterflow-openharmony@1";
const PATCH: &str = "--- a/entry/src/main/ets/pages/Index.ets\n\
                     +++ b/entry/src/main/ets/pages/Index.ets\n\
                     @@ -1 +1 @@\n-old\n+new\n";
const DAEMON: &str = env!("CARGO_BIN_EXE_arkdeck-agentd");

/// One test at a time: they share the account's guard and pipe.
static TURN: Mutex<()> = Mutex::new(());
fn turn() -> MutexGuard<'static, ()> {
    TURN.lock().unwrap_or_else(PoisonError::into_inner)
}

fn plain(path: PathBuf) -> PathBuf {
    match path.to_str().and_then(|text| text.strip_prefix(r"\\?\")) {
        Some(text) => PathBuf::from(text),
        None => path,
    }
}

/// A fake account below the temporary directory, removed afterwards.
struct Account(PathBuf);

impl Account {
    fn new() -> Self {
        let nonce = u64::from_ne_bytes(arkdeck_platform::random_bytes::<8>().unwrap());
        let temporary = plain(std::env::temp_dir().canonicalize().unwrap());
        let profile = temporary.join(format!("ad-fake-workspace-account-{nonce:016x}"));
        std::fs::create_dir_all(profile.join("AppData").join("Local")).unwrap();
        Self(profile)
    }
    fn state(&self) -> PathBuf {
        self.0
            .join("AppData")
            .join("Local")
            .join("ArkDeck")
            .join("Agentd")
    }
    fn daemon(&self) -> Command {
        self.daemon_at(Path::new(DAEMON))
    }
    fn daemon_at(&self, executable: &Path) -> Command {
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
            .env("USERPROFILE", &self.0)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        command
    }
}

impl Drop for Account {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
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
    fn start(account: &Account) -> Self {
        Self::spawn(account.daemon())
    }
    fn spawn(mut command: Command) -> Self {
        let mut child = command.spawn().unwrap();
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
    let answer = request(pipe, method, params.clone());
    assert_eq!(answer["ok"], true, "{method} {params}: {answer}");
    answer["result"].clone()
}

fn job_request(label: &str, operation: &str, inputs: Value) -> Value {
    json!({"requestJson": json!({
        "schemaVersion": "1.0.0", "documentType": "runtime-operation-request",
        "requestId": format!("request-{label}"), "idempotencyKey": format!("idempotency-{label}"),
        "operation": {"id": operation, "version": 1},
        "target": {"targetId": "workspace-host"},
        "inputs": inputs, "requestedOutputs": ["derivedArtifacts"],
    }).to_string()})
}

/// The revision Swift's provider measures for the WaterFlow profile over
/// these files (no git working copy).
fn revision(files: &[(&str, &[u8])]) -> String {
    let mut material = format!("profileVersion\t{PROFILE}\nhead\tabsent\nindex\tabsent\n");
    for (path, bytes) in files {
        material.push_str(&format!("file\t{path}\t{}\n", sha256_hex(bytes)));
    }
    sha256_hex(material.as_bytes())
}

/// The patch imported as `artifact import workspace-patch` imports it, bound
/// to the host target the patch Jobs name; the commit's lease.
fn import_patch(artifacts: &Path, target: &str) -> String {
    let imports = ImportUploadStore::open(artifacts).unwrap();
    let store = ArtifactReadStore::open(artifacts).unwrap();
    let binding = |intent: &ImportIntent| -> Result<ImportBinding, WireError> {
        Ok(ImportBinding {
            target_id: intent.target_id.clone(),
            binding_revision: None,
            stable_identity_sha256: None,
        })
    };
    let now = arkdeck_hoststore::runtime_now().unwrap();
    let bytes = PATCH.as_bytes();
    let begin = imports
        .handle_resource(
            "artifact.import.begin",
            json!({"schemaVersion": "arkdeck.import-intent/1",
                "importRequestId": "workspace-mutation-process", "kind": "workspace-patch",
                "targetId": target, "bindingRevision": "1",
                "deviceProfile": null, "name": "change.patch",
                "byteCount": bytes.len().to_string(), "sha256": sha256_hex(bytes)})
            .as_object()
            .unwrap(),
            &now,
            false,
            binding,
        )
        .unwrap();
    let id = begin["importId"].as_str().unwrap();
    imports
        .handle_resource(
            "artifact.import.append",
            json!({"importId": id, "generation": "1", "offset": "0",
                "byteCount": bytes.len().to_string(), "sha256": sha256_hex(bytes),
                "base64": encode_import_chunk(bytes).unwrap()})
            .as_object()
            .unwrap(),
            &now,
            false,
            binding,
        )
        .unwrap();
    let committed = imports
        .commit(
            json!({"importId": id, "generation": "1"})
                .as_object()
                .unwrap(),
            &now,
            false,
            &store,
            1024 * 1024 * 1024,
            binding,
        )
        .unwrap();
    committed["receipt"]["lease"]
        .as_str()
        .unwrap_or_else(|| panic!("the commit names its lease: {committed}"))
        .to_owned()
}

#[test]
fn the_account_daemon_patches_checkpoints_and_reverts_a_copy() {
    let _turn = turn();
    if !account_free() {
        return;
    }
    let account = Account::new();
    let project = account.0.join("project");
    for (path, bytes) in [
        ("build-profile.json5", "{}\n"),
        ("entry/src/main/module.json5", "{}\n"),
        ("entry/src/main/ets/pages/Index.ets", "old\n"),
        ("entry/src/main/ets/Other.ets", "other\n"),
    ] {
        std::fs::create_dir_all(project.join(path).parent().unwrap()).unwrap();
        std::fs::write(project.join(path), bytes).unwrap();
    }
    let project_text = project.to_str().unwrap().to_owned();
    // Registered, then composed by the next start.
    let mut daemon = Daemon::start(&account);
    let pipe = daemon.serving();
    let registered = answered(
        &pipe,
        "workspace.project.register",
        json!({"registrationRequestId": "workspace-mutation-process", "kind": "openharmony",
            "root": project_text}),
    )["projectRef"]
        .as_str()
        .unwrap()
        .to_owned();
    daemon.stop();
    let lease = import_patch(&account.state().join("artifacts"), "workspace-host");
    assert!(lease.starts_with("lease-v1:imp-"), "{lease}");

    let mut daemon = Daemon::start(&account);
    let pipe = daemon.serving();
    let source_revision = revision(&[
        ("entry/src/main/ets/Other.ets", b"other\n"),
        ("entry/src/main/ets/pages/Index.ets", b"old\n"),
    ]);
    let prepared = job_request(
        "copy",
        "workspace.prepare-isolated-copy",
        json!({"projectRef": registered, "expectedWorkspaceRevision": source_revision,
            "allowedFileGlobs": ["entry/src/main/ets/pages/**"]}),
    );
    let job = answered(&pipe, "job.submit", prepared)["jobId"]
        .as_str()
        .unwrap()
        .to_owned();
    let ran = answered(&pipe, "job.run", json!({"jobId": job}));
    assert_eq!(ran["state"], "succeeded", "{ran}");
    let base = revision(&[("entry/src/main/ets/pages/Index.ets", b"old\n")]);
    let digest = sha256_hex(format!("runtime-{job}|{registered}|{base}").as_bytes());
    let (workspace_id, copy) = (
        format!("evo-{}", &digest[..24]),
        format!("evolution-{}", &digest[..20]),
    );
    let copied = account
        .state()
        .join("evolution-workspaces")
        .join(&workspace_id)
        .join("workspace")
        .join("entry/src/main/ets/pages/Index.ets");
    assert_eq!(std::fs::read(&copied).unwrap(), b"old\n");

    // The patch applied to the copy under the Runtime's own capability.
    let apply = job_request(
        "apply",
        "workspace.apply-patch",
        json!({"projectRef": copy, "patchArtifactRef": lease,
            "allowedFileGlobs": ["entry/src/main/ets/pages/**"],
            "expectedWorkspaceRevision": base}),
    );
    let planned = answered(&pipe, "job.plan", apply.clone());
    assert_eq!(planned["authorizationPolicy"], "standingCapability");
    assert_eq!(planned["effectiveEffect"], "deviceMutation");
    let applied = answered(&pipe, "job.submit", apply)["jobId"]
        .as_str()
        .unwrap()
        .to_owned();
    let ran = answered(&pipe, "job.run", json!({"jobId": applied}));
    assert_eq!(ran["state"], "succeeded", "{ran}");
    let result = answered(&pipe, "job.result", json!({"jobId": applied}));
    assert_eq!(
        result["artifacts"][0]["name"], "applied-patch.json",
        "{result}"
    );
    assert_eq!(
        result["evidence"]["authority"]["kind"], "runtimeCapability",
        "{result}"
    );
    assert_eq!(std::fs::read(&copied).unwrap(), b"new\n");
    assert_eq!(
        std::fs::read(project.join("entry/src/main/ets/pages/Index.ets")).unwrap(),
        b"old\n"
    );

    // The person's own tree: planned, never admitted.
    let primary = job_request(
        "primary",
        "workspace.apply-patch",
        json!({"projectRef": registered, "patchArtifactRef": lease,
            "allowedFileGlobs": ["entry/src/main/ets/pages/**"]}),
    );
    assert_eq!(request(&pipe, "job.plan", primary.clone())["ok"], true);
    let refused = request(&pipe, "job.submit", primary);
    assert_eq!(refused["error"]["code"], "admissionDenied", "{refused}");
    assert_eq!(refused["error"]["details"]["newDispatchCount"], 0);
    assert_eq!(
        std::fs::read(project.join("entry/src/main/ets/pages/Index.ets")).unwrap(),
        b"old\n"
    );
    daemon.stop();

    // A restarted daemon adopts the patched copy through its lineage,
    // checkpoints it with the trusted tar, and reverts the exact attempt
    // from its own durable copy of the patch.
    let mut daemon = Daemon::start(&account);
    let pipe = daemon.serving();
    assert!(
        !daemon
            .seen
            .iter()
            .any(|line| line.starts_with("runtime workspace not adopted")),
        "{:?}",
        daemon.seen
    );
    let checkpoint = job_request(
        "checkpoint",
        "workspace.create-checkpoint",
        json!({"projectRef": copy,
            "checkpointFilePaths": ["entry/src/main/ets/pages/Index.ets"]}),
    );
    let planned = answered(&pipe, "job.plan", checkpoint.clone());
    assert_eq!(planned["effectiveEffect"], "deviceMutation", "{planned}");
    let checkpointed = answered(&pipe, "job.submit", checkpoint)["jobId"]
        .as_str()
        .unwrap()
        .to_owned();
    let ran = answered(&pipe, "job.run", json!({"jobId": checkpointed}));
    assert_eq!(ran["state"], "succeeded", "{ran}");
    let archive = account
        .state()
        .join("workspace-patch-attempts")
        .join(format!(
            "checkpoint-{}.tar",
            sha256_hex(checkpointed.as_bytes())
        ));
    let bytes = std::fs::read(&archive).unwrap();
    assert!(
        bytes.len() >= 1024 && bytes.len().is_multiple_of(512),
        "{}",
        bytes.len()
    );
    assert!(
        bytes
            .windows(b"entry/src/main/ets/pages/Index.ets".len())
            .any(|window| window == b"entry/src/main/ets/pages/Index.ets"),
        "the archive names the declared file"
    );

    let attempt = format!(
        "patch-{}",
        &sha256_hex(format!("{applied}\n{}\n{copy}", sha256_hex(PATCH.as_bytes())).as_bytes())
            [..32]
    );
    let revert = job_request(
        "revert",
        "workspace.revert-patch",
        json!({"projectRef": copy, "patchAttemptRef": attempt}),
    );
    let reverted = answered(&pipe, "job.submit", revert)["jobId"]
        .as_str()
        .unwrap()
        .to_owned();
    let ran = answered(&pipe, "job.run", json!({"jobId": reverted}));
    assert_eq!(ran["state"], "succeeded", "{ran}");
    assert_eq!(std::fs::read(&copied).unwrap(), b"old\n");
    let report = answered(&pipe, "job.result", json!({"jobId": reverted}));
    assert_eq!(report["artifacts"][0]["name"], "revert-report.json");
    daemon.stop();
    let durable = account
        .state()
        .join("workspace-patch-attempts")
        .join(format!("{attempt}.json"));
    let attempt: Value = serde_json::from_slice(&std::fs::read(durable).unwrap()).unwrap();
    assert!(attempt["revertedAtUTC"].is_string(), "{attempt}");
}

/// A fake account's project registered, the daemon stopped: the account and
/// the project's reference.
fn registered(executable: &Path) -> (Account, String) {
    let account = Account::new();
    let project = account.0.join("project");
    for (path, bytes) in [
        ("build-profile.json5", "{}\n"),
        ("entry/src/main/module.json5", "{}\n"),
        ("entry/src/main/ets/pages/Index.ets", "old\n"),
        ("entry/src/main/ets/Other.ets", "other\n"),
    ] {
        std::fs::create_dir_all(project.join(path).parent().unwrap()).unwrap();
        std::fs::write(project.join(path), bytes).unwrap();
    }
    let mut daemon = Daemon::spawn(account.daemon_at(executable));
    let pipe = daemon.serving();
    let registered = answered(
        &pipe,
        "workspace.project.register",
        json!({"registrationRequestId": "workspace-mutation-cli", "kind": "openharmony",
            "root": project.to_str().unwrap()}),
    )["projectRef"]
        .as_str()
        .unwrap()
        .to_owned();
    daemon.stop();
    (account, registered)
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
fn the_workspace_mutation_leaves_run_through_the_cli_against_a_dev_signed_daemon() {
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
    let nonce = u64::from_ne_bytes(arkdeck_platform::random_bytes::<8>().unwrap());
    let signed = plain(std::env::temp_dir().canonicalize().unwrap())
        .join(format!("ad-signed-workspace-{nonce:016x}"));
    std::fs::create_dir(&signed).unwrap();
    let daemon = signed.join("arkdeck-agentd.exe");
    std::fs::copy(DAEMON, &daemon).unwrap();
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
    let (account, registered) = registered(&daemon);

    let mut running = Daemon::spawn(account.daemon_at(&daemon));
    let mut pipe = running.serving();
    let inputs = |name: &str, value: Value| {
        let path = account.0.join(format!("{name}.json"));
        std::fs::write(&path, value.to_string()).unwrap();
        path.to_str().unwrap().to_owned()
    };
    let cli = |pipe: &str, leaf: &str, inputs: &str, execution: &str| -> Value {
        let cli = Path::new(DAEMON).with_file_name("arkdeck.exe");
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
            .args([
                "workspace",
                leaf,
                "--inputs-file",
                inputs,
                "--execution-id",
                execution,
                "--output",
                "json",
            ])
            .env("USERPROFILE", &account.0)
            .env("ARKDECK_ENDPOINT", pipe)
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
        let envelope: Value =
            serde_json::from_slice(&output.stdout).unwrap_or_else(|_| panic!("{leaf}: {output:?}"));
        assert_eq!(output.status.code(), Some(0), "{leaf}: {envelope}");
        let result = envelope["result"].clone();
        assert_eq!(result["terminalState"], "succeeded", "{leaf}: {result}");
        assert_eq!(result["providerID"], "workspace", "{leaf}: {result}");
        assert_eq!(result["evidenceBlockers"], json!([]), "{leaf}: {result}");
        let produced = result["artifacts"].as_array().unwrap();
        assert_eq!(produced.len(), 1, "{leaf}: {result}");
        assert_eq!(produced[0]["bytesVerified"], true, "{leaf}: {result}");
        result
    };
    let source_revision = revision(&[
        ("entry/src/main/ets/Other.ets", b"other\n"),
        ("entry/src/main/ets/pages/Index.ets", b"old\n"),
    ]);
    let copy_result = cli(
        &pipe,
        "isolate",
        &inputs(
            "isolate",
            json!({"projectRef": registered, "expectedWorkspaceRevision": source_revision,
                "allowedFileGlobs": ["entry/src/main/ets/pages/**"]}),
        ),
        "exec-windows-isolate",
    );
    let job = copy_result["jobID"].as_str().unwrap().to_owned();
    let base = revision(&[("entry/src/main/ets/pages/Index.ets", b"old\n")]);
    let digest = sha256_hex(format!("runtime-{job}|{registered}|{base}").as_bytes());
    let (workspace_id, copy) = (
        format!("evo-{}", &digest[..24]),
        format!("evolution-{}", &digest[..20]),
    );
    let copied = account
        .state()
        .join("evolution-workspaces")
        .join(&workspace_id)
        .join("workspace")
        .join("entry/src/main/ets/pages/Index.ets");
    // The patch is imported for the copy, the scope a CLI execution names
    // for a workspace operation, while the daemon is stopped; the next start
    // adopts the copy.
    running.stop();
    let lease = import_patch(&account.state().join("artifacts"), &copy);
    running = Daemon::spawn(account.daemon_at(&daemon));
    pipe = running.serving();
    let applied = cli(
        &pipe,
        "patch",
        &inputs(
            "patch",
            json!({"projectRef": copy, "patchArtifactRef": lease,
                "allowedFileGlobs": ["entry/src/main/ets/pages/**"],
                "expectedWorkspaceRevision": base}),
        ),
        "exec-windows-patch",
    );
    assert_eq!(applied["actualEffect"], "deviceMutation", "{applied}");
    assert_eq!(std::fs::read(&copied).unwrap(), b"new\n");
    let applied_job = applied["jobID"].as_str().unwrap().to_owned();
    cli(
        &pipe,
        "checkpoint",
        &inputs(
            "checkpoint",
            json!({"projectRef": copy,
                "checkpointFilePaths": ["entry/src/main/ets/pages/Index.ets"]}),
        ),
        "exec-windows-checkpoint",
    );
    let attempt = format!(
        "patch-{}",
        &sha256_hex(format!("{applied_job}\n{}\n{copy}", sha256_hex(PATCH.as_bytes())).as_bytes())
            [..32]
    );
    cli(
        &pipe,
        "revert",
        &inputs(
            "revert",
            json!({"projectRef": copy, "patchAttemptRef": attempt}),
        ),
        "exec-windows-revert",
    );
    assert_eq!(std::fs::read(&copied).unwrap(), b"old\n");
    running.stop();
    drop(account);
    let _ = std::fs::remove_dir_all(&signed);
    // What this measured is what the coverage manifest counts.
    let product = arkdeck_cli::machine_contracts::contract_products()
        .into_iter()
        .find(|product| product.relative_path == "cli-feature-coverage.json")
        .unwrap();
    let coverage: Value = serde_json::from_slice(&product.bytes).unwrap();
    for feature in [
        "workspace.apply-patch@1",
        "workspace.revert-patch@1",
        "workspace.create-checkpoint@1",
    ] {
        let statuses: Vec<&Value> = coverage["entries"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|entry| entry["feature"] == feature)
            .map(|entry| &entry["implementationStatusByPlatform"]["windows"])
            .collect();
        assert_eq!(statuses, [&json!("implemented")], "{feature}");
    }
}
