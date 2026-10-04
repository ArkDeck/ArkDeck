//! The Windows account daemon's HDC from its Bootstrap tool selection, end
//! to end (TASK-XPA-012): the real signed CLI drives the account daemon's
//! composition over a fake account.
//!
//! The account daemon composes an HDC only from its Bootstrap registry's
//! selection, admitted only by a registered Windows HDC tuple
//! (`windows_lifecycle`, CHG-2026-078: DevEco's `hdc.exe` only). A Windows
//! run cannot start that tool here, so this is a test build: this binary,
//! which compiles the daemon's own lifecycle and composition, copied and
//! signed with the host-trusted development signer (`signed_daemon::
//! signed_copy`), started as a child that runs one test,
//! [`the_signed_account_daemon`]. The child takes the account's root as
//! `arkdeck-agentd` does (`windows_lifecycle::start`), over a fake profile
//! (`USERPROFILE`), with `ARKDECK_HDC_PATH` naming a stand-in compiled here;
//! the only thing it does that production cannot is admit that stand-in's
//! digest through a fixture tuple (`Authority::with_tuples`, compiled into
//! test builds alone). It composes the registered HDC from the Bootstrap
//! selection exactly as production does: the stand-in is adopted as the
//! first selection, its retained copy is started as the managed server on
//! the tuple's endpoint, and the tool-selection owner is composed beside it.
//!
//! The real `arkdeck.exe`, pinned to the signed copy, lists the registered
//! tool as the account's selection and asks to select it. The tool-selection
//! owner answers with its typed action, as Swift's daemon answered and its
//! CLI printed it: the active tool is no candidate, so the action is drifted
//! (`tool.selectionFactsUnavailable`) and nothing is dispatched.
//!
//! It then registers a second executable a fixture tuple names (`runtime
//! tool register --kind hdc`): retained and listed beside the selection in
//! the macOS Runtime's answer shape, idempotent, and an executable no tuple
//! names is refused. Registration admits by the composition's own tuple
//! table, as the selection does (`BootstrapReaders::open_existing_identified`),
//! so the leaf is counted in `WINDOWS_MEASURED_LEAVES`. Selecting that
//! candidate still drifts: an awaiting-approval answer needs a healthy server
//! proof from the HDC lifecycle owner, which only a registered tuple's server
//! gives (#2501), so `runtime tool select` is not counted here. Every account
//! daemon starter is held off
//! for the whole run (`StarterLock`), as the account-location tests hold
//! them. Nothing installed, no `hdc` and no device is involved.
use crate::host::Host;
use crate::signed_daemon::signed_copy;
use crate::windows_lifecycle;
use arkdeck_control::Control;
use arkdeck_platform::{InstanceScope, StarterLock};
use serde_json::Value;
use std::io::{BufRead, BufReader};
use std::net::{Ipv4Addr, SocketAddrV4};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::Arc;
use std::sync::mpsc::{self, Receiver};
use std::time::{Duration, Instant};

mod loopback_ports {
    include!("../../../../tests/support/loopback_ports.rs");
}

/// The fixture tuple's digest, set only for the child.
const TUPLE: &str = "ARKDECK_TEST_ACCOUNT_DAEMON_TUPLE";
const CHILD: &str = "account_tool_selection::the_signed_account_daemon";
const DRAIN_DEADLINE: Duration = Duration::from_secs(20);
const CONNECTION_IDLE: Duration = Duration::from_secs(20);
const DEADLINE: Duration = Duration::from_secs(120);

/// A stand-in HDC compiled at test time: `-s <endpoint> -m` listens on the
/// endpoint until it is ended; `-s <endpoint> checkserver` answers agreeing
/// versions; `list targets -v` answers the registered UART-only listing;
/// anything else is unregistered (status 64). No real HDC runs.
const STAND_IN: &str = r#"
fn main() {
    let arguments: Vec<String> = std::env::args().collect();
    if arguments[1..] == ["list", "targets", "-v"] {
        print!("COM1\t\tUART\tReady\tunknown...\thdc\r\n");
        return;
    }
    match arguments.get(3).map(String::as_str) {
        Some("-m") => {
            let listener = std::net::TcpListener::bind(&arguments[2]).unwrap();
            for connection in listener.incoming() {
                drop(connection);
            }
        }
        Some("checkserver") => {
            println!("Client version:Ver: 3.2.0d, server version:Ver: 3.2.0d");
        }
        _ => std::process::exit(64),
    }
}
"#;

/// The child: serves the account's root until it is asked to stop, then
/// exits; in any other run of this binary it returns at once.
#[test]
fn the_signed_account_daemon() {
    let Ok(sha256) = std::env::var(TUPLE) else {
        return;
    };
    let code = match serve(sha256) {
        Ok(()) => 0,
        Err(error) => {
            eprintln!("arkdeck-agentd: {error}");
            1
        }
    };
    std::process::exit(code);
}

/// `arkdeck-agentd`'s Windows serve (`src/main.rs`) for the account's root,
/// its registered tuples replaced by the fixture's.
fn serve(sha256: String) -> Result<(), Box<dyn std::error::Error>> {
    let port: u16 = std::env::var(arkdeck_provider_hdc::SERVER_PORT_VARIABLE)?.parse()?;
    // One tuple for each digest the test names, all on the same endpoint.
    let tuples: &'static [arkdeck_provider_hdc::WindowsHdcTuple] = Box::leak(
        sha256
            .split(',')
            .map(|digest| arkdeck_provider_hdc::WindowsHdcTuple {
                candidate: "stand-in",
                executable_sha256: Box::leak(digest.to_owned().into_boxed_str()),
                reported_version: "3.2.0d",
                version_stdout: b"Ver: 3.2.0d\r\n",
                endpoint: SocketAddrV4::new(Ipv4Addr::LOCALHOST, port),
            })
            .collect::<Vec<_>>()
            .into_boxed_slice(),
    );
    let windows_lifecycle::Serving {
        stop,
        listener,
        authority,
    } = match windows_lifecycle::start(None, None, &crate::host::utc_now(), &|name| {
        std::env::var_os(name)
    })? {
        windows_lifecycle::Start::Serve(serving) => serving,
        windows_lifecycle::Start::AlreadyRunning(instance) => {
            return Err(format!("another daemon owns the root: {}", instance.running()).into());
        }
    };
    let authority = authority
        .ok_or("the account's root composes an authority")?
        .with_tuples(tuples);
    let (host, arkforge, managed) = authority.compose(Host::from_environment())?;
    let managed = managed.ok_or("the account daemon composed no managed HDC server")?;
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
    if let Some(stopped) = managed.stop() {
        for line in stopped.report(true) {
            eprintln!("arkdeck-agentd: {line}");
        }
    }
    if drain.complete {
        authority.release();
    }
    println!("arkdeck-agentd stopped");
    let _ = std::io::Write::flush(&mut std::io::stdout());
    Ok(())
}

/// A fresh directory below `TEMP`, in its plain canonical spelling.
fn temporary(prefix: &str) -> PathBuf {
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

/// The stand-in compiled into `directory`, its bytes made its own by
/// `variant`.
fn stand_in(directory: &Path, variant: &str) -> Vec<u8> {
    std::fs::create_dir_all(directory).unwrap();
    std::fs::write(
        directory.join("hdc.rs"),
        format!(
            "{STAND_IN}\n#[used]\nstatic VARIANT: [u8; {}] = *b\"{variant}\";\n",
            variant.len()
        ),
    )
    .unwrap();
    let rustc = std::env::var_os("RUSTC").unwrap_or_else(|| "rustc".into());
    let output = Command::new(rustc)
        .arg("--edition=2021")
        .arg("-o")
        .arg(directory.join("hdc.exe"))
        .arg(directory.join("hdc.rs"))
        .output()
        .unwrap();
    assert!(output.status.success(), "{output:?}");
    std::fs::read(directory.join("hdc.exe")).unwrap()
}

/// The signed account daemon, its stdout read line by line.
struct AccountDaemon {
    executable: PathBuf,
    pin: String,
    profile: PathBuf,
    pipe: String,
    child: Option<Child>,
    lines: Receiver<String>,
    seen: Vec<String>,
}

impl AccountDaemon {
    fn start(executable: &Path, pin: &str, profile: &Path, variables: &[(&str, String)]) -> Self {
        let mut command = Command::new(executable);
        for (key, _) in std::env::vars_os() {
            let upper = key.to_string_lossy().to_ascii_uppercase();
            if upper.starts_with("ARKDECK_") || upper.starts_with("OHOS_HDC_") {
                command.env_remove(key);
            }
        }
        let stderr = std::fs::File::create(
            profile
                .parent()
                .unwrap()
                .join(format!("account-daemon-stderr-{}.log", std::process::id())),
        )
        .unwrap();
        let mut child = command
            .args(["--exact", CHILD, "--nocapture", "--test-threads=1"])
            .env("USERPROFILE", profile)
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
            profile: profile.to_owned(),
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

    fn line_starting(&mut self, prefix: &str) -> String {
        let deadline = Instant::now() + DEADLINE;
        loop {
            let left = deadline.saturating_duration_since(Instant::now());
            match self.lines.recv_timeout(left) {
                Ok(line) if line.starts_with(prefix) => return line,
                Ok(line) => self.seen.push(line),
                Err(_) => panic!(
                    "the signed account daemon never printed {prefix:?}; it printed {:?} (its \
                     stderr is beside the fake profile)",
                    self.seen
                ),
            }
        }
    }

    /// The real CLI beside the daemon, verifying it and its signer pin as it
    /// verifies an installed daemon: its exit status and its JSON envelope.
    fn cli(&self, arguments: &[&str]) -> (Option<i32>, Value) {
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
            .env("USERPROFILE", &self.profile)
            .env("ARKDECK_ENDPOINT", &self.pipe)
            .env("ARKDECK_DAEMON_PATH", &self.executable)
            .env("ARKDECK_DAEMON_SIGNER_SHA256", &self.pin)
            .stdin(Stdio::null())
            .output()
            .unwrap_or_else(|error| {
                panic!(
                    "the arkdeck CLI beside the daemon ({}): {error}; run the workspace tests, \
                     or `cargo build -p arkdeck-cli` before testing this crate alone",
                    cli.display()
                )
            });
        let envelope = serde_json::from_slice(&output.stdout)
            .unwrap_or_else(|_| panic!("{arguments:?}: {output:?}"));
        (output.status.code(), envelope)
    }

    /// Asks it to stop through the account's scope and waits for its drained
    /// end.
    fn stop(mut self) {
        InstanceScope::account()
            .unwrap()
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
                "the signed account daemon did not end"
            );
            std::thread::sleep(Duration::from_millis(50));
        };
        assert!(status.success(), "{status:?}");
    }
}

impl Drop for AccountDaemon {
    fn drop(&mut self) {
        if let Some(mut child) = self.child.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}

#[test]
fn the_account_daemon_composes_its_selected_hdc_beside_the_tool_selection_owner() {
    let _turn = crate::turn();
    let _starters = StarterLock::acquire(&InstanceScope::account().unwrap(), DEADLINE * 5)
        .unwrap()
        .expect("another process held the account's daemon starters' turn");
    let scratch = temporary("account-tool-select");
    let Some((executable, pin)) = signed_copy(&scratch.join("signed-bin")) else {
        return;
    };
    let profile = scratch.join("profile");
    std::fs::create_dir_all(profile.join("AppData").join("Local")).unwrap();
    let bytes = stand_in(&scratch.join("stand-in"), "a");
    // The configured file in a private directory of the fake account, as an
    // installed DevEco keeps its `hdc.exe`.
    let sdk = profile.join("sdk");
    arkdeck_platform::create_private_directory(&sdk).unwrap();
    let hdc = sdk.join("hdc.exe");
    std::io::Write::write_all(
        &mut arkdeck_platform::create_private_file(&hdc).unwrap(),
        &bytes,
    )
    .unwrap();
    let sha256 = arkdeck_contract::sha256_hex(&bytes);
    // A second registered tool: another stand-in, its own digest in the
    // fixture tuple table, kept in the same private directory.
    let other_bytes = stand_in(&scratch.join("stand-in-b"), "b");
    let other = sdk.join("hdc-b.exe");
    std::io::Write::write_all(
        &mut arkdeck_platform::create_private_file(&other).unwrap(),
        &other_bytes,
    )
    .unwrap();
    let other_sha256 = arkdeck_contract::sha256_hex(&other_bytes);
    assert_ne!(other_sha256, sha256);
    let port = loopback_ports::free_port();
    let daemon = AccountDaemon::start(
        &executable,
        &pin,
        &profile,
        &[
            (TUPLE, format!("{sha256},{other_sha256}")),
            ("ARKDECK_HDC_PATH", hdc.display().to_string()),
            (arkdeck_provider_hdc::SERVER_PORT_VARIABLE, port.to_string()),
        ],
    );
    assert!(
        daemon.seen.iter().any(|line| line
            .starts_with("arkdeck-agentd composes the selected registered Windows HDC stand-in")),
        "{:?}",
        daemon.seen
    );
    let census = daemon
        .seen
        .iter()
        .find(|line| line.starts_with("arkdeck-agentd owners: "))
        .cloned()
        .unwrap_or_default();
    assert!(census.contains("managedHdc"), "{census}");

    // The registered tool is the account's selection.
    let (status, listed) = daemon.cli(&["runtime", "tool", "list"]);
    assert_eq!(status, Some(0), "{listed}");
    let rows = listed["result"]["items"]
        .as_array()
        .or_else(|| listed["result"]["tools"].as_array())
        .unwrap_or_else(|| panic!("{listed}"));
    let selected: Vec<&Value> = rows.iter().filter(|row| row["selected"] == true).collect();
    assert_eq!(selected.len(), 1, "{listed}");
    assert_eq!(selected[0]["executableSHA256"], sha256.as_str());
    assert_eq!(selected[0]["platform"], "windows");
    let tool = selected[0]["toolRef"].as_str().unwrap().to_owned();

    // The tool-selection owner answers with its typed drifted action, in
    // the published result contract's shape, and nothing is dispatched.
    let (status, selection) = daemon.cli(&[
        "runtime",
        "tool",
        "select",
        "--tool",
        &tool,
        "--expected-active-generation",
        "1",
        "--action-request-id",
        "request-account-tool-select",
    ]);
    assert_eq!(status, Some(0), "{selection}");
    assert_eq!(selection["ok"], true, "{selection}");
    let action = &selection["result"];
    assert_eq!(action["kind"], "runtimeToolSelection", "{selection}");
    assert_eq!(action["state"], "previewDrifted", "{selection}");
    assert_eq!(
        action["blockerReasonCode"], "tool.selectionFactsUnavailable",
        "{selection}"
    );
    assert_eq!(action["dispatchCount"], 0, "{selection}");
    // Nothing was selected: the account's selection is unchanged.
    let (status, again) = daemon.cli(&["runtime", "tool", "list"]);
    assert_eq!(status, Some(0), "{again}");
    assert_eq!(again["result"]["items"], listed["result"]["items"]);

    // `runtime tool register --kind hdc` of a second executable a tuple
    // names: retained and registered beside the selection, answered in the
    // shape the macOS Runtime answers (`ControlFrames/
    // runtime.tool.register.jsonl`), never selected or run.
    let register = [
        "runtime",
        "tool",
        "register",
        "--kind",
        "hdc",
        "--file",
        other.to_str().unwrap(),
    ];
    let (status, registered) = daemon.cli(&register);
    assert_eq!(status, Some(0), "{registered}");
    assert_eq!(
        registered["command"], "runtime.tool.register",
        "{registered}"
    );
    let tool_row = &registered["result"];
    let macos: Value = include_str!(
        "../../../../../Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames/runtime.tool.register.jsonl"
    )
    .lines()
    .map(|line| serde_json::from_str::<Value>(line).unwrap())
    .find(|frame| frame["ok"] == true && frame["result"]["kind"] == "hdc")
    .expect("the macOS Runtime's HDC registration")["result"]
        .clone();
    let keys =
        |value: &Value| -> Vec<String> { value.as_object().unwrap().keys().cloned().collect() };
    assert_eq!(keys(tool_row), keys(&macos), "{registered}");
    assert_eq!(
        keys(&tool_row["trust"]),
        keys(&macos["trust"]),
        "{registered}"
    );
    for (key, value) in [
        ("kind", "hdc"),
        ("platform", "windows"),
        ("state", "available"),
        ("generation", "1"),
        ("source", "registeredCopy"),
        ("executableSHA256", other_sha256.as_str()),
    ] {
        assert_eq!(tool_row[key], value, "{key}: {registered}");
    }
    assert_eq!(tool_row["selected"], false, "{registered}");
    assert_eq!(tool_row["contentRetained"], true, "{registered}");
    assert_eq!(
        tool_row["trust"]["registeredIdentity"], true,
        "{registered}"
    );
    assert_eq!(tool_row["trust"]["toolVersion"], "3.2.0d", "{registered}");
    let other_ref = tool_row["toolRef"].as_str().unwrap().to_owned();
    assert!(other_ref.starts_with("tool:sha256:"), "{registered}");
    // Registered again: the same row.
    let (status, again) = daemon.cli(&register);
    assert_eq!(status, Some(0), "{again}");
    assert_eq!(again["result"], *tool_row, "{again}");
    // Listed beside the selection, which is unchanged.
    let (status, both) = daemon.cli(&["runtime", "tool", "list"]);
    assert_eq!(status, Some(0), "{both}");
    let rows = both["result"]["items"].as_array().unwrap();
    assert_eq!(rows.len(), 2, "{both}");
    assert!(
        rows.iter()
            .any(|row| row["toolRef"] == other_ref.as_str() && row["selected"] == false),
        "{both}"
    );
    assert!(
        rows.iter()
            .any(|row| row["toolRef"] == tool.as_str() && row["selected"] == true),
        "{both}"
    );
    // An hdc.exe no tuple names is refused, and nothing is retained.
    let untupled_bytes = stand_in(&scratch.join("stand-in-c"), "c");
    let untupled = sdk.join("hdc-c.exe");
    std::io::Write::write_all(
        &mut arkdeck_platform::create_private_file(&untupled).unwrap(),
        &untupled_bytes,
    )
    .unwrap();
    let (status, refused) = daemon.cli(&[
        "runtime",
        "tool",
        "register",
        "--kind",
        "hdc",
        "--file",
        untupled.to_str().unwrap(),
    ]);
    assert_ne!(status, Some(0), "{refused}");
    assert_eq!(refused["error"]["code"], "admissionDenied", "{refused}");
    let (_, after) = daemon.cli(&["runtime", "tool", "list"]);
    assert_eq!(after["result"]["items"], both["result"]["items"], "{after}");

    // Selecting the registered candidate still drifts: the selection's
    // impact reads the managed server's health through the HDC lifecycle
    // owner, which no Windows composition proves healthy yet (#2501), so
    // `runtime tool select` is not counted. Nothing is dispatched.
    let (status, selection) = daemon.cli(&[
        "runtime",
        "tool",
        "select",
        "--tool",
        &other_ref,
        "--expected-active-generation",
        "1",
        "--action-request-id",
        "request-account-tool-select-b",
    ]);
    assert_eq!(status, Some(0), "{selection}");
    assert_eq!(
        selection["result"]["state"], "previewDrifted",
        "{selection}"
    );
    assert_eq!(
        selection["result"]["blockerReasonCode"], "tool.selectionFactsUnavailable",
        "{selection}"
    );
    assert_eq!(selection["result"]["dispatchCount"], 0, "{selection}");
    daemon.stop();
    let _ = std::fs::remove_dir_all(&scratch);
    let product = arkdeck_cli::machine_contracts::contract_products()
        .into_iter()
        .find(|product| product.relative_path == "cli-feature-coverage.json")
        .expect("the CLI renders its feature coverage");
    let coverage: Value = serde_json::from_slice(&product.bytes).unwrap();
    let windows = |feature: &str| -> Value {
        coverage["entries"]
            .as_array()
            .unwrap()
            .iter()
            .find(|entry| entry["feature"] == feature)
            .unwrap_or_else(|| panic!("{feature}"))["implementationStatusByPlatform"]["windows"]
            .clone()
    };
    assert_eq!(windows("runtime.tool.register"), "implemented");
    assert_eq!(windows("runtime.tool.select"), "partial");
}
