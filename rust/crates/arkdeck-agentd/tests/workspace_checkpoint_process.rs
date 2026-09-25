//! The production daemon checkpoints registered workspace projects and sweeps
//! its own isolated copies (TASK-XPA-015, M3) through its installed socket as
//! a caller meets them, with the host's own tools: a project inside a git
//! working copy is checkpointed as a commit object under the Runtime's own
//! one-use capability for the exact plan — each checkpoint under the next
//! generation, no capability a caller names admitted — leaving the working
//! copy as it was; a plain project is sealed into the Runtime-owned archive
//! by `/usr/bin/bsdtar`; a Runtime-owned copy is measured by a dry sweep,
//! then destroyed by a wet one, after which its reference no longer resolves.
//!
//! `/usr/bin/git` is an `xcode-select` tool shim: one file under clang's,
//! make's and seventy-five other names, which started from its inode runs
//! whichever of them last started by name. So each git checkpoint here comes
//! right after clang or make has run, the project holds a Makefile whose
//! `stash` and `create` targets would leave a mark, and the checkpoint must
//! still be git's, with no mark: the Runtime pins the git xcrun resolves.
//!
//! The daemon runs with its environment cleared and `CFFIXED_USER_HOME`
//! naming a temporary home below `/private/tmp`, as the production composition
//! tests run it: no Mach service, LaunchAgent, installed state, HDC or device
//! is touched.
#![cfg(target_os = "macos")]

use arkdeck_contract::sha256_hex;
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
const INDEX: &str = "entry/src/main/ets/pages/Index.ets";
const INDEX_SOURCE: &str = "@Entry\n@Component\nstruct Index {\n  build() {}\n}\n";

/// A temporary account home, removed afterwards.
struct Home(PathBuf);
impl Home {
    fn new() -> Self {
        let nonce = u64::from_ne_bytes(arkdeck_platform::random_bytes::<8>().unwrap());
        let path = PathBuf::from(format!("/private/tmp/adk-{nonce:016x}"));
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

    /// SIGTERM and the drain.
    fn stop(mut self) {
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
        "id": "workspace-checkpoint-process", "method": method, "params": params}))
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

fn job_request(label: &str, operation: &str, inputs: Value, capability: Option<&str>) -> Value {
    let mut document = json!({
        "schemaVersion": "1.0.0", "documentType": "runtime-operation-request",
        "requestId": format!("request-{label}"), "idempotencyKey": format!("idempotency-{label}"),
        "operation": {"id": operation, "version": 1},
        "target": {"targetId": "workspace-host"},
        "inputs": inputs, "requestedOutputs": ["derivedArtifacts"],
    });
    if let Some(capability) = capability {
        document["authorization"] = json!({"capabilityId": capability});
    }
    json!({"requestJson": document.to_string()})
}

fn git(arguments: &[&str], directory: &Path) -> Vec<u8> {
    let output = Command::new("/usr/bin/git")
        .arg("-C")
        .arg(directory)
        .args(arguments)
        .env_clear()
        .envs([
            ("PATH", "/usr/bin:/bin"),
            ("GIT_CONFIG_NOSYSTEM", "1"),
            ("GIT_CONFIG_GLOBAL", "/dev/null"),
            ("GIT_AUTHOR_NAME", "Process"),
            ("GIT_AUTHOR_EMAIL", "process@invalid.example"),
            ("GIT_COMMITTER_NAME", "Process"),
            ("GIT_COMMITTER_EMAIL", "process@invalid.example"),
        ])
        .stderr(Stdio::null())
        .output()
        .unwrap();
    assert!(output.status.success(), "git {arguments:?}");
    output.stdout
}

/// One OpenHarmony-shaped project below the home.
fn project(root: &Path) {
    for (path, bytes) in [
        ("build-profile.json5", "{}\n"),
        ("entry/src/main/module.json5", "{}\n"),
        (INDEX, INDEX_SOURCE),
    ] {
        fs::create_dir_all(root.join(path).parent().unwrap()).unwrap();
        fs::write(root.join(path), bytes).unwrap();
    }
}

/// The revision Swift's provider measures for the WaterFlow profile over the
/// sources of a project that is not a git checkout.
fn revision(files: &[(&str, &[u8])]) -> String {
    let mut material = format!("profileVersion\t{PROFILE}\nhead\tabsent\nindex\tabsent\n");
    for (path, bytes) in files {
        material.push_str(&format!("file\t{path}\t{}\n", sha256_hex(bytes)));
    }
    sha256_hex(material.as_bytes())
}

/// Submits and runs one Job: its identity and what the run answered.
fn run(home: &Home, request: Value) -> (String, Value) {
    let job = answered(home, "job.submit", request)["jobId"]
        .as_str()
        .unwrap()
        .to_owned();
    let ran = answered(home, "job.run", json!({"jobId": job}));
    (job, ran)
}

/// Submits, runs and reads one Job: its identity and its result.
fn job(home: &Home, request: Value) -> (String, Value) {
    let (job, ran) = run(home, request);
    assert_eq!(ran["state"], "succeeded", "{ran}");
    let result = answered(home, "job.result", json!({"jobId": job}));
    (job, result)
}

/// Starts one of the shim's other names, as a build would, so that a launch
/// of the shim from its inode would run that tool next.
fn prime(tool: &str) {
    let started = Command::new(tool)
        .arg("--version")
        .env_clear()
        .env("PATH", "/usr/bin:/bin")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .unwrap();
    assert!(started.success(), "{tool}");
}

/// The marks the Makefile's targets leave, which a checkpoint that ran make
/// in the project would have left.
const MAKE_MARKS: [&str; 2] = ["ran-make-stash", "ran-make-create"];

/// The one product a Job published.
fn product(home: &Home, job: &str, result: &Value) -> Vec<u8> {
    let artifact = result["artifacts"][0]["artifactId"].as_str().unwrap();
    fs::read(home.state().join("artifacts").join(job).join(artifact)).unwrap()
}

#[test]
fn the_production_daemon_checkpoints_and_sweeps_with_the_host_tools() {
    let home = Home::new();
    let checkout = home.0.join("checkout");
    let plain = home.0.join("plain");
    project(&checkout);
    project(&plain);
    fs::write(
        checkout.join("Makefile"),
        "stash create:\n\t@touch ran-make-$@\n",
    )
    .unwrap();
    git(&["init", "--quiet"], &checkout);
    git(&["add", "-A"], &checkout);
    git(&["commit", "--quiet", "-m", "base"], &checkout);
    fs::write(checkout.join(INDEX), format!("{INDEX_SOURCE}// edited\n")).unwrap();
    // Registered, then composed by the next start.
    let daemon = Daemon::start(&home);
    let register = |label: &str, root: &Path| {
        answered(
            &home,
            "workspace.project.register",
            json!({"registrationRequestId": label, "kind": "openharmony",
                "root": root.to_str().unwrap()}),
        )["projectRef"]
            .as_str()
            .unwrap()
            .to_owned()
    };
    let checkout_ref = register("workspace-checkpoint-git", &checkout);
    let plain_ref = register("workspace-checkpoint-plain", &plain);
    daemon.stop();

    let daemon = Daemon::start(&home);
    let status_before = git(&["status", "--porcelain=v1"], &checkout);
    let index_before = fs::read(checkout.join(".git/index")).unwrap();
    // A git checkpoint under the Runtime's own capability for the plan.
    let checkpoint = job_request(
        "git",
        "workspace.create-checkpoint",
        json!({"projectRef": checkout_ref}),
        None,
    );
    let planned = answered(&home, "job.plan", checkpoint.clone());
    assert_eq!(planned["authorizationPolicy"], "runtimeCapability");
    assert_eq!(planned["effectiveEffect"], "deviceMutation");
    prime("/usr/bin/clang");
    let (first, result) = job(&home, checkpoint);
    let authority = &result["evidence"]["authority"];
    assert_eq!(authority["kind"], "runtimeCapability", "{result}");
    assert_eq!(authority["planDigest"], planned["materializedPlanDigest"]);
    let reference = authority["reference"].as_str().unwrap().to_owned();
    assert!(
        reference.starts_with("CAP-RT-POLICY-") && reference.ends_with("-G1"),
        "{reference}"
    );
    let envelope: Value = serde_json::from_slice(&product(&home, &first, &result)).unwrap();
    assert_eq!(envelope["checkpointKind"], "gitObject", "{envelope}");
    let object = envelope["checkpointObject"].as_str().unwrap();
    assert_eq!(git(&["cat-file", "-t", object], &checkout), b"commit\n");
    assert_eq!(git(&["stash", "list"], &checkout), b"");
    assert_eq!(git(&["status", "--porcelain=v1"], &checkout), status_before);
    assert_eq!(fs::read(checkout.join(".git/index")).unwrap(), index_before);
    // The capability was one use: the next checkpoint runs under the next
    // generation of the same policy, and runs git after make has run.
    prime("/usr/bin/make");
    let (again, ran) = run(
        &home,
        job_request(
            "git-again",
            "workspace.create-checkpoint",
            json!({"projectRef": checkout_ref}),
            None,
        ),
    );
    for mark in MAKE_MARKS {
        assert!(
            !checkout.join(mark).exists(),
            "the checkpoint ran make in the project: {ran}"
        );
    }
    assert_eq!(ran["state"], "succeeded", "{ran}");
    let again = answered(&home, "job.result", json!({"jobId": again}));
    assert_eq!(
        again["evidence"]["authority"]["reference"],
        format!("{}-G2", reference.strip_suffix("-G1").unwrap())
    );
    // No capability a caller names admits it.
    let named = request(
        &home,
        "job.submit",
        job_request(
            "git-named",
            "workspace.create-checkpoint",
            json!({"projectRef": checkout_ref}),
            Some(&reference),
        ),
    );
    assert_eq!(named["error"]["code"], "admissionDenied", "{named}");
    assert_eq!(
        named["error"]["message"],
        "caller-supplied capabilities cannot admit a Runtime-owned policy"
    );

    // A plain project sealed into the Runtime-owned archive.
    let (sealed, result) = job(
        &home,
        job_request(
            "archive",
            "workspace.create-checkpoint",
            json!({"projectRef": plain_ref, "checkpointFilePaths": [INDEX]}),
            None,
        ),
    );
    let envelope: Value = serde_json::from_slice(&product(&home, &sealed, &result)).unwrap();
    assert_eq!(envelope["checkpointKind"], "sealedArchive", "{envelope}");
    let archive = home
        .state()
        .join("workspace-patch-attempts")
        .join(format!("checkpoint-{}.tar", sha256_hex(sealed.as_bytes())));
    let bytes = fs::read(&archive).unwrap();
    assert_eq!(envelope["checkpointObject"], sha256_hex(&bytes));
    let listed = Command::new("/usr/bin/bsdtar")
        .arg("-tf")
        .arg(&archive)
        .env_clear()
        .output()
        .unwrap()
        .stdout;
    assert!(
        String::from_utf8(listed)
            .unwrap()
            .lines()
            .any(|line| line == INDEX)
    );

    // A Runtime-owned copy of the plain project, measured, then swept.
    let source = revision(&[(INDEX, INDEX_SOURCE.as_bytes())]);
    let (made, _) = job(
        &home,
        job_request(
            "copy",
            "workspace.prepare-isolated-copy",
            json!({"projectRef": plain_ref, "expectedWorkspaceRevision": source,
                "allowedFileGlobs": ["entry/src/main/ets/pages/**"]}),
            None,
        ),
    );
    let digest = sha256_hex(format!("runtime-{made}|{plain_ref}|{source}").as_bytes());
    let (workspace_id, copy) = (
        format!("evo-{}", &digest[..24]),
        format!("evolution-{}", &digest[..20]),
    );
    let task_root = home
        .state()
        .join("evolution-workspaces")
        .join(&workspace_id);
    for (label, dry_run, disposition) in [
        ("sweep-dry", true, "wouldDestroy"),
        ("sweep", false, "destroyed"),
    ] {
        let sweep = job_request(
            label,
            "workspace.sweep-isolated-copies",
            json!({"retainLatestCount": 0, "minimumQuiescentSeconds": 0, "dryRun": dry_run}),
            None,
        );
        let planned = answered(&home, "job.plan", sweep.clone());
        assert_eq!(planned["authorizationPolicy"], "defaultReadOnly");
        assert_eq!(planned["effectiveEffect"], "hostOnly");
        let (swept, result) = job(&home, sweep);
        let findings: Value = serde_json::from_slice(&product(&home, &swept, &result)).unwrap();
        assert_eq!(findings["documentType"], "arkdeck-workspace-sweep");
        let finding = findings["findings"]
            .as_array()
            .unwrap()
            .iter()
            .find(|finding| finding["workspaceId"] == workspace_id.as_str())
            .unwrap_or_else(|| panic!("{label}: {findings}"));
        assert_eq!(finding["disposition"], disposition, "{label}: {findings}");
        assert_eq!(finding["referencingJobs"], 1, "{label}: {findings}");
        assert_eq!(
            task_root.join("workspace").exists(),
            dry_run,
            "{label}: the tree"
        );
    }
    assert!(task_root.join("teardown.json").exists());
    assert!(task_root.join("workspace.json").exists());
    let refused = request(
        &home,
        "job.plan",
        job_request(
            "read-swept",
            "workspace.read-source-range",
            json!({"projectRef": copy, "filePath": INDEX, "lineStart": 1, "lineEnd": 1}),
            None,
        ),
    );
    // The production composition resolves a Job's project through the
    // registered projects first: a destroyed copy's reference names none.
    assert_eq!(refused["error"]["code"], "invalidInput", "{refused}");
    assert_eq!(
        refused["error"]["message"], "workspace project is not registered",
        "{refused}"
    );
    daemon.stop();
}
