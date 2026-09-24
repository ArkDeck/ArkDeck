//! The Swift Flash host reads oracle (`rust/tests/fixtures/flash-host-reads`,
//! recorded by `FlashHostReadsOracleContractTests`) replayed through the
//! production Host and Control: `flash.reconcile-alias` over the Target store
//! and the post-flash alias of an Application Support root, with the census
//! and the clock the oracle fixed, and `debug.status` and
//! `recovery.flash-invocation.list` over the invocation documents Swift's
//! controller wrote. Every answer must be Swift's, byte for byte once the
//! pager's random revision and cursors are named, and every file the
//! reconciler leaves in the Application Support root must be Swift's.
use arkdeck_contract::{CONTRACT_IDENTITY, PROTOCOL_VERSION};
use arkdeck_control::Control;
use arkdeck_hoststore::{FlashAliasReconciler, FlashInvocations, TargetStore};
use arkdeck_platform::{RegistryUnavailable, UsbHostDevice};
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::fs;
use std::os::unix::fs::{DirBuilderExt, MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

/// The census an exchange's setup names; `None` is a registry that cannot be
/// read.
type Census = Arc<Mutex<Option<Vec<UsbHostDevice>>>>;

struct Root(PathBuf);

impl Root {
    fn new() -> Self {
        let root = std::env::temp_dir().canonicalize().unwrap().join(format!(
            "flash-host-reads-{:x}",
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
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../tests/fixtures/flash-host-reads")
}

fn control(root: &Path, census: &Census) -> Control<crate::host::Host> {
    let census = Arc::clone(census);
    Control::new(
        crate::host::Host::from_environment()
            .with_targets(TargetStore::open(&root.join("state/targets")).unwrap())
            .with_flash_alias_reconciler(FlashAliasReconciler::new(
                root,
                move || {
                    census
                        .lock()
                        .unwrap()
                        .clone()
                        .ok_or(RegistryUnavailable::Matching)
                },
                || "2026-09-25T00:00:00Z".to_owned(),
            ))
            .with_flash_invocations(FlashInvocations::open(&root.join("state")).unwrap()),
    )
    .unwrap()
}

fn call(control: &Control<crate::host::Host>, id: usize, method: &str, params: Value) -> Value {
    let reply: Value = serde_json::from_slice(
        &control.handle_frame(
            &serde_json::to_vec(&json!({
                "protocolVersion": PROTOCOL_VERSION, "contractIdentity": CONTRACT_IDENTITY,
                "id": format!("flash-host-reads-{id}"), "method": method, "params": params,
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
fn perform(root: &Path, fixtures: &Path, census: &Census, action: &Value) {
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
        "remove" => fs::remove_file(path("path")).unwrap(),
        "chmod" => fs::set_permissions(
            path("path"),
            fs::Permissions::from_mode(mode(action["mode"].as_str().unwrap())),
        )
        .unwrap(),
        "symlink" => {
            std::os::unix::fs::symlink(action["to"].as_str().unwrap(), path("path")).unwrap()
        }
        "usb" => {
            *census.lock().unwrap() = action["devices"]
                .as_array()
                .map(|devices| devices.iter().map(device).collect());
        }
        other => panic!("unknown setup action {other}"),
    }
}

/// Every file of the Application Support root outside the state directory,
/// with its kind, mode and size, and its bytes.
fn application_support_files(root: &Path) -> (Vec<Value>, BTreeMap<String, Vec<u8>>) {
    fn walk(root: &Path, relative: &Path, listing: &mut Vec<(String, PathBuf)>) {
        for entry in fs::read_dir(root.join(relative)).unwrap() {
            let entry = entry.unwrap();
            let path = relative.join(entry.file_name());
            let name = path.to_str().unwrap().to_owned();
            if name == "state" || name == "engine" {
                continue;
            }
            listing.push((name, path.clone()));
            if entry.file_type().unwrap().is_dir() {
                walk(root, &path, listing);
            }
        }
    }
    let mut paths = Vec::new();
    walk(root, Path::new(""), &mut paths);
    paths.sort();
    let mut listing = Vec::new();
    let mut bytes = BTreeMap::new();
    for (name, path) in paths {
        let metadata = fs::symlink_metadata(root.join(&path)).unwrap();
        let kind = if metadata.is_dir() {
            "directory"
        } else if metadata.file_type().is_symlink() {
            "link"
        } else {
            "file"
        };
        listing.push(json!({
            "path": name, "kind": kind,
            "mode": format!("{:o}", metadata.mode() & 0o777), "bytes": metadata.len(),
        }));
        if kind == "file" {
            bytes.insert(name, fs::read(root.join(&path)).unwrap());
        }
    }
    (listing, bytes)
}

#[test]
fn the_rust_daemon_replays_the_swift_flash_host_reads_oracle() {
    let fixtures = fixtures();
    let cases: Value =
        serde_json::from_slice(&fs::read(fixtures.join("cases.json")).unwrap()).unwrap();
    let root = Root::new();
    let census: Census = Arc::new(Mutex::new(Some(Vec::new())));
    let control = control(&root.0, &census);
    let mut cursors: BTreeMap<String, String> = BTreeMap::new();
    let mut compared = 0;
    for exchange in cases["exchanges"].as_array().unwrap() {
        let index = exchange["index"].as_u64().unwrap();
        let name = exchange["name"].as_str().unwrap();
        for action in exchange["setup"].as_array().unwrap() {
            perform(&root.0, &fixtures, &census, action);
        }
        // A request naming an earlier answer's cursor sends this replay's.
        let mut params = exchange["params"].clone();
        for value in params.as_object_mut().unwrap().values_mut() {
            if let Some(cursor) = value.as_str().and_then(|label| cursors.get(label)) {
                *value = json!(cursor);
            }
        }
        let mut answer = call(
            &control,
            index as usize,
            exchange["method"].as_str().unwrap(),
            params,
        );
        if let Some(result) = answer.get_mut("result").and_then(Value::as_object_mut) {
            if result.get("snapshotRevision").is_some_and(Value::is_string) {
                result.insert("snapshotRevision".into(), json!("<snapshotRevision>"));
            }
            if let Some(cursor) = result.get("nextCursor").and_then(Value::as_str) {
                let label = format!("<nextCursor-{index}>");
                cursors.insert(label.clone(), cursor.to_owned());
                result.insert("nextCursor".into(), json!(label));
            }
        }
        assert_eq!(answer, exchange["answer"], "{index} {name}");
        if let Some(recorded) = exchange.get("files") {
            let (listing, bytes) = application_support_files(&root.0);
            assert_eq!(&json!(listing), recorded, "{index} {name}: files");
            for (path, content) in bytes {
                let expected = fs::read(fixtures.join(format!("steps/{index:02}-{name}/{path}")))
                    .unwrap_or_else(|_| panic!("{index} {name}: {path} was not recorded"));
                assert_eq!(content, expected, "{index} {name}: {path}");
            }
        }
        compared += 1;
    }
    assert!(compared >= 61, "every recorded exchange replays");
}

#[test]
fn a_host_without_the_owners_answers_as_swifts_daemon_without_them() {
    let control = Control::new(crate::host::Host::from_environment()).unwrap();
    for (method, params, message) in [
        (
            "flash.reconcile-alias",
            json!({"targetId": "TGT-HOST", "expectedBindingRevision": 2}),
            "Rockchip post-flash alias reconciliation is not configured",
        ),
        (
            "debug.status",
            json!({}),
            "Runtime debug invocation is not configured",
        ),
        (
            "recovery.flash-invocation.list",
            json!({}),
            "Runtime Flash invocation owner is not configured",
        ),
    ] {
        let answer = call(&control, 1, method, params);
        assert_eq!(
            answer,
            json!({"ok": false, "error": {"code": "internalError", "message": message}}),
            "{method}"
        );
    }
    // The reconciler's parameters are read before its owner, as Swift's are.
    assert_eq!(
        call(&control, 2, "flash.reconcile-alias", json!({}))["error"]["code"],
        "invalidParams"
    );
}

#[test]
fn parameters_swift_ignores_or_refuses_by_name_are_answered_as_swift_answers_them() {
    let root = Root::new();
    let census: Census = Arc::new(Mutex::new(Some(Vec::new())));
    let control = control(&root.0, &census);
    for (method, params, code, message) in [
        // A revision spelled as a string, or with a fraction, is no integer.
        (
            "flash.reconcile-alias",
            json!({"targetId": "TGT-HOST", "expectedBindingRevision": "2"}),
            "invalidParams",
            "targetId and expectedBindingRevision are required",
        ),
        (
            "flash.reconcile-alias",
            json!({"targetId": "TGT-HOST", "expectedBindingRevision": 2.5}),
            "invalidParams",
            "targetId and expectedBindingRevision are required",
        ),
        (
            "debug.status",
            json!({"invocationId": "debug-a", "extra": true}),
            "invalidParams",
            "debug.status accepts exactly invocationId",
        ),
        (
            "debug.status",
            json!({"invocationId": 7}),
            "invalidParams",
            "debug.status accepts exactly invocationId",
        ),
        (
            "recovery.flash-invocation.list",
            json!({"page": 1}),
            "invalidParams",
            "Flash invocation list accepts only pageSize and cursor",
        ),
        (
            "recovery.flash-invocation.list",
            json!({"pageSize": "4"}),
            "invalidParams",
            "pageSize must be between 1 and 1000",
        ),
    ] {
        let answer = call(&control, 1, method, params.clone());
        assert_eq!(answer["error"]["code"], code, "{method} {params}");
        assert_eq!(answer["error"]["message"], message, "{method} {params}");
    }
    // A revision with no fraction is Foundation's integer, and an extra
    // parameter is ignored: the Target is simply not adopted here.
    for params in [
        json!({"targetId": "TGT-HOST", "expectedBindingRevision": 2.0}),
        json!({"targetId": "TGT-HOST", "expectedBindingRevision": 2, "extra": true}),
    ] {
        assert_eq!(
            call(&control, 2, "flash.reconcile-alias", params)["error"]["message"],
            "post-flash alias reconciliation was refused: admissionRejected(\"selected target \
             or binding revision is stale\")"
        );
    }
}
