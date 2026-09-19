//! `ManagedHdcServer` (SPK-6, TASK-XPA-016): the HDC server the daemon owns,
//! started, proved ready and bound to its own launch as Swift's
//! `HeadlessHDCServerHost` does it. The tool is a fake `hdc` compiled here
//! from a few lines of C — a shell script cannot own a TCP listener, and a
//! copied Apple binary cannot run — with its behaviour fixed at compile time,
//! since the host names the child's environment. No real HDC is launched.
//! Spawning children, these tests keep a binary of their own.
#![cfg(target_os = "macos")]

use arkdeck_platform::{ServerExit, VerifiedTool};
use arkdeck_provider_hdc::{ManagedHdcServer, StartBudget, StartFailure};
use sha2::{Digest, Sha256};
use std::fs;
use std::net::{Ipv4Addr, SocketAddr, SocketAddrV4, TcpStream};
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::process::Command;
use std::time::{Duration, Instant};

/// A fake `hdc`: `-s <endpoint> -m` binds the endpoint's port after a
/// compile-time cold start and accepts forever; `checkserver` answers the
/// registered line with a compile-time server version; anything else is
/// unregistered. `EXIT_EARLY` ends the server before it binds, `NEVER_BIND`
/// keeps it alive without a listener, `PRINT_PORT` reports the server port
/// variable it was given.
const FAKE_HDC: &str = include_str!("../../../tests/fixtures/managed-hdc/fake-hdc.c");

/// One compiled variant of the fake under its own canonical directory.
struct FakeHdc {
    directory: PathBuf,
    tool: VerifiedTool,
}

impl FakeHdc {
    fn compile(name: &str, defines: &[&str]) -> Self {
        let directory =
            std::env::temp_dir().join(format!("arkdeck-managed-hdc-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&directory);
        fs::create_dir(&directory).unwrap();
        fs::set_permissions(&directory, fs::Permissions::from_mode(0o700)).unwrap();
        let directory = directory.canonicalize().unwrap();
        let source = directory.join("fake-hdc.c");
        fs::write(&source, FAKE_HDC).unwrap();
        let binary = directory.join("hdc");
        let mut command = Command::new("cc");
        command.arg("-O0").arg("-o").arg(&binary).arg(&source);
        for define in defines {
            command.arg(format!("-D{define}"));
        }
        let output = command
            .output()
            .expect("cc from the developer tools compiles the fake");
        assert!(
            output.status.success(),
            "fake hdc did not compile: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        fs::set_permissions(&binary, fs::Permissions::from_mode(0o700)).unwrap();
        let digest = format!("{:x}", Sha256::digest(fs::read(&binary).unwrap()));
        let tool = VerifiedTool::open(&binary, &digest).unwrap();
        Self { directory, tool }
    }
}

impl Drop for FakeHdc {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.directory);
    }
}

/// A loopback endpoint no other test of this binary was handed, below the
/// kernel's ephemeral range (see `loopback_ports`).
fn free_endpoint() -> SocketAddrV4 {
    loopback_ports::free_endpoint()
}

mod loopback_ports {
    include!("../../../tests/support/loopback_ports.rs");
}

fn budget(readiness: Duration) -> StartBudget {
    StartBudget {
        readiness,
        ..StartBudget::default()
    }
}

fn reachable(endpoint: SocketAddrV4) -> bool {
    TcpStream::connect_timeout(&SocketAddr::V4(endpoint), Duration::from_millis(100)).is_ok()
}

fn unreachable_within(endpoint: SocketAddrV4, budget: Duration) -> bool {
    let deadline = Instant::now() + budget;
    while Instant::now() < deadline {
        if !reachable(endpoint) {
            return true;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    !reachable(endpoint)
}

#[test]
fn a_cold_server_becomes_ready_and_is_bound_to_its_launch() {
    let fake = FakeHdc::compile("cold", &["COLD_MS=1000"]);
    let endpoint = free_endpoint();
    let started = Instant::now();
    let mut server =
        ManagedHdcServer::start(&fake.tool, endpoint, budget(Duration::from_secs(15))).unwrap();
    assert!(
        started.elapsed() >= Duration::from_millis(900),
        "readiness waited for the listener"
    );
    assert_eq!(server.endpoint(), endpoint);
    assert_eq!(server.check().client_version, "3.2.0d");
    assert_eq!(server.check().server_version, "3.2.0d");
    let launch = server.launch().clone();
    let identity = server.identity().clone();
    assert_eq!(identity.pid, launch.pid);
    assert_eq!(
        (identity.start_seconds, identity.start_microseconds),
        (launch.start_seconds, launch.start_microseconds)
    );
    assert_eq!(identity.executable_path, launch.executable_path);
    assert_eq!(identity.executable_sha256, fake.tool.sha256());
    assert_eq!(identity.endpoint, endpoint);
    assert!(reachable(endpoint));
    server.revalidate().unwrap();
    let stopped = server.stop().unwrap();
    assert!(
        matches!(stopped.exit, ServerExit::Signalled(_)),
        "{:?}",
        stopped.exit
    );
    assert!(stopped.stdout.is_empty());
    assert!(unreachable_within(endpoint, Duration::from_secs(5)));
}

#[test]
fn a_server_that_ends_before_it_listens_reports_its_exit() {
    let fake = FakeHdc::compile("early", &["EXIT_EARLY=3"]);
    let endpoint = free_endpoint();
    let started = Instant::now();
    let error = ManagedHdcServer::start(&fake.tool, endpoint, budget(Duration::from_secs(10)))
        .err()
        .expect("a server that ends is not ready");
    assert!(started.elapsed() < Duration::from_secs(8));
    let StartFailure::Exited(reason) = error else {
        panic!("expected the exit, got {error:?}");
    };
    assert_eq!(reason, "foreground HDC server exited with status 3");
}

#[test]
fn a_server_whose_versions_disagree_is_never_ready_and_is_stopped() {
    let fake = FakeHdc::compile("mismatch", &["SERVER_VERSION=\"3.2.0f\""]);
    let endpoint = free_endpoint();
    let error = ManagedHdcServer::start(&fake.tool, endpoint, budget(Duration::from_secs(3)))
        .err()
        .expect("disagreeing versions are not ready");
    let StartFailure::NotReady(reason) = error else {
        panic!("expected the deadline, got {error:?}");
    };
    assert!(
        reason.starts_with("checkserver exit=0 stdoutBytes="),
        "{reason}"
    );
    // The failed launch is ended: its listener goes away.
    assert!(unreachable_within(endpoint, Duration::from_secs(5)));
}

#[test]
fn a_listener_of_another_process_never_binds_the_launch() {
    let fake = FakeHdc::compile("foreign", &["NEVER_BIND=1"]);
    // The foreign listener keeps the port it was handed: releasing it and
    // binding again would open a window for another test's server.
    let foreign = loopback_ports::issued_listener();
    let SocketAddr::V4(endpoint) = foreign.local_addr().unwrap() else {
        panic!("a loopback v4 listener");
    };
    let error = ManagedHdcServer::start(&fake.tool, endpoint, budget(Duration::from_secs(10)))
        .err()
        .expect("another process's listener is not this launch");
    let StartFailure::Unbound(reason) = error else {
        panic!("expected the identity refusal, got {error:?}");
    };
    assert_eq!(
        reason,
        "managed HDC launch could not be bound to its live process identity"
    );
    drop(foreign);
}

#[test]
fn the_server_port_is_named_to_the_child_and_its_output_is_kept() {
    let fake = FakeHdc::compile("port", &["PRINT_PORT=1"]);
    let endpoint = free_endpoint();
    let server =
        ManagedHdcServer::start(&fake.tool, endpoint, budget(Duration::from_secs(10))).unwrap();
    let stopped = server.stop().unwrap();
    assert_eq!(
        stopped.stdout,
        format!("OHOS_HDC_SERVER_PORT={}\n", endpoint.port()).into_bytes()
    );
    assert!(stopped.stderr.is_empty());
}

/// A server its owner drops without stopping it is ended with it: nothing
/// is left listening on the endpoint (the daemon's own stop stops it first).
#[test]
fn a_dropped_server_leaves_nothing_on_its_endpoint() {
    let fake = FakeHdc::compile("dropped", &[]);
    let endpoint = free_endpoint();
    let mut server =
        ManagedHdcServer::start(&fake.tool, endpoint, budget(Duration::from_secs(15))).unwrap();
    assert!(!server.exited());
    assert!(reachable(endpoint));
    drop(server);
    assert!(unreachable_within(endpoint, Duration::from_secs(5)));
}

/// Swift's selector without an explicit endpoint: the inherited port on the
/// IPv4 loopback, else the documented default; a set port outside 1...65535
/// is refused rather than defaulted.
#[test]
fn the_endpoint_is_the_inherited_port_or_the_default() {
    use arkdeck_provider_hdc::EndpointSelection;
    let loopback = |port| SocketAddrV4::new(Ipv4Addr::LOCALHOST, port);
    assert_eq!(
        EndpointSelection::select(None).unwrap(),
        EndpointSelection {
            endpoint: loopback(8710),
            source: "default"
        }
    );
    for (value, port) in [("8711", 8711), ("+9000", 9000), ("65535", 65535), ("1", 1)] {
        assert_eq!(
            EndpointSelection::select(Some(value)).unwrap(),
            EndpointSelection {
                endpoint: loopback(port),
                source: "inheritedEnvironment"
            },
            "{value}"
        );
    }
    for value in ["", "0", "65536", "-1", " 8710", "8710.0", "port"] {
        let refusal = EndpointSelection::select(Some(value)).unwrap_err();
        assert_eq!(refusal, "OHOS_HDC_SERVER_PORT is not a port in 1...65535");
    }
}
