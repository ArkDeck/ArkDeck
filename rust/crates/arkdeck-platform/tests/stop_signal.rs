//! The daemon's stop request and the listener that stops for it. The stop
//! handler is process-wide, so these checks keep a test binary of their own,
//! and the one test that sends SIGTERM to this process is the only one that
//! waits on the listener.
#![cfg(unix)]

use arkdeck_platform::{
    LocalConnection, LocalEndpoint, LocalListener, ServerIdentity, StopSignal, random_bytes,
};
use std::fs;
use std::io::{Read, Write};
use std::os::unix::process::ExitStatusExt;
use std::path::PathBuf;
use std::process::Command;
use std::sync::OnceLock;
use std::time::{Duration, Instant};

struct Directory(PathBuf);
impl Directory {
    fn new() -> Self {
        let nonce = u64::from_le_bytes(random_bytes().unwrap());
        let path = std::env::temp_dir()
            .canonicalize()
            .unwrap()
            .join(format!("ad-stop-{nonce:016x}"));
        Self(path)
    }
    fn endpoint(&self) -> LocalEndpoint {
        LocalEndpoint::new(self.0.join("control.sock"))
    }
}
impl Drop for Directory {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn stop() -> &'static StopSignal {
    static STOP: OnceLock<StopSignal> = OnceLock::new();
    STOP.get_or_init(|| StopSignal::install().unwrap())
}

fn identity() -> ServerIdentity {
    ServerIdentity::new("/unused/on/unix")
}

#[test]
fn a_requested_stop_ends_accepting_and_stays_requested() {
    let stop = stop();
    assert!(
        StopSignal::install().is_err(),
        "one stop request per process"
    );
    let directory = Directory::new();
    let endpoint = directory.endpoint();
    let mut listener = LocalListener::bind(&endpoint).unwrap();

    // Before any stop, a connection is accepted and served as by accept().
    let client_endpoint = endpoint.clone();
    let client = std::thread::spawn(move || {
        let mut client = LocalConnection::connect(&client_endpoint, &identity()).unwrap();
        client.write_all(b"ping\n").unwrap();
        let mut reply = [0; 5];
        client.read_exact(&mut reply).unwrap();
        reply
    });
    let mut accepted = listener.accept_until(stop).unwrap().expect("a connection");
    let mut bytes = [0; 5];
    accepted.read_exact(&mut bytes).unwrap();
    assert_eq!(&bytes, b"ping\n");
    accepted.write_all(b"pong\n").unwrap();
    assert_eq!(&client.join().unwrap(), b"pong\n");
    assert!(!stop.requested());

    // SIGTERM to this very process is recorded, not acted on.
    signal_self(libc::SIGTERM);
    let deadline = Instant::now() + Duration::from_secs(10);
    while !stop.requested() {
        assert!(Instant::now() < deadline, "the stop was never recorded");
        std::thread::sleep(Duration::from_millis(5));
    }

    // A waiting client is never accepted once the stop is requested, and
    // the request is still there on every later look.
    let waiting = LocalConnection::connect(&endpoint, &identity()).unwrap();
    for _ in 0..3 {
        assert!(listener.accept_until(stop).unwrap().is_none());
        assert!(stop.requested());
    }
    drop(waiting);

    // A second signal is recorded as well and changes nothing.
    signal_self(libc::SIGINT);
    assert!(listener.accept_until(stop).unwrap().is_none());

    // Stopping the listener removes its name: a client is refused now.
    let _lock = listener.stop_listening();
    assert!(!endpoint.as_path().exists());
    assert!(LocalConnection::connect(&endpoint, &identity()).is_err());
}

#[test]
fn a_launched_child_keeps_the_default_stop_action() {
    let _stop = stop();
    // A caught signal is reset to its default across exec: the child ends
    // by the SIGTERM it sends itself.
    let status = Command::new("/bin/sh")
        .args(["-c", "kill -TERM $$; exit 0"])
        .status()
        .unwrap();
    assert_eq!(status.signal(), Some(libc::SIGTERM));
}

fn signal_self(signal: libc::c_int) {
    // SAFETY: signals this test process, whose handler only records it.
    assert_eq!(unsafe { libc::kill(libc::getpid(), signal) }, 0);
}

#[test]
fn a_closer_ends_a_read_waiting_on_another_thread() {
    let directory = Directory::new();
    let endpoint = directory.endpoint();
    let mut listener = LocalListener::bind(&endpoint).unwrap();
    let client_endpoint = endpoint.clone();
    let client = std::thread::spawn(move || {
        let mut client = LocalConnection::connect(&client_endpoint, &identity()).unwrap();
        let mut rest = Vec::new();
        client.read_to_end(&mut rest).unwrap();
        rest
    });
    let mut accepted = listener.accept().unwrap();
    let closer = accepted.closer().unwrap();
    let reader = std::thread::spawn(move || {
        let started = Instant::now();
        let mut byte = [0; 1];
        let read = accepted.read(&mut byte);
        (read.ok(), started.elapsed())
    });
    std::thread::sleep(Duration::from_millis(100));
    closer.close();
    let (read, waited) = reader.join().unwrap();
    assert_eq!(read, Some(0));
    assert!(waited < Duration::from_secs(5), "{waited:?}");
    // The peer sees the end of the stream too.
    assert!(client.join().unwrap().is_empty());
}

#[cfg(target_os = "macos")]
#[test]
fn a_stopped_facade_keeps_its_directory_until_the_lock_is_released() {
    let directory = Directory::new();
    fs::create_dir(&directory.0).unwrap();
    fs::set_permissions(
        &directory.0,
        std::os::unix::fs::PermissionsExt::from_mode(0o700),
    )
    .unwrap();
    let endpoint = directory.endpoint();
    let listener = LocalListener::bind_facade(&endpoint).unwrap();
    let lock = listener.stop_listening();
    assert!(!endpoint.as_path().exists());
    // No socket, yet no second owner while the first still drains.
    let refused = LocalListener::bind_facade(&endpoint)
        .err()
        .expect("the directory is still owned");
    assert_eq!(refused.kind(), std::io::ErrorKind::PermissionDenied);
    drop(lock);
    let second = LocalListener::bind_facade(&endpoint).unwrap();
    assert!(endpoint.as_path().exists());
    drop(second);
}
