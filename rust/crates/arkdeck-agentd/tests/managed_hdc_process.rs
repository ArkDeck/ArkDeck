//! The isolated daemon with its managed HDC server (TASK-XPA-016 R2), over
//! its socket: `ARKDECK_DEVELOPMENT_HDC_SERVER=managed` starts the
//! development HDC as `hdc -s <endpoint> -m` before the daemon serves,
//! `runtime.hdc.status` and `target.availability` answer from it, and SIGTERM
//! drains the daemon, stops the server and ends the daemon with status 0,
//! leaving nothing on the endpoint. A daemon that ends without its stop
//! (SIGKILL, or exit 70 after another client's `kill -r`) leaves a server
//! the next start did not launch: every start refuses it before launching
//! anything, neither adopting nor stopping it, until it ends (TASK-XPA-014).
//! Host-only: the HDC is a fake compiled here from C (a shell script cannot
//! own a TCP listener); the Target is the adoption fixture's, copied. No real
//! HDC, device, installed state or Swift daemon is used. Spawning children,
//! these tests keep a binary of their own.
#![cfg(target_os = "macos")]
use arkdeck_contract::{CONTRACT_IDENTITY, PROTOCOL_VERSION, sha256_hex, validate_method_value};
use serde_json::{Value, json};
use std::fs;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{Ipv4Addr, SocketAddr, SocketAddrV4, TcpStream};
use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Output, Stdio};
use std::sync::{Mutex, MutexGuard, PoisonError};
use std::time::{Duration, Instant};

/// One test at a time. Each takes loopback ports in this process, for its
/// daemon's managed server (`free_port`) or to listen on (`issued_listener`),
/// while another test spawns compilers, daemons and fake `hdc`s: a child
/// spawned while this process is still making a socket keeps it, bound and
/// listening once it is, for the child's whole life, so a port released here
/// could still be held.
static TURN: Mutex<()> = Mutex::new(());
fn turn() -> MutexGuard<'static, ()> {
    TURN.lock().unwrap_or_else(PoisonError::into_inner)
}

const FAKE_HDC: &str = include_str!("../../../tests/fixtures/managed-hdc/fake-hdc.c");
const TARGET: &str = "TGT-3ba3f5f43b92";

mod loopback_ports {
    include!("../../../tests/support/loopback_ports.rs");
}
use loopback_ports::{free_port, issued_listener};
mod fake_hdc_servers {
    include!("../../../tests/support/fake_hdc_servers.rs");
}

fn reachable(port: u16) -> bool {
    TcpStream::connect_timeout(
        &SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::LOCALHOST, port)),
        Duration::from_millis(100),
    )
    .is_ok()
}

fn fixture(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/fixtures")
        .join(name)
}

struct Runtime {
    root: PathBuf,
    port: u16,
    child: Option<Child>,
}

impl Runtime {
    fn new() -> Self {
        let root = PathBuf::from(format!(
            "/private/tmp/arkdeck-managed-hdc-process-{:032x}",
            u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap())
        ));
        for directory in [
            root.clone(),
            root.join("state"),
            root.join("state/targets-state"),
            root.join("tools"),
        ] {
            fs::DirBuilder::new()
                .mode(0o700)
                .create(&directory)
                .unwrap();
        }
        let targets = root.join("state/targets-state/targets.json");
        fs::copy(
            fixture("target-adoption/targets-state/targets.json"),
            &targets,
        )
        .unwrap();
        fs::set_permissions(&targets, fs::Permissions::from_mode(0o600)).unwrap();
        let source = root.join("tools/fake-hdc.c");
        fs::write(&source, FAKE_HDC).unwrap();
        // Every invocation is recorded in `tools/calls`; `kill` stops a
        // server of this build through the `tools/stop` marker and `kill -r`
        // then starts one in a session of its own, recorded in
        // `tools/servers`; a server of this build ends once this test
        // process is gone.
        let tools = root.join("tools");
        let output = Command::new("cc")
            .arg("-O0")
            .arg(format!("-DRESTART_DIR=\"{}\"", tools.display()))
            .arg(format!("-DSELF_PATH=\"{}\"", tools.join("hdc").display()))
            .arg(format!(
                "-DRECORD_CALLS=\"{}\"",
                tools.join("calls").display()
            ))
            .arg(format!("-DOWNER_PID={}", std::process::id()))
            .arg("-o")
            .arg(root.join("tools/hdc"))
            .arg(&source)
            .output()
            .expect("cc from the developer tools compiles the fake");
        assert!(
            output.status.success(),
            "fake hdc did not compile: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        fs::set_permissions(root.join("tools/hdc"), fs::Permissions::from_mode(0o700)).unwrap();
        Self {
            root,
            port: free_port(),
            child: None,
        }
    }

    fn hdc(&self) -> PathBuf {
        self.root.join("tools/hdc")
    }

    /// The fake, verified as the daemon verifies its development HDC.
    fn tool(&self) -> arkdeck_platform::VerifiedTool {
        arkdeck_platform::VerifiedTool::open(
            self.hdc(),
            &sha256_hex(&fs::read(self.hdc()).unwrap()),
        )
        .unwrap()
    }

    fn endpoint(&self) -> SocketAddrV4 {
        SocketAddrV4::new(Ipv4Addr::LOCALHOST, self.port)
    }

    /// The fake run as any other client of the endpoint would run `hdc`:
    /// `kill` ends the server there and waits for the endpoint to free,
    /// `kill -r` then starts a server in a session of its own.
    fn hdc_client(&self, arguments: &[&str]) -> std::process::ExitStatus {
        Command::new(self.hdc())
            .arg("-s")
            .arg(self.endpoint().to_string())
            .args(arguments)
            .env("OHOS_HDC_SERVER_PORT", self.port.to_string())
            .status()
            .unwrap()
    }

    /// An operator's `hdc -s <endpoint> kill`: whatever server of this build
    /// listens there ends, and the marker that ended it is cleared so that
    /// the next server of this build runs.
    fn operator_kill(&self) {
        assert!(self.hdc_client(&["kill"]).success());
        fs::remove_file(self.root.join("tools/stop")).unwrap();
        assert!(!reachable(self.port), "the server did not end");
    }

    /// How many `-m` servers of this fake ever ran: those a daemon launched
    /// and those a `kill -r` started.
    fn launches(&self) -> usize {
        fs::read_to_string(self.root.join("tools/calls"))
            .unwrap_or_default()
            .lines()
            .filter(|line| line.ends_with(" -m"))
            .count()
    }

    /// Every run of this fake, whatever it ran as: a server, a readiness
    /// `checkserver`, a client.
    fn runs(&self) -> Vec<String> {
        fs::read_to_string(self.root.join("tools/calls"))
            .unwrap_or_default()
            .lines()
            .map(str::to_owned)
            .collect()
    }

    /// A start the daemon refuses on its environment: refused before
    /// anything is launched, so this fake never ran — no server, not even a
    /// readiness probe — and nothing of it is left running.
    fn refused_before_any_launch(&self, environment: &[(&str, &str)]) -> Output {
        let output = self.refused(environment);
        assert_eq!(
            self.runs(),
            Vec::<String>::new(),
            "{environment:?}: the HDC ran before the start was refused"
        );
        assert!(
            !self.fake_running(),
            "{environment:?}: no managed server was started"
        );
        output
    }

    /// The servers a `kill -r` of this fake started, by PID.
    fn recorded_servers(&self) -> Vec<i32> {
        fs::read_to_string(self.root.join("tools/servers"))
            .unwrap_or_default()
            .lines()
            .map(|line| line.parse().unwrap())
            .collect()
    }

    /// The running daemon's own end, within `within`: its status.
    fn exit_within(&mut self, within: Duration) -> std::process::ExitStatus {
        let mut child = self.child.take().unwrap();
        let deadline = Instant::now() + within;
        loop {
            if let Some(status) = child.try_wait().unwrap() {
                return status;
            }
            if Instant::now() >= deadline {
                let _ = child.kill();
                let _ = child.wait();
                panic!("the daemon did not end within {within:?}");
            }
            std::thread::sleep(Duration::from_millis(10));
        }
    }

    /// SIGKILL to the daemon alone: no drain, no stop.
    fn kill(&mut self) {
        let mut child = self.child.take().unwrap();
        child.kill().unwrap();
        let status = child.wait().unwrap();
        assert_eq!(
            std::os::unix::process::ExitStatusExt::signal(&status),
            Some(9)
        );
    }

    /// Every start while a server this daemon did not launch holds the
    /// endpoint: refused before anything is launched, naming that server,
    /// which it neither adopts nor stops.
    fn refused_beside(&self, pid: i32, generation: u64) {
        let port = self.port.to_string();
        let launched = self.launches();
        for _ in 0..2 {
            let output = self.refused(&[
                ("ARKDECK_DEVELOPMENT_HDC_SERVER", "managed"),
                ("OHOS_HDC_SERVER_PORT", &port),
            ]);
            let stderr = String::from_utf8_lossy(&output.stderr);
            assert!(
                stderr.contains(&format!(
                    "arkdeck-agentd: the managed HDC server did not start: managed HDC endpoint \
                     was not absent before the foreground launch: a server of the configured \
                     HDC executable that this launch did not start listens there (pid {pid}, \
                     generation {generation}); nothing was launched, and that server is neither \
                     adopted nor stopped\n"
                )),
                "{stderr}"
            );
            assert!(output.stdout.is_empty());
            assert_eq!(self.launches(), launched, "a server was launched beside it");
        }
    }

    /// Whether any process still runs this test's own fake: the managed
    /// server a daemon started, whatever port it listens on. A port that is
    /// merely reachable may belong to another test's server.
    fn fake_running(&self) -> bool {
        Command::new("/usr/bin/pgrep")
            .args(["-f", &self.hdc().to_string_lossy()])
            .stdout(Stdio::null())
            .status()
            .unwrap()
            .success()
    }

    fn state(&self) -> PathBuf {
        self.root.join("state")
    }

    fn socket(&self) -> PathBuf {
        self.state().join("control.sock")
    }

    fn command(&self, environment: &[(&str, &str)]) -> Command {
        let mut command = Command::new(env!("CARGO_BIN_EXE_arkdeck-agentd"));
        for (key, _) in std::env::vars_os() {
            let key_text = key.to_string_lossy();
            if key_text.starts_with("ARKDECK_") || key_text.starts_with("OHOS_HDC_") {
                command.env_remove(key);
            }
        }
        command
            .env("ARKDECK_DEVELOPMENT_STATE_ROOT", self.state())
            .env("ARKDECK_ENDPOINT", self.socket())
            .env("ARKDECK_DEVELOPMENT_HDC_PATH", self.hdc())
            .envs(environment.iter().copied());
        command
    }

    /// The daemon with its managed server, answering health.
    fn start(&mut self) {
        self.start_with(&[]);
    }

    /// The managed server, with whatever else the caller composes.
    fn start_with(&mut self, environment: &[(&str, &str)]) {
        let port = self.port.to_string();
        self.child = Some(
            self.command(
                &[
                    ("ARKDECK_DEVELOPMENT_HDC_SERVER", "managed"),
                    ("OHOS_HDC_SERVER_PORT", &port),
                ]
                .iter()
                .copied()
                .chain(environment.iter().copied())
                .collect::<Vec<_>>(),
            )
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()
            .unwrap(),
        );
        // Only an upper bound on the daemon's startup, which includes the
        // managed server's readiness.
        let deadline = Instant::now() + Duration::from_secs(60);
        while UnixStream::connect(self.socket()).is_err() {
            assert!(
                self.child.as_mut().unwrap().try_wait().unwrap().is_none(),
                "daemon exited"
            );
            assert!(Instant::now() < deadline, "daemon startup timeout");
            std::thread::sleep(Duration::from_millis(10));
        }
        assert_eq!(self.call("health", json!({}))["ok"], true);
    }

    /// A startup the daemon refuses: its status and what it wrote.
    fn refused(&self, environment: &[(&str, &str)]) -> Output {
        let output = self
            .command(environment)
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .output()
            .unwrap();
        assert_eq!(output.status.code(), Some(69), "{output:?}");
        output
    }

    /// One current request frame over a new connection, and its answer.
    fn call(&self, method: &str, params: Value) -> Value {
        let mut stream = UnixStream::connect(self.socket()).unwrap();
        stream
            .set_read_timeout(Some(Duration::from_secs(20)))
            .unwrap();
        stream.write_all(&frame(method, params)).unwrap();
        let mut line = String::new();
        BufReader::new(stream).read_line(&mut line).unwrap();
        assert!(line.ends_with('\n'), "no answer to {method}: {line:?}");
        serde_json::from_str(&line).unwrap()
    }

    /// The Rust CLI against this daemon's socket, as the daemon it names.
    fn cli(&self, arguments: &[&str]) -> std::process::ExitStatus {
        // Cargo builds both binary packages before running workspace tests.
        let cli = Path::new(env!("CARGO_BIN_EXE_arkdeck-agentd")).with_file_name("arkdeck");
        let mut command = Command::new(cli);
        for (key, _) in std::env::vars_os() {
            if key.to_string_lossy().starts_with("ARKDECK_") {
                command.env_remove(key);
            }
        }
        command
            .args(arguments)
            .args(["--output", "json", "--socket"])
            .arg(self.socket())
            .env("ARKDECK_DAEMON_PATH", env!("CARGO_BIN_EXE_arkdeck-agentd"))
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .expect(
                "the arkdeck CLI beside the daemon: run the workspace tests, or \
                 `cargo build -p arkdeck-cli` before testing this crate alone",
            )
    }

    /// SIGTERM, then the daemon's end within `within`: its status and stdout.
    fn terminate(&mut self, within: Duration) -> (std::process::ExitStatus, String) {
        let mut child = self.child.take().unwrap();
        let status = Command::new("/bin/kill")
            .args(["-TERM", &child.id().to_string()])
            .status()
            .unwrap();
        assert!(status.success());
        let deadline = Instant::now() + within;
        let status = loop {
            if let Some(status) = child.try_wait().unwrap() {
                break status;
            }
            if Instant::now() >= deadline {
                let _ = child.kill();
                let _ = child.wait();
                panic!("the daemon did not end within {within:?} of SIGTERM");
            }
            std::thread::sleep(Duration::from_millis(10));
        };
        let mut stdout = String::new();
        child
            .stdout
            .take()
            .unwrap()
            .read_to_string(&mut stdout)
            .unwrap();
        (status, stdout)
    }
}

impl Drop for Runtime {
    fn drop(&mut self) {
        if let Some(mut child) = self.child.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
        // A server this test left behind would keep its port: end it first.
        let _ = Command::new("/usr/bin/pkill")
            .args(["-KILL", "-f", &self.hdc().to_string_lossy()])
            .status();
        // A `kill -r` server is nobody's child: ended by its recorded PID.
        fake_hdc_servers::tear_down(&self.root.join("tools"), &self.hdc());
        let _ = fs::remove_dir_all(&self.root);
    }
}

/// The commandless proof of the server on `endpoint`, once one listens there
/// within `budget`.
fn proved_within(
    tool: &arkdeck_platform::VerifiedTool,
    endpoint: SocketAddrV4,
    budget: Duration,
) -> arkdeck_platform::LoopbackServerLease {
    let deadline = Instant::now() + budget;
    loop {
        match arkdeck_platform::LoopbackServerLease::acquire(tool, endpoint) {
            Ok(lease) => return lease,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                assert!(Instant::now() < deadline, "no server listens: {error}");
                std::thread::sleep(Duration::from_millis(20));
            }
            Err(error) => panic!("the endpoint's server is not proved: {error}"),
        }
    }
}

/// Swift `stableGeneration`: a server's birth in microseconds.
fn generation(lease: &arkdeck_platform::LoopbackServerLease) -> u64 {
    lease.identity().start_seconds * 1_000_000 + lease.identity().start_microseconds
}

fn frame(method: &str, params: Value) -> Vec<u8> {
    let mut frame = serde_json::to_vec(&json!({
        "protocolVersion": PROTOCOL_VERSION, "contractIdentity": CONTRACT_IDENTITY,
        "id": "managed-hdc-process", "method": method, "params": params,
    }))
    .unwrap();
    frame.push(b'\n');
    frame
}

#[test]
fn unexpected_foreground_exit_ends_the_daemon_and_a_successor_rebuilds_the_provider() {
    let _turn = turn();
    use arkdeck_platform::{LoopbackServerLease, VerifiedTool};
    let mut runtime = Runtime::new();
    runtime.start();
    let tool = VerifiedTool::open(
        runtime.hdc(),
        &sha256_hex(&fs::read(runtime.hdc()).unwrap()),
    )
    .unwrap();
    let endpoint = SocketAddrV4::new(Ipv4Addr::LOCALHOST, runtime.port);
    let before = LoopbackServerLease::acquire(&tool, endpoint).unwrap();
    // This is the exact retained fake child's PID, never a real HDC target.
    assert!(
        Command::new("/bin/kill")
            .args(["-KILL", &before.identity().pid.to_string()])
            .status()
            .unwrap()
            .success()
    );
    let mut child = runtime.child.take().unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    let status = loop {
        if let Some(status) = child.try_wait().unwrap() {
            break status;
        }
        if Instant::now() >= deadline {
            let _ = child.kill();
            let _ = child.wait();
            panic!("daemon kept serving after its foreground HDC died");
        }
        std::thread::sleep(Duration::from_millis(10));
    };
    assert_eq!(status.code(), Some(70));
    assert!(UnixStream::connect(runtime.socket()).is_err());
    assert!(before.revalidate().is_err());
    // Emulate launchd starting the same binary/root; no installed service is
    // changed. Startup must recover the stale control socket and store locks.
    runtime.start();
    let after = LoopbackServerLease::acquire(&tool, endpoint).unwrap();
    assert_ne!(before.identity(), after.identity());
    assert_eq!(runtime.call("runtime.hdc.status", json!({}))["ok"], true);
    let (status, _) = runtime.terminate(Duration::from_secs(10));
    assert_eq!(status.code(), Some(0));
    assert!(after.revalidate().is_err());
}

#[test]
fn the_managed_server_answers_status_and_availability_and_stops_with_the_daemon() {
    let _turn = turn();
    let mut runtime = Runtime::new();
    let digest = sha256_hex(&fs::read(runtime.hdc()).unwrap());
    runtime.start();
    assert!(reachable(runtime.port), "the managed server listens");

    // runtime.hdc.status: the managed server's live facts. The fake's digest
    // has no published commandless identity family, so the identity is not
    // observed and ownership stays unproven, as Swift's observer answers.
    let status = runtime.call("runtime.hdc.status", json!({}));
    assert_eq!(status["ok"], true, "{status}");
    let result = &status["result"];
    validate_method_value("runtime.hdc.status", "result", result).unwrap();
    let endpoint = format!("127.0.0.1:{}", runtime.port);
    for (member, expected) in [
        ("schemaVersion", json!("arkdeck.runtime-hdc-status/1")),
        ("availability", json!("unavailable")),
        ("reasonCode", json!("hdc.identityFamilyUnavailable")),
        ("executablePath", json!(runtime.hdc().to_string_lossy())),
        ("executableSource", json!("runtimeConfiguration")),
        ("configuredExecutableSHA256", json!(digest)),
        ("executableSHA256", json!(digest)),
        ("clientVersion", Value::Null),
        ("clientVersionSource", Value::Null),
        ("serverVersion", Value::Null),
        ("daemonVersion", Value::Null),
        ("endpoint", json!(endpoint)),
        ("endpointSource", json!("inheritedEnvironment")),
        (
            "serverEndpointRef",
            json!(format!("hdc-endpoint:{}", sha256_hex(endpoint.as_bytes()))),
        ),
        ("ownership", json!("unknown")),
        ("generation", Value::Null),
        ("processId", Value::Null),
        ("serverHealth", json!("unknown")),
        ("newDispatchCount", json!(0)),
        (
            "startupVersions",
            json!({"client": "3.2.0d", "server": "3.2.0d"}),
        ),
    ] {
        assert_eq!(result[member], expected, "{member}: {result}");
    }
    assert!(result["signature"].is_object(), "{result}");

    // target.availability: the tool leg is the managed server's startup facts.
    let availability = runtime.call("target.availability", json!({"targetId": TARGET}));
    assert_eq!(availability["ok"], true, "{availability}");
    validate_method_value("target.availability", "result", &availability["result"]).unwrap();
    assert_eq!(
        availability["result"]["tool"],
        json!({
            "state": "ready", "toolSha256": digest, "clientVersion": "3.2.0d",
            "serverVersion": "3.2.0d", "endpointSource": "inheritedEnvironment",
        })
    );

    // doctor: standard mode does not observe the identity, and the report is
    // ready (degraded only by the Session output owner Swift does not
    // publish). Deep mode observes it: the fake's digest has no commandless
    // identity family, so the identity is a blocker naming why.
    let standard = runtime.call("doctor", json!({}));
    let report = &standard["result"];
    validate_method_value("doctor", "result", report).unwrap();
    assert_eq!(report["ready"], true, "{report}");
    assert_eq!(report["overall"], "degraded");
    assert_eq!(report["checks"]["hdc"]["configured"], true);
    assert_eq!(
        report["checks"]["hdc"]["reasonCode"],
        "doctor.deepNotRequested"
    );
    assert_eq!(report["checks"]["target"]["adoptedTargetCount"], 1);
    assert_eq!(report["checks"]["target"]["bootstrapConfigured"], true);
    let deep = runtime.call("doctor", json!({"deep": true}));
    let report = &deep["result"];
    validate_method_value("doctor", "result", report).unwrap();
    assert_eq!(report["ready"], false, "{report}");
    let blockers: Vec<_> = report["findings"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|finding| finding["severity"] == "blocker")
        .map(|finding| finding["summary"].as_str().unwrap().to_owned())
        .collect();
    assert_eq!(
        blockers,
        [
            "the selected HDC server identity is unavailable or not Runtime-managed: \
          hdc.identityFamilyUnavailable"
        ]
    );
    assert_eq!(
        report["checks"]["recovery"],
        json!({"checked": true, "outstandingCleanupCount": 0})
    );
    assert_eq!(
        report["checks"]["storage"]["runtimeArtifacts"]["checked"],
        true
    );
    // The CLI's gate over those reports: `--require-healthy` passes the
    // standard report and refuses the deep one with 69.
    assert_eq!(
        runtime.cli(&["doctor", "--require-healthy"]).code(),
        Some(0)
    );
    assert_eq!(
        runtime
            .cli(&["doctor", "--deep", "--require-healthy"])
            .code(),
        Some(69)
    );

    // An idle connection is ended by the drain, not left to its read timeout.
    let mut idle = UnixStream::connect(runtime.socket()).unwrap();
    idle.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
    idle.write_all(&frame("health", json!({}))).unwrap();
    let mut idle = BufReader::new(idle);
    let mut line = String::new();
    idle.read_line(&mut line).unwrap();
    assert!(line.contains("\"ok\":true"), "{line}");

    let started = Instant::now();
    let (status, stdout) = runtime.terminate(Duration::from_secs(15));
    assert_eq!(status.code(), Some(0), "{status:?}");
    assert_eq!(stdout, "arkdeck-agentd stopped\n");
    assert!(
        started.elapsed() < Duration::from_secs(10),
        "{:?}",
        started.elapsed()
    );
    let mut rest = Vec::new();
    idle.read_to_end(&mut rest).unwrap();
    assert!(rest.is_empty());
    assert!(!runtime.socket().exists(), "the socket's name is removed");
    assert!(!runtime.fake_running(), "no managed server is left");
}

#[test]
fn a_foreign_listener_on_the_endpoint_never_becomes_the_managed_server() {
    let _turn = turn();
    let mut runtime = Runtime::new();
    // Another process's listener on the selected endpoint, held from the
    // moment its port is found: no managed server is launched beside it,
    // and the listener answering is never taken for one.
    let foreign = issued_listener();
    runtime.port = foreign.local_addr().unwrap().port();
    let port = runtime.port.to_string();
    let output = runtime.refused(&[
        ("ARKDECK_DEVELOPMENT_HDC_SERVER", "managed"),
        ("OHOS_HDC_SERVER_PORT", &port),
    ]);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains(
            "the managed HDC server did not start: managed HDC endpoint was not absent before \
             the foreground launch: a listener that is not the configured HDC executable holds \
             it; nothing was launched, and that server is neither adopted nor stopped"
        ),
        "{stderr}"
    );
    assert!(output.stdout.is_empty());
    assert_eq!(runtime.launches(), 0, "a server was launched beside it");
    drop(foreign);
    assert!(!runtime.fake_running(), "no managed server was left behind");
}

/// Another client's restart (`hdc -s <endpoint> kill -r`, which this daemon
/// neither ran nor approved) ends the daemon's foreground server, so the
/// daemon exits 70 for launchd to rebuild it, and the replacement that
/// restart started is a server no later start launched. Every start refuses
/// before launching anything, naming that server, which it neither adopts
/// nor stops; once an operator's `hdc kill` has ended it, the next start
/// serves with a server of its own and its stop leaves nothing behind.
#[test]
fn an_external_restart_leaves_a_server_every_start_refuses_until_it_ends() {
    let _turn = turn();
    let mut runtime = Runtime::new();
    runtime.start();
    let tool = runtime.tool();
    let original = proved_within(&tool, runtime.endpoint(), Duration::from_secs(5));
    assert!(runtime.hdc_client(&["kill", "-r"]).success());
    assert_eq!(
        runtime.exit_within(Duration::from_secs(10)).code(),
        Some(70)
    );
    let replacement = proved_within(&tool, runtime.endpoint(), Duration::from_secs(10));
    assert_ne!(replacement.identity().pid, original.identity().pid);
    assert_eq!(runtime.recorded_servers(), [replacement.identity().pid]);

    runtime.refused_beside(replacement.identity().pid, generation(&replacement));
    replacement.revalidate().unwrap();

    runtime.operator_kill();
    assert!(replacement.revalidate().is_err());
    let launched = runtime.launches();
    runtime.start();
    assert_eq!(runtime.launches(), launched + 1);
    let own = proved_within(&tool, runtime.endpoint(), Duration::from_secs(5));
    assert_ne!(own.identity().pid, replacement.identity().pid);
    assert_eq!(runtime.call("runtime.hdc.status", json!({}))["ok"], true);
    let (status, stdout) = runtime.terminate(Duration::from_secs(15));
    assert_eq!(status.code(), Some(0));
    assert_eq!(stdout, "arkdeck-agentd stopped\n");
    assert!(own.revalidate().is_err());
    assert!(!runtime.fake_running(), "no server is left");
}

/// A daemon killed outright (SIGKILL: no drain and no stop) leaves the
/// server it launched listening as nobody's child. The next start did not
/// launch it: every start refuses before launching anything, naming it,
/// neither adopting nor stopping it, until it ends; then the next start
/// serves with a server of its own.
#[test]
fn a_killed_daemon_leaves_its_server_and_every_start_refuses_it_until_it_ends() {
    let _turn = turn();
    let mut runtime = Runtime::new();
    runtime.start();
    let tool = runtime.tool();
    let orphan = proved_within(&tool, runtime.endpoint(), Duration::from_secs(5));
    runtime.kill();
    orphan.revalidate().unwrap();

    runtime.refused_beside(orphan.identity().pid, generation(&orphan));
    orphan.revalidate().unwrap();

    runtime.operator_kill();
    assert!(orphan.revalidate().is_err());
    runtime.start();
    let own = proved_within(&tool, runtime.endpoint(), Duration::from_secs(5));
    assert_ne!(own.identity().pid, orphan.identity().pid);
    let (status, _) = runtime.terminate(Duration::from_secs(15));
    assert_eq!(status.code(), Some(0));
    assert!(!runtime.fake_running(), "no server is left");
}

#[test]
fn a_managed_server_is_configured_only_as_the_isolated_owner_names_it() {
    let _turn = turn();
    let runtime = Runtime::new();
    for (environment, message) in [
        (
            vec![("ARKDECK_DEVELOPMENT_HDC_SERVER", "external")],
            "ARKDECK_DEVELOPMENT_HDC_SERVER accepts only managed",
        ),
        (
            vec![
                ("ARKDECK_DEVELOPMENT_HDC_SERVER", "managed"),
                ("OHOS_HDC_SERVER_PORT", "65536"),
            ],
            "OHOS_HDC_SERVER_PORT is not a port in 1...65535",
        ),
    ] {
        let output = runtime.refused_before_any_launch(&environment);
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert!(stderr.contains(message), "{environment:?}: {stderr}");
    }
    // Without a development HDC, or outside an isolated root, nothing starts.
    let output = runtime
        .command(&[("ARKDECK_DEVELOPMENT_HDC_SERVER", "managed")])
        .env_remove("ARKDECK_DEVELOPMENT_HDC_PATH")
        .output()
        .unwrap();
    assert_eq!(output.status.code(), Some(69));
    assert!(
        String::from_utf8_lossy(&output.stderr)
            .contains("a managed development HDC server needs ARKDECK_DEVELOPMENT_HDC_PATH")
    );
    let output = runtime
        .command(&[("ARKDECK_DEVELOPMENT_HDC_SERVER", "managed")])
        .env_remove("ARKDECK_DEVELOPMENT_HDC_PATH")
        .env_remove("ARKDECK_DEVELOPMENT_STATE_ROOT")
        .env_remove("ARKDECK_ENDPOINT")
        .output()
        .unwrap();
    assert_eq!(output.status.code(), Some(69));
    assert!(
        String::from_utf8_lossy(&output.stderr)
            .contains("a development HDC is configured only for an isolated development root")
    );
    assert_eq!(runtime.runs(), Vec::<String>::new());
    assert!(!runtime.fake_running());
}

#[test]
fn development_usb_relations_beside_a_registered_hdc_are_acknowledged_only_as_named() {
    let _turn = turn();
    // The acknowledgment (maintainer decision 2026-09-19, option A) lets the
    // isolated owner read a relation file beside a registered HDC it starts
    // as its managed server. The fake is no registered HDC, so every
    // composition here is one the acknowledgment does not name: startup fails
    // before any server starts, and without it the fixture's relations stay
    // allowed as before.
    const ACKNOWLEDGMENT: &str = "ARKDECK_DEVELOPMENT_USB_RELATIONS_WITH_REGISTERED_HDC";
    let runtime = Runtime::new();
    let relations = runtime.root.join("usb-relations.json");
    let relations = relations.to_str().unwrap();
    let port = runtime.port.to_string();
    let acknowledged_only = "ARKDECK_DEVELOPMENT_USB_RELATIONS_WITH_REGISTERED_HDC is acknowledged \
                             only with development USB relations and a registered HDC started as \
                             the managed server";
    for (environment, message) in [
        (
            vec![
                (ACKNOWLEDGMENT, "yes"),
                ("ARKDECK_DEVELOPMENT_USB_RELATIONS", relations),
                ("ARKDECK_DEVELOPMENT_HDC_SERVER", "managed"),
                ("OHOS_HDC_SERVER_PORT", port.as_str()),
            ],
            "ARKDECK_DEVELOPMENT_USB_RELATIONS_WITH_REGISTERED_HDC accepts only acknowledged",
        ),
        // A fixture started as the managed server, with relations.
        (
            vec![
                (ACKNOWLEDGMENT, "acknowledged"),
                ("ARKDECK_DEVELOPMENT_USB_RELATIONS", relations),
                ("ARKDECK_DEVELOPMENT_HDC_SERVER", "managed"),
                ("OHOS_HDC_SERVER_PORT", port.as_str()),
            ],
            acknowledged_only,
        ),
        // A fixture the owner does not start, with relations.
        (
            vec![
                (ACKNOWLEDGMENT, "acknowledged"),
                ("ARKDECK_DEVELOPMENT_USB_RELATIONS", relations),
            ],
            acknowledged_only,
        ),
        // No relation file at all.
        (
            vec![
                (ACKNOWLEDGMENT, "acknowledged"),
                ("ARKDECK_DEVELOPMENT_HDC_SERVER", "managed"),
                ("OHOS_HDC_SERVER_PORT", port.as_str()),
            ],
            acknowledged_only,
        ),
        // A relation file named by anything but an explicit absolute path,
        // beside the fixture this owner would start as its managed server.
        (
            vec![
                ("ARKDECK_DEVELOPMENT_USB_RELATIONS", "usb-relations.json"),
                ("ARKDECK_DEVELOPMENT_HDC_SERVER", "managed"),
                ("OHOS_HDC_SERVER_PORT", port.as_str()),
            ],
            "ARKDECK_DEVELOPMENT_USB_RELATIONS must be an explicit absolute path",
        ),
    ] {
        let output = runtime.refused_before_any_launch(&environment);
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert!(stderr.contains(message), "{environment:?}: {stderr}");
        assert!(output.stdout.is_empty(), "{environment:?}");
    }
    // No development HDC in the isolated root.
    let output = runtime
        .command(&[(ACKNOWLEDGMENT, "acknowledged")])
        .env_remove("ARKDECK_DEVELOPMENT_HDC_PATH")
        .output()
        .unwrap();
    assert_eq!(output.status.code(), Some(69));
    assert!(String::from_utf8_lossy(&output.stderr).contains(acknowledged_only));
    assert_eq!(runtime.runs(), Vec::<String>::new());
    // The standalone daemon never reads development relations, acknowledged
    // or not. Its endpoint is one no daemon could bind, so a daemon that
    // did not refuse would fail on another message, never serve.
    let output = runtime
        .command(&[(ACKNOWLEDGMENT, "acknowledged")])
        .env_remove("ARKDECK_DEVELOPMENT_HDC_PATH")
        .env_remove("ARKDECK_DEVELOPMENT_STATE_ROOT")
        .env("ARKDECK_ENDPOINT", runtime.root.join("absent/control.sock"))
        .output()
        .unwrap();
    assert_eq!(output.status.code(), Some(69));
    assert!(String::from_utf8_lossy(&output.stderr).contains(
        "development USB relations beside a registered HDC are acknowledged only for an \
             isolated development root"
    ));
    assert_eq!(runtime.runs(), Vec::<String>::new());
    assert!(!runtime.fake_running());
}

#[test]
fn the_development_mutation_authority_is_acknowledged_only_as_named() {
    let _turn = turn();
    // The acknowledgment (maintainer decision 2026-09-20, as option A of
    // 2026-09-19) lets the isolated owner prove a device mutation's state
    // continuity against its own root. Every composition it does not name
    // fails startup before any server starts: the fake never runs, not even
    // for a readiness probe (TASK-XPA-014; a refusal after the managed
    // server's launch once left that server running as nobody's child).
    const ACKNOWLEDGMENT: &str = "ARKDECK_DEVELOPMENT_MUTATION_AUTHORITY";
    let mut runtime = Runtime::new();
    let port = runtime.port.to_string();
    let acknowledged_only = "ARKDECK_DEVELOPMENT_MUTATION_AUTHORITY is acknowledged only with an \
                             isolated development state root whose development HDC the owner \
                             starts as its managed server";
    for (environment, message) in [
        (
            vec![
                (ACKNOWLEDGMENT, "yes"),
                ("ARKDECK_DEVELOPMENT_HDC_SERVER", "managed"),
                ("OHOS_HDC_SERVER_PORT", port.as_str()),
            ],
            "ARKDECK_DEVELOPMENT_MUTATION_AUTHORITY accepts only acknowledged",
        ),
        // Acknowledged without the managed server, which the owner must start
        // for the device it then mutates.
        (vec![(ACKNOWLEDGMENT, "acknowledged")], acknowledged_only),
    ] {
        let output = runtime.refused_before_any_launch(&environment);
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert!(stderr.contains(message), "{environment:?}: {stderr}");
        assert!(output.stdout.is_empty(), "{environment:?}");
    }
    // The standalone daemon proves its continuity against the installed
    // Runtime's root and never takes this authority. Its endpoint here is one
    // no daemon could bind, so a daemon that did not refuse would fail on
    // another message, never serve.
    let output = runtime
        .command(&[(ACKNOWLEDGMENT, "acknowledged")])
        .env_remove("ARKDECK_DEVELOPMENT_HDC_PATH")
        .env_remove("ARKDECK_DEVELOPMENT_STATE_ROOT")
        .env("ARKDECK_ENDPOINT", runtime.root.join("absent/control.sock"))
        .output()
        .unwrap();
    assert_eq!(output.status.code(), Some(69));
    assert!(String::from_utf8_lossy(&output.stderr).contains(
        "a development mutation authority is acknowledged only for an isolated development \
             root"
    ));
    assert_eq!(runtime.runs(), Vec::<String>::new());
    assert!(!runtime.fake_running());
    // The one composition it names serves, with its managed server.
    runtime.start_with(&[(ACKNOWLEDGMENT, "acknowledged")]);
    assert_eq!(runtime.call("health", json!({}))["ok"], true);
    let (status, _) = runtime.terminate(Duration::from_secs(60));
    assert_eq!(status.code(), Some(0));
}

/// A start that fails once its managed server is launched — here its Job
/// recovery, refusing an admitted Job whose record outlived its journal —
/// stops that server before the daemon exits and names it by PID: that very
/// process is gone and nothing of the fake runs (TASK-XPA-014). A daemon that
/// left its end to whoever dropped the server last could exit while only the
/// foreground-exit monitor held it, leaving the server as nobody's child.
#[test]
fn a_start_that_fails_after_its_launch_stops_the_managed_server() {
    let _turn = turn();
    const JOB: &str = "job-082b8363fce0462b4571a62147751099";
    let runtime = Runtime::new();
    {
        let state = runtime.state().join("jobs-state");
        fs::DirBuilder::new().mode(0o700).create(&state).unwrap();
        let jobs = arkdeck_hoststore::JobStore::open_owner(&state).unwrap();
        let record = arkdeck_hoststore::JobRecord::decode(
            &fs::read(fixture(&format!(
                "job-reconcile-analyzer/before/jobs/{JOB}/job-record.json"
            )))
            .unwrap(),
        )
        .unwrap();
        jobs.admit(&record, &"a".repeat(64)).unwrap();
        fs::DirBuilder::new()
            .mode(0o700)
            .recursive(true)
            .create(state.join("jobs").join(JOB))
            .unwrap();
        jobs.persist(&record, "2026-09-26T00:00:00Z").unwrap();
    }
    let port = runtime.port.to_string();
    let output = runtime.refused(&[
        ("ARKDECK_DEVELOPMENT_HDC_SERVER", "managed"),
        ("OHOS_HDC_SERVER_PORT", &port),
    ]);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.ends_with(&format!(
            "arkdeck-agentd: internalFailure(\"admitted job {JOB} has a partial durable \
             projection\")\n"
        )),
        "{stderr}"
    );
    assert!(output.stdout.is_empty(), "{stderr}");
    // The start failed after its launch: the server ran, and was ready.
    assert_eq!(runtime.launches(), 1, "{stderr}");
    let reported = stderr
        .lines()
        .find_map(|line| {
            line.strip_prefix(
                "arkdeck-agentd: stopped the managed HDC server this daemon launched (pid ",
            )
        })
        .unwrap_or_else(|| panic!("the daemon named no server it stopped: {stderr}"));
    let (pid, end) = reported.split_once("), which ").unwrap();
    let pid: i32 = pid.parse().unwrap();
    assert!(
        matches!(end, "ended on signal 15" | "ended on signal 9"),
        "{stderr}"
    );
    assert!(
        arkdeck_platform::process_argument_record(pid).is_none(),
        "the server the daemon reported stopped (pid {pid}) still runs"
    );
    assert!(
        !runtime.fake_running(),
        "the managed server was left running"
    );
}

#[test]
fn the_development_code_sign_helper_is_named_only_where_it_may_be() {
    let _turn = turn();
    // The helper a native deployment stages is the one this bundle carries;
    // an isolated development root may name another, and every composition
    // that may not, or names one that does not verify, fails startup, before
    // the managed server this owner would start is launched.
    const HELPER: &str = "ARKDECK_DEVELOPMENT_CODE_SIGN_HELPER";
    let runtime = Runtime::new();
    let junk = runtime.root.join("not-a-helper");
    std::fs::write(&junk, b"not an ELF at all").unwrap();
    let junk = junk.to_str().unwrap();
    let port = runtime.port.to_string();
    let managed = [
        ("ARKDECK_DEVELOPMENT_HDC_SERVER", "managed"),
        ("OHOS_HDC_SERVER_PORT", port.as_str()),
    ];
    for (helper, message) in [
        (
            "arkdeck-code-sign-enable",
            "ARKDECK_DEVELOPMENT_CODE_SIGN_HELPER must be an explicit absolute path",
        ),
        (junk, "bundled code-sign helper is invalid"),
    ] {
        for environment in [
            vec![(HELPER, helper)],
            [(HELPER, helper)].iter().chain(&managed).copied().collect(),
        ] {
            let output = runtime.refused_before_any_launch(&environment);
            let stderr = String::from_utf8_lossy(&output.stderr);
            assert!(stderr.contains(message), "{environment:?}: {stderr}");
        }
    }
    // The standalone daemon and the facade compose only their own bundle's.
    // The endpoint here is one no daemon could bind, so a daemon that did not
    // refuse would fail on another message, never serve.
    let output = runtime
        .command(&[(HELPER, junk)])
        .env_remove("ARKDECK_DEVELOPMENT_HDC_PATH")
        .env_remove("ARKDECK_DEVELOPMENT_STATE_ROOT")
        .env("ARKDECK_ENDPOINT", runtime.root.join("absent/control.sock"))
        .output()
        .unwrap();
    assert_eq!(output.status.code(), Some(69));
    assert!(
        String::from_utf8_lossy(&output.stderr).contains(
            "a development code-sign helper is named only for an isolated development root"
        )
    );
    assert_eq!(runtime.runs(), Vec::<String>::new());
    assert!(!runtime.fake_running());
}
