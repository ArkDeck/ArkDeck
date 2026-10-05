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
//! it admits that stand-in's digest through a fixture tuple
//! (`Authority::with_tuples`, compiled into test builds alone). It composes
//! the registered HDC from the Bootstrap
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
//! gives (#2501). A second test uses the existing owner-test impact port to
//! supply fixture health while preserving real kernel process identity,
//! managed lifecycle dispatch, durable audit and startup settlement. The
//! signed CLI selects the second tool and reads the settled generation after
//! restart. The production tuple table and health families stay unchanged.
//! Every account daemon starter is held off
//! for the whole run (`StarterLock`), as the account-location tests hold
//! them. Nothing installed, no `hdc` and no device is involved.
use crate::host::Host;
use crate::signed_daemon::signed_copy;
use crate::windows_lifecycle;
use arkdeck_contract::{CONTRACT_IDENTITY, PROTOCOL_VERSION};
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
const HEALTH: &str = "ARKDECK_TEST_ACCOUNT_DAEMON_HEALTH";
const APPROVE: &str = "ARKDECK_TEST_ACCOUNT_DAEMON_APPROVE";
const CHILD: &str = "account_tool_selection::the_signed_account_daemon";
const DRAIN_DEADLINE: Duration = Duration::from_secs(20);
const CONNECTION_IDLE: Duration = Duration::from_secs(20);
const DEADLINE: Duration = Duration::from_secs(120);

/// A stand-in HDC compiled at test time: `-s <endpoint> -m` listens on the
/// endpoint until it is ended; `-s <endpoint> checkserver` answers agreeing
/// versions; `kill -r` replaces only its own token-protected listener;
/// `list targets -v` answers the registered UART-only listing;
/// anything else is unregistered (status 64). No real HDC runs.
const STAND_IN: &str = r#"
fn main() {
    use std::io::{Read, Write};
    let arguments: Vec<String> = std::env::args().collect();
    let mut calls = std::fs::OpenOptions::new().create(true).append(true).open(CALLS).unwrap();
    writeln!(calls, "{}", arguments[1..].join(" ")).unwrap();
    if arguments[1..] == ["list", "targets", "-v"] {
        print!("COM1\t\tUART\tReady\tunknown...\thdc\r\n");
        return;
    }
    match arguments.get(3).map(String::as_str) {
        Some("-m") => {
            let listener = std::net::TcpListener::bind(&arguments[2]).unwrap();
            for connection in listener.incoming() {
                if let Ok(mut connection) = connection {
                    connection.set_read_timeout(Some(std::time::Duration::from_millis(100))).unwrap();
                    let mut token = vec![0; SHUTDOWN_TOKEN.len()];
                    if connection.read_exact(&mut token).is_ok() && token == SHUTDOWN_TOKEN.as_bytes() {
                        return;
                    }
                }
            }
        }
        Some("checkserver") => {
            println!("Client version:Ver: 3.2.0d, server version:Ver: 3.2.0d");
        }
        Some("kill") if arguments.get(4).map(String::as_str) == Some("-r") => {
            // Only this fixture's own listener accepts its private token.
            std::net::TcpStream::connect(&arguments[2]).unwrap()
                .write_all(SHUTDOWN_TOKEN.as_bytes()).unwrap();
            let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
            while std::net::TcpStream::connect(&arguments[2]).is_ok() {
                assert!(std::time::Instant::now() < deadline);
                std::thread::sleep(std::time::Duration::from_millis(10));
            }
            std::process::Command::new(std::env::current_exe().unwrap())
                .args(["-s", &arguments[2], "-m"])
                .stdin(std::process::Stdio::null())
                .stdout(std::process::Stdio::null())
                .stderr(std::process::Stdio::null())
                .spawn().unwrap();
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
    let (mut host, arkforge, managed) = authority.compose(Host::from_environment())?;
    let managed = managed.ok_or("the account daemon composed no managed HDC server")?;
    if std::env::var_os(HEALTH).is_some() {
        host.test_hdc_impact = Some(Box::new(FixtureHealth(Arc::clone(managed.server()))));
    }
    let control = Arc::new(Control::new(host)?);
    let approval_cancelled = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let approval = std::env::var_os(APPROVE).map(|path| {
        let control = Arc::clone(&control);
        let cancelled = Arc::clone(&approval_cancelled);
        std::thread::spawn(move || approve_fixture_action(&control, Path::new(&path), &cancelled))
    });
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
    // A failure before the parent requests approval must still drain this
    // fixture's managed server; an approval already in progress completes.
    approval_cancelled.store(true, std::sync::atomic::Ordering::Release);
    if let Some(approval) = approval {
        approval.join().expect("the fixture approval completed");
    }
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

/// Only this signed test binary supplies fixture health. The executable,
/// listener, process birth and supervisor generation must still match the
/// managed child; production's registered HDC families are never changed.
struct FixtureHealth(Arc<crate::managed_hdc::ManagedHdc>);
impl arkdeck_hoststore::ImpactSource for FixtureHealth {
    fn endpoint_reference(&self) -> String {
        arkdeck_provider_hdc::server_endpoint_ref(self.0.endpoint())
    }

    fn read_impact(&self) -> Result<arkdeck_hoststore::ImpactReading, String> {
        use arkdeck_provider_hdc::{ManagedProcessVerifier, SupervisorState};
        let executable = self.0.executable();
        let tool = arkdeck_platform::VerifiedTool::open(&executable.path, &executable.sha256)
            .map_err(|error| error.to_string())?;
        let endpoint = self
            .0
            .endpoint()
            .parse()
            .map_err(|error: std::net::AddrParseError| error.to_string())?;
        let identity = arkdeck_platform::LoopbackServerLease::acquire(&tool, endpoint)
            .map_err(|error| error.to_string())?;
        let launch = self
            .0
            .active_launch()
            .ok_or("fixture launch is unavailable")?;
        let state = self
            .0
            .state(self.0.endpoint())
            .ok_or("fixture supervisor is unavailable")?;
        if !launch.matches(identity.identity())
            || !self
                .0
                .process_verifier()
                .verifies(identity.identity(), &launch.arguments)
            || !state.healthy
            || !state.ark_deck_managed
            || arkdeck_provider_hdc::generation(identity.identity())
                != u64::try_from(state.generation).ok()
        {
            return Err("fixture managed identity drifted".into());
        }
        identity.revalidate().map_err(|error| error.to_string())?;
        let impact = serde_json::json!({
            "serverEndpointRef":self.endpoint_reference(),"endpoint":self.0.endpoint(),
            "serverOwnership":"arkDeckManaged","serverGeneration":state.generation.to_string(),
            "serverHealth":"healthy","serverVersion":"3.2.0d",
            "tool":{"reference":null,"executablePath":executable.path,"source":"runtimeConfiguration",
                "sha256":executable.sha256,"signature":null,"version":"3.2.0d","trust":"unverified"},
            "affectedTargetIds":[],"affectedJobIds":[],"detectedOtherClientIds":[],
            "otherClientsMayExist":true,"affectedDeviceObservations":[],
            "criticalJobGate":{"state":"clear","blocking":[],"reasonCode":null},
            "interruption":{"kind":"hdcEndpointUnavailable","affectsAllParticipants":true},
            "recovery":{"kind":"statusThenReconcile","replayAllowed":false}
        });
        Ok(arkdeck_hoststore::ImpactReading {
            impact: arkdeck_hoststore::Impact::new(impact.as_object().unwrap().clone())
                .map_err(|error| error.message)?,
            relations: vec![],
            blocker: None,
        })
    }
}

/// The owner-test's foreground-console approval, available only in this
/// fixture child. The real CLI has already obtained the immutable action.
fn approve_fixture_action(
    control: &Control<Host>,
    path: &Path,
    cancelled: &std::sync::atomic::AtomicBool,
) {
    let deadline = Instant::now() + DEADLINE;
    let params = loop {
        match std::fs::read(path) {
            Ok(bytes) => break serde_json::from_slice::<Value>(&bytes).unwrap(),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                if cancelled.load(std::sync::atomic::Ordering::Acquire) {
                    return;
                }
                assert!(
                    Instant::now() < deadline,
                    "fixture approval was not requested"
                );
                std::thread::sleep(Duration::from_millis(10));
            }
            Err(error) => panic!("fixture approval request: {error}"),
        }
    };
    let send = |params: &Value| -> Value {
        let frame = serde_json::to_vec(&serde_json::json!({
            "protocolVersion":PROTOCOL_VERSION,"contractIdentity":CONTRACT_IDENTITY,
            "id":"fixture-selection-approval","method":"human-action.resume","params":params
        }))
        .unwrap();
        serde_json::from_slice(
            control
                .handle_frame_with_console(&frame, true)
                .trim_ascii_end(),
        )
        .unwrap()
    };
    let challenge = send(&params);
    if challenge["ok"] != true {
        println!("arkdeck-fixture selection approval {challenge}");
        let _ = std::io::Write::flush(&mut std::io::stdout());
        return;
    }
    // The generator's added alternative stays closed, and the real CLI's
    // console reviewer verifies the immutable selection preview and digest.
    let mut unknown_field = challenge["result"].clone();
    unknown_field["controlAction"]["preview"]["unregisteredFact"] = Value::Bool(true);
    assert!(
        arkdeck_contract::validate_method_value("human-action.resume", "result", &unknown_field)
            .is_err()
    );
    let input = format!("{}\n", challenge["result"]["challenge"].as_str().unwrap());
    let response = arkdeck_cli::read_console_challenge(
        &challenge["result"],
        true,
        &mut std::io::Cursor::new(input),
        &mut Vec::new(),
    )
    .unwrap();
    let mut approved = params;
    approved["challengeResponse"] = Value::String(response);
    let result = send(&approved);
    println!("arkdeck-fixture selection approval {result}");
    let _ = std::io::Write::flush(&mut std::io::stdout());
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
            "{STAND_IN}\n#[used]\nstatic VARIANT: [u8; {}] = *b\"{variant}\";\nstatic SHUTDOWN_TOKEN: &str = {:?};\nstatic CALLS: &str = {:?};\n",
            variant.len(), directory.parent().unwrap().display().to_string(),
            directory.parent().unwrap().join("stand-in-calls").display().to_string()
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

/// The selected path, with test-only registered identity/health facts and
/// the production Bootstrap, tool-selection and managed lifecycle owners.
/// Every observable select/list request is made by the real CLI, which still
/// verifies the signed daemon's Authenticode identity and signer pin.
#[test]
fn the_signed_cli_selects_a_candidate_and_reads_the_settled_selection_after_restart() {
    let _turn = crate::turn();
    let _starters = StarterLock::acquire(&InstanceScope::account().unwrap(), DEADLINE * 5)
        .unwrap()
        .expect("another process held the account's daemon starters' turn");
    let scratch = temporary("ArkDeck-fixture-tool-select");
    let Some((executable, pin)) = signed_copy(&scratch.join("signed-bin")) else {
        return;
    };
    let profile = scratch.join("profile");
    std::fs::create_dir_all(profile.join("AppData").join("Local")).unwrap();
    let sdk = profile.join("sdk");
    arkdeck_platform::create_private_directory(&sdk).unwrap();
    let paths = [sdk.join("hdc.exe"), sdk.join("hdc-b.exe")];
    let hashes: Vec<String> = ["a", "b"]
        .into_iter()
        .enumerate()
        .map(|(index, variant)| {
            let bytes = stand_in(&scratch.join(format!("stand-in-{variant}")), variant);
            std::io::Write::write_all(
                &mut arkdeck_platform::create_private_file(&paths[index]).unwrap(),
                &bytes,
            )
            .unwrap();
            arkdeck_contract::sha256_hex(&bytes)
        })
        .collect();
    assert_ne!(hashes[0], hashes[1]);
    let port = loopback_ports::free_port();
    let approve = profile.join("approve-fixture-action.json");
    let variables = [
        (TUPLE, hashes.join(",")),
        (HEALTH, "fixture".into()),
        (arkdeck_provider_hdc::SERVER_PORT_VARIABLE, port.to_string()),
    ];
    let mut startup = variables.to_vec();
    startup.push(("ARKDECK_HDC_PATH", paths[0].display().to_string()));
    startup.push((APPROVE, approve.display().to_string()));
    let mut daemon = AccountDaemon::start(&executable, &pin, &profile, &startup);
    let (status, registered) = daemon.cli(&[
        "runtime",
        "tool",
        "register",
        "--kind",
        "hdc",
        "--file",
        paths[1].to_str().unwrap(),
    ]);
    assert_eq!(status, Some(0), "{registered}");
    let candidate = registered["result"]["toolRef"].as_str().unwrap().to_owned();
    let select = [
        "runtime",
        "tool",
        "select",
        "--tool",
        &candidate,
        "--expected-active-generation",
        "1",
        "--action-request-id",
        "fixture-selected-path",
    ];
    let (status, waiting) = daemon.cli(&select);
    assert_eq!(status, Some(0), "{waiting}");
    assert_eq!(
        waiting["result"]["state"], "awaitingImpactApproval",
        "{waiting}"
    );
    assert_eq!(waiting["result"]["dispatchCount"], 0, "{waiting}");
    assert_eq!(
        waiting["result"]["preview"]["newTool"]["toolRef"], candidate,
        "{waiting}"
    );
    assert_eq!(
        waiting["result"]["preview"]["serverHealth"], "healthy",
        "{waiting}"
    );
    // Dedupe before approval preserves the immutable preview and dispatches nothing.
    let (status, repeated) = daemon.cli(&select);
    assert_eq!(status, Some(0), "{repeated}");
    assert_eq!(repeated["result"], waiting["result"], "{repeated}");
    let approval = serde_json::json!({
        "humanAction":waiting["result"]["humanAction"]["actionId"],
        "resumeReference":waiting["result"]["humanAction"]["resumeReference"]
    });
    std::io::Write::write_all(
        &mut arkdeck_platform::create_private_file(&approve).unwrap(),
        &serde_json::to_vec(&approval).unwrap(),
    )
    .unwrap();
    let response = daemon.line_starting("arkdeck-fixture selection approval ");
    let approved: Value =
        serde_json::from_str(response.trim_start_matches("arkdeck-fixture selection approval "))
            .unwrap();
    assert_eq!(approved["ok"], true, "{approved}");
    assert_eq!(approved["result"]["state"], "outcomeUnknown", "{approved}");
    assert_eq!(approved["result"]["dispatchCount"], 1, "{approved}");
    // The old provider graph drains. Startup publishes the exact pending
    // selection after a new managed launch; a status read settles its durable
    // action from that registry outcome. The selection intent is not replayed.
    daemon.wait_stopped();
    let mut restart = variables.to_vec();
    // Composition is opt-in; an absent configured file proves startup uses
    // the durable selection rather than adopting the configured executable.
    restart.push((
        "ARKDECK_HDC_PATH",
        profile.join("absent-hdc.exe").display().to_string(),
    ));
    let daemon = AccountDaemon::start(&executable, &pin, &profile, &restart);
    let (status, settled) = daemon.cli(&[
        "control-action",
        "show",
        "--control-action",
        waiting["result"]["controlActionId"].as_str().unwrap(),
    ]);
    assert_eq!(status, Some(0), "{settled}");
    assert_eq!(settled["result"]["state"], "succeeded", "{settled}");
    let (status, selected) = daemon.cli(&select);
    assert_eq!(status, Some(0), "{selected}");
    assert_eq!(selected["result"]["state"], "succeeded", "{selected}");
    assert_eq!(selected["result"]["dispatchCount"], 1, "{selected}");
    assert_eq!(
        selected["result"]["controlActionId"], waiting["result"]["controlActionId"],
        "{selected}"
    );
    let (status, reconciled) = daemon.cli(&[
        "control-action",
        "reconcile",
        "--control-action",
        selected["result"]["controlActionId"].as_str().unwrap(),
    ]);
    assert_eq!(status, Some(0), "{reconciled}");
    assert_eq!(reconciled["result"], selected["result"], "{reconciled}");
    let (status, actions) = daemon.cli(&["control-action", "list"]);
    assert_eq!(status, Some(0), "{actions}");
    assert_eq!(
        actions["result"]["items"],
        serde_json::json!([selected["result"]]),
        "{actions}"
    );
    let (status, listed) = daemon.cli(&["runtime", "tool", "list"]);
    assert_eq!(status, Some(0), "{listed}");
    let rows = listed["result"]["items"].as_array().unwrap();
    let active: Vec<&Value> = rows.iter().filter(|row| row["selected"] == true).collect();
    assert_eq!(active.len(), 1, "{listed}");
    assert_eq!(active[0]["toolRef"], candidate, "{listed}");
    assert_eq!(active[0]["executableSHA256"], hashes[1], "{listed}");
    assert_eq!(active[0]["activeSelectionGeneration"], "2", "{listed}");
    let (status, repeated) = daemon.cli(&select);
    assert_eq!(status, Some(0), "{repeated}");
    assert_eq!(repeated["result"], selected["result"], "{repeated}");
    daemon.stop();
    let calls = std::fs::read_to_string(scratch.join("stand-in-calls")).unwrap();
    assert_eq!(
        calls
            .lines()
            .filter(|line| line.ends_with("kill -r"))
            .count(),
        1,
        "{calls}"
    );
    assert!(
        calls
            .lines()
            .all(|line| line.starts_with("-s ") || line == "list targets -v"),
        "{calls}"
    );
    let _ = std::fs::remove_dir_all(&scratch);
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
    fn stop(self) {
        InstanceScope::account()
            .unwrap()
            .request_stop(self.child.as_ref().unwrap().id())
            .unwrap();
        self.wait_stopped();
    }

    fn wait_stopped(mut self) {
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
            // A failed assertion must still drain this fixture's managed HDC.
            if InstanceScope::account().is_ok_and(|scope| scope.request_stop(child.id()).is_ok()) {
                let deadline = Instant::now() + DRAIN_DEADLINE;
                while Instant::now() < deadline {
                    if child.try_wait().is_ok_and(|status| status.is_some()) {
                        return;
                    }
                    std::thread::sleep(Duration::from_millis(10));
                }
            }
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
    // owner; this stand-in has no published health proof without the
    // test-only health port. Nothing is dispatched.
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
    assert_eq!(windows("runtime.tool.select"), "implemented");
}
