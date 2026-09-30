//! Trace export and the Trace cache on Windows (TASK-XPA-021).
//!
//! * `trace export` end to end without a transport: the real CLI's parse and
//!   its Trace rule (`require_trace_artifact`), the NTFS Artifact owner's
//!   `artifact.inspect` and `artifact.export`, and the CLI's receipt check,
//!   over a Job the macOS Runtime recorded
//!   (`rust/tests/fixtures/capture-diagnostics-trace`): the Trace the capture
//!   published is exported with its recorded bytes and digest, and any other
//!   of the capture's Artifacts, or its Trace the capture recorded missing,
//!   is refused before a byte is written. The Job owner's proof is the
//!   caller's here, as in the owner tests.
//! * The real daemon over an isolated development root composes the Trace
//!   cache owner over `trace-cache\traces`: `trace.cache.status` answers its
//!   inventory, before and after a restart and a derived entry laid down in
//!   the macOS layout; `trace.cache.purge` is refused before admission
//!   (`operationUnavailable`, ruling 18: the Job owner's active-Session
//!   census is not asked on Windows yet, so nothing proves that no Session
//!   needs the entry) and removes nothing; a `trace-cache` that is not
//!   owner-only refuses the start.
//! * Through the real CLI against a copy of the daemon signed with the
//!   host-trusted development signer (`ARKDECK_DEV_SIGNER_THUMBPRINT`):
//!   `trace cache status` answers, `trace cache purge` is reported as a
//!   refusal (exit 69), and `trace export` is refused by the daemon's
//!   Artifact owner (`resourceNotFound`: its Job store does not hold the
//!   capture's Job) with nothing exported. Without that variable this test says so and
//!   checks nothing.
//!
//! Every daemon runs with every `ARKDECK_` and `OHOS_HDC_` input removed but
//! its development root, a fresh directory below the temporary directory:
//! nothing installed is read or written, and no device, `hdc` or ArkTrace
//! distribution is involved.
#![cfg(windows)]

use arkdeck_contract::sha256_hex;
use arkdeck_hoststore::ArtifactReadStore;
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
/// A capture that published its Trace, the Trace, and another of its
/// Artifacts.
const JOB: &str = "job-1c209bf5f7b1537cbd2406f5640e0ab8";
const TRACE: &str = "ART-148c3168fc02b640a96d452463b2a8d7";
/// A capture whose Trace was recorded missing.
const MISSING_JOB: &str = "job-d87e93b62a5439c408b76112d61e5f7b";
const MISSING_TRACE: &str = "ART-MISSING-4903e18e23ca2842f4f8ebcbba84f0b7";

fn recorded(job: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/fixtures/capture-diagnostics-trace/artifacts")
        .join(job)
}

/// A recorded Artifact index with each retention deadline a century later.
/// The recorded deadlines lapsed long before this run, and the daemon's
/// start-up retention sweep reclaims a settled Job's lapsed Artifacts, as
/// Swift's does; no answer compared here names a deadline but as this root
/// holds it.
fn unexpired(bytes: &[u8]) -> Vec<u8> {
    let mut index: serde_json::Value = serde_json::from_slice(bytes).unwrap();
    for row in index["artifacts"].as_array_mut().unwrap() {
        if let Some(deadline) = row["retention"]["deadlineUTC"].as_str() {
            let (year, rest) = deadline.split_at(4);
            let later = format!("{}{rest}", year.parse::<u32>().unwrap() + 100);
            row["retention"]["deadlineUTC"] = serde_json::json!(later);
        }
    }
    serde_json::to_vec_pretty(&index).unwrap()
}

fn index(job: &str) -> Value {
    serde_json::from_slice(&std::fs::read(recorded(job).join("index.json")).unwrap()).unwrap()
}

/// The recorded index entry of `artifact`.
fn entry(job: &str, artifact: &str) -> Value {
    index(job)["artifacts"]
        .as_array()
        .unwrap()
        .iter()
        .find(|entry| entry["artifactID"] == artifact)
        .unwrap()
        .clone()
}

/// A fresh development root named by its plain drive path, removed
/// afterwards.
struct Root(PathBuf);
impl Root {
    fn new() -> Self {
        let nonce = u64::from_ne_bytes(arkdeck_platform::random_bytes::<8>().unwrap());
        let path = std::env::temp_dir()
            .canonicalize()
            .unwrap()
            .join(format!("ad-wintrace-{nonce:016x}"));
        std::fs::create_dir(&path).unwrap();
        let path = match path.to_str().and_then(|text| text.strip_prefix(r"\\?\")) {
            Some(text) => PathBuf::from(text),
            None => path,
        };
        Self(path)
    }
    fn artifacts(&self) -> PathBuf {
        self.0.join("artifacts")
    }
    /// A recorded Job's Artifacts as the macOS Runtime published them: a
    /// private Artifact root, the index owner-only, each payload sealed, the
    /// retention deadlines a century later (`unexpired`).
    fn with_recorded_job(self, name: &str) -> Self {
        let root = HostDirectory::open_or_create_private(&self.artifacts()).unwrap();
        let job = root.create_private_child(name).unwrap();
        for entry in std::fs::read_dir(recorded(name)).unwrap() {
            let file = entry.unwrap().file_name().into_string().unwrap();
            let bytes = std::fs::read(recorded(name).join(&file)).unwrap();
            let bytes = if file == "index.json" {
                unexpired(&bytes)
            } else {
                bytes
            };
            job.create_document(&file, &bytes).unwrap();
            if file != "index.json" {
                job.seal_document(&file).unwrap();
            }
        }
        self
    }
    fn exports(&self) -> PathBuf {
        let path = self.0.join("exports");
        let _ = std::fs::create_dir(&path);
        path
    }
    fn traces(&self) -> PathBuf {
        self.0.join("trace-cache").join("traces")
    }
    /// One ready derived entry in the macOS cache layout (the Trace owner's
    /// unit fixture): its database, its metadata, its key lock and lease,
    /// and its owner record bound to the entry directory's identity. Laid
    /// down in the daemon's private `traces`, whose DACL every entry
    /// inherits.
    fn with_cache_entry(&self) -> PathBuf {
        let cache = self.traces();
        for directory in [".staging/.owners", ".locks", ".leases"] {
            std::fs::create_dir_all(cache.join(directory)).unwrap();
        }
        let trace = "a".repeat(64);
        let parser = "b".repeat(64);
        let entry = cache.join(&trace).join(&parser);
        std::fs::create_dir_all(&entry).unwrap();
        std::fs::write(entry.join("database.sqlite"), b"fixture database").unwrap();
        let metadata = json!({"formatVersion":1,
            "cacheKey":{"traceSHA256":trace,"parserBinarySHA256":parser,"upstreamRevision":"fixture","schemaAdapterVersion":"fixture","indexSchemaVersion":1,"parserKey":parser},
            "parser":{"name":"fixture","reportedVersion":"fixture","binarySHA256":parser,"upstreamRepository":"fixture","upstreamRevision":"fixture","architecture":"fixture","adapterVersion":"fixture","buildRecipeVersion":"fixture"},
            "traceSHA256":trace,"sourceSHA256":trace,"sourceByteCount":3,"schemaFingerprint":"fixture","schemaAdapterVersion":"fixture","indexSchemaVersion":1,
            "databasePreparation":{"schemaAdapterVersion":"fixture","schemaFingerprint":"fixture","indexVersion":1,"upstreamDatabaseSHA256":trace,"upstreamDatabaseByteCount":16},
            "databaseByteCount":16,"createdAt":"2026-09-11T00:00:00Z","lastAccessedAt":"2026-09-11T00:00:00Z"});
        std::fs::write(
            entry.join("metadata.json"),
            serde_json::to_vec(&metadata).unwrap(),
        )
        .unwrap();
        let lock = sha256_hex(format!("{trace}:{parser}").as_bytes());
        std::fs::write(cache.join(".locks").join(format!("{lock}.lock")), b"").unwrap();
        std::fs::write(cache.join(".leases").join(format!("{lock}.lease")), b"").unwrap();
        let (device, inode) = HostDirectory::open(&entry)
            .unwrap()
            .directory_identity()
            .unwrap();
        let owners = cache.join(".staging").join(".owners");
        std::fs::write(owners.join("entry-fixture.lock"), b"").unwrap();
        std::fs::write(
            owners.join("entry-fixture.json"),
            serde_json::to_vec(&json!({"formatVersion":1,"state":"ready","device":device,
                "inode":inode,"relativePath":format!("{trace}/{parser}")}))
            .unwrap(),
        )
        .unwrap();
        entry
    }
    /// Every entry below `path` with its bytes.
    fn tree(path: &Path) -> Vec<(PathBuf, Option<Vec<u8>>)> {
        let mut entries: Vec<_> = std::fs::read_dir(path)
            .unwrap()
            .map(|entry| entry.unwrap().path())
            .collect();
        entries.sort();
        let mut tree = Vec::new();
        for entry in entries {
            if entry.is_dir() {
                tree.push((entry.clone(), None));
                tree.extend(Self::tree(&entry));
            } else {
                tree.push((entry.clone(), Some(std::fs::read(&entry).unwrap())));
            }
        }
        tree
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
                Err(error) => {
                    let mut stderr = String::new();
                    if let Some(child) = self.child.as_mut()
                        && child.try_wait().ok().flatten().is_some()
                        && let Some(pipe) = child.stderr.as_mut()
                    {
                        let _ = pipe.read_to_string(&mut stderr);
                    }
                    panic!(
                        "no line starting {prefix:?} ({error}); stdout so far {:?}, stderr {stderr:?}",
                        self.seen
                    )
                }
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

/// Refused by the Artifact owner before anything is read or dispatched.
fn refused(pipe: &str, method: &str, params: Value, code: &str) -> Value {
    let reply = request(pipe, method, params);
    assert_eq!(reply["ok"], false, "{method}: {reply}");
    assert_eq!(reply["error"]["code"], code, "{method}: {reply}");
    reply
}

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

fn accept(_: &str) -> Result<(), arkdeck_contract::WireError> {
    Ok(())
}

fn trace_export(job: &str, artifact: &str, destination: &Path) -> Vec<String> {
    [
        "trace",
        "export",
        "--job",
        job,
        "--artifact",
        artifact,
        "--destination",
        destination.to_str().unwrap(),
        "--allow-sensitive",
    ]
    .map(str::to_owned)
    .to_vec()
}

/// `trace export` as the CLI's `main` runs it, with the owner answering in
/// process in place of the daemon: inspect, the metadata and Trace rules,
/// then export and the receipt rule. The CLI's refusal code, or the owner's.
fn run_trace_export(store: &ArtifactReadStore, argv: &[String]) -> Result<Value, String> {
    let invocation = arkdeck_cli::parse(argv).map_err(|error| error.code.to_owned())?;
    let params = invocation.params.clone().unwrap();
    let inspect = Map::from_iter([
        ("owner".into(), params["owner"].clone()),
        ("artifactId".into(), params["artifactId"].clone()),
    ]);
    let metadata = store
        .handle_resource("artifact.inspect", &inspect, accept)
        .map_err(|error| error.code)?;
    arkdeck_cli::validate_artifact_metadata(&params, &metadata)
        .map_err(|error| error.code.to_owned())?;
    arkdeck_cli::require_trace_artifact(&metadata).map_err(|error| error.code.to_owned())?;
    let export =
        arkdeck_cli::artifact_export_params(&invocation).map_err(|error| error.code.to_owned())?;
    let receipt = store
        .handle_resource("artifact.export", &export, accept)
        .map_err(|error| error.code)?;
    arkdeck_cli::validate_artifact_export(&invocation, &metadata, &receipt)
        .map_err(|error| error.code.to_owned())?;
    Ok(receipt)
}

#[test]
fn trace_export_publishes_the_recorded_trace_and_refuses_any_other_artifact() {
    let root = Root::new()
        .with_recorded_job(JOB)
        .with_recorded_job(MISSING_JOB);
    let before = Root::tree(&root.artifacts());
    let store = ArtifactReadStore::open(&root.artifacts()).unwrap();
    let exports = root.exports();

    let receipt = run_trace_export(&store, &trace_export(JOB, TRACE, &exports)).unwrap();
    let bytes = std::fs::read(recorded(JOB).join(TRACE)).unwrap();
    let recorded_entry = entry(JOB, TRACE);
    assert_eq!(recorded_entry["sha256"], sha256_hex(&bytes));
    let file = format!("{TRACE}-trace.htrace");
    assert_eq!(
        receipt,
        json!({"schemaVersion": "arkdeck.artifact-export/1",
            "owner": {"kind": "job", "id": JOB}, "artifactId": TRACE,
            "artifactDigest": recorded_entry["sha256"], "byteCount": bytes.len(),
            "privacy": "sensitive", "exportedPath": exports.join(&file).to_str().unwrap(),
            "overwritten": false})
    );
    assert_eq!(std::fs::read(exports.join(&file)).unwrap(), bytes);
    // Again: the exported file is never replaced without `--overwrite`.
    assert!(run_trace_export(&store, &trace_export(JOB, TRACE, &exports)).is_err());
    assert_eq!(std::fs::read(exports.join(&file)).unwrap(), bytes);

    // Every other Artifact the capture published is refused by the Trace
    // rule after inspection, before anything is exported.
    let others: Vec<String> = index(JOB)["artifacts"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|entry| entry["artifactID"] != TRACE && entry["status"].get("published").is_some())
        .map(|entry| entry["artifactID"].as_str().unwrap().to_owned())
        .collect();
    assert!(!others.is_empty());
    for other in &others {
        assert_eq!(
            run_trace_export(&store, &trace_export(JOB, other, &exports)),
            Err("invalidInput".to_owned()),
            "{other}"
        );
    }
    // A Trace the capture recorded missing has no bytes to export.
    assert!(run_trace_export(&store, &trace_export(MISSING_JOB, MISSING_TRACE, &exports)).is_err());
    assert_eq!(
        std::fs::read_dir(&exports).unwrap().count(),
        1,
        "only the Trace was exported"
    );
    assert_eq!(
        Root::tree(&root.artifacts()),
        before,
        "the store is unchanged"
    );
}

fn status(pipe: &str) -> Value {
    let reply = request(pipe, "trace.cache.status", json!({}));
    assert_eq!(reply["ok"], true, "{reply}");
    reply["result"].clone()
}

#[test]
fn the_trace_cache_owner_answers_status_and_refuses_purge_without_a_job_owner() {
    let _turn = turn();
    let root = Root::new();
    let executable = Path::new(env!("CARGO_BIN_EXE_arkdeck-agentd"));

    let mut first = Daemon::start(executable, &root.0);
    let pipe = first.serving();
    assert!(
        first.seen.contains(
            &"arkdeck-agentd owners: jobs, capabilities, mutationAuthority, targets, artifacts, imports, storage, workspaceProjects, planning, agentExecutions, humanActions, traceCache, flashHostFacts, deviceAccess"
                .to_owned()
        ),
        "{:?}",
        first.seen
    );
    assert_eq!(
        status(&pipe),
        json!({"schemaVersion": "arkdeck.trace-cache-status/1",
            "purgeScope": "inactiveDerivedDatabases", "entryCount": 0, "activeEntryCount": 0,
            "inactiveEntryCount": 0, "totalByteCount": "0"})
    );
    first.stop(&root.0);

    let entry = root.with_cache_entry();
    let cache = Root::tree(&root.traces());
    let mut second = Daemon::start(executable, &root.0);
    let pipe = second.serving();
    let counted = status(&pipe);
    assert_eq!(counted["entryCount"], 1, "{counted}");
    assert_eq!(counted["inactiveEntryCount"], 1, "{counted}");
    assert_eq!(counted["activeEntryCount"], 0, "{counted}");
    // Refused before admission (ruling 18): the Job owner's active-Session
    // census is not asked on Windows yet, so nothing proves that no Session
    // needs the entry.
    let reply = refused(
        &pipe,
        "trace.cache.purge",
        json!({}),
        "operationUnavailable",
    );
    assert_eq!(
        reply["error"],
        json!({"code": "operationUnavailable",
            "message": "Trace cache purge needs the Job and Artifact retention owners; nothing was purged",
            "details": {"phase": "preAdmission", "newDispatchCount": 0,
                "purgeScope": "inactiveDerivedDatabases"}}),
        "{reply}"
    );
    refused(
        &pipe,
        "trace.cache.status",
        json!({"path": "C:\\cache"}),
        "invalidParams",
    );
    second.stop(&root.0);
    assert!(entry.join("database.sqlite").exists());
    assert_eq!(Root::tree(&root.traces()), cache, "nothing was purged");
}

#[test]
fn a_trace_cache_that_is_not_owner_only_refuses_the_start() {
    let _turn = turn();
    let root = Root::new();
    // Created as any directory below the temporary directory is: it
    // inherits grants to others, which the owner refuses and never rewrites.
    std::fs::create_dir(root.0.join("trace-cache")).unwrap();
    let output = daemon(Path::new(env!("CARGO_BIN_EXE_arkdeck-agentd")), &root.0)
        .output()
        .unwrap();
    assert_eq!(output.status.code(), Some(69), "{output:?}");
    let stderr = String::from_utf8(output.stderr).unwrap();
    assert!(
        stderr.contains("the Trace cache") && stderr.contains("nothing was started"),
        "{stderr}"
    );
    assert!(!root.traces().exists());
}

#[test]
fn trace_commands_run_through_the_cli_against_a_dev_signed_daemon() {
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
    let root = Root::new().with_recorded_job(JOB);
    let before = Root::tree(&root.artifacts());
    let exports = root.exports();
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

    let mut running = Daemon::start(&daemon, &root.0);
    let pipe = running.serving();
    let (status, envelope) = cli(&daemon, &pin, &pipe, &["trace", "cache", "status"]);
    assert_eq!(status, Some(0), "{envelope}");
    assert_eq!(envelope["result"]["entryCount"], 0, "{envelope}");
    let (status, envelope) = cli(&daemon, &pin, &pipe, &["trace", "cache", "purge"]);
    // The refusal before admission carries its proof: the CLI reports a
    // refusal, not an unknown outcome.
    assert_eq!(status, Some(69), "{envelope}");
    assert_eq!(
        envelope["error"]["code"], "operationUnavailable",
        "{envelope}"
    );
    assert_eq!(envelope["error"]["details"]["phase"], "preAdmission");
    assert_eq!(envelope["error"]["details"]["newDispatchCount"], 0);
    // The daemon's Artifact owner refuses the inspection the export starts
    // with: its Job store does not hold the capture's Job.
    let argv = trace_export(JOB, TRACE, &exports);
    let argv: Vec<&str> = argv.iter().map(String::as_str).collect();
    let (status, envelope) = cli(&daemon, &pin, &pipe, &argv);
    assert_eq!(status, Some(65), "{envelope}");
    assert_eq!(envelope["error"]["code"], "resourceNotFound", "{envelope}");
    assert_eq!(
        envelope["error"]["message"], "Artifact Job owner does not exist",
        "{envelope}"
    );
    running.stop(&root.0);
    // The daemon's Import owner keeps its private `.imports-v1` in the
    // Artifact root, created as it opens; every recorded entry is unchanged.
    let imports = root.artifacts().join(".imports-v1");
    let after: Vec<_> = Root::tree(&root.artifacts())
        .into_iter()
        .filter(|(path, _)| !path.starts_with(&imports))
        .collect();
    assert_eq!(after, before);
    assert_eq!(
        std::fs::read_dir(&exports).unwrap().count(),
        0,
        "nothing was exported"
    );
}
