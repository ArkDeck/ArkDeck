//! The Swift Loader binding oracle (`rust/tests/fixtures/loader-binding`,
//! recorded by `LoaderBindingOracleContractTests`) replayed through the
//! production Host and Control: `flash.bind-current-loader` over the Target
//! store, the binding and the Runtime's reactivation records of an
//! Application Support root, with the census and ArkForge's half of the
//! Loader observation each exchange's setup names. Every answer must be
//! Swift's, byte for byte, and so must every file the bind leaves: the
//! binding and its lock, and the Target document it advanced.
use arkdeck_contract::{CONTRACT_IDENTITY, PROTOCOL_VERSION, validate_method_value};
use arkdeck_control::Control;
use arkdeck_hoststore::{LoaderBinding, TargetStore};
use arkdeck_platform::{RegistryUnavailable, UsbHostDevice};
use arkdeck_provider_hdc::{LoaderIdentity, LoaderObserver};
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::fs;
use std::os::unix::fs::{DirBuilderExt, MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

const METHOD: &str = "flash.bind-current-loader";

/// The census an exchange's setup names; `None` is a registry that cannot be
/// read.
type Census = Arc<Mutex<Option<Vec<UsbHostDevice>>>>;

/// ArkForge's half of the Loader observation, as the setup scripts it.
#[derive(Clone)]
enum Script {
    Confirm,
    Port(String),
    Refuse(String),
}

struct Observation(Arc<Mutex<Script>>);

impl LoaderObserver for Observation {
    fn observe_loader(
        &self,
        stable_identity_sha256: &str,
        expected_usb_topology: Option<&str>,
        _request_id: &str,
    ) -> Result<LoaderIdentity, String> {
        let identity = |topology: &str| LoaderIdentity {
            serial_digest_sha256: stable_identity_sha256.to_owned(),
            topology: topology.to_owned(),
        };
        match self.0.lock().unwrap().clone() {
            Script::Confirm => Ok(identity(expected_usb_topology.unwrap_or_default())),
            Script::Port(topology) => Ok(identity(&topology)),
            Script::Refuse(reason) => Err(reason),
        }
    }
}

/// The Application Support root. Not below `/private`: Swift's reactivation
/// records' root must be its own standardized path, and Foundation
/// standardizes `/private/tmp/…` to `/tmp/…`.
struct Root(PathBuf);

impl Root {
    fn new() -> Self {
        let root = PathBuf::from("/tmp").join(format!(
            "arkdeck-loader-binding-{:x}",
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

fn fixtures() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../tests/fixtures/loader-binding")
}

fn control(
    root: &Path,
    census: &Census,
    script: &Arc<Mutex<Script>>,
) -> Control<crate::host::Host> {
    let census = Arc::clone(census);
    Control::new(
        crate::host::Host::from_environment()
            // The Target store is opened by its canonical path, as the
            // daemon's always is; the root keeps the path Swift's did.
            .with_targets(
                TargetStore::open(&root.canonicalize().unwrap().join("state/targets")).unwrap(),
            )
            .with_loader_binding(LoaderBinding::new(
                root,
                move || {
                    census
                        .lock()
                        .unwrap()
                        .clone()
                        .ok_or(RegistryUnavailable::Matching)
                },
                Observation(Arc::clone(script)),
            )),
    )
    .unwrap()
}

fn call(control: &Control<crate::host::Host>, id: usize, params: Value) -> Value {
    let reply: Value = serde_json::from_slice(
        &control.handle_frame(
            &serde_json::to_vec(&json!({
                "protocolVersion": PROTOCOL_VERSION, "contractIdentity": CONTRACT_IDENTITY,
                "id": format!("loader-binding-{id}"), "method": METHOD, "params": params,
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

fn mode(text: &str) -> u32 {
    u32::from_str_radix(text, 8).unwrap()
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
fn perform(
    root: &Path,
    fixtures: &Path,
    census: &Census,
    script: &Arc<Mutex<Script>>,
    action: &Value,
) {
    let path = |key: &str| root.join(action[key].as_str().unwrap());
    match action["action"].as_str().unwrap() {
        "write" => {
            let target = path("path");
            let _ = fs::remove_file(&target);
            fs::write(
                &target,
                fs::read(fixtures.join(action["input"].as_str().unwrap())).unwrap(),
            )
            .unwrap();
            fs::set_permissions(
                &target,
                fs::Permissions::from_mode(mode(action["mode"].as_str().unwrap())),
            )
            .unwrap();
        }
        "mkdir" => {
            let target = path("path");
            fs::DirBuilder::new().create(&target).unwrap();
            fs::set_permissions(
                &target,
                fs::Permissions::from_mode(mode(action["mode"].as_str().unwrap())),
            )
            .unwrap();
        }
        "usb" => {
            *census.lock().unwrap() = action["devices"]
                .as_array()
                .map(|devices| devices.iter().map(device).collect());
        }
        "loader" => {
            *script.lock().unwrap() = match action["script"].as_str().unwrap() {
                "confirm" => Script::Confirm,
                "port" => Script::Port(action["topology"].as_str().unwrap().to_owned()),
                "refuse" => Script::Refuse(action["refusal"].as_str().unwrap().to_owned()),
                other => panic!("unknown observation script {other}"),
            };
        }
        other => panic!("unknown setup action {other}"),
    }
}

/// Every file of the root but the engine's, the state directory's and the
/// reactivation records, then the Target document, with its kind, mode and
/// size, and its bytes: what Swift's oracle records after each exchange.
fn bound_files(root: &Path) -> (Vec<Value>, BTreeMap<String, Vec<u8>>) {
    fn walk(root: &Path, relative: &Path, listing: &mut Vec<String>) {
        for entry in fs::read_dir(root.join(relative)).unwrap() {
            let entry = entry.unwrap();
            let path = relative.join(entry.file_name());
            listing.push(path.to_str().unwrap().to_owned());
            if entry.file_type().unwrap().is_dir() {
                walk(root, &path, listing);
            }
        }
    }
    let mut paths = Vec::new();
    walk(root, Path::new(""), &mut paths);
    paths.retain(|path| {
        path == "state/targets/targets.json"
            || ["engine", "state", "Agentd"]
                .iter()
                .all(|excluded| path != excluded && !path.starts_with(&format!("{excluded}/")))
    });
    paths.sort();
    let mut listing = Vec::new();
    let mut bytes = BTreeMap::new();
    for path in paths {
        let metadata = fs::symlink_metadata(root.join(&path)).unwrap();
        let kind = if metadata.is_dir() {
            "directory"
        } else if metadata.file_type().is_symlink() {
            "link"
        } else {
            "file"
        };
        listing.push(json!({
            "path": path, "kind": kind,
            "mode": format!("{:o}", metadata.mode() & 0o777), "bytes": metadata.len(),
        }));
        if kind == "file" {
            bytes.insert(path.clone(), fs::read(root.join(&path)).unwrap());
        }
    }
    (listing, bytes)
}

/// Every recorded answer is one the published contract carries.
fn conforms(answer: &Value) -> bool {
    if answer["ok"] == true {
        validate_method_value(METHOD, "result", &answer["result"]).is_ok()
    } else {
        validate_method_value(METHOD, "errorCode", &answer["error"]["code"]).is_ok()
            && answer["error"].get("details").is_none_or(|details| {
                validate_method_value(METHOD, "errorDetails", details).is_ok()
            })
    }
}

#[test]
fn the_rust_daemon_replays_the_swift_loader_binding_oracle() {
    let fixtures = fixtures();
    let cases: Value =
        serde_json::from_slice(&fs::read(fixtures.join("cases.json")).unwrap()).unwrap();
    let root = Root::new();
    let census: Census = Arc::new(Mutex::new(Some(Vec::new())));
    let script = Arc::new(Mutex::new(Script::Confirm));
    let control = control(&root.0, &census, &script);
    let mut compared = 0;
    for exchange in cases["exchanges"].as_array().unwrap() {
        let index = exchange["index"].as_u64().unwrap();
        let name = exchange["name"].as_str().unwrap();
        for action in exchange["setup"].as_array().unwrap() {
            perform(&root.0, &fixtures, &census, &script, action);
        }
        let answer = call(&control, index as usize, exchange["params"].clone());
        assert!(conforms(&answer), "{index} {name}: {answer}");
        assert_eq!(answer, exchange["answer"], "{index} {name}");
        let (listing, bytes) = bound_files(&root.0);
        assert_eq!(json!(listing), exchange["files"], "{index} {name}: files");
        for (path, content) in bytes {
            let expected = fs::read(fixtures.join(format!("steps/{index:02}-{name}/{path}")))
                .unwrap_or_else(|_| panic!("{index} {name}: {path} was not recorded"));
            assert_eq!(
                String::from_utf8_lossy(&content),
                String::from_utf8_lossy(&expected),
                "{index} {name}: {path}"
            );
        }
        compared += 1;
    }
    assert_eq!(compared, 33, "every recorded exchange replays");
}

#[test]
fn a_host_without_the_owner_answers_as_swifts_daemon_without_it() {
    let control = Control::new(crate::host::Host::from_environment()).unwrap();
    assert_eq!(
        call(
            &control,
            1,
            json!({"targetId": "TGT-BOARD-A", "expectedBindingRevision": 1})
        ),
        json!({"ok": false, "error": {"code": "internalError",
            "message": "Rockchip Loader binding is not configured"}})
    );
    // Its parameters are read before its owner, as Swift's are.
    assert_eq!(
        call(&control, 2, json!({}))["error"]["code"],
        "invalidParams"
    );
}

#[test]
fn parameters_swift_refuses_or_ignores_by_name_are_answered_as_swift_answers_them() {
    let root = Root::new();
    let census: Census = Arc::new(Mutex::new(Some(Vec::new())));
    let script = Arc::new(Mutex::new(Script::Confirm));
    let control = control(&root.0, &census, &script);
    // A revision spelled as a string, or with a fraction, is no integer.
    for params in [
        json!({"targetId": "TGT-BOARD-A", "expectedBindingRevision": "1"}),
        json!({"targetId": "TGT-BOARD-A", "expectedBindingRevision": 1.5}),
        json!({"targetId": 7, "expectedBindingRevision": 1}),
    ] {
        assert_eq!(
            call(&control, 1, params.clone())["error"]["message"],
            "targetId and expectedBindingRevision are required",
            "{params}"
        );
    }
    // A revision with no fraction is Foundation's integer, and an extra
    // parameter is ignored: the Target is simply not adopted here.
    for params in [
        json!({"targetId": "TGT-BOARD-A", "expectedBindingRevision": 1.0}),
        json!({"targetId": "TGT-BOARD-A", "expectedBindingRevision": 1, "extra": true}),
    ] {
        assert_eq!(
            call(&control, 2, params)["error"]["message"],
            "Rockchip Loader binding was refused: admissionRejected(\"selected target or \
             binding revision is stale\")"
        );
    }
}
