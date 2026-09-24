//! Swift `ProductArkForgeLoaderObserver` as the flash facts compose it: the
//! Runtime's USB census names the bound Loader and its port, and a stand-in
//! for the ArkForge lane daemon's public socket, spoken with ArkForge's own
//! codec, must independently hold exactly one settled DAYU200 RockUSB Loader
//! there. Each refusal is Swift's. No daemon, board or USB host is involved.
#![cfg(target_os = "macos")]

use arkdeck_contract::sha256_hex;
use arkdeck_hoststore::ArkForgeLoader;
use arkdeck_platform::UsbHostDevice;
use arkdeck_provider_arkforge::topology_digest;
use arkdeck_provider_hdc::{LoaderIdentity, LoaderObserver};
use arkforge_ipc::framing::{read_frame, write_frame};
use arkforge_ipc::messages::{Hello, HelloAck, KeyValue, Request, Response};
use arkforge_ipc::{PROTOCOL_MAJOR, PROTOCOL_MINOR, SessionKind, Status, wire};
use std::os::unix::net::UnixListener;
use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};

const SERIAL: &str = "loader-serial-0451";
const PORT: &str = "17956864";

struct Root(PathBuf);

impl Root {
    fn new() -> Self {
        static NEXT: AtomicUsize = AtomicUsize::new(0);
        let root = PathBuf::from("/private/tmp").join(format!(
            "adal-{}-{}",
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

/// One observation the stand-in reports: its port, mode and USB identity.
struct Seen(&'static str, &'static str, &'static str);

/// One public session answering `discoverDevices` with these observations.
fn serve(root: &Root, seen: Vec<Seen>) -> std::thread::JoinHandle<()> {
    let listener = UnixListener::bind(root.0.join("public.sock")).unwrap();
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
            execution_ready: true,
            execution_blockers: Vec::new(),
            toolchain_id: "arkforged-native-rockusb".into(),
            toolchain_sha256: "0".repeat(64),
        };
        write_frame(&mut stream, &ack.encode()).unwrap();
        let request = Request::decode(&read_frame(&mut stream).unwrap().unwrap()).unwrap();
        let mut payload = Vec::new();
        for (index, Seen(port, mode, identity)) in seen.iter().enumerate() {
            let mut observation = Vec::new();
            wire::write_string(&mut observation, 1, &format!("USB-{index}"));
            wire::write_string(&mut observation, 3, mode);
            wire::write_string(&mut observation, 4, &topology_digest(port).unwrap());
            wire::write_string(&mut observation, 6, "serialAndTopology");
            wire::write_message(
                &mut observation,
                8,
                &KeyValue {
                    key: "usb.identity".into(),
                    value: (*identity).into(),
                }
                .encode(),
            );
            wire::write_message(&mut payload, 1, &observation);
        }
        let response = Response {
            request_id: request.request_id,
            api: request.api,
            status: Status::Ok,
            payload,
            stream_sequence: 0,
            stream_end: true,
        };
        write_frame(&mut stream, &response.encode()).unwrap();
    })
}

fn loader(serial: &str, port: &str) -> UsbHostDevice {
    UsbHostDevice {
        serial: serial.into(),
        vendor_id: 0x2207,
        product_id: 0x350a,
        topology: port.into(),
        product_name: None,
        registry_entry_id: Some(0x1_0000_0042),
    }
}

/// The product Loader observation over `devices` and the lane directory
/// `root`, as the live probe calls it.
fn observe(
    root: &Root,
    devices: Vec<UsbHostDevice>,
    admitted: Option<&str>,
) -> Result<LoaderIdentity, String> {
    ArkForgeLoader::new(move || Ok(devices.clone()), &root.0).observe_loader(
        &sha256_hex(SERIAL.as_bytes()),
        admitted,
        "live-mode-1",
    )
}

#[test]
fn the_census_and_the_lane_daemon_agree_on_the_bound_loader() {
    let root = Root::new();
    let daemon = serve(
        &root,
        vec![
            Seen("19922944", "hdc-normal", "0x2207:0x5000"),
            Seen(PORT, "rockusb-loader", "0x2207:0x350a"),
        ],
    );
    assert_eq!(
        observe(&root, vec![loader(SERIAL, PORT)], Some(PORT)),
        Ok(LoaderIdentity {
            serial_digest_sha256: sha256_hex(SERIAL.as_bytes()),
            topology: PORT.into(),
        })
    );
    daemon.join().unwrap();
}

#[test]
fn the_census_must_see_the_exact_loader_at_its_admitted_port_first() {
    let root = Root::new();
    // No session is opened for any of these.
    assert_eq!(
        observe(&root, Vec::new(), None).unwrap_err(),
        "IOKit did not observe the exact bound Loader: admissionRejected(\"DAYU200 target \
         unavailable\")"
    );
    assert_eq!(
        observe(&root, vec![loader("another-board", PORT)], None).unwrap_err(),
        "IOKit did not observe the exact bound Loader: admissionRejected(\"DAYU200 target \
         unavailable\")"
    );
    assert_eq!(
        observe(&root, vec![loader(SERIAL, PORT)], Some("20000000")).unwrap_err(),
        "IOKit observed the bound Loader at USB topology 17956864, not the admitted topology \
         20000000"
    );
}

#[test]
fn the_lane_daemon_must_see_exactly_that_loader_at_that_port() {
    let root = Root::new();
    let refusal = observe(&root, vec![loader(SERIAL, PORT)], None).unwrap_err();
    assert!(
        refusal.starts_with("arkforged discoverDevices is unavailable: DAEMON_UNAVAILABLE: "),
        "{refusal}"
    );

    let daemon = serve(
        &root,
        vec![Seen("19922944", "rockusb-loader", "0x2207:0x350a")],
    );
    assert_eq!(
        observe(&root, vec![loader(SERIAL, PORT)], None).unwrap_err(),
        "arkforged did not uniquely observe the bound Loader: the daemon sees no device at the \
         port this job is bound to (17956864); it observed USB-0. Nothing was materialized — a \
         plan built against a device the daemon cannot see is a plan for some other board"
    );
    daemon.join().unwrap();

    std::fs::remove_file(root.0.join("public.sock")).unwrap();
    let daemon = serve(&root, vec![Seen(PORT, "rockusb-maskrom", "0x2207:0x350a")]);
    assert_eq!(
        observe(&root, vec![loader(SERIAL, PORT)], None).unwrap_err(),
        "arkforged returned an unusable Loader observation: mode is rockusb-maskrom, expected \
         rockusb-loader"
    );
    daemon.join().unwrap();

    std::fs::remove_file(root.0.join("public.sock")).unwrap();
    let daemon = serve(&root, vec![Seen(PORT, "rockusb-loader", "0x2207:0x5000")]);
    assert_eq!(
        observe(&root, vec![loader(SERIAL, PORT)], None).unwrap_err(),
        "arkforged returned an unusable Loader observation: USB class is not the registered \
         DAYU200 Loader"
    );
    daemon.join().unwrap();
}
