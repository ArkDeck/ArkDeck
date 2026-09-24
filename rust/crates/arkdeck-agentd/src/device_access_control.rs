//! Production Host and Control `flash.device-access` through the real
//! observer, against a stand-in for `arkforged`'s public socket answered with
//! ArkForge's own IPC codec: each of the three answers Swift's daemon gave in
//! the committed control frames (a refused parameter, the refusal without a
//! daemon, two flashing modes), frame for frame. Host tests only: no daemon,
//! board or USB host is involved.
use arkdeck_contract::{CONTRACT_IDENTITY, PROTOCOL_VERSION};
use arkdeck_control::Control;
use arkdeck_provider_arkforge::DeviceAccessObserver;
use arkforge_ipc::framing::{read_frame, write_frame};
use arkforge_ipc::messages::{Hello, HelloAck, Request, Response};
use arkforge_ipc::{Api, PROTOCOL_MAJOR, PROTOCOL_MINOR, SessionKind, Status, wire};
use serde_json::{Value, json};
use std::os::unix::net::UnixListener;
use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};

const CORPUS: &str = include_str!(
    "../../../../Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames/flash.device-access.jsonl"
);

/// A lane runtime directory short enough for a socket path.
struct Root(PathBuf);

impl Root {
    fn new() -> Self {
        static NEXT: AtomicUsize = AtomicUsize::new(0);
        let root = PathBuf::from("/private/tmp").join(format!(
            "adda-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::create_dir(&root).unwrap();
        Self(root)
    }

    /// One public session answering `discoverDevices` with these modes; the
    /// requests it received.
    fn serve(&self, modes: &'static [&'static str]) -> std::thread::JoinHandle<Vec<Api>> {
        let listener = UnixListener::bind(self.0.join("public.sock")).unwrap();
        std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let hello = Hello::decode(&read_frame(&mut stream).unwrap().unwrap()).unwrap();
            assert_eq!(hello.session_kind, SessionKind::Public);
            let ack = HelloAck {
                protocol_major: PROTOCOL_MAJOR,
                protocol_minor: PROTOCOL_MINOR,
                session_kind: SessionKind::Public,
                daemon_version: "0.1.0".into(),
                refusal: None,
                execution_ready: false,
                execution_blockers: vec!["NO_PAIRED_AUTHORITY".into()],
                toolchain_id: String::new(),
                toolchain_sha256: String::new(),
            };
            write_frame(&mut stream, &ack.encode()).unwrap();
            let request = Request::decode(&read_frame(&mut stream).unwrap().unwrap()).unwrap();
            let mut payload = Vec::new();
            for (index, mode) in modes.iter().enumerate() {
                let mut observation = Vec::new();
                wire::write_string(&mut observation, 1, &format!("OBS-{index}"));
                wire::write_string(&mut observation, 3, mode);
                wire::write_message(&mut payload, 1, &observation);
            }
            let response = Response {
                request_id: request.request_id.clone(),
                api: request.api,
                status: Status::Ok,
                payload,
                stream_sequence: 0,
                stream_end: true,
            };
            write_frame(&mut stream, &response.encode()).unwrap();
            vec![request.api]
        })
    }
}

impl Drop for Root {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn control(root: &Root) -> Control<crate::host::Host> {
    Control::new(
        crate::host::Host::from_environment()
            .with_device_access(DeviceAccessObserver::new(&root.0)),
    )
    .unwrap()
}

/// The frame Swift recorded, answered by this Control, as `{ok, result|error}`.
fn answer(control: &Control<crate::host::Host>, frame: &Value) -> Value {
    let mut request = json!({
        "protocolVersion": PROTOCOL_VERSION, "contractIdentity": CONTRACT_IDENTITY,
        "id": "device-access", "method": "flash.device-access",
    });
    if let Some(params) = frame.get("params") {
        request["params"] = params.clone();
    }
    let reply: Value =
        serde_json::from_slice(&control.handle_frame(&serde_json::to_vec(&request).unwrap()))
            .unwrap();
    if reply["ok"] == true {
        json!({"ok": true, "result": reply["result"]})
    } else {
        json!({"ok": false, "error": reply["error"]})
    }
}

fn recorded(frame: &Value) -> Value {
    if frame["ok"] == true {
        json!({"ok": true, "result": frame["result"]})
    } else {
        json!({"ok": false, "error": frame["error"]})
    }
}

#[test]
fn each_answer_swifts_daemon_recorded_is_this_runtimes() {
    let frames: Vec<Value> = CORPUS
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect();
    assert!(frames.len() >= 3, "the corpus only grows");
    let mut compared = 0;
    for frame in &frames {
        let root = Root::new();
        let expected = recorded(frame);
        let server = (frame["ok"] == true).then(|| {
            // Swift's two modes, among the non-flashing modes ArkForge also
            // reports.
            root.serve(&["rockusb-loader", "hdc-normal", "maskrom"])
        });
        // A parameter is refused before any session; without a daemon the
        // session fails; with one, the modes are the answer.
        assert_eq!(answer(&control(&root), frame), expected, "{frame}");
        if let Some(server) = server {
            assert_eq!(server.join().unwrap(), [Api::DiscoverDevices]);
        }
        compared += 1;
    }
    assert_eq!(compared, frames.len());
    // A frame whose parameters Swift refuses never reaches the socket, even
    // when a daemon is serving it.
    let root = Root::new();
    let listener = UnixListener::bind(root.0.join("public.sock")).unwrap();
    listener.set_nonblocking(true).unwrap();
    let refused = answer(
        &control(&root),
        &json!({"params": {"socketPath": "/caller/path"}}),
    );
    assert_eq!(refused["error"]["code"], "invalidParams");
    assert!(listener.accept().is_err(), "no session was opened");
}
