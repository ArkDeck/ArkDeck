//! Native typed client preview against local Unix socket fixtures. No daemon,
//! artifact import, Job, permit, device or installed Runtime is involved.
#![cfg(unix)]
use arkdeck_provider_arkforge::{
    LanePlanPreview, LanePreview, LanePreviewHost, NativePlanConnections,
    authority_support::Configuration,
};
use arkforge_ipc::framing::{read_frame, write_frame};
use arkforge_ipc::messages::{
    Assessment, ErrorBody, ExecutablePlan, Hello, HelloAck, InspectArtifactResponse,
    MaterializePlanResponse, Request, Response,
};
use arkforge_ipc::{Api, PROTOCOL_MAJOR, PROTOCOL_MINOR, SessionKind, Status, wire};
use std::{
    fs,
    os::unix::net::{UnixListener, UnixStream},
    path::PathBuf,
    sync::{Arc, Mutex},
    thread,
    time::{Duration, Instant},
};

struct Root(PathBuf);
impl Root {
    fn new() -> Self {
        let path = PathBuf::from("/tmp").join(format!(
            "ap-{}-{}",
            std::process::id(),
            u64::from_ne_bytes(arkdeck_platform::random_bytes::<8>().unwrap())
        ));
        fs::create_dir(&path).unwrap();
        Self(path)
    }
}
impl Drop for Root {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

// As the platform HTTP fixtures do, bound the nonblocking accept itself.
// A client regression before opening the public connection must fail this
// fixture instead of blocking the subsequent join forever.
fn accept_before(listener: &UnixListener, deadline: Instant) -> std::io::Result<UnixStream> {
    listener.set_nonblocking(true)?;
    loop {
        match listener.accept() {
            Ok((stream, _)) => {
                // Darwin inherits O_NONBLOCK from the listening socket.
                stream.set_nonblocking(false)?;
                return Ok(stream);
            }
            Err(error)
                if matches!(
                    error.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::Interrupted
                ) =>
            {
                if Instant::now() >= deadline {
                    return Err(std::io::Error::new(
                        std::io::ErrorKind::TimedOut,
                        "preview fixture received no client before its accept deadline",
                    ));
                }
                thread::yield_now();
            }
            Err(error) => return Err(error),
        }
    }
}

#[test]
fn fixture_without_a_client_has_a_bounded_accept() {
    let root = Root::new();
    let listener = UnixListener::bind(root.0.join("unconnected.sock")).unwrap();
    assert_eq!(
        accept_before(&listener, Instant::now() + Duration::from_millis(10))
            .unwrap_err()
            .kind(),
        std::io::ErrorKind::TimedOut
    );
}

fn serve(
    listener: UnixListener,
    kind: SessionKind,
    mode: &'static str,
    calls: Arc<Mutex<Vec<String>>>,
) -> thread::JoinHandle<()> {
    thread::spawn(move || {
        let mut stream = accept_before(&listener, Instant::now() + Duration::from_secs(5)).unwrap();
        stream
            .set_read_timeout(Some(Duration::from_secs(5)))
            .unwrap();
        let hello = Hello::decode(&read_frame(&mut stream).unwrap().unwrap()).unwrap();
        assert_eq!(hello.session_kind, kind);
        write_frame(
            &mut stream,
            &HelloAck {
                protocol_major: PROTOCOL_MAJOR,
                protocol_minor: PROTOCOL_MINOR,
                session_kind: kind,
                daemon_version: "fixture".into(),
                refusal: None,
                execution_ready: true,
                execution_blockers: Vec::new(),
                toolchain_id: "arkforged-native-rockusb".into(),
                toolchain_sha256: "11".repeat(32),
            }
            .encode(),
        )
        .unwrap();
        while let Some(frame) = read_frame(&mut stream).unwrap() {
            let request = Request::decode(&frame).unwrap();
            calls
                .lock()
                .unwrap()
                .push(format!("{kind:?}:{:?}", request.api));
            let (status, payload) = match request.api {
                Api::InspectArtifact if mode == "missing" => (
                    Status::Refused,
                    ErrorBody {
                        code: "NOT_FOUND".into(),
                        message: "fixture store is empty".into(),
                    }
                    .encode(),
                ),
                Api::InspectArtifact => (
                    Status::Ok,
                    InspectArtifactResponse {
                        content_sha256: "ee".repeat(32),
                        ..InspectArtifactResponse::default()
                    }
                    .encode(),
                ),
                Api::DiscoverDevices => (
                    Status::Ok,
                    if mode == "unobserved" {
                        Vec::new()
                    } else {
                        observation()
                    },
                ),
                Api::MaterializePlan => (Status::Ok, plan_reply(kind, mode, &request.payload)),
                other => panic!("preview issued an unexpected API: {other:?}"),
            };
            write_frame(
                &mut stream,
                &Response {
                    request_id: request.request_id,
                    api: request.api,
                    status,
                    payload,
                    stream_sequence: 0,
                    stream_end: true,
                }
                .encode(),
            )
            .unwrap();
        }
    })
}

#[test]
fn native_preview_uses_sdk_inspection_and_discovery_without_import_or_execution() {
    for mode in ["missing", "unobserved", "available", "public-plan"] {
        let missing = mode == "missing";
        let root = Root::new();
        let calls = Arc::new(Mutex::new(Vec::new()));
        let controller = serve(
            UnixListener::bind(root.0.join("controller.sock")).unwrap(),
            SessionKind::Controller,
            mode,
            calls.clone(),
        );
        let public = (!missing).then(|| {
            serve(
                UnixListener::bind(root.0.join("public.sock")).unwrap(),
                SessionKind::Public,
                mode,
                calls.clone(),
            )
        });
        fs::write(root.0.join("immutable-artifact"), b"unchanged fixture").unwrap();
        let preview = LanePreviewHost::new(
            Box::new(NativePlanConnections(root.0.clone())),
            support(),
            "org.openharmony.dayu200".into(),
        );
        let result = preview.preview(&"ee".repeat(32), "17956864");
        controller.join().unwrap();
        if let Some(public) = public {
            public.join().unwrap();
        }
        if missing {
            assert_eq!(result, LanePreview::BundleNotInLaneStore);
            assert_eq!(*calls.lock().unwrap(), ["Controller:InspectArtifact"]);
        } else if mode == "unobserved" {
            assert!(
                matches!(result, LanePreview::DeviceNotObserved(_)),
                "{result:?}"
            );
            assert_eq!(
                *calls.lock().unwrap(),
                [
                    "Controller:InspectArtifact",
                    "Public:InspectArtifact",
                    "Public:DiscoverDevices"
                ]
            );
        }
        if mode == "available" {
            assert_eq!(
                result,
                LanePreview::Available {
                    plan_id: "PLAN-preview".into(),
                    plan_sha256: "dd".repeat(32),
                    observation_mode: "hdc-normal".into()
                }
            );
            assert_eq!(
                *calls.lock().unwrap(),
                [
                    "Controller:InspectArtifact",
                    "Public:InspectArtifact",
                    "Public:DiscoverDevices",
                    "Public:MaterializePlan",
                    "Controller:DiscoverDevices",
                    "Controller:MaterializePlan",
                    "Controller:MaterializePlan"
                ]
            );
        } else if mode == "public-plan" {
            assert_eq!(
                result,
                LanePreview::PlanNotExecutable {
                    availability: "unusable".into(),
                    reason: "the public ArkForge endpoint returned an executable plan".into(),
                    unknowns: [(
                        "publicPlan".into(),
                        "assessment-only boundary was bypassed".into()
                    )]
                    .into_iter()
                    .collect()
                }
            );
            assert_eq!(
                *calls.lock().unwrap(),
                [
                    "Controller:InspectArtifact",
                    "Public:InspectArtifact",
                    "Public:DiscoverDevices",
                    "Public:MaterializePlan"
                ]
            );
        }
        assert_eq!(
            fs::read(root.0.join("immutable-artifact")).unwrap(),
            b"unchanged fixture"
        );
        assert_eq!(
            fs::read_dir(&root.0).unwrap().count(),
            if missing { 2 } else { 3 }
        );
    }
}

fn support() -> Configuration {
    Configuration::new(&"22".repeat(32), &"33".repeat(32), "fixture-campaign")
}

// Fixture messages use the upstream wire primitives and message encoders;
// production has no second codec or raw socket exchange implementation.
fn observation() -> Vec<u8> {
    let mut observation = Vec::new();
    for (field, value) in [
        (1, "OBS-preview".into()),
        (3, "hdc-normal".into()),
        (
            4,
            arkdeck_provider_arkforge::topology_digest("17956864").unwrap(),
        ),
        (5, "cc".repeat(32)),
        (6, "serialAndTopology".into()),
    ] {
        wire::write_string(&mut observation, field, &value);
    }
    let mut list = Vec::new();
    wire::write_message(&mut list, 1, &observation);
    list
}

fn plan_reply(kind: SessionKind, mode: &str, payload: &[u8]) -> Vec<u8> {
    let mut reader = wire::Reader::new(payload);
    let mut fields = std::collections::BTreeMap::new();
    while let Some((field, value)) = reader.next_field().unwrap() {
        fields.insert(field, value);
    }
    assert_eq!(fields[&1].as_str(1).unwrap(), "ee".repeat(32));
    assert_eq!(fields[&2].as_str(2).unwrap(), "org.openharmony.dayu200");
    assert_eq!(fields[&3].as_str(3).unwrap(), "OBS-preview");
    let mechanics = "99".repeat(32);
    if kind == SessionKind::Public {
        assert_eq!(fields.keys().copied().collect::<Vec<_>>(), [1, 2, 3, 4]);
        return if mode == "public-plan" {
            MaterializePlanResponse::Plan(ExecutablePlan::default())
        } else {
            MaterializePlanResponse::Assessment(Assessment {
                mechanics_maturity_key_sha256: mechanics,
                ..Assessment::default()
            })
        }
        .encode();
    }
    assert_eq!(fields[&7].as_str(7).unwrap(), "PREVIEW-eeeeeeeeeeee");
    assert_eq!(fields[&8].as_u64().unwrap(), 1);
    assert_eq!(fields[&10].as_str(10).unwrap(), "primaryFlash");
    let state = fields[&12].as_str(12).unwrap();
    if state == "hardwareGated" {
        let key = arkdeck_provider_arkforge::authority_support::pending_key_sha256();
        assert_eq!(fields[&11].as_bytes().unwrap(), key);
        return MaterializePlanResponse::Assessment(Assessment {
            mechanics_maturity_key_sha256: mechanics,
            mechanics_maturity_state: "hardwareCampaign".into(),
            authority_support_key_sha256: key.iter().map(|b| format!("{b:02x}")).collect(),
            authority_support_state: "hardwareGated".into(),
            ..Assessment::default()
        })
        .encode();
    }
    let seal = support().seal(&mechanics).unwrap();
    assert_eq!(state, seal.state);
    assert_eq!(fields[&11].as_bytes().unwrap(), seal.key_sha256);
    MaterializePlanResponse::Plan(ExecutablePlan {
        plan_id: "PLAN-preview".into(),
        plan_sha256: "dd".repeat(32),
        execution_purpose: "primaryFlash".into(),
        mechanics_maturity_key_sha256: mechanics,
        mechanics_maturity_state: "hardwareCampaign".into(),
        mechanics_maturity_campaign: "fixture-campaign".into(),
        authority_support_key_sha256: seal.key_hex(),
        authority_support_state: seal.state.clone(),
        authority_support_campaign: seal.campaign().into(),
        ..ExecutablePlan::default()
    })
    .encode()
}
