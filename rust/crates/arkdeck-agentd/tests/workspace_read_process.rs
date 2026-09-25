//! The production daemon serves the four read-only workspace operations
//! (TASK-XPA-015, M3) through its installed socket as a caller meets them:
//! a registered OpenHarmony project inside a git working copy, composed by
//! the next start with the inspector the host configured
//! (`ARKDECK_WORKSPACE_INSPECTOR`, the real `/usr/bin/grep`) and the host's
//! own pinned `/usr/bin/sed` and `/usr/bin/git`. Each read plans under the
//! default read-only policy, runs, and publishes exactly what its tool prints
//! when run directly with the argv the provider builds; a read the profile
//! does not offer is refused before anything is admitted.
//!
//! The daemon runs with its environment cleared and `CFFIXED_USER_HOME`
//! naming a temporary home below `/private/tmp`, as the production composition
//! tests run it: no Mach service, LaunchAgent, installed state, HDC or device
//! is touched.
#![cfg(target_os = "macos")]

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
const INDEX: &str = "entry/src/main/ets/pages/Index.ets";
const INDEX_SOURCE: &str = "@Entry\n@Component\nstruct Index {\n  build() {}\n}\n";

/// A temporary account home, removed afterwards.
struct Home(PathBuf);
impl Home {
    fn new() -> Self {
        let nonce = u64::from_ne_bytes(arkdeck_platform::random_bytes::<8>().unwrap());
        let path = PathBuf::from(format!("/private/tmp/adr-{nonce:016x}"));
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
            // As Swift's LaunchAgent configures its daemon.
            .env("ARKDECK_WORKSPACE_INSPECTOR", "/usr/bin/grep")
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
        "id": "workspace-read-process", "method": method, "params": params}))
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

/// A host tool's own answer to `arguments`, in the clean base environment.
fn direct(program: &str, arguments: &[&str]) -> Vec<u8> {
    let output = Command::new(program)
        .args(arguments)
        .env_clear()
        .envs([("PATH", "/usr/bin:/bin"), ("LANG", "C"), ("LC_ALL", "C")])
        .output()
        .unwrap();
    output.stdout
}

fn git(arguments: &[&str], directory: &Path) {
    let status = Command::new("/usr/bin/git")
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
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .unwrap();
    assert!(status.success(), "git {arguments:?}");
}

#[test]
fn the_production_daemon_serves_the_workspace_reads_with_the_host_tools() {
    let home = Home::new();
    let project = home.0.join("project");
    for (path, bytes) in [
        ("build-profile.json5", "{}\n"),
        ("entry/src/main/module.json5", "{}\n"),
        (INDEX, INDEX_SOURCE),
    ] {
        fs::create_dir_all(project.join(path).parent().unwrap()).unwrap();
        fs::write(project.join(path), bytes).unwrap();
    }
    git(&["init", "--quiet"], &project);
    git(&["add", "-A"], &project);
    git(&["commit", "--quiet", "-m", "base"], &project);
    fs::write(project.join(INDEX), format!("{INDEX_SOURCE}// edited\n")).unwrap();
    // Registered, then composed by the next start.
    let daemon = Daemon::start(&home);
    let registered = answered(
        &home,
        "workspace.project.register",
        json!({"registrationRequestId": "workspace-read-process", "kind": "openharmony",
            "root": project.to_str().unwrap()}),
    )["projectRef"]
        .as_str()
        .unwrap()
        .to_owned();
    daemon.stop();

    let daemon = Daemon::start(&home);
    let physical = project.canonicalize().unwrap();
    let registered_root = physical.to_str().unwrap().to_owned();
    // The canonical spelling the profile runs git and sed in.
    let profile_root = registered_root
        .strip_prefix("/private")
        .unwrap_or(&registered_root)
        .to_owned();
    let artifacts = home.state().join("artifacts");
    for (label, operation, inputs, expected) in [
        (
            "inspect",
            "workspace.inspect-source",
            json!({"projectRef": registered, "symbol": "build", "fileScope": "*.ets"}),
            // Published as Swift's store publishes text: the account home
            // the matches are named below is redacted.
            String::from_utf8(direct(
                "/usr/bin/grep",
                &[
                    "-r",
                    "-n",
                    "--include",
                    "*.ets",
                    "--",
                    "build",
                    &registered_root,
                ],
            ))
            .unwrap()
            .replace(home.0.to_str().unwrap(), "<HOME>")
            .into_bytes(),
        ),
        (
            "range",
            "workspace.read-source-range",
            json!({"projectRef": registered, "filePath": INDEX, "lineStart": 2, "lineEnd": 6}),
            direct(
                "/usr/bin/sed",
                &["-n", "2,6p", &format!("{profile_root}/{INDEX}")],
            ),
        ),
        (
            "status",
            "workspace.inspect-git-status",
            json!({"projectRef": registered}),
            direct(
                "/usr/bin/git",
                &[
                    "-C",
                    &profile_root,
                    "status",
                    "--porcelain=v1",
                    "--untracked-files=all",
                    "--",
                    ".",
                ],
            ),
        ),
        (
            "diff",
            "workspace.inspect-diff",
            json!({"projectRef": registered, "baseRevision": "HEAD", "pathScope": "entry"}),
            direct(
                "/usr/bin/git",
                &["-C", &profile_root, "diff", "--stat", "HEAD", "--", "entry"],
            ),
        ),
    ] {
        assert!(!expected.is_empty(), "{label}: the host tool answers");
        let request = job_request(label, operation, inputs);
        let planned = answered(&home, "job.plan", request.clone());
        assert_eq!(planned["authorizationPolicy"], "defaultReadOnly", "{label}");
        assert_eq!(planned["effectiveEffect"], "hostOnly", "{label}");
        let job = answered(&home, "job.submit", request)["jobId"]
            .as_str()
            .unwrap()
            .to_owned();
        let ran = answered(&home, "job.run", json!({"jobId": job}));
        assert_eq!(ran["state"], "succeeded", "{label}: {ran}");
        let result = answered(&home, "job.result", json!({"jobId": job}));
        assert_eq!(
            result["evidence"]["status"], "verified",
            "{label}: {result}"
        );
        let artifact = result["artifacts"][0]["artifactId"].as_str().unwrap();
        let stored = fs::read(artifacts.join(&job).join(artifact)).unwrap();
        assert_eq!(stored, expected, "{label}");
    }
    // A revision the provider will not accept is refused before anything is
    // admitted.
    let refused = request(
        &home,
        "job.plan",
        job_request(
            "diff-option",
            "workspace.inspect-diff",
            json!({"projectRef": registered, "baseRevision": "--output=/tmp/x",
                "pathScope": "entry"}),
        ),
    );
    assert_eq!(refused["error"]["code"], "invalidInput", "{refused}");
    assert_eq!(
        refused["error"]["message"],
        "typed plan preflight failed before authorization: workspace.malformedRevision"
    );
    daemon.stop();
}
