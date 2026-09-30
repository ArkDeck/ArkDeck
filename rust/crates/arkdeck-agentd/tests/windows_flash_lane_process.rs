//! The Windows daemon's ArkForge lane (TASK-XPA-010, GJ-4): what the real
//! daemon composes over an isolated development root, and where it stops.
//!
//! The lane is composed as the macOS compositions compose it beside the Job
//! state: one validated `ARKDECK_ARKFORGE_BUNDLE_PATH` bundle names the
//! `arkforged.exe` to start and pair over stdin. Its authority support binds
//! the managed-control HDC's digest, and no Windows HDC tuple is registered
//! (its integration change waits for the maintainer's samples), so no HDC is
//! composed and the lane is refused before anything is launched:
//!
//! * without a bundle, and with a retired lane name, the start reports
//!   Swift's absence, and so does a Flash `job.plan` and `job.submit`,
//!   refused before admission with zero dispatch;
//! * with a verified bundle, the start reports that the authority cannot be
//!   bound without the managed-control HDC digest; the bundle's daemon never
//!   runs, so nothing serves the lane's pipes, and `flash.device-access`
//!   answers Swift's one refusal; a Flash is refused before admission with
//!   that reason and zero dispatch, and nothing is admitted;
//! * the Flash facts and the device access observer are composed either
//!   way (the census names them); the facts read the Windows USB census,
//!   which fails closed until the DAYU200 sample confirms its mapping, so
//!   `flash.bootloader-status` observes no board.
//!
//! Every daemon runs with every `ARKDECK_` and `OHOS_HDC_` input removed but
//! its development root and, where a case names one, its bundle: nothing
//! installed is read or written, no HDC is configured, and no device, `hdc`
//! or `arkforged` is involved.
#![cfg(windows)]

use arkdeck_contract::sha256_hex;
use arkdeck_platform::StateRoot;
use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc::{self, Receiver};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::time::{Duration, Instant};

/// One test at a time: a child spawned while another test's daemon starts
/// would inherit that daemon's inheritable handles.
static TURN: Mutex<()> = Mutex::new(());
fn turn() -> MutexGuard<'static, ()> {
    TURN.lock().unwrap_or_else(PoisonError::into_inner)
}

const DEADLINE: Duration = Duration::from_secs(60);
const BUNDLE_KEY: &str = "ARKDECK_ARKFORGE_BUNDLE_PATH";

fn plan_fixture() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/fixtures/flash-plan")
}

fn plan_cases() -> Value {
    serde_json::from_slice(&std::fs::read(plan_fixture().join("cases.json")).unwrap()).unwrap()
}

/// The recorded Flash plan oracle's canonical request.
fn canonical_request() -> Value {
    let cases = plan_cases();
    let exchange = cases["exchanges"]
        .as_array()
        .unwrap()
        .iter()
        .find(|exchange| exchange["name"] == "canonical.full")
        .unwrap();
    let mut request: Value =
        serde_json::from_str(exchange["requestJson"].as_str().unwrap()).unwrap();
    request["idempotencyKey"] = json!("idem-windows-flash-lane");
    request
}

/// A fresh development root, removed afterwards.
struct Root(PathBuf);
impl Root {
    fn new() -> Self {
        let nonce = u64::from_ne_bytes(arkdeck_platform::random_bytes::<8>().unwrap());
        let path = std::env::temp_dir()
            .canonicalize()
            .unwrap()
            .join(format!("ad-winflash-{nonce:016x}"));
        std::fs::create_dir(&path).unwrap();
        let root = Self(path);
        root.lay_down();
        root
    }

    /// The Flash plan oracle's Artifact root and Target store, as Swift's
    /// Import left them, in the root's `artifacts` and `targets-state`:
    /// every directory private, every file created in it, each 0400 payload
    /// sealed as the Artifact store seals one.
    fn lay_down(&self) {
        fn private(path: &Path) {
            if !path.exists() {
                private(path.parent().unwrap());
                arkdeck_platform::HostDirectory::open_or_create_private(path).unwrap();
            }
        }
        for input in plan_cases()["inputs"].as_array().unwrap() {
            let path = input["path"].as_str().unwrap();
            let (source, destination) = match path.strip_prefix("../targets/") {
                Some(target) => (
                    plan_fixture().join("inputs/targets").join(target),
                    self.0.join("targets-state").join(target),
                ),
                None => (
                    plan_fixture().join("inputs/artifacts").join(path),
                    self.0.join("artifacts").join(path),
                ),
            };
            private(destination.parent().unwrap());
            let directory =
                arkdeck_platform::HostDirectory::open(destination.parent().unwrap()).unwrap();
            let name = destination.file_name().unwrap().to_str().unwrap();
            directory
                .create_document(name, &std::fs::read(source).unwrap())
                .unwrap();
            if input["mode"] == "400" {
                directory.seal_document(name).unwrap();
            }
        }
    }

    /// A verified `ArkForge.bundle` beside the root: a daemon, a CLI and the
    /// DAYU200 profile. Its daemon writes `launched` next to it if it ever
    /// runs; the lane must never start it.
    fn bundle(&self) -> PathBuf {
        let bundle = self.0.with_extension("bundle");
        for directory in ["bin", "Contents/Resources/profiles"] {
            std::fs::create_dir_all(bundle.join(directory)).unwrap();
        }
        let members: [(&str, Vec<u8>, &str, Option<&str>); 3] = [
            ("bin/arkforge.exe", b"stand-in cli".to_vec(), "cli", None),
            (
                "bin/arkforged.exe",
                // Never run: its bytes only need to be what the manifest says.
                std::fs::read(std::env::current_exe().unwrap()).unwrap(),
                "daemon",
                None,
            ),
            (
                "Contents/Resources/profiles/dayu200.yaml",
                b"schema: arkforge.device-profile/v1\nprofile:\n  id: org.openharmony.dayu200\n  \
                  version: 1.0.0\n"
                    .to_vec(),
                "profile",
                Some("org.openharmony.dayu200"),
            ),
        ];
        let mut manifest = Vec::new();
        for (path, bytes, role, profile) in &members {
            std::fs::write(bundle.join(path), bytes).unwrap();
            manifest.push(json!({"path": path, "sha256": sha256_hex(bytes),
                "bytes": bytes.len(), "role": role, "profileId": profile}));
        }
        std::fs::write(
            bundle.join("Contents/Resources/arkforge-bundle.json"),
            serde_json::to_vec(&json!({"schema": "arkforge.release-bundle/v1",
                "version": "0.1.0-test", "members": manifest}))
            .unwrap(),
        )
        .unwrap();
        bundle
    }

    /// Every Job below the Job store, by name.
    fn jobs(&self) -> Vec<String> {
        std::fs::read_dir(self.0.join("jobs-state").join("jobs"))
            .map(|entries| {
                entries
                    .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
                    .collect()
            })
            .unwrap_or_default()
    }
}
impl Drop for Root {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
        let _ = std::fs::remove_dir_all(self.0.with_extension("bundle"));
    }
}

/// A running daemon: its stdout read line by line as it comes, its stderr
/// kept whole.
struct Daemon {
    child: Option<Child>,
    lines: Receiver<String>,
    seen: Vec<String>,
    errors: Arc<Mutex<String>>,
}

impl Daemon {
    fn start(root: &Path, environment: &[(&str, &Path)]) -> Self {
        let mut command = Command::new(env!("CARGO_BIN_EXE_arkdeck-agentd"));
        for (key, _) in std::env::vars_os() {
            let key = key.to_string_lossy().into_owned();
            if key.to_ascii_uppercase().starts_with("ARKDECK_")
                || key.to_ascii_uppercase().starts_with("OHOS_HDC_")
            {
                command.env_remove(key);
            }
        }
        command.env("ARKDECK_DEVELOPMENT_STATE_ROOT", root);
        for (key, value) in environment {
            command.env(key, value);
        }
        let mut child = command
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
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
        let errors = Arc::new(Mutex::new(String::new()));
        let mut stderr = child.stderr.take().unwrap();
        let kept = Arc::clone(&errors);
        std::thread::spawn(move || {
            let mut buffer = [0u8; 4096];
            while let Ok(read) = stderr.read(&mut buffer) {
                if read == 0 {
                    break;
                }
                kept.lock()
                    .unwrap()
                    .push_str(&String::from_utf8_lossy(&buffer[..read]));
            }
        });
        Self {
            child: Some(child),
            lines,
            seen: Vec::new(),
            errors,
        }
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
                    "no line starting {prefix:?} ({error}); stdout so far {:?}, stderr {:?}",
                    self.seen,
                    self.errors.lock().unwrap()
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

    /// What it wrote to stderr so far.
    fn errors(&self) -> String {
        self.errors.lock().unwrap().clone()
    }

    /// Asks it to stop, by its root's scope and its pid, and waits for its end.
    fn stop(&mut self, root: &Path) {
        let scope = StateRoot::development(root).unwrap().scope().unwrap();
        scope
            .request_stop(self.child.as_ref().unwrap().id())
            .unwrap();
        self.line_starting("arkdeck-agentd stopped");
        let mut child = self.child.take().unwrap();
        let deadline = Instant::now() + DEADLINE;
        loop {
            if let Some(status) = child.try_wait().unwrap() {
                assert!(status.success(), "{status:?}");
                return;
            }
            assert!(Instant::now() < deadline, "the daemon did not end");
            std::thread::sleep(Duration::from_millis(20));
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

/// A Flash `job.plan` and `job.submit`, each refused before admission with
/// `reason` as the provider's and zero dispatch; nothing is admitted.
fn assert_flash_refused(pipe: &str, root: &Root, reason: &str) {
    let params = json!({"requestJson": serde_json::to_string(&canonical_request()).unwrap()});
    for method in ["job.plan", "job.submit"] {
        let reply = request(pipe, method, params.clone());
        assert_eq!(reply["ok"], false, "{method}: {reply}");
        assert_eq!(reply["error"]["code"], "invalidInput", "{method}: {reply}");
        assert_eq!(
            reply["error"]["message"],
            format!("flash.full-restore@1 is runtime unavailable: {reason}"),
            "{method}: {reply}"
        );
        assert_eq!(
            reply["error"]["details"],
            json!({"phase": "preAdmission", "newDispatchCount": 0}),
            "{method}: {reply}"
        );
    }
    assert!(root.jobs().is_empty(), "admitted: {:?}", root.jobs());
}

/// What the lane's observers answer without a daemon serving its pipes.
fn assert_no_lane_daemon(pipe: &str, runtime: &Path) {
    assert!(runtime.is_dir(), "{}", runtime.display());
    assert_eq!(
        request(pipe, "flash.device-access", json!({})),
        json!({"id": "flash.device-access", "ok": false, "error": {
            "code": "rejected", "message": "Rockchip device access observation failed"}})
    );
}

/// The census the start reports: the Flash facts and the device access
/// observer are composed, and no lane plan previewer without a lane.
fn assert_census(daemon: &mut Daemon) {
    let owners = daemon.line_starting("arkdeck-agentd owners: ");
    assert!(
        owners.ends_with("traceCache, flashHostFacts, deviceAccess"),
        "{owners}"
    );
}

#[test]
fn without_a_bundle_the_start_and_a_flash_report_swifts_absence() {
    let _turn = turn();
    let root = Root::new();
    let mut daemon = Daemon::start(&root.0, &[]);
    assert_census(&mut daemon);
    let pipe = daemon.serving();
    let absence = "no ArkForge lane: ARKDECK_ARKFORGE_BUNDLE_PATH is unset, so this daemon \
                   performs no Rockchip writes. canonical ArkForge Flash refuses before \
                   authorization";
    assert!(daemon.errors().contains(absence), "{}", daemon.errors());
    assert_flash_refused(&pipe, &root, absence);
    assert_no_lane_daemon(&pipe, &root.0.join("jobs-state").join("arkforge"));
    // The facts read the Windows USB census, which fails closed until the
    // DAYU200 sample confirms its mapping: no board is observed.
    let status = request(&pipe, "flash.bootloader-status", json!({}));
    assert_eq!(status["ok"], false, "{status}");
    assert_eq!(status["error"]["code"], "rejected", "{status}");
    assert!(
        status["error"]["message"]
            .as_str()
            .unwrap()
            .starts_with("Rockchip bootloader status could not be observed: "),
        "{status}"
    );
    assert!(
        status["error"]["message"]
            .as_str()
            .unwrap()
            .contains("USB registry unavailable"),
        "{status}"
    );
    daemon.stop(&root.0);
}

#[test]
fn a_retired_lane_name_is_refused_by_name() {
    let _turn = turn();
    let root = Root::new();
    let bundle = root.bundle();
    let mut daemon = Daemon::start(
        &root.0,
        &[(BUNDLE_KEY, &bundle), ("ARKDECK_ARKFORGED_PATH", &bundle)],
    );
    assert_census(&mut daemon);
    let pipe = daemon.serving();
    let absence = "no ArkForge lane: ARKDECK_ARKFORGED_PATH is retired configuration. \
                   Reconfigure this installation with `runtime service update \
                   --arkforge-bundle` so one validated ARKDECK_ARKFORGE_BUNDLE_PATH is \
                   published";
    assert!(daemon.errors().contains(absence), "{}", daemon.errors());
    assert_flash_refused(&pipe, &root, absence);
    daemon.stop(&root.0);
}

#[test]
fn a_verified_bundle_is_refused_before_its_daemon_starts_without_the_managed_control_hdc() {
    let _turn = turn();
    let root = Root::new();
    let bundle = root.bundle();
    let mut daemon = Daemon::start(&root.0, &[(BUNDLE_KEY, &bundle)]);
    assert_census(&mut daemon);
    let pipe = daemon.serving();
    let absence = "no ArkForge lane: cannot bind ArkForge authority support: the \
                   managed-control HDC digest is absent or malformed";
    assert!(daemon.errors().contains(absence), "{}", daemon.errors());
    assert!(
        !daemon.errors().contains("arkforge lane: composed"),
        "{}",
        daemon.errors()
    );
    assert_flash_refused(&pipe, &root, absence);
    // The bundle's daemon never ran: nothing serves the lane's pipes.
    assert_no_lane_daemon(&pipe, &root.0.join("jobs-state").join("arkforge"));
    daemon.stop(&root.0);
    // Nothing the lane owns is left to stop.
    assert!(
        !daemon.errors().contains("stopped the arkforged"),
        "{}",
        daemon.errors()
    );
}
