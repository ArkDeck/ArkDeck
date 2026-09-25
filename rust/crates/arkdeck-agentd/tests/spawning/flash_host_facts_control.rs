//! The Swift Flash host facts oracle (`rust/tests/fixtures/flash-host-facts`,
//! recorded by `FlashHostFactsOracleContractTests`) replayed through the
//! production Host and Control: `flash.bootloader-status`,
//! `flash.prerequisites` and `flash.lanePlanPreview` over the Target store,
//! the Rockchip binding and the post-flash alias of an Application Support
//! root, with the census, the measured `arkforged`, the Loader observation
//! and the shared fake HDC each exchange's setup names, and the composition
//! each preview names. Every answer must be Swift's, byte for byte, and every
//! exchange must make exactly the HDC calls Swift's made.
//!
//! One declared difference: where Swift's preview went on to ask the lane's
//! daemon (the oracle records the calls it received), this Runtime's stops,
//! with the same Target and revision, and answers `previewFailed` with why.
//!
//! The oracle's live probe had no USB port, while this Runtime's reads the
//! census: the port only names an HDC-normal alias's current topology among
//! the server facts, which `flash.prerequisites` does not project. Host tests
//! only: the fake reaches no device, and nothing installed is read or
//! written.
use arkdeck_contract::{
    CONTRACT_IDENTITY, CONTRACT_INPUTS, PROTOCOL_VERSION, sha256_hex, strict_json,
    validate_method_value,
};
use arkdeck_control::Control;
use arkdeck_hoststore::{
    FlashHostFacts, LANE_PREVIEW_UNAVAILABLE, NativeRockUsbIdentity, TargetStore,
};
use arkdeck_platform::{RegistryUnavailable, UsbHostDevice, VerifiedTool};
use arkdeck_provider_hdc::{LoaderIdentity, LoaderObserver, ProcessDispatch};
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::fs;
use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

/// The census an exchange's setup names; `None` is a registry that cannot be
/// read.
type Census = Arc<Mutex<Option<Vec<UsbHostDevice>>>>;

/// The fake HDC's fixed root, which its driver names, shared with every
/// oracle replay under one lock.
const HDC_ROOT: &str = "/private/tmp/arkdeck-hdc-oracle";

struct Root(PathBuf);

impl Root {
    fn new() -> Self {
        let root = std::env::temp_dir().canonicalize().unwrap().join(format!(
            "flash-host-facts-{:x}",
            u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap())
        ));
        fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(root.join("state/targets"))
            .unwrap();
        Self(root)
    }
}

impl Drop for Root {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

/// `HDCOracleFake.install` with the oracle's answers, held under its lock.
struct Hdc {
    root: PathBuf,
    _lock: fs::File,
}

impl Hdc {
    fn install(fixtures: &Path) -> Self {
        let lock = fs::OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .open("/private/tmp/arkdeck-hdc-oracle.lock")
            .unwrap();
        lock.lock().unwrap();
        let root = PathBuf::from(HDC_ROOT);
        let _ = fs::remove_dir_all(&root);
        fs::DirBuilder::new().mode(0o700).create(&root).unwrap();
        for (file, mode) in [("hdc", 0o700), ("hdc-answers.sh", 0o600)] {
            fs::copy(fixtures.join(file), root.join(file)).unwrap();
            fs::set_permissions(root.join(file), fs::Permissions::from_mode(mode)).unwrap();
        }
        Self { root, _lock: lock }
    }

    fn dispatch(&self) -> ProcessDispatch {
        let digest = sha256_hex(&fs::read(self.root.join("hdc")).unwrap());
        ProcessDispatch::new(
            VerifiedTool::open(self.root.join("hdc"), &digest).unwrap(),
            None,
        )
    }

    fn mode(&self, mode: &str) {
        fs::write(self.root.join("hdc-mode"), format!("{mode}\n")).unwrap();
    }

    /// The fake's calls since the last read, each its arguments, as the
    /// oracle records them.
    fn calls(&self) -> Value {
        let log = self.root.join("hdc-invocations.log");
        let text = fs::read_to_string(&log).unwrap_or_default();
        let _ = fs::write(&log, "");
        Value::Array(
            text.lines()
                .filter(|line| !line.is_empty())
                .map(|line| {
                    let mut arguments: Vec<&str> = line.split('\u{1f}').collect();
                    arguments.pop();
                    json!(arguments)
                })
                .collect(),
        )
    }
}

impl Drop for Hdc {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

/// ArkForge's dual-source Loader observation, scripted as the oracle
/// scripted it: the topology it confirms, or the reason it refuses with.
#[derive(Clone)]
struct Loader(Arc<Mutex<Result<String, String>>>);

impl LoaderObserver for Loader {
    fn observe_loader(
        &self,
        stable_identity_sha256: &str,
        _expected_usb_topology: Option<&str>,
        _request_id: &str,
    ) -> Result<LoaderIdentity, String> {
        self.0
            .lock()
            .unwrap()
            .clone()
            .map(|topology| LoaderIdentity {
                serial_digest_sha256: stable_identity_sha256.to_owned(),
                topology,
            })
    }
}

/// What the setup has named so far.
struct Scene {
    census: Census,
    rockusb: NativeRockUsbIdentity,
    loader: Loader,
    probe: bool,
}

impl Scene {
    fn new() -> Self {
        Self {
            census: Arc::new(Mutex::new(Some(Vec::new()))),
            rockusb: NativeRockUsbIdentity::unconfigured(),
            loader: Loader(Arc::new(Mutex::new(Err(
                "DAYU200 target unavailable".to_owned()
            )))),
            probe: true,
        }
    }

    /// The daemon as composed for this exchange: with the HDC the probe
    /// reads, or, as Swift's daemon without HDC, with none; and as the
    /// exchange's `composition` names it — with a lane (the default), without
    /// one, without a Target store, or without the facts.
    fn control(&self, root: &Path, hdc: &Hdc, composition: &str) -> Control<crate::host::Host> {
        let census = Arc::clone(&self.census);
        let facts = FlashHostFacts::new(root, move || {
            census
                .lock()
                .unwrap()
                .clone()
                .ok_or(RegistryUnavailable::Matching)
        })
        .with_rockusb(self.rockusb.clone())
        .with_loader_observer(Box::new(self.loader.clone()));
        let host = crate::host::Host::from_environment().with_lane_plan_preview(
            (composition != "noLane").then(|| "org.openharmony.dayu200".to_owned()),
        );
        let host = if composition == "noTargetStore" {
            host
        } else {
            host.with_targets(TargetStore::open(&root.join("state/targets")).unwrap())
        };
        let host = if composition == "noFactsPort" {
            host
        } else {
            host.with_flash_host_facts(facts)
        };
        Control::new(if self.probe {
            host.with_development_hdc(Some(hdc.dispatch()))
        } else {
            host
        })
        .unwrap()
    }
}

fn fixtures() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../tests/fixtures/flash-host-facts")
}

fn call(control: &Control<crate::host::Host>, id: u64, method: &str, params: Value) -> Value {
    let reply: Value = serde_json::from_slice(
        &control.handle_frame(
            &serde_json::to_vec(&json!({
                "protocolVersion": PROTOCOL_VERSION, "contractIdentity": CONTRACT_IDENTITY,
                "id": format!("flash-host-facts-{id}"), "method": method, "params": params,
            }))
            .unwrap(),
        ),
    )
    .unwrap();
    if reply["ok"] == true {
        json!({"ok": true, "result": reply["result"]})
    } else {
        json!({"ok": false, "error": reply["error"]})
    }
}

fn device(value: &Value) -> UsbHostDevice {
    UsbHostDevice {
        serial: value["serial"].as_str().unwrap().to_owned(),
        vendor_id: u16::try_from(value["vendorId"].as_u64().unwrap()).unwrap(),
        product_id: u16::try_from(value["productId"].as_u64().unwrap()).unwrap(),
        topology: value["topology"].as_str().unwrap().to_owned(),
        product_name: value["productName"].as_str().map(str::to_owned),
        registry_entry_id: value["registryEntryId"].as_u64(),
    }
}

/// One setup action of the oracle, performed here as Swift performed it.
fn perform(root: &Path, fixtures: &Path, hdc: &Hdc, scene: &mut Scene, action: &Value) {
    let text = |key: &str| action[key].as_str().map(str::to_owned);
    match action["action"].as_str().unwrap() {
        "write" => {
            let target = root.join(action["path"].as_str().unwrap());
            let _ = fs::remove_file(&target);
            fs::write(
                &target,
                fs::read(fixtures.join(action["input"].as_str().unwrap())).unwrap(),
            )
            .unwrap();
            fs::set_permissions(
                &target,
                fs::Permissions::from_mode(
                    u32::from_str_radix(action["mode"].as_str().unwrap(), 8).unwrap(),
                ),
            )
            .unwrap();
        }
        "remove" => fs::remove_file(root.join(action["path"].as_str().unwrap())).unwrap(),
        "usb" => {
            *scene.census.lock().unwrap() = action["devices"]
                .as_array()
                .map(|devices| devices.iter().map(device).collect());
        }
        "rockusb" => {
            let daemon = text("daemon").map(|daemon| {
                if action["underRoot"] == true {
                    root.join(daemon).to_str().unwrap().to_owned()
                } else {
                    daemon
                }
            });
            scene.rockusb = NativeRockUsbIdentity::configured(daemon, text("declared"));
        }
        "loader" => {
            *scene.loader.0.lock().unwrap() = match text("topology") {
                Some(topology) => Ok(topology),
                None => Err(text("refusal").unwrap()),
            };
        }
        "probe" => scene.probe = action["probe"].as_bool().unwrap(),
        "hdcMode" => hdc.mode(action["mode"].as_str().unwrap()),
        other => panic!("unknown setup action {other}"),
    }
}

/// The published contract view runs this checkout's tests against the merge
/// base's inputs, which name their commit and may predate the widened
/// `flash.bootloader-status` result. The checkout and candidate views carry
/// it.
fn published_view() -> bool {
    let inputs = strict_json(CONTRACT_INPUTS.as_bytes()).unwrap();
    inputs["kind"] == "development" && inputs.get("commit").is_some()
}

/// What the control layer answers in place of Swift's recorded answer under
/// this build's schema: the answer when the schema publishes it, else
/// `internalError`. The checkout and candidate views must publish all of them.
fn published(method: &str, answer: &Value) -> Value {
    let conforms = if answer["ok"] == true {
        validate_method_value(method, "result", &answer["result"]).is_ok()
    } else {
        validate_method_value(method, "errorCode", &answer["error"]["code"]).is_ok()
    };
    assert!(
        conforms || published_view(),
        "the current contract must publish Swift's answer {answer}"
    );
    if conforms {
        answer.clone()
    } else {
        json!({"ok": false, "error": {"code": "internalError",
            "message": "the result does not conform to the current contract"}})
    }
}

#[test]
fn the_rust_daemon_replays_the_swift_flash_host_facts_oracle() {
    let _turn = crate::turn();
    let fixtures = fixtures();
    let cases: Value =
        serde_json::from_slice(&fs::read(fixtures.join("cases.json")).unwrap()).unwrap();
    let hdc = Hdc::install(&fixtures);
    let root = Root::new();
    let mut scene = Scene::new();
    let mut compared = 0;
    let mut declared = 0;
    // What the setup last wrote to each path, or `None` once it removed it.
    let mut written: BTreeMap<String, Option<(String, String)>> = BTreeMap::new();
    for exchange in cases["exchanges"].as_array().unwrap() {
        let index = exchange["index"].as_u64().unwrap();
        let name = exchange["name"].as_str().unwrap();
        for action in exchange["setup"].as_array().unwrap() {
            perform(&root.0, &fixtures, &hdc, &mut scene, action);
            let path = action["path"].as_str().map(str::to_owned);
            match (action["action"].as_str().unwrap(), path) {
                ("write", Some(path)) => {
                    let input = action["input"].as_str().unwrap().to_owned();
                    let mode = action["mode"].as_str().unwrap().to_owned();
                    written.insert(path, Some((input, mode)));
                }
                ("remove", Some(path)) => {
                    written.insert(path, None);
                }
                _ => {}
            }
        }
        let method = exchange["method"].as_str().unwrap();
        let control = scene.control(
            &root.0,
            &hdc,
            exchange["composition"].as_str().unwrap_or("lane"),
        );
        let answer = call(&control, index, method, exchange["params"].clone());
        let expected = if exchange["laneCalls"]
            .as_array()
            .is_some_and(|calls| !calls.is_empty())
        {
            // The declared difference: Swift's preview asked the lane's
            // daemon, whose store the oracle scripted empty; this one stops
            // before it, for the same Target at the same revision.
            let swift = &exchange["answer"]["result"];
            assert_eq!(swift["state"], "bundleNotInLaneStore", "{index} {name}");
            declared += 1;
            json!({"ok": true, "result": {
                "targetId": swift["targetId"], "bindingRevision": swift["bindingRevision"],
                "state": "previewFailed", "reason": LANE_PREVIEW_UNAVAILABLE}})
        } else {
            published(method, &exchange["answer"])
        };
        assert_eq!(answer, expected, "{index} {name}");
        assert_eq!(
            hdc.calls(),
            exchange["hdcCalls"],
            "{index} {name}: HDC calls"
        );
        compared += 1;
    }
    assert!(compared >= 74, "every recorded exchange replays");
    assert_eq!(declared, 8, "the previews that reached the lane");
    // The reads wrote nothing: the Application Support root holds what the
    // setup last wrote, byte for byte and in its mode, and nothing else.
    let mut left: Vec<String> = fs::read_dir(&root.0)
        .unwrap()
        .map(|entry| entry.unwrap().file_name().into_string().unwrap())
        .collect();
    left.sort();
    let mut expected: Vec<String> = written
        .iter()
        .filter(|(_, input)| input.is_some())
        .map(|(path, _)| path.split('/').next().unwrap().to_owned())
        .chain(["state".to_owned()])
        .collect();
    expected.sort();
    expected.dedup();
    assert_eq!(left, expected);
    for (path, input) in &written {
        let Some((input, mode)) = input else {
            assert!(!root.0.join(path).exists(), "{path} was removed");
            continue;
        };
        assert_eq!(
            fs::read(root.0.join(path)).unwrap(),
            fs::read(fixtures.join(input)).unwrap(),
            "{path}"
        );
        assert_eq!(
            format!(
                "{:o}",
                fs::metadata(root.0.join(path))
                    .unwrap()
                    .permissions()
                    .mode()
                    & 0o777
            ),
            *mode,
            "{path}"
        );
    }
}

#[test]
fn a_host_without_the_facts_answers_as_swifts_daemon_without_its_observers() {
    let _turn = crate::turn();
    let control = Control::new(crate::host::Host::from_environment()).unwrap();
    for (method, params, message) in [
        (
            "flash.bootloader-status",
            json!({}),
            "Rockchip bootloader status observation is not configured",
        ),
        (
            "flash.prerequisites",
            json!({"targetId": "TGT-HOST", "profileReference": "dayu200"}),
            "Flash prerequisite observation is not configured",
        ),
        (
            "flash.lanePlanPreview",
            json!({"targetId": "TGT-HOST", "profileReference": "dayu200",
                "archiveSha256": "e".repeat(64)}),
            "lane plan preview is not configured",
        ),
    ] {
        assert_eq!(
            call(&control, 1, method, params),
            json!({"ok": false, "error": {"code": "internalError", "message": message}}),
            "{method}"
        );
    }
    // The prerequisites' parameters are read before their owner, as Swift's
    // are, and only the published profile is supported.
    for params in [
        json!({}),
        json!({"targetId": "TGT-HOST"}),
        json!({"targetId": "TGT-HOST", "profileReference": "DAYU200"}),
        json!({"targetId": 7, "profileReference": "dayu200"}),
    ] {
        assert_eq!(
            call(&control, 2, "flash.prerequisites", params.clone())["error"],
            json!({"code": "invalidParams",
                "message": "a supported targetId and profileReference are required"}),
            "{params}"
        );
    }
    // So are the preview's, and its digest is 64 hexadecimal characters as
    // Swift's `Character` reads them: none other, no longer, none combined.
    let digest = "e".repeat(64);
    for params in [
        json!({"targetId": "TGT-HOST", "profileReference": "dayu200"}),
        json!({"targetId": "TGT-HOST", "profileReference": "DAYU200", "archiveSha256": digest}),
        json!({"targetId": 7, "profileReference": "dayu200", "archiveSha256": digest}),
        json!({"targetId": "TGT-HOST", "profileReference": "dayu200", "archiveSha256": 7}),
        json!({"targetId": "TGT-HOST", "profileReference": "dayu200",
            "archiveSha256": "e".repeat(65)}),
        json!({"targetId": "TGT-HOST", "profileReference": "dayu200",
            "archiveSha256": format!("{}\u{FF47}", "e".repeat(63))}),
        json!({"targetId": "TGT-HOST", "profileReference": "dayu200",
            "archiveSha256": format!("{}e\u{301}", "e".repeat(62))}),
    ] {
        assert_eq!(
            call(&control, 3, "flash.lanePlanPreview", params.clone())["error"],
            json!({"code": "invalidParams", "message":
                "a supported targetId, profileReference and 64-hex archiveSha256 are required"}),
            "{params}"
        );
    }
    for digest in ["\u{FF19}\u{FF26}".repeat(32), "A".repeat(64)] {
        assert_eq!(
            call(
                &control,
                4,
                "flash.lanePlanPreview",
                json!({"targetId": "TGT-HOST", "profileReference": "dayu200",
                    "archiveSha256": digest})
            )["error"]["message"],
            "lane plan preview is not configured",
            "{digest}"
        );
    }
}

#[test]
fn members_swift_ignores_change_neither_the_reads_nor_the_answers() {
    let _turn = crate::turn();
    let fixtures = fixtures();
    let hdc = Hdc::install(&fixtures);
    let root = Root::new();
    let scene = Scene::new();
    let control = scene.control(&root.0, &hdc, "lane");
    assert_eq!(
        call(
            &control,
            1,
            "flash.bootloader-status",
            json!({"targetId": "TGT-HOST", "serial": "loader-serial-0451"})
        ),
        call(&control, 2, "flash.bootloader-status", json!({}))
    );
    assert_eq!(
        call(
            &control,
            3,
            "flash.prerequisites",
            json!({"targetId": "TGT-HOST", "profileReference": "dayu200",
                "connectKey": "forged", "rockusbPath": "/usr/local/bin/rockusb"})
        ),
        json!({"ok": false, "error": {"code": "notFound", "message": "target is not adopted"}})
    );
    assert_eq!(
        call(
            &control,
            4,
            "flash.lanePlanPreview",
            json!({"targetId": "TGT-HOST", "profileReference": "dayu200",
                "archiveSha256": "e".repeat(64), "planId": "forged", "usbTopology": "1"})
        ),
        json!({"ok": false, "error": {"code": "notFound", "message": "target is not adopted"}})
    );
    assert_eq!(hdc.calls(), json!([]));
}
