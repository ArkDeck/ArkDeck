//! GJ-1's device hops on Windows with the registered HDC (CHG-2026-074
//! TASK-XPA-005 over CHG-2026-078): the real daemon, over an isolated
//! development root, composes the registered DevEco Studio 26.0.0.43
//! `hdc.exe` (`3.2.0g`) as its managed server, and the real CLI, verifying a
//! copy of the daemon signed with the host-trusted development signer,
//! reads `device candidates` and `target adopt` through it.
//!
//! It needs two host facts, and without either it says so and checks
//! nothing:
//! - `ARKDECK_LIVE_WINDOWS_HDC`: the path of the registered `hdc.exe` (its
//!   bytes must hash to the registered tuple; any other executable fails);
//! - `ARKDECK_DEV_SIGNER_THUMBPRINT`: the development signer.
//!
//! Nothing else may listen on `127.0.0.1:8710` (the daemon starts and owns
//! the server there, and stops it before it ends; an existing server is never
//! adopted or stopped). With no board attached, the host's UART rows are no
//! device: the candidates are empty and an adoption of the oracle key is
//! refused before anything is written. With the DAYU200 attached (HDC-normal
//! image), its one candidate is proved by the Windows USB census and adopted
//! once. No device is changed either way: both hops only read.
#![cfg(windows)]

use arkdeck_platform::StateRoot;
use serde_json::Value;
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc::{self, Receiver};
use std::time::{Duration, Instant};

const DEADLINE: Duration = Duration::from_secs(90);
const C2_SHA256: &str = "c79518498aaf4e719733961216444e70c3eb53c8ba7006b933e6d7f2e1c6101e";

struct Root(PathBuf);
impl Root {
    fn new() -> Self {
        let nonce = u64::from_ne_bytes(arkdeck_platform::random_bytes::<8>().unwrap());
        let path = std::env::temp_dir()
            .canonicalize()
            .unwrap()
            .join(format!("ad-winhdclive-{nonce:016x}"));
        std::fs::create_dir(&path).unwrap();
        Self(path)
    }
    fn targets(&self) -> Option<Vec<u8>> {
        std::fs::read(self.0.join("targets-state").join("targets.json")).ok()
    }
}
impl Drop for Root {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

struct Daemon {
    child: Option<Child>,
    lines: Receiver<String>,
    seen: Vec<String>,
}

impl Daemon {
    fn start(executable: &Path, root: &Path, hdc: &Path) -> Self {
        let mut command = Command::new(executable);
        for (key, _) in std::env::vars_os() {
            let key = key.to_string_lossy().into_owned();
            if key.to_ascii_uppercase().starts_with("ARKDECK_")
                || key.to_ascii_uppercase().starts_with("OHOS_HDC_")
            {
                command.env_remove(key);
            }
        }
        let mut child = command
            .env("ARKDECK_DEVELOPMENT_STATE_ROOT", root)
            .env("ARKDECK_DEVELOPMENT_HDC_PATH", hdc)
            .env("ARKDECK_DEVELOPMENT_HDC_SERVER", "managed")
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()
            .unwrap();
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

    fn stop(&mut self, root: &Path) {
        let child = self.child.take().unwrap();
        let scope = StateRoot::development(root).unwrap().scope().unwrap();
        scope.request_stop(child.id()).unwrap();
        self.line_starting("arkdeck-agentd stopped");
        let mut child = child;
        let deadline = Instant::now() + DEADLINE;
        loop {
            if let Some(status) = child.try_wait().unwrap() {
                assert!(status.success(), "{status:?}");
                return;
            }
            assert!(Instant::now() < deadline, "the daemon did not end");
            std::thread::sleep(Duration::from_millis(100));
        }
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
        "PowerShell 7 is required to sign the daemon"
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

#[test]
fn gj1_device_hops_run_through_the_registered_windows_hdc() {
    let Some(hdc) = std::env::var_os("ARKDECK_LIVE_WINDOWS_HDC").filter(|v| !v.is_empty()) else {
        eprintln!(
            "SKIPPED: ARKDECK_LIVE_WINDOWS_HDC does not name the registered hdc.exe (DevEco Studio \
             26.0.0.43's toolchains hdc.exe); nothing was checked"
        );
        return;
    };
    let Some(thumbprint) =
        std::env::var_os("ARKDECK_DEV_SIGNER_THUMBPRINT").filter(|value| !value.is_empty())
    else {
        eprintln!(
            "SKIPPED: ARKDECK_DEV_SIGNER_THUMBPRINT is not set (or empty), so no host-trusted \
             development signer can sign the daemon the CLI must verify; nothing was checked"
        );
        return;
    };
    let hdc = PathBuf::from(hdc);
    // The named executable must be the registered one: a live run never
    // measures another build.
    let digest = arkdeck_contract::sha256_hex(&std::fs::read(&hdc).unwrap());
    assert_eq!(
        digest,
        C2_SHA256,
        "{} is not the registered hdc.exe",
        hdc.display()
    );
    assert!(
        std::net::TcpStream::connect_timeout(
            &"127.0.0.1:8710".parse().unwrap(),
            Duration::from_millis(300)
        )
        .is_err(),
        "something already listens on 127.0.0.1:8710: quit DevEco Studio (or stop the HDC server \
         it owns) before this run; this test never stops a server it did not start"
    );

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

    let mut running = Daemon::start(&daemon, &root.0, &hdc);
    let pipe = running.serving();
    assert!(
        running
            .seen
            .iter()
            .any(|line| line.contains("c2") && line.contains(C2_SHA256)),
        "the daemon reports the registered tuple it composed: {:?}",
        running.seen
    );

    // Server health is the commandless observation of the managed server.
    let (status, doctor) = cli(&daemon, &pin, &pipe, &["doctor", "--deep"]);
    eprintln!("doctor --deep: {}", doctor["result"]["checks"]["hdc"]);
    assert!(status.is_some(), "{doctor}");
    let (_, status_envelope) = cli(&daemon, &pin, &pipe, &["runtime", "hdc", "status"]);
    eprintln!("runtime hdc status: {status_envelope}");
    let hdc = &doctor["result"]["checks"]["hdc"];
    assert_eq!(hdc["configured"], true, "{hdc}");
    assert_eq!(hdc["checked"], true, "{hdc}");
    assert_eq!(hdc["availability"], "available", "{hdc}");
    assert_eq!(hdc["ownership"], "arkDeckManaged", "{hdc}");
    assert_eq!(hdc["reasonCode"], "hdc.identityObserved", "{hdc}");
    // The commandless identity names the managed server's process, and
    // proves no health: nothing ran to ask for it.
    let status = &status_envelope["result"];
    assert!(status["processId"].as_u64().is_some(), "{status}");
    assert_eq!(status["newDispatchCount"], 0, "{status}");
    assert_eq!(
        status["healthReasonCode"], "hdc.commandlessIdentityDoesNotProveHealth",
        "{status}"
    );

    let (status, candidates) = cli(&daemon, &pin, &pipe, &["device", "candidates"]);
    eprintln!("device candidates: {candidates}");
    assert_eq!(status, Some(0), "{candidates}");
    let observations = candidates["result"]["observations"]
        .as_array()
        .unwrap_or_else(|| panic!("{candidates}"))
        .clone();
    let generation = candidates["result"]["snapshotGeneration"]
        .as_str()
        .map(str::to_owned);

    if observations.is_empty() {
        // No board: the UART rows are no device, and the oracle key is not
        // a candidate of this observation.
        let (status, envelope) = cli(
            &daemon,
            &pin,
            &pipe,
            &[
                "target",
                "adopt",
                "--candidate",
                "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                "--observation",
                "obs-00000000-0000-4000-8000-000000000000",
                "--observation-generation",
                generation.as_deref().unwrap_or("1"),
            ],
        );
        eprintln!("target adopt (no board): {envelope}");
        assert_ne!(status, Some(0), "{envelope}");
        assert!(envelope["error"]["code"].is_string(), "{envelope}");
        let (status, listed) = cli(&daemon, &pin, &pipe, &["target", "list"]);
        assert_eq!(status, Some(0), "{listed}");
        assert_eq!(
            listed["result"],
            serde_json::json!([]),
            "nothing was adopted"
        );
        let _ = root.targets();
    } else {
        assert_eq!(observations.len(), 1, "one DAYU200: {candidates}");
        let observation = &observations[0];
        assert_eq!(
            observation["observationContinuity"], "relationProven",
            "{observation}"
        );
        let candidate = observation["candidateKey"].as_str().unwrap().to_owned();
        let observation_id = observation["observationId"].as_str().unwrap().to_owned();
        let (status, adopted) = cli(
            &daemon,
            &pin,
            &pipe,
            &[
                "target",
                "adopt",
                "--candidate",
                &candidate,
                "--observation",
                &observation_id,
                "--observation-generation",
                generation.as_deref().unwrap(),
            ],
        );
        eprintln!("target adopt: {adopted}");
        assert_eq!(status, Some(0), "{adopted}");
        let (status, listed) = cli(&daemon, &pin, &pipe, &["target", "list"]);
        assert_eq!(status, Some(0), "{listed}");
        assert_eq!(listed["result"][0]["toolVersion"], "3.2.0g", "{listed}");
    }
    running.stop(&root.0);
    // The managed server ended with its daemon.
    assert!(
        std::net::TcpStream::connect_timeout(
            &"127.0.0.1:8710".parse().unwrap(),
            Duration::from_millis(300)
        )
        .is_err(),
        "the daemon stopped the server it started"
    );
}
