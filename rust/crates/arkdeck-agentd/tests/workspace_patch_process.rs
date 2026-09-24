//! The production daemon applies a patch to a Runtime-owned copy of a
//! registered workspace project and reverts it (TASK-XPA-015, M3), through
//! its installed socket as a caller meets it, with the real `/usr/bin/patch`
//! the composed profile pinned: the copy is made; the patch — imported for
//! the host target the Jobs name — plans, is admitted under the capability
//! the Runtime issues for the copy, runs and publishes its product; the same
//! patch against the person's own tree is refused before admission; a
//! restarted daemon adopts the patched copy through its durable patch
//! lineage, and the exact attempt is reverted.
//!
//! The daemon runs with its environment cleared and `CFFIXED_USER_HOME`
//! naming a temporary home below `/private/tmp`, as the production composition
//! tests run it: no Mach service, LaunchAgent, installed state, HDC or device
//! is touched.
#![cfg(target_os = "macos")]

use arkdeck_contract::{ImportIntent, WireError, encode_import_chunk, sha256_hex};
use arkdeck_hoststore::{ArtifactReadStore, ImportBinding, ImportUploadStore};
use serde_json::{Value, json};
use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::DirBuilderExt;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc;
use std::time::{Duration, Instant};

const DEADLINE: Duration = Duration::from_secs(30);
const PROFILE: &str = "waterflow-openharmony@1";
const PATCH: &str = "--- a/entry/src/main/ets/pages/Index.ets\n\
                     +++ b/entry/src/main/ets/pages/Index.ets\n\
                     @@ -1 +1 @@\n-old\n+new\n";

/// A temporary account home, removed afterwards.
struct Home(PathBuf);
impl Home {
    fn new() -> Self {
        let nonce = u64::from_ne_bytes(arkdeck_platform::random_bytes::<8>().unwrap());
        let path = PathBuf::from(format!("/private/tmp/adw-{nonce:016x}"));
        fs::DirBuilder::new().mode(0o700).create(&path).unwrap();
        Self(path)
    }
    fn state(&self) -> PathBuf {
        self.0.join("Library/Application Support/ArkDeck/Agentd")
    }
    fn socket(&self) -> PathBuf {
        self.state().join("agentd.sock")
    }
}
impl Drop for Home {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

/// The production daemon over `home`, serving, its stdout read as written.
struct Daemon {
    child: Child,
    lines: mpsc::Receiver<String>,
    stdout: Vec<String>,
}

impl Daemon {
    fn start(home: &Home) -> Self {
        let mut child = Command::new(env!("CARGO_BIN_EXE_arkdeck-agentd"))
            .env_clear()
            .env("CFFIXED_USER_HOME", &home.0)
            .env("HOME", &home.0)
            .env("ARKDECK_RUNTIME_COMPOSITION", "production")
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
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
        let mut daemon = Self {
            child,
            lines,
            stdout: Vec::new(),
        };
        daemon.line("arkdeck-agentd listening on ");
        daemon
    }

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
                Err(_) => panic!("no line {prefix:?}: stdout {:?}", self.stdout),
            }
        }
    }

    /// SIGTERM and the drain; the copies it reported it could not adopt.
    fn stop(mut self) -> Vec<String> {
        let signalled = Command::new("/bin/kill")
            .arg("-TERM")
            .arg(self.child.id().to_string())
            .status()
            .unwrap();
        assert!(signalled.success());
        self.line("arkdeck-agentd stopped");
        let deadline = Instant::now() + DEADLINE;
        while self.child.try_wait().unwrap().is_none() {
            assert!(Instant::now() < deadline, "the daemon did not end");
            std::thread::sleep(Duration::from_millis(10));
        }
        self.stdout
            .iter()
            .filter(|line| line.starts_with("runtime workspace"))
            .cloned()
            .collect()
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

fn request(home: &Home, method: &str, params: Value) -> Value {
    let mut stream = UnixStream::connect(home.socket()).unwrap();
    stream
        .set_read_timeout(Some(Duration::from_secs(60)))
        .unwrap();
    let mut frame = serde_json::to_vec(&json!({
        "protocolVersion": arkdeck_contract::PROTOCOL_VERSION,
        "contractIdentity": arkdeck_contract::CONTRACT_IDENTITY,
        "id": "workspace-patch-process", "method": method, "params": params}))
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
/// these files.
fn revision(files: &[(&str, &[u8])]) -> String {
    let mut material = format!("profileVersion\t{PROFILE}\nhead\tabsent\nindex\tabsent\n");
    for (path, bytes) in files {
        material.push_str(&format!("file\t{path}\t{}\n", sha256_hex(bytes)));
    }
    sha256_hex(material.as_bytes())
}

/// The patch imported as `artifact import workspace-patch` imports it, bound
/// to the host target the patch Jobs name; the commit's lease.
fn import_patch(artifacts: &Path) -> String {
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
                "importRequestId": "workspace-patch-process", "kind": "workspace-patch",
                "targetId": "workspace-host", "bindingRevision": "1",
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
fn the_production_daemon_patches_a_copy_and_reverts_it_with_the_real_patch() {
    let home = Home::new();
    let project = home.0.join("project");
    for (path, bytes) in [
        ("build-profile.json5", "{}\n"),
        ("entry/src/main/module.json5", "{}\n"),
        ("entry/src/main/ets/pages/Index.ets", "old\n"),
        ("entry/src/main/ets/Other.ets", "other\n"),
    ] {
        fs::create_dir_all(project.join(path).parent().unwrap()).unwrap();
        fs::write(project.join(path), bytes).unwrap();
    }
    // Registered, then composed by the next start.
    let daemon = Daemon::start(&home);
    let registered = answered(
        &home,
        "workspace.project.register",
        json!({"registrationRequestId": "workspace-patch-process", "kind": "openharmony",
            "root": project.to_str().unwrap()}),
    )["projectRef"]
        .as_str()
        .unwrap()
        .to_owned();
    assert_eq!(daemon.stop(), Vec::<String>::new());
    let lease = import_patch(&home.state().join("artifacts"));
    assert!(lease.starts_with("lease-v1:imp-"), "{lease}");

    let daemon = Daemon::start(&home);
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
    let job = answered(&home, "job.submit", prepared)["jobId"]
        .as_str()
        .unwrap()
        .to_owned();
    assert_eq!(
        answered(&home, "job.run", json!({"jobId": job}))["state"],
        "succeeded"
    );
    let base = revision(&[("entry/src/main/ets/pages/Index.ets", b"old\n")]);
    let digest = sha256_hex(format!("runtime-{job}|{registered}|{base}").as_bytes());
    let (workspace_id, copy) = (
        format!("evo-{}", &digest[..24]),
        format!("evolution-{}", &digest[..20]),
    );
    let copied = home
        .state()
        .join("evolution-workspaces")
        .join(&workspace_id)
        .join("workspace/entry/src/main/ets/pages/Index.ets");

    // The patch applied to the copy under the Runtime's own capability.
    let apply = job_request(
        "apply",
        "workspace.apply-patch",
        json!({"projectRef": copy, "patchArtifactRef": lease,
            "allowedFileGlobs": ["entry/src/main/ets/pages/**"],
            "expectedWorkspaceRevision": base}),
    );
    let planned = answered(&home, "job.plan", apply.clone());
    assert_eq!(planned["authorizationPolicy"], "standingCapability");
    assert_eq!(planned["effectiveEffect"], "deviceMutation");
    let applied = answered(&home, "job.submit", apply)["jobId"]
        .as_str()
        .unwrap()
        .to_owned();
    let ran = answered(&home, "job.run", json!({"jobId": applied}));
    assert_eq!(ran["state"], "succeeded", "{ran}");
    // As Swift's writer does, a Job whose intent is above host-only is read
    // as a device Session, which a Job with no device observation cannot
    // substantiate: its publication is refused, the Job stands.
    assert_eq!(ran["sessionPublication"]["state"], "failed", "{ran}");
    assert_eq!(
        ran["sessionPublication"]["reasonCode"], "sourceIntegrityFailed",
        "{ran}"
    );
    let result = answered(&home, "job.result", json!({"jobId": applied}));
    assert_eq!(result["artifacts"][0]["name"], "applied-patch.json");
    assert_eq!(result["evidence"]["authority"]["kind"], "runtimeCapability");
    assert!(
        result["evidence"]["authority"]["reference"]
            .as_str()
            .unwrap()
            .starts_with("CAP-RT-POLICY-")
    );
    assert_eq!(fs::read(&copied).unwrap(), b"new\n");
    assert_eq!(
        fs::read(project.join("entry/src/main/ets/pages/Index.ets")).unwrap(),
        b"old\n"
    );

    // The person's own tree: planned, never admitted.
    let primary = job_request(
        "primary",
        "workspace.apply-patch",
        json!({"projectRef": registered, "patchArtifactRef": lease,
            "allowedFileGlobs": ["entry/src/main/ets/pages/**"]}),
    );
    assert_eq!(request(&home, "job.plan", primary.clone())["ok"], true);
    let refused = request(&home, "job.submit", primary);
    assert_eq!(refused["error"]["code"], "admissionDenied", "{refused}");
    assert_eq!(
        refused["error"]["message"],
        "effect deviceMutation requires an explicit runtime capability"
    );
    assert_eq!(refused["error"]["details"]["newDispatchCount"], 0);
    assert_eq!(
        fs::read(project.join("entry/src/main/ets/pages/Index.ets")).unwrap(),
        b"old\n"
    );
    assert_eq!(daemon.stop(), Vec::<String>::new());

    // A restarted daemon adopts the patched copy through its lineage, and
    // reverts the exact attempt from its own durable copy of the patch.
    let daemon = Daemon::start(&home);
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
    let reverted = answered(&home, "job.submit", revert)["jobId"]
        .as_str()
        .unwrap()
        .to_owned();
    let ran = answered(&home, "job.run", json!({"jobId": reverted}));
    assert_eq!(ran["state"], "succeeded", "{ran}");
    assert_eq!(ran["sessionPublication"]["state"], "failed", "{ran}");
    assert_eq!(fs::read(&copied).unwrap(), b"old\n");
    let report = answered(&home, "job.result", json!({"jobId": reverted}));
    assert_eq!(report["artifacts"][0]["name"], "revert-report.json");
    assert_eq!(daemon.stop(), Vec::<String>::new());
    let durable = home
        .state()
        .join("workspace-patch-attempts")
        .join(format!("{attempt}.json"));
    let attempt: Value = serde_json::from_slice(&fs::read(durable).unwrap()).unwrap();
    assert!(attempt["revertedAtUTC"].is_string(), "{attempt}");
}
