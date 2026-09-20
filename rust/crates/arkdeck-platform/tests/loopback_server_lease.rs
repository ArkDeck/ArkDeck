//! The macOS proof that an HDC server already exists (SPK-6, TASK-XPA-016):
//! a real listener process is found by executable path, single registered
//! loopback listener and birth identity, without any connect or spawn of the
//! observed tool. Spawning children, these tests keep a binary of their own.
//!
//! The listener is this binary itself: re-executed with `listener_process`
//! selected and the endpoint named in its environment, it binds one TCP
//! listener and holds it until it is killed. The lease selects candidates by
//! executable path, so one test's children are candidates in another test's
//! scan, where a child read between being listed and exiting can fail the
//! scan rather than be skipped by it. The tests that scan therefore take
//! their turn one at a time, each judging a population of its own making —
//! and no `nc` on the machine is a candidate at all (a copied Apple binary
//! cannot run: the kernel kills it).
#![cfg(target_os = "macos")]

use arkdeck_platform::{LoopbackServerLease, VerifiedTool, random_bytes};
use sha2::{Digest, Sha256};
use std::fs;
use std::io::{ErrorKind, Read};
use std::net::{Ipv4Addr, SocketAddrV4, TcpListener};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::{Mutex, MutexGuard, PoisonError};
use std::time::{Duration, Instant};

const LISTENER_HOST: &str = "ARKDECK_LEASE_LISTENER_HOST";
const LISTENER_PORT: &str = "ARKDECK_LEASE_LISTENER_PORT";
const LISTENER_READY: &str = "ARKDECK_LEASE_LISTENER_READY";

/// A scanning test's turn, held for as long as the test has children so that
/// the running processes of the verified executable are only ever its own.
fn alone() -> MutexGuard<'static, ()> {
    static TURN: Mutex<()> = Mutex::new(());
    TURN.lock().unwrap_or_else(PoisonError::into_inner)
}

/// The listener process's body: selected by name in a re-execution of this
/// binary, it holds exactly one TCP listener on the named endpoint until it
/// is killed, and names itself listening by writing the file it was given.
/// Run as an ordinary test, it does nothing.
#[test]
fn listener_process() {
    let (Ok(host), Ok(port)) = (std::env::var(LISTENER_HOST), std::env::var(LISTENER_PORT)) else {
        return;
    };
    // The address is parsed, never looked up: binding must not wait on a
    // name service that a loaded host can keep waiting.
    let address = SocketAddrV4::new(host.parse().unwrap(), port.parse().unwrap());
    let _listener = TcpListener::bind(address).unwrap();
    fs::write(std::env::var(LISTENER_READY).unwrap(), b"listening").unwrap();
    loop {
        std::thread::sleep(Duration::from_secs(3600));
    }
}

/// The directory a test's listeners report themselves listening in.
struct Directory(PathBuf);

impl Directory {
    fn new() -> Self {
        let path = std::env::temp_dir().canonicalize().unwrap().join(format!(
            "arkdeck-lease-{:032x}",
            u128::from_le_bytes(random_bytes().unwrap())
        ));
        fs::create_dir(&path).unwrap();
        Self(path)
    }
}

impl Drop for Directory {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

/// This binary as the verified executable every listener runs.
struct Executable {
    path: PathBuf,
    tool: VerifiedTool,
    reports: Directory,
}

impl Executable {
    fn new() -> Self {
        let path = std::env::current_exe().unwrap().canonicalize().unwrap();
        let digest = format!("{:x}", Sha256::digest(fs::read(&path).unwrap()));
        let tool = VerifiedTool::open(&path, &digest).unwrap();
        Self {
            path,
            tool,
            reports: Directory::new(),
        }
    }

    /// One TCP listener on `host:port`, held by a process of this binary and
    /// listening by the time it is returned; no connection is ever made to
    /// it.
    fn listener(&self, host: &str, port: u16) -> Listener {
        let report = self.reports.0.join(format!("listening-{port}"));
        let child = Command::new(&self.path)
            .args(["--exact", "listener_process", "--test-threads", "1"])
            .env(LISTENER_HOST, host)
            .env(LISTENER_PORT, port.to_string())
            .env(LISTENER_READY, &report)
            .stdin(Stdio::null())
            // The harness prints a panicking child's reason on its stdout,
            // which is read only once the child is known to have exited.
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let mut listener = Listener(child);
        listener.wait_until_listening(&report);
        listener
    }
}

mod loopback_ports {
    include!("../../../tests/support/loopback_ports.rs");
}
use loopback_ports::free_port;

struct Listener(Child);

impl Listener {
    fn pid(&self) -> i32 {
        i32::try_from(self.0.id()).unwrap()
    }

    /// Waits until the child says it is listening, and stops the moment it
    /// exits instead: a child that never bound is reported as that, rather
    /// than left to look like an endpoint no process owns.
    fn wait_until_listening(&mut self, report: &Path) {
        let deadline = Instant::now() + Duration::from_secs(20);
        loop {
            if report.exists() {
                return;
            }
            if let Some(status) = self.0.try_wait().unwrap() {
                let mut reason = String::new();
                if let Some(stdout) = self.0.stdout.as_mut() {
                    let _ = stdout.read_to_string(&mut reason);
                }
                panic!("the listener exited before it listened: {status}\n{reason}");
            }
            assert!(
                Instant::now() < deadline,
                "the listener never reported itself listening"
            );
            std::thread::sleep(Duration::from_millis(10));
        }
    }
}

impl Drop for Listener {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

fn acquire_within(
    tool: &VerifiedTool,
    endpoint: SocketAddrV4,
    budget: Duration,
) -> std::io::Result<LoopbackServerLease> {
    let deadline = Instant::now() + budget;
    loop {
        match LoopbackServerLease::acquire(tool, endpoint) {
            Err(error) if error.kind() == ErrorKind::NotFound && Instant::now() < deadline => {
                std::thread::sleep(Duration::from_millis(50));
            }
            result => return result,
        }
    }
}

#[test]
fn an_existing_loopback_listener_of_the_verified_executable_is_proved_without_a_connect() {
    let _alone = alone();
    let this = Executable::new();
    let port = free_port();
    let mut listener = this.listener("127.0.0.1", port);
    let endpoint = SocketAddrV4::new(Ipv4Addr::LOCALHOST, port);
    let lease = acquire_within(&this.tool, endpoint, Duration::from_secs(5)).unwrap();
    let identity = lease.identity();
    assert_eq!(identity.pid, listener.pid());
    assert_eq!(identity.executable_path, this.path);
    assert_eq!(identity.executable_sha256, this.tool.sha256());
    assert_eq!(identity.endpoint, endpoint);
    assert!(identity.start_microseconds < 1_000_000);
    lease.revalidate().unwrap();
    // Proved without a word to it: the listener still runs, unspoken to.
    assert!(matches!(listener.0.try_wait(), Ok(None)));
    drop(listener);
    let deadline = Instant::now() + Duration::from_secs(5);
    while lease.revalidate().is_ok() && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(20));
    }
    let error = lease.revalidate().unwrap_err();
    assert_eq!(error.kind(), ErrorKind::PermissionDenied);
    assert!(error.to_string().contains("identity changed"));
}

#[test]
fn no_process_on_the_endpoint_is_unavailable_not_unknown() {
    let _alone = alone();
    let this = Executable::new();
    let endpoint = SocketAddrV4::new(Ipv4Addr::LOCALHOST, free_port());
    let error = LoopbackServerLease::acquire(&this.tool, endpoint).unwrap_err();
    assert_eq!(error.kind(), ErrorKind::NotFound);
    assert!(
        error
            .to_string()
            .contains("no existing selected HDC process")
    );
}

/// The population the scan walks changes under it: listeners of the verified
/// executable on other ports come and go while the endpoint is judged. A
/// listener that exits between being listed and being scanned owns nothing,
/// and the verdict for the endpoint stays `unavailable`, never `unknown`.
#[test]
fn listeners_of_the_executable_that_come_and_go_on_other_ports_do_not_disturb_the_verdict() {
    let _alone = alone();
    let this = Executable::new();
    let endpoint = SocketAddrV4::new(Ipv4Addr::LOCALHOST, free_port());
    let deadline = Instant::now() + Duration::from_secs(3);
    let mut scans = 0;
    while Instant::now() < deadline {
        let listeners: Vec<Listener> = (0..3)
            .map(|_| this.listener("127.0.0.1", free_port()))
            .collect();
        let error = LoopbackServerLease::acquire(&this.tool, endpoint).unwrap_err();
        assert_eq!(error.kind(), ErrorKind::NotFound, "{error}");
        drop(listeners);
        let error = LoopbackServerLease::acquire(&this.tool, endpoint).unwrap_err();
        assert_eq!(error.kind(), ErrorKind::NotFound, "{error}");
        scans += 2;
    }
    assert!(scans >= 2);
}

/// `/usr/bin/nc -l`, run from where it is installed, owns the endpoint: a
/// listener of another executable, however exact, is never the server.
#[test]
fn a_listener_owned_by_another_executable_is_not_the_server() {
    let _alone = alone();
    let this = Executable::new();
    let port = free_port();
    let other = Listener(
        Command::new("/usr/bin/nc")
            .args(["-l", "127.0.0.1", &port.to_string()])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap(),
    );
    // Listening is proved by the port refusing a second bind; a connection
    // would end `nc -l`.
    let deadline = Instant::now() + Duration::from_secs(5);
    while TcpListener::bind((Ipv4Addr::LOCALHOST, port)).is_ok() && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(20));
    }
    let endpoint = SocketAddrV4::new(Ipv4Addr::LOCALHOST, port);
    let error = LoopbackServerLease::acquire(&this.tool, endpoint).unwrap_err();
    assert_eq!(error.kind(), ErrorKind::NotFound, "{error}");
    drop(other);
}

#[test]
fn a_wildcard_listener_of_the_verified_executable_is_unknown() {
    let _alone = alone();
    let this = Executable::new();
    let port = free_port();
    let _listener = this.listener("0.0.0.0", port);
    let endpoint = SocketAddrV4::new(Ipv4Addr::LOCALHOST, port);
    let deadline = Instant::now() + Duration::from_secs(5);
    let error = loop {
        match LoopbackServerLease::acquire(&this.tool, endpoint) {
            Err(error) if error.kind() == ErrorKind::NotFound && Instant::now() < deadline => {
                std::thread::sleep(Duration::from_millis(50));
            }
            Err(error) => break error,
            Ok(_) => panic!("a wildcard listener must never prove the registered endpoint"),
        }
    };
    assert_eq!(error.kind(), ErrorKind::PermissionDenied);
    assert!(error.to_string().contains("unregistered listener address"));
}

#[test]
fn the_endpoint_must_be_the_exact_ipv4_loopback() {
    let this = Executable::new();
    for endpoint in [
        SocketAddrV4::new(Ipv4Addr::new(10, 0, 0, 1), 8710),
        SocketAddrV4::new(Ipv4Addr::UNSPECIFIED, 8710),
        SocketAddrV4::new(Ipv4Addr::LOCALHOST, 0),
    ] {
        let error = LoopbackServerLease::acquire(&this.tool, endpoint).unwrap_err();
        assert_eq!(error.kind(), ErrorKind::InvalidInput);
    }
}
