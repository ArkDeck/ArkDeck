//! The signed test daemon (Windows): the production Windows development root
//! composition, served on its pipe, with an in-process fake HDC, which the
//! real signed `arkdeck.exe` drives as it drives an installed daemon.
//!
//! The production Windows daemon composes an HDC only for a registered
//! Windows HDC tuple, has no fake-HDC input, and its development root runs no
//! fixture HDC (rulings 26 and 51). A Job of a device operation can therefore
//! be measured end to end on Windows only through a test build. This is that
//! test build: this binary, which compiles the daemon's own lifecycle and
//! composition (`windows_lifecycle`), copied and signed with the host-trusted
//! development signer, so the CLI's peer check (`ARKDECK_DAEMON_PATH` and
//! `ARKDECK_DAEMON_SIGNER_SHA256`) is the production one, unchanged. The copy
//! is started as a child that runs one test, [`the_signed_test_daemon`]: it
//! takes the development root as `arkdeck-agentd` does
//! (`windows_lifecycle::start`), composes its owners
//! (`Authority::compose`) and the code-sign helper beside its executable, and
//! only then gives the Host the fake through its test-only seam
//! (`Host::with_test_hdc`, compiled into test builds alone); it recovers,
//! serves and drains as `arkdeck-agentd` does.
//!
//! The fake is the shared oracle fake's answers in process
//! (`oracle_fake.rs`), over a root of its own, answering as the recorded
//! driver whose digest is the fixture's `hdc`. Started with a board
//! ([`SignedDaemon::start_with_board`]), the Host also reads a synthetic USB
//! census naming the fixture's DAYU200 by its serial. Host tests only: nothing here
//! reaches a device or an installed Runtime.
use crate::host::Host;
use crate::{code_sign_helper, oracle_fake, windows_lifecycle};
use arkdeck_control::Control;
use arkdeck_platform::StateRoot;
use serde_json::Value;
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::Arc;
use std::sync::mpsc::{self, Receiver};
use std::time::{Duration, Instant};

/// Names the fixture directory whose fake HDC (`hdc-answers.sh`, `hdc`) the
/// child composes; set only for the child.
const FIXTURE: &str = "ARKDECK_TEST_SIGNED_DAEMON_FIXTURE";
/// The fake HDC's own root (its call log, mode file and device markers).
const FAKE_ROOT: &str = "ARKDECK_TEST_SIGNED_DAEMON_FAKE_ROOT";
/// A replay's fixed clock, `<now>|<precise now>`, which the child's Host
/// reads instead of the system's (`host::TEST_CLOCK`).
pub(crate) const CLOCK: &str = "ARKDECK_TEST_SIGNED_DAEMON_CLOCK";
/// The Job state a replay's device mutations prove their continuity against:
/// the replay root's own, as the oracle's was, where a Windows development
/// root otherwise names the account's (`windows_lifecycle`).
pub(crate) const MUTATION_ROOT: &str = "ARKDECK_TEST_SIGNED_DAEMON_MUTATION_ROOT";
/// A `cases.json` whose recorded `codeSignHelper` facts stand in for the
/// bundled helper, at `<replay root>\hostrkdeck-code-sign-enable`, the
/// path its argv names: the oracle recorded the helper's facts, not its
/// bytes, and the fake never reads them.
pub(crate) const HELPER: &str = "ARKDECK_TEST_SIGNED_DAEMON_HELPER";
/// The serial of the one DAYU200 a synthetic USB census names
/// ([`SignedDaemon::start_with_board`]): the Host reads it through the
/// production census relations (`Host::with_usb_registry_relations`), so an
/// observation of the fake's device is proved the adopted Target's, as a
/// registered HDC's composition proves it over the Runtime's own census.
pub(crate) const BOARD: &str = "ARKDECK_TEST_SIGNED_DAEMON_BOARD";
/// Set (to anything) for the diagnostic-session oracle's fake: the Trace
/// legs' answers, with the long recording's start and finish answered in the
/// ring lifecycle vocabulary the oracle's producer adapted them to
/// ([`RingVocabulary`]).
pub(crate) const RING_VOCABULARY: &str = "ARKDECK_TEST_SIGNED_DAEMON_RING_VOCABULARY";
/// The child's test, by its full name.
const CHILD: &str = "signed_daemon::the_signed_test_daemon";
/// As `arkdeck-agentd`'s (`src/main.rs`).
const DRAIN_DEADLINE: Duration = Duration::from_secs(20);
const CONNECTION_IDLE: Duration = Duration::from_secs(20);
/// How long the parent waits for the child's lines and its end.
const DEADLINE: Duration = Duration::from_secs(120);

/// The child: serves until it is asked to stop, then exits; in any other run
/// of this binary it returns at once.
#[test]
fn the_signed_test_daemon() {
    let (Some(fixture), Some(fake_root)) = (std::env::var_os(FIXTURE), std::env::var_os(FAKE_ROOT))
    else {
        return;
    };
    let code = match serve(Path::new(&fixture), Path::new(&fake_root)) {
        Ok(()) => 0,
        Err(error) => {
            eprintln!("arkdeck-agentd: {error}");
            1
        }
    };
    std::process::exit(code);
}

/// `arkdeck-agentd`'s Windows serve (`src/main.rs`), with the fake given to
/// the composed Host.
fn serve(fixture: &Path, fake_root: &Path) -> Result<(), Box<dyn std::error::Error>> {
    let development = std::env::var_os("ARKDECK_DEVELOPMENT_STATE_ROOT")
        .ok_or("the signed test daemon serves a development root only")?;
    let windows_lifecycle::Serving {
        stop,
        listener,
        authority,
    } = match windows_lifecycle::start(
        Some(&development),
        std::env::var_os("ARKDECK_ENDPOINT").as_deref(),
        &crate::host::utc_now(),
        &|name| std::env::var_os(name),
    )? {
        windows_lifecycle::Start::Serve(serving) => serving,
        windows_lifecycle::Start::AlreadyRunning(instance) => {
            return Err(format!("another daemon owns the root: {}", instance.running()).into());
        }
    };
    let authority = authority.ok_or("a development root composes an authority")?;
    if let Some(clock) = std::env::var_os(CLOCK) {
        let clock = clock
            .into_string()
            .map_err(|_| "the test clock is not text")?;
        let (now, precise) = clock
            .split_once('|')
            .ok_or("the test clock is <now>|<precise now>")?;
        crate::host::TEST_CLOCK
            .set((now.to_owned(), precise.to_owned()))
            .map_err(|_| "the test clock is taken once")?;
    }
    let host = Host::from_environment();
    let host = match std::env::var_os(HELPER) {
        Some(cases) => {
            host.with_code_sign_helper(recorded_helper(Path::new(&cases), Path::new(&development))?)
        }
        None => match code_sign_helper::bundled() {
            Ok(Some(helper)) => host.with_code_sign_helper(helper),
            Ok(None) => host,
            Err(reason) => {
                println!("native deployment stays unavailable: {reason}");
                host
            }
        },
    };
    let (host, arkforge, managed) = authority.compose(host)?;
    if managed.is_some() {
        return Err("the signed test daemon composes no managed HDC server".into());
    }
    let host = match std::env::var_os(MUTATION_ROOT) {
        Some(root) => host.with_mutation_root(PathBuf::from(root)),
        None => host,
    };
    let answers =
        oracle_fake::Answers::of(&std::fs::read_to_string(fixture.join("hdc-answers.sh"))?);
    let tool_sha256 = arkdeck_contract::sha256_hex(&std::fs::read(fixture.join("hdc"))?);
    let fake = oracle_fake::OracleFake::new(fake_root, answers);
    let fake: Arc<dyn arkdeck_provider_hdc::HdcDispatch + Send + Sync> =
        if std::env::var_os(RING_VOCABULARY).is_some() {
            Arc::new(RingVocabulary(fake))
        } else {
            Arc::new(fake)
        };
    let host = host.with_test_hdc(fake, &tool_sha256);
    // The board the fake's device is, in its HDC-normal personality on one
    // port with one attachment, as the census reads a present DAYU200.
    let host = match std::env::var(BOARD) {
        Ok(serial) => host.with_usb_registry_relations(
            arkdeck_provider_hdc::UsbRegistryRelations::new(move || {
                Ok(vec![arkdeck_platform::UsbHostDevice {
                    serial: serial.clone(),
                    vendor_id: arkdeck_provider_hdc::ROCKUSB_VENDOR_ID,
                    product_id: arkdeck_provider_hdc::DAYU200_NORMAL_PRODUCT_ID,
                    topology: "1".into(),
                    product_name: Some("HDC Device".into()),
                    registry_entry_id: Some(1),
                }])
            }),
        ),
        Err(_) => host,
    };
    if let Some(recovered) = host.recover_active_jobs()? {
        for (job, reason) in recovered.quarantined.iter().chain(&recovered.refused) {
            eprintln!("arkdeck-agentd: job {job} was not recovered: {reason}");
        }
    }
    if let Some(staged) = host.recover_staged_sessions() {
        for (entry, reason) in &staged.kept {
            eprintln!("arkdeck-agentd: staged Session {entry} is kept as it is: {reason}");
        }
    }
    if let Some(Err(error)) = host.collect_expired_artifacts() {
        println!("artifact retention sweep failed: {error}");
    }
    let control = Arc::new(Control::new(host)?);
    println!(
        "arkdeck-agentd listening on {}",
        authority.endpoint.as_path().display()
    );
    let _ = std::io::Write::flush(&mut std::io::stdout());
    let drain = arkdeck_agentd::serve_control(
        listener,
        control,
        |listener| listener.accept_until(&stop),
        CONNECTION_IDLE,
        DRAIN_DEADLINE,
    )?;
    drop(drain.listener_lock);
    arkforge.stop();
    if drain.complete {
        authority.release();
    }
    println!("arkdeck-agentd stopped");
    let _ = std::io::Write::flush(&mut std::io::stdout());
    Ok(())
}

/// The shared fake, with the long recording's start and finish answered as
/// the diagnostic-session oracle's producer answered them
/// (`arkdeck-hoststore/tests/capture_diagnostics.rs`,
/// `diagnostic_session_publishes_host_marks_and_stops_after_an_unknown_anchor`):
/// the Swift fake's Trace answers predate the observed ring lifecycle
/// vocabulary. Every call is still the fake's, logged and answered by it.
struct RingVocabulary(oracle_fake::OracleFake);

impl arkdeck_provider_hdc::HdcDispatch for RingVocabulary {
    fn mutation_identity_current(&self) -> bool {
        arkdeck_provider_hdc::HdcDispatch::mutation_identity_current(&self.0)
    }

    fn dispatch(
        &self,
        plan: &arkdeck_provider_hdc::ProcessPlan,
    ) -> Result<arkdeck_provider_hdc::Receipt, arkdeck_provider_hdc::DispatchFailure> {
        let mut receipt = arkdeck_provider_hdc::HdcDispatch::dispatch(&self.0, plan)?;
        if plan.arguments.iter().any(|arg| arg == "--trace_begin") {
            receipt.stdout = b"OpenRecording done\n".to_vec();
        } else if plan
            .arguments
            .iter()
            .any(|arg| arg == "--trace_finish_nodump")
        {
            receipt.stdout = b"end capture trace.\n".to_vec();
        }
        Ok(receipt)
    }
}

/// The helper `cases.json` recorded, at the replay root's
/// `hostrkdeck-code-sign-enable` (see [`HELPER`]).
fn recorded_helper(
    cases: &Path,
    root: &Path,
) -> Result<arkdeck_provider_hdc::CodeSignHelper, Box<dyn std::error::Error>> {
    let cases: Value = serde_json::from_slice(&std::fs::read(cases)?)?;
    let recorded = &cases["codeSignHelper"];
    let text = |key: &str| {
        recorded[key]
            .as_str()
            .map(str::to_owned)
            .ok_or_else(|| format!("the recorded helper has no {key}"))
    };
    Ok(arkdeck_provider_hdc::CodeSignHelper {
        facts: arkdeck_provider_hdc::CodeSignHelperFacts {
            abi: arkdeck_provider_hdc::NativeAbi::Arm64,
            build_id: text("buildId")?,
            sha256: text("sha256")?,
            byte_count: recorded["byteCount"]
                .as_i64()
                .ok_or("the recorded helper has no byteCount")?,
        },
        host_path: root.join("host").join("arkdeck-code-sign-enable"),
    })
}

/// This binary, copied into `directory` and signed with the development
/// signer whose thumbprint `ARKDECK_DEV_SIGNER_THUMBPRINT` names: the copy
/// and the signer pin the CLI verifies. `None` (reported) when no signer is
/// configured.
pub(crate) fn signed_copy(directory: &Path) -> Option<(PathBuf, String)> {
    let Some(thumbprint) =
        std::env::var_os("ARKDECK_DEV_SIGNER_THUMBPRINT").filter(|value| !value.is_empty())
    else {
        eprintln!(
            "SKIPPED: ARKDECK_DEV_SIGNER_THUMBPRINT is not set (or empty), so no host-trusted \
             development signer can sign the test daemon the CLI must verify \
             (rust/scripts/windows-dev-identity.ps1 create); nothing was checked"
        );
        return None;
    };
    std::fs::create_dir_all(directory).unwrap();
    let daemon = directory.join("arkdeck-agentd-test.exe");
    std::fs::copy(std::env::current_exe().unwrap(), &daemon).unwrap();
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
    Some((daemon, pin["pin"].as_str().unwrap().to_owned()))
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
        "PowerShell 7 is required to sign the test daemon"
    );
    alias
}

/// The signed test daemon, running over a development root, its stdout read
/// line by line as it comes and its stderr kept in `daemon-stderr.log`
/// beside the root.
pub(crate) struct SignedDaemon {
    executable: PathBuf,
    pin: String,
    root: PathBuf,
    pipe: String,
    child: Option<Child>,
    lines: Receiver<String>,
    seen: Vec<String>,
}

impl SignedDaemon {
    /// Starts `executable` (a [`signed_copy`]) over the development `root`,
    /// with the fake HDC of `fixture` over `fake_root`, and waits until it
    /// serves.
    pub(crate) fn start(
        executable: &Path,
        pin: &str,
        root: &Path,
        fixture: &Path,
        fake_root: &Path,
    ) -> Self {
        Self::start_with(executable, pin, root, fixture, fake_root, &[])
    }

    /// [`Self::start`], with the synthetic USB census naming one DAYU200 whose
    /// serial is `serial` (the fixture's connect key; [`BOARD`]).
    pub(crate) fn start_with_board(
        executable: &Path,
        pin: &str,
        root: &Path,
        fixture: &Path,
        fake_root: &Path,
        serial: &str,
    ) -> Self {
        Self::start_with(
            executable,
            pin,
            root,
            fixture,
            fake_root,
            &[(BOARD, serial.to_owned())],
        )
    }

    /// [`Self::start`], with the replay's composition inputs (`CLOCK`,
    /// `MUTATION_ROOT`, `HELPER`, `BOARD`) as `variables`.
    pub(crate) fn start_with(
        executable: &Path,
        pin: &str,
        root: &Path,
        fixture: &Path,
        fake_root: &Path,
        variables: &[(&str, String)],
    ) -> Self {
        let mut command = Command::new(executable);
        for (key, _) in std::env::vars_os() {
            let upper = key.to_string_lossy().to_ascii_uppercase();
            if upper.starts_with("ARKDECK_") || upper.starts_with("OHOS_HDC_") {
                command.env_remove(key);
            }
        }
        let stderr = std::fs::File::create(
            root.parent()
                .unwrap()
                .join(format!("daemon-stderr-{}.log", std::process::id())),
        )
        .unwrap();
        let mut child = command
            .args(["--exact", CHILD, "--nocapture", "--test-threads=1"])
            .env("ARKDECK_DEVELOPMENT_STATE_ROOT", root)
            .env(FIXTURE, fixture)
            .env(FAKE_ROOT, fake_root)
            .envs(variables.iter().map(|(key, value)| (*key, value)))
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::from(stderr))
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
        let mut daemon = Self {
            executable: executable.to_owned(),
            pin: pin.to_owned(),
            root: root.to_owned(),
            pipe: String::new(),
            child: Some(child),
            lines,
            seen: Vec::new(),
        };
        daemon.pipe = daemon
            .line_starting("arkdeck-agentd listening on ")
            .trim_start_matches("arkdeck-agentd listening on ")
            .to_owned();
        daemon
    }

    /// Every line up to the first that starts with `prefix`, which is returned.
    fn line_starting(&mut self, prefix: &str) -> String {
        let deadline = Instant::now() + DEADLINE;
        loop {
            let left = deadline.saturating_duration_since(Instant::now());
            match self.lines.recv_timeout(left) {
                Ok(line) if line.starts_with(prefix) => return line,
                Ok(line) => self.seen.push(line),
                Err(_) => panic!(
                    "the signed test daemon never printed {prefix:?}; it printed {:?}",
                    self.seen
                ),
            }
        }
    }

    /// The real CLI beside the daemon, against its pipe, verifying it and
    /// its signer pin (or `pin`, when given) as it verifies an installed
    /// daemon: its exit status and its JSON envelope.
    pub(crate) fn cli_pinned(&self, pin: &str, arguments: &[&str]) -> (Option<i32>, Value) {
        let output = self
            .command(pin, arguments)
            .output()
            .unwrap_or_else(|error| {
                panic!(
                    "the arkdeck CLI beside the daemon ({}): {error}; run the workspace tests, \
                 or `cargo build -p arkdeck-cli` before testing this crate alone",
                    cli().display()
                )
            });
        envelope(arguments, &output)
    }

    /// [`Self::cli`], started and left running: its exit status and its
    /// envelope are read by [`Running::finish`], while other requests are
    /// sent to the same daemon.
    pub(crate) fn cli_running(&self, arguments: &[&str]) -> Running {
        let child = self
            .command(&self.pin, arguments)
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap_or_else(|error| panic!("the arkdeck CLI ({}): {error}", cli().display()));
        Running {
            arguments: arguments
                .iter()
                .map(|argument| (*argument).to_owned())
                .collect(),
            child,
        }
    }

    /// The real CLI's invocation against this daemon's pipe, under `pin`.
    fn command(&self, pin: &str, arguments: &[&str]) -> Command {
        let mut command = Command::new(cli());
        for (key, _) in std::env::vars_os() {
            if key
                .to_string_lossy()
                .to_ascii_uppercase()
                .starts_with("ARKDECK_")
            {
                command.env_remove(key);
            }
        }
        command
            .args(arguments)
            .args(["--output", "json"])
            .env("ARKDECK_ENDPOINT", &self.pipe)
            .env("ARKDECK_DAEMON_PATH", &self.executable)
            .env("ARKDECK_DAEMON_SIGNER_SHA256", pin)
            .stdin(Stdio::null());
        command
    }

    /// The pipe it serves, as it printed it.
    pub(crate) fn pipe(&self) -> &str {
        &self.pipe
    }

    /// [`Self::cli_pinned`] with the signed copy's own pin.
    pub(crate) fn cli(&self, arguments: &[&str]) -> (Option<i32>, Value) {
        self.cli_pinned(&self.pin.clone(), arguments)
    }

    /// Asks it to stop, by its root's scope and its pid, and waits for its
    /// drained end.
    pub(crate) fn stop(mut self) {
        let scope = StateRoot::development(&self.root).unwrap().scope().unwrap();
        scope
            .request_stop(self.child.as_ref().unwrap().id())
            .unwrap();
        self.line_starting("arkdeck-agentd stopped");
        let mut child = self.child.take().unwrap();
        let deadline = Instant::now() + DEADLINE;
        let status = loop {
            if let Some(status) = child.try_wait().unwrap() {
                break status;
            }
            assert!(
                Instant::now() < deadline,
                "the signed test daemon did not end"
            );
            std::thread::sleep(Duration::from_millis(50));
        };
        assert!(status.success(), "{status:?}");
    }
}

/// The real CLI beside the daemon's test build.
fn cli() -> PathBuf {
    Path::new(env!("CARGO_BIN_EXE_arkdeck-agentd")).with_file_name("arkdeck.exe")
}

/// A finished CLI's exit status and its JSON envelope.
fn envelope(
    arguments: &[impl std::fmt::Debug],
    output: &std::process::Output,
) -> (Option<i32>, Value) {
    let envelope = serde_json::from_slice(&output.stdout)
        .unwrap_or_else(|_| panic!("{arguments:?}: {output:?}"));
    (output.status.code(), envelope)
}

/// A CLI left running ([`SignedDaemon::cli_running`]).
pub(crate) struct Running {
    arguments: Vec<String>,
    child: Child,
}

impl Running {
    /// Waits for its end: its exit status and its envelope.
    pub(crate) fn finish(self) -> (Option<i32>, Value) {
        let output = self.child.wait_with_output().unwrap();
        envelope(&self.arguments, &output)
    }
}

impl Drop for SignedDaemon {
    fn drop(&mut self) {
        if let Some(mut child) = self.child.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}

/// A fresh directory below `TEMP`, in its plain canonical spelling.
pub(crate) fn temporary(prefix: &str) -> PathBuf {
    let base = std::env::temp_dir().canonicalize().unwrap();
    let base = match base.to_str().and_then(|text| text.strip_prefix(r"\\?\")) {
        Some(plain) => PathBuf::from(plain),
        None => base,
    };
    base.join(format!(
        "{prefix}-{:x}",
        u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap())
    ))
}

pub(crate) fn fixtures(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/fixtures")
        .join(name)
}

/// The harness itself: the real CLI drives the signed test daemon over its
/// pipe and is answered by it, and refuses it under any other signer pin.
#[test]
fn the_real_cli_drives_the_signed_test_daemon_over_its_pipe() {
    let _turn = crate::turn();
    let scratch = temporary("signed-test-daemon");
    let Some((executable, pin)) = signed_copy(&scratch.join("signed-bin")) else {
        return;
    };
    let (root, fake_root) = (scratch.join("state"), scratch.join("arkdeck-hdc-oracle"));
    std::fs::create_dir_all(&root).unwrap();
    std::fs::create_dir_all(&fake_root).unwrap();
    let daemon = SignedDaemon::start(&executable, &pin, &root, &fixtures("debug-hap"), &fake_root);
    let (status, envelope) = daemon.cli(&["job", "list"]);
    assert_eq!(status, Some(0), "{envelope}");
    assert_eq!(envelope["ok"], true, "{envelope}");
    let other = "0".repeat(64);
    let (status, envelope) = daemon.cli_pinned(&other, &["job", "list"]);
    assert_ne!(status, Some(0), "a daemon under another signer: {envelope}");
    assert_eq!(envelope["ok"], false, "{envelope}");
    daemon.stop();
    let _ = std::fs::remove_dir_all(&scratch);
}
