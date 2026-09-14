//! The macOS proof that an HDC server already exists (SPK-6, TASK-XPA-016):
//! a real listener process is found by executable path, single registered
//! loopback listener and birth identity, without any connect or spawn of the
//! observed tool. Spawning children, these tests keep a binary of their own.
#![cfg(target_os = "macos")]

use arkdeck_platform::{LoopbackServerLease, VerifiedTool};
use sha2::{Digest, Sha256};
use std::io::ErrorKind;
use std::net::{Ipv4Addr, SocketAddrV4, TcpListener};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

/// A listener process whose executable path the lease must recognise.
const NC: &str = "/usr/bin/nc";

fn nc_tool() -> VerifiedTool {
    let digest = format!("{:x}", Sha256::digest(std::fs::read(NC).unwrap()));
    VerifiedTool::open(NC, &digest).unwrap()
}

/// A port nothing listened on a moment ago.
fn free_port() -> u16 {
    TcpListener::bind((Ipv4Addr::LOCALHOST, 0))
        .unwrap()
        .local_addr()
        .unwrap()
        .port()
}

struct Listener(Child);

impl Listener {
    /// `nc -l <host> <port>`: one TCP listener, no connection ever made to it.
    fn spawn(host: Option<&str>, port: u16) -> Self {
        let mut command = Command::new(NC);
        command.arg("-l");
        if let Some(host) = host {
            command.arg(host);
        }
        command
            .arg(port.to_string())
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        Self(command.spawn().unwrap())
    }

    fn pid(&self) -> i32 {
        i32::try_from(self.0.id()).unwrap()
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
    let tool = nc_tool();
    let port = free_port();
    let mut listener = Listener::spawn(Some("127.0.0.1"), port);
    let endpoint = SocketAddrV4::new(Ipv4Addr::LOCALHOST, port);
    let lease = acquire_within(&tool, endpoint, Duration::from_secs(5)).unwrap();
    let identity = lease.identity();
    assert_eq!(identity.pid, listener.pid());
    assert_eq!(identity.executable_path, std::fs::canonicalize(NC).unwrap());
    assert_eq!(identity.executable_sha256, tool.sha256());
    assert_eq!(identity.endpoint, endpoint);
    assert!(identity.start_microseconds < 1_000_000);
    lease.revalidate().unwrap();
    // `nc -l` exits on its first connection; none was made.
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
    let tool = nc_tool();
    let endpoint = SocketAddrV4::new(Ipv4Addr::LOCALHOST, free_port());
    let error = LoopbackServerLease::acquire(&tool, endpoint).unwrap_err();
    assert_eq!(error.kind(), ErrorKind::NotFound);
    assert!(
        error
            .to_string()
            .contains("no existing selected HDC process")
    );
}

#[test]
fn a_listener_owned_by_another_executable_is_not_the_server() {
    let tool = nc_tool();
    let own = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
    let endpoint = SocketAddrV4::new(Ipv4Addr::LOCALHOST, own.local_addr().unwrap().port());
    let error = LoopbackServerLease::acquire(&tool, endpoint).unwrap_err();
    assert_eq!(error.kind(), ErrorKind::NotFound);
}

#[test]
fn a_wildcard_listener_of_the_verified_executable_is_unknown() {
    let tool = nc_tool();
    let port = free_port();
    let _listener = Listener::spawn(None, port);
    let endpoint = SocketAddrV4::new(Ipv4Addr::LOCALHOST, port);
    let deadline = Instant::now() + Duration::from_secs(5);
    let error = loop {
        match LoopbackServerLease::acquire(&tool, endpoint) {
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
    let tool = nc_tool();
    for endpoint in [
        SocketAddrV4::new(Ipv4Addr::new(10, 0, 0, 1), 8710),
        SocketAddrV4::new(Ipv4Addr::UNSPECIFIED, 8710),
        SocketAddrV4::new(Ipv4Addr::LOCALHOST, 0),
    ] {
        let error = LoopbackServerLease::acquire(&tool, endpoint).unwrap_err();
        assert_eq!(error.kind(), ErrorKind::InvalidInput);
    }
}
