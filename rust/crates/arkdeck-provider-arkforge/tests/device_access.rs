//! The device access observer against a stand-in for `arkforged`'s public
//! socket, spoken with ArkForge's own IPC codec at the pinned revision: the
//! handshake, one `discoverDevices`, and each way that can go wrong. No
//! daemon, board or USB host is involved.
#![cfg(unix)]

use arkdeck_provider_arkforge::{DeviceAccessFailure, DeviceAccessObserver, DeviceMode};
use arkforge_ipc::framing::{read_frame, write_frame};
use arkforge_ipc::messages::{ErrorBody, Hello, HelloAck, Request, Response};
use arkforge_ipc::{Api, PROTOCOL_MAJOR, PROTOCOL_MINOR, SessionKind, Status, wire};
use std::os::unix::net::UnixListener;
use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

/// A runtime directory short enough for a socket path on every host.
struct Root(PathBuf);

impl Root {
    fn new() -> Self {
        static NEXT: AtomicUsize = AtomicUsize::new(0);
        let base = if cfg!(target_os = "macos") {
            PathBuf::from("/private/tmp")
        } else {
            std::env::temp_dir()
        };
        let root = base.join(format!(
            "adpa-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::create_dir(&root).unwrap();
        Self(root)
    }
}

impl Drop for Root {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// What the stand-in answers once a session opens.
enum Answer {
    /// The handshake, refused.
    Refusal(&'static str),
    /// `discoverDevices`, answered with one observation per mode.
    Modes(&'static [&'static str]),
    /// `discoverDevices`, failed with ArkForge's code and words.
    Failure(&'static str, &'static str),
    /// Acknowledged, then silent for longer than any bound here.
    Silence,
    /// An observation that names no observation.
    Nameless,
}

fn acknowledgement(refusal: Option<&str>) -> HelloAck {
    HelloAck {
        protocol_major: PROTOCOL_MAJOR,
        protocol_minor: PROTOCOL_MINOR,
        session_kind: SessionKind::Public,
        daemon_version: "0.1.0".into(),
        refusal: refusal.map(str::to_owned),
        execution_ready: false,
        execution_blockers: vec!["NO_PAIRED_AUTHORITY".into()],
        toolchain_id: String::new(),
        toolchain_sha256: String::new(),
    }
}

fn observations(modes: &[&str], identify: bool) -> Vec<u8> {
    let mut payload = Vec::new();
    for (index, mode) in modes.iter().enumerate() {
        let mut observation = Vec::new();
        if identify {
            wire::write_string(&mut observation, 1, &format!("OBS-{index}"));
        }
        wire::write_uint64(&mut observation, 2, 1_770_000_000_000);
        wire::write_string(&mut observation, 3, mode);
        wire::write_string(&mut observation, 6, "serialAndTopology");
        wire::write_message(&mut payload, 1, &observation);
    }
    payload
}

/// Serves one session in `root`, and returns the requests it received.
fn serve(root: &Root, answer: Answer) -> JoinHandle<Vec<Request>> {
    let listener = UnixListener::bind(root.0.join("public.sock")).unwrap();
    std::thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        let hello = Hello::decode(&read_frame(&mut stream).unwrap().unwrap()).unwrap();
        assert_eq!(hello.session_kind, SessionKind::Public);
        assert_eq!(hello.protocol_major, PROTOCOL_MAJOR);
        let refusal = match answer {
            Answer::Refusal(reason) => Some(reason),
            _ => None,
        };
        write_frame(&mut stream, &acknowledgement(refusal).encode()).unwrap();
        if refusal.is_some() {
            return Vec::new();
        }
        let request = Request::decode(&read_frame(&mut stream).unwrap().unwrap()).unwrap();
        let (status, payload) = match answer {
            Answer::Modes(modes) => (Status::Ok, observations(modes, true)),
            Answer::Nameless => (Status::Ok, observations(&["rockusb-loader"], false)),
            Answer::Failure(code, message) => (
                Status::Internal,
                ErrorBody {
                    code: code.into(),
                    message: message.into(),
                }
                .encode(),
            ),
            Answer::Silence => {
                std::thread::sleep(Duration::from_secs(2));
                return vec![request];
            }
            Answer::Refusal(_) => unreachable!(),
        };
        let response = Response {
            request_id: request.request_id.clone(),
            api: request.api,
            status,
            payload,
            stream_sequence: 0,
            stream_end: true,
        };
        write_frame(&mut stream, &response.encode()).unwrap();
        vec![request]
    })
}

#[test]
fn the_flashing_modes_the_daemon_sees_are_read_through_one_public_session() {
    let root = Root::new();
    let server = serve(
        &root,
        Answer::Modes(&[
            "rockusb-loader",
            "hdc-normal",
            "loader",
            "rockusb-maskrom",
            "normal",
            "maskrom",
        ]),
    );
    let modes = DeviceAccessObserver::new(&root.0).observe().unwrap();
    assert_eq!(
        modes,
        [
            DeviceMode::Loader,
            DeviceMode::Loader,
            DeviceMode::Maskrom,
            DeviceMode::Maskrom
        ]
    );
    // Exactly one call, `discoverDevices` with an empty request.
    let requests = server.join().unwrap();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].api, Api::DiscoverDevices);
    assert!(requests[0].payload.is_empty());
}

#[test]
fn nothing_attached_is_an_empty_answer_and_not_a_failure() {
    let root = Root::new();
    let server = serve(&root, Answer::Modes(&[]));
    assert_eq!(DeviceAccessObserver::new(&root.0).observe(), Ok(Vec::new()));
    server.join().unwrap();
    let root = Root::new();
    let server = serve(&root, Answer::Modes(&["hdc-normal"]));
    assert_eq!(DeviceAccessObserver::new(&root.0).observe(), Ok(Vec::new()));
    server.join().unwrap();
}

#[test]
fn an_unreachable_or_refusing_daemon_and_a_failed_discovery_are_failures() {
    let root = Root::new();
    let Err(DeviceAccessFailure::Client { code, .. }) =
        DeviceAccessObserver::new(&root.0).observe()
    else {
        panic!("no daemon is no answer");
    };
    assert_eq!(code, "DAEMON_UNAVAILABLE");

    let server = serve(
        &root,
        Answer::Refusal("protocol major 2 is not compatible with 1"),
    );
    let Err(DeviceAccessFailure::Client { code, .. }) =
        DeviceAccessObserver::new(&root.0).observe()
    else {
        panic!("a refused session is no answer");
    };
    assert_eq!(code, "PROTOCOL_REFUSED");
    server.join().unwrap();

    std::fs::remove_file(root.0.join("public.sock")).unwrap();
    let server = serve(
        &root,
        Answer::Failure("DISCOVERY_FAILED", "the USB transport is unavailable"),
    );
    assert_eq!(
        DeviceAccessObserver::new(&root.0).observe(),
        Err(DeviceAccessFailure::Client {
            code: "DISCOVERY_FAILED".into(),
            message: "the USB transport is unavailable".into(),
        })
    );
    server.join().unwrap();
}

#[test]
fn a_daemon_that_never_answers_is_bounded() {
    let root = Root::new();
    let server = serve(&root, Answer::Silence);
    let started = Instant::now();
    assert_eq!(
        DeviceAccessObserver::new(&root.0)
            .with_timeout(Duration::from_millis(300))
            .observe(),
        Err(DeviceAccessFailure::TimedOut)
    );
    assert!(started.elapsed() < Duration::from_secs(2));
    // It asked, and got no answer in time.
    assert_eq!(server.join().unwrap().len(), 1);
}

/// ArkForge's Rust client refuses an observation without an identity, where
/// the Swift SDK would have counted it: a declared, fail-closed difference.
#[test]
fn an_observation_that_names_no_observation_is_refused() {
    let root = Root::new();
    let server = serve(&root, Answer::Nameless);
    let Err(DeviceAccessFailure::Client { code, .. }) =
        DeviceAccessObserver::new(&root.0).observe()
    else {
        panic!("a nameless observation is no answer");
    };
    assert_eq!(code, "IPC_RESPONSE_INVALID");
    server.join().unwrap();
}
