#![cfg(windows)]

use arkdeck_platform::{
    LocalConnection, LocalEndpoint, LocalListener, LoopbackServerLease, ServerIdentity,
    VerifiedTool, random_bytes,
};
use sha2::{Digest, Sha256};
use std::io::{self, Read, Write};
use std::net::{Ipv4Addr, SocketAddrV4, TcpListener};
use std::time::{Duration, Instant};

fn endpoint() -> LocalEndpoint {
    LocalEndpoint::new(format!(
        r"\\.\pipe\arkdeck-spk3-test-{:032x}",
        u128::from_le_bytes(random_bytes().unwrap())
    ))
}

#[test]
fn second_daemon_cannot_take_an_existing_pipe_name() {
    let endpoint = endpoint();
    let _listener = LocalListener::bind(&endpoint).unwrap();
    let error = LocalListener::bind(&endpoint)
        .err()
        .expect("duplicate daemon rejected");
    assert_eq!(error.kind(), io::ErrorKind::PermissionDenied);
    assert!(error.to_string().contains("Win32 error 5"));
}

#[test]
fn remote_pipe_name_is_not_a_supported_client_endpoint() {
    // This validates the public API boundary, not PIPE_REJECT_REMOTE_CLIENTS.
    // The latter requires a real remote Windows client in SPK-3.
    let endpoint = LocalEndpoint::new(r"\\remote\pipe\arkdeck-agentd");
    let identity = ServerIdentity::new(std::env::current_exe().unwrap());
    assert!(LocalConnection::connect(&endpoint, &identity).is_err());
    assert!(LocalListener::bind(&endpoint).is_err());
}

fn refused_before_first_byte(identity: ServerIdentity, expected_message: &str) {
    let endpoint = endpoint();
    let server_endpoint = endpoint.clone();
    let (ready_tx, ready_rx) = std::sync::mpsc::channel();
    let server = std::thread::spawn(move || {
        let mut listener = LocalListener::bind(&server_endpoint).unwrap();
        ready_tx.send(()).unwrap();
        let mut connection = listener.accept().unwrap();
        connection
            .set_read_timeout(Some(Duration::from_secs(3)))
            .unwrap();
        match connection.read(&mut [0u8; 1]) {
            Ok(0) => {}
            Err(error) if matches!(error.raw_os_error(), Some(109 | 233)) => {}
            result => panic!("untrusted server received data or remained connected: {result:?}"),
        }
    });
    ready_rx.recv_timeout(Duration::from_secs(5)).unwrap();
    let error = LocalConnection::connect(&endpoint, &identity)
        .err()
        .expect("untrusted server refused");
    assert!(error.to_string().contains(expected_message), "{error}");
    server.join().unwrap();
}

#[test]
fn same_account_wrong_image_is_refused_before_any_frame() {
    let system = std::env::var_os("SystemRoot").unwrap();
    let expected = std::path::PathBuf::from(system)
        .join("System32")
        .join("cmd.exe");
    refused_before_first_byte(ServerIdentity::new(expected), "image differs");
}

#[test]
fn same_image_without_product_signing_identity_is_refused_before_any_frame() {
    let mut identity = ServerIdentity::new(std::env::current_exe().unwrap());
    identity.authenticode_sha256 = Some("0".repeat(64));
    refused_before_first_byte(identity, "signing identity");
}

#[test]
fn missing_signing_and_package_configuration_has_no_implicit_fallback() {
    refused_before_first_byte(
        ServerIdentity::new(std::env::current_exe().unwrap()),
        "signing identity",
    );
}

#[test]
fn kernel_lease_requires_an_existing_exact_loopback_listener() {
    let path = std::env::current_exe().unwrap();
    let digest = format!("{:x}", Sha256::digest(std::fs::read(&path).unwrap()));
    let tool = VerifiedTool::open(path, &digest).unwrap();
    let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
    let endpoint = SocketAddrV4::new(Ipv4Addr::LOCALHOST, listener.local_addr().unwrap().port());
    let lease = LoopbackServerLease::acquire(&tool, endpoint).unwrap();
    lease.revalidate().unwrap();
    drop(listener);
    assert!(lease.revalidate().is_err());
    assert!(LoopbackServerLease::acquire(&tool, endpoint).is_err());
}

#[test]
fn rapid_disconnect_does_not_poison_listener_and_completed_reads_have_exact_counts() {
    let endpoint = endpoint();
    let mut listener = LocalListener::bind(&endpoint).unwrap();
    let connect = || {
        std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .open(endpoint.as_path())
            .unwrap()
    };
    for _ in 0..16 {
        drop(connect());
        match listener.accept() {
            Ok(mut connection) => assert_eq!(connection.read(&mut [0; 1]).unwrap(), 0),
            Err(error) => assert_eq!(error.kind(), io::ErrorKind::PermissionDenied, "{error}"),
        }
    }
    let mut client = connect();
    let mut server = listener.accept().unwrap();
    client.write_all(b"exact-count").unwrap();
    let mut buffer = [0; 32];
    assert_eq!(server.read(&mut buffer).unwrap(), 11);
    assert_eq!(&buffer[..11], b"exact-count");
    server.write_all(b"reply").unwrap();
    let mut reply = [0; 5];
    client.read_exact(&mut reply).unwrap();
    assert_eq!(&reply, b"reply");
    drop(client);
    assert_eq!(server.read(&mut buffer).unwrap(), 0);
}

#[test]
fn pending_read_and_write_cancel_safely_and_report_native_latency() {
    for writing in [false, true] {
        let endpoint = endpoint();
        let mut listener = LocalListener::bind(&endpoint).unwrap();
        let _silent_client = std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .open(endpoint.as_path())
            .unwrap();
        let mut server = listener.accept().unwrap();
        server
            .set_read_timeout(Some(Duration::from_millis(100)))
            .unwrap();
        server
            .set_write_timeout(Some(Duration::from_millis(100)))
            .unwrap();
        let started = Instant::now();
        let error = if writing {
            server.write(&vec![b'x'; 512 * 1024]).unwrap_err()
        } else {
            server.read(&mut [0; 64]).unwrap_err()
        };
        let elapsed = started.elapsed();
        eprintln!(
            "windows_pipe_{}_cancel_elapsed_ms={}",
            if writing { "write" } else { "read" },
            elapsed.as_millis()
        );
        assert_eq!(error.kind(), io::ErrorKind::TimedOut);
        assert!(
            elapsed < Duration::from_secs(5),
            "native cancellation exceeded the test budget: {elapsed:?}"
        );
    }
}

#[test]
fn peer_close_racing_timeout_completes_before_releasing_read_buffer() {
    for _ in 0..8 {
        let endpoint = endpoint();
        let mut listener = LocalListener::bind(&endpoint).unwrap();
        let client = std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .open(endpoint.as_path())
            .unwrap();
        let mut server = listener.accept().unwrap();
        server
            .set_read_timeout(Some(Duration::from_millis(25)))
            .unwrap();
        let closer = std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(25));
            drop(client);
        });
        let started = Instant::now();
        match server.read(&mut [0; 64]) {
            Ok(0) => {}
            Err(error) if error.kind() == io::ErrorKind::TimedOut => {}
            result => panic!("unexpected cancellation/close outcome: {result:?}"),
        }
        assert!(started.elapsed() < Duration::from_secs(5));
        closer.join().unwrap();
        assert_eq!(server.read(&mut [0; 64]).unwrap(), 0);
    }
}
