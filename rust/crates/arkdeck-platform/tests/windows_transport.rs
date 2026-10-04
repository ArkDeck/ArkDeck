#![cfg(windows)]

use arkdeck_platform::{
    Latch, LocalConnection, LocalEndpoint, LocalListener, LoopbackServerLease, Readiness,
    ServerIdentity, VerifiedTool, random_bytes,
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
    assert!(
        error
            .to_string()
            .contains("is held by another instance (Win32 error 5)")
    );
}

#[test]
fn single_instance_squatter_is_refused_as_a_held_name() {
    use std::os::windows::ffi::OsStrExt;
    use std::os::windows::io::{FromRawHandle, OwnedHandle};
    use windows_sys::Win32::Foundation::INVALID_HANDLE_VALUE;
    use windows_sys::Win32::Storage::FileSystem::{
        FILE_FLAG_FIRST_PIPE_INSTANCE, PIPE_ACCESS_DUPLEX,
    };
    use windows_sys::Win32::System::Pipes::{
        CreateNamedPipeW, PIPE_READMODE_BYTE, PIPE_REJECT_REMOTE_CLIENTS, PIPE_TYPE_BYTE, PIPE_WAIT,
    };

    let endpoint = endpoint();
    // A same-account squatter that created the name first, allowing a single
    // instance, as the SPK-3 `raw-squat` probe does.
    let name: Vec<u16> = endpoint
        .as_path()
        .as_os_str()
        .encode_wide()
        .chain(Some(0))
        .collect();
    // SAFETY: NUL-terminated name alive for the synchronous call; default
    // security; the handle is owned at once.
    let raw = unsafe {
        CreateNamedPipeW(
            name.as_ptr(),
            PIPE_ACCESS_DUPLEX | FILE_FLAG_FIRST_PIPE_INSTANCE,
            PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
            1,
            4096,
            4096,
            5000,
            std::ptr::null(),
        )
    };
    assert_ne!(raw, INVALID_HANDLE_VALUE, "{}", io::Error::last_os_error());
    // SAFETY: a newly created, valid pipe handle, owned from here on.
    let _squatter = unsafe { OwnedHandle::from_raw_handle(raw) };

    let error = LocalListener::bind(&endpoint)
        .err()
        .expect("a squatted name refuses the daemon");
    assert_eq!(error.kind(), io::ErrorKind::PermissionDenied, "{error}");
    assert_eq!(error.raw_os_error(), None, "not the raw pipe-busy error");
    let message = error.to_string();
    assert!(
        message.contains(&format!(
            "named pipe {} is held by another instance (Win32 error 231)",
            endpoint.as_path().display()
        )),
        "{message}"
    );
    assert!(message.ends_with("daemon did not start"), "{message}");
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
        // The client refuses this server on identity and closes without a
        // frame. Whether the listener sees that as a connection that reads
        // end-of-pipe, or as `ConnectNamedPipe` completing on an already
        // closed client, depends only on scheduling; both are the refusal the
        // test asserts, and only data or a lingering client is a failure.
        let mut connection = match listener.accept() {
            Ok(connection) => connection,
            Err(error)
                if error.kind() == io::ErrorKind::PermissionDenied
                    && error
                        .to_string()
                        .contains("pipe client disconnected before authentication") =>
            {
                return;
            }
            Err(error) => panic!("untrusted server could not accept the client: {error}"),
        };
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

/// Maintainer ruling 17: a publisher identity with only one of its two values
/// refuses the server outright, even beside a certificate pin or a package
/// family, rather than silently not applying.
#[test]
fn partial_publisher_identity_is_refused_before_any_frame() {
    let mut identity = ServerIdentity::new(std::env::current_exe().unwrap());
    identity.package_family = Some("Contoso.ArkDeck_8wekyb3d8bbwe".into());
    identity.authenticode_sha256 = Some("0".repeat(64));
    identity.publisher_organization = Some("Contoso Ltd".into());
    refused_before_first_byte(identity, "partial daemon publisher identity");
}

/// An unsigned, unpackaged image satisfies neither a publisher identity nor
/// a package family.
#[test]
fn publisher_identity_or_package_family_without_their_proof_is_refused_before_any_frame() {
    let mut identity = ServerIdentity::new(std::env::current_exe().unwrap());
    identity.publisher_organization = Some("Contoso Ltd".into());
    identity.publisher_eku =
        Some("1.3.6.1.4.1.311.97.990309390.766961637.194916062.941502583".into());
    refused_before_first_byte(identity.clone(), "signing identity");
    identity.package_family = Some("Contoso.ArkDeck_8wekyb3d8bbwe".into());
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

fn client(endpoint: &LocalEndpoint) -> std::fs::File {
    std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open(endpoint.as_path())
        .unwrap()
}

#[test]
fn a_set_latch_ends_accepting_and_wins_over_a_waiting_client() {
    let endpoint = endpoint();
    let mut listener = LocalListener::bind(&endpoint).unwrap();
    let latch = std::sync::Arc::new(Latch::new().unwrap());
    // Set while accept waits: the wait ends without a connection.
    let setter = {
        let latch = std::sync::Arc::clone(&latch);
        std::thread::spawn(move || {
            // Not a synchronisation: set before or during the wait, the answer
            // is the same; the pause only makes the blocked wait the likely one.
            std::thread::sleep(Duration::from_millis(100));
            latch.set();
        })
    };
    assert!(listener.accept_until_latch(&latch).unwrap().is_none());
    setter.join().unwrap();
    assert!(latch.is_set());
    // A client already waiting is never accepted once the latch is set.
    let _waiting = client(&endpoint);
    for _ in 0..3 {
        assert!(listener.accept_until_latch(&latch).unwrap().is_none());
    }
    // Stopped listening, the name refuses a new client.
    drop(_waiting);
    let _lock = listener.stop_listening();
    assert!(
        std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .open(endpoint.as_path())
            .is_err()
    );
}

#[test]
fn an_unset_latch_accepts_the_next_client() {
    let endpoint = endpoint();
    let mut listener = LocalListener::bind(&endpoint).unwrap();
    let latch = Latch::new().unwrap();
    let mut client = client(&endpoint);
    let mut served = listener.accept_until_latch(&latch).unwrap().unwrap();
    client.write_all(b"x").unwrap();
    let mut byte = [0; 1];
    served.read_exact(&mut byte).unwrap();
    assert_eq!(&byte, b"x");
}

#[test]
fn a_connection_waits_for_its_next_byte_its_end_or_the_latch() {
    let endpoint = endpoint();
    let mut listener = LocalListener::bind(&endpoint).unwrap();
    let mut client = client(&endpoint);
    let served = listener.accept().unwrap();
    let latch = Latch::new().unwrap();
    assert_eq!(
        served
            .wait_readable(&latch, Duration::from_millis(100))
            .unwrap(),
        Readiness::TimedOut
    );
    client.write_all(b"{").unwrap();
    // Waiting reads nothing: the byte stays for the read.
    for _ in 0..2 {
        assert_eq!(
            served
                .wait_readable(&latch, Duration::from_secs(10))
                .unwrap(),
            Readiness::Readable
        );
    }
    latch.set();
    assert_eq!(
        served
            .wait_readable(&latch, Duration::from_secs(10))
            .unwrap(),
        Readiness::Latched
    );
    let mut served = served;
    let mut byte = [0; 1];
    served.read_exact(&mut byte).unwrap();
    assert_eq!(&byte, b"{");
    // A peer that has gone reads as readable; the read reports the end.
    let fresh = Latch::new().unwrap();
    drop(client);
    assert_eq!(
        served
            .wait_readable(&fresh, Duration::from_secs(10))
            .unwrap(),
        Readiness::Readable
    );
    assert_eq!(served.read(&mut byte).unwrap(), 0);
}

#[test]
fn a_closer_ends_a_blocked_read_and_every_later_transfer() {
    let endpoint = endpoint();
    let mut listener = LocalListener::bind(&endpoint).unwrap();
    let mut client = client(&endpoint);
    let mut served = listener.accept().unwrap();
    served
        .set_read_timeout(Some(Duration::from_secs(30)))
        .unwrap();
    served.write_all(b"reply").unwrap();
    let closer = served.closer().unwrap();
    let reading = std::thread::spawn(move || {
        let started = Instant::now();
        let count = served.read(&mut [0; 16]).unwrap();
        (count, started.elapsed(), served)
    });
    // Not a synchronisation: closed before or during the read, the
    // answer is the same; the pause makes the blocked read the likely one.
    std::thread::sleep(Duration::from_millis(200));
    closer.close();
    let (count, waited, mut served) = reading.join().unwrap();
    assert_eq!(count, 0);
    assert!(waited < Duration::from_secs(10), "{waited:?}");
    assert_eq!(served.read(&mut [0; 16]).unwrap(), 0);
    assert_eq!(
        served.write(b"late").unwrap_err().kind(),
        io::ErrorKind::BrokenPipe
    );
    let latch = Latch::new().unwrap();
    assert_eq!(
        served
            .wait_readable(&latch, Duration::from_secs(10))
            .unwrap(),
        Readiness::Readable
    );
    drop(served);
    drop(closer);
    // The reply written before the close still reaches the peer, then its end.
    let mut rest = Vec::new();
    client.read_to_end(&mut rest).unwrap();
    assert_eq!(rest, b"reply");
}

/// The foreground-console origin (maintainer ruling 2026-10-04) of a real
/// connection: its client is this test process, so the answer is what the
/// host says of this process: the daemon's own user (always, here) in the
/// session the console is attached to. On a console logon it is the
/// console; over Remote Desktop, in a service or on a runner without a
/// console session it is not.
#[test]
fn a_connection_s_console_origin_is_its_client_s_session_and_user() {
    use windows_sys::Win32::System::RemoteDesktop::{
        ProcessIdToSessionId, WTSGetActiveConsoleSessionId,
    };
    let endpoint = endpoint();
    let mut listener = LocalListener::bind(&endpoint).unwrap();
    let opener = {
        let endpoint = endpoint.clone();
        std::thread::spawn(move || client(&endpoint))
    };
    let connection = listener.accept().unwrap();
    let _client = opener.join().unwrap();
    let mut session = 0;
    // SAFETY: valid output storage for the synchronous call.
    assert_ne!(
        unsafe { ProcessIdToSessionId(std::process::id(), &mut session) },
        0
    );
    // SAFETY: no arguments.
    let active = unsafe { WTSGetActiveConsoleSessionId() };
    let expected = active != 0xFFFF_FFFF && active == session;
    eprintln!("session {session}, active console session {active:#x}: console {expected}");
    assert_eq!(connection.foreground_console(), expected);
}
