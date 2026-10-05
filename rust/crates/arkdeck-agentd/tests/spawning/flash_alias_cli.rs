//! `flash reconcile-alias` over the Windows signed daemon's pipe: the
//! recorded Swift `flash-host-reads` refusals and repair, and the
//! `post-flash-alias` reissued lineage, with their exact durable bytes.
//! The census is synthetic and composed into this test binary alone. The
//! production reconciler still checks the Target revision, registered USB
//! personality and complete lineage before writing. No HDC is dispatched.
use crate::host::Host;
use crate::signed_daemon::{self, SignedDaemon};
use arkdeck_hoststore::FlashAliasReconciler;
use arkdeck_platform::{HostDirectory, RegistryUnavailable, UsbHostDevice};
use arkdeck_provider_hdc::UsbRelation;
use serde_json::{Value, json};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

/// Only the signed spawning test binary reads this input. Null is an
/// unavailable census; an array holds the oracle's USB observations.
const CENSUS: &str = "ARKDECK_TEST_SIGNED_DAEMON_ALIAS_CENSUS";
const ALIAS: &str = "rockchip-post-flash-hdc-binding.json";

/// Replaces only this test daemon's alias census, after its production
/// owners are composed. Without this input the composition is unchanged.
pub(crate) fn compose(host: Host, root: &Path) -> Host {
    let Some(path) = std::env::var_os(CENSUS) else {
        return host;
    };
    let path = PathBuf::from(path);
    host.with_flash_alias_reconciler(FlashAliasReconciler::new(
        root,
        move || {
            let devices: Value = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
            let Some(devices) = devices.as_array() else {
                return Err(RegistryUnavailable::Matching);
            };
            Ok(devices
                .iter()
                .map(|device| {
                    // Parse the same typed USB relation as the other signed
                    // daemon census. Keep all personalities here: the
                    // production reconciler filters the registered board.
                    let relation = UsbRelation::from_value(&json!({
                        "serial": device["serial"],
                        "location": device["topology"],
                        "attachmentId": device["registryEntryId"].as_u64().unwrap_or(0),
                        "vendorId": device["vendorId"],
                        "productId": device["productId"],
                    }))
                    .expect("the oracle's USB relation");
                    UsbHostDevice {
                        serial: relation.serial,
                        topology: relation.location,
                        registry_entry_id: device["registryEntryId"].as_u64(),
                        vendor_id: relation.vendor_id,
                        product_id: relation.product_id,
                        product_name: device["productName"].as_str().map(str::to_owned),
                    }
                })
                .collect())
        },
        crate::host::utc_now,
    ))
}

struct Scratch(PathBuf);

impl Drop for Scratch {
    fn drop(&mut self) {
        if !std::thread::panicking() {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
}

fn document(path: &Path) -> Value {
    serde_json::from_slice(&fs::read(path).unwrap()).unwrap()
}

fn write_private(path: &Path, bytes: &[u8]) {
    let parent = HostDirectory::open_or_create_private(path.parent().unwrap()).unwrap();
    if path.exists() {
        fs::remove_file(path).unwrap();
    }
    parent
        .create_document(path.file_name().unwrap().to_str().unwrap(), bytes)
        .unwrap();
}

fn daemon_path(root: &Path, recorded: &str) -> PathBuf {
    match recorded.strip_prefix("state/targets/") {
        Some(name) => root.join("targets-state").join(name),
        None => root.join(recorded),
    }
}

fn set_mode(path: &Path, mode: &str) {
    assert_eq!(mode, "644", "the oracle's only wider alias mode");
    let output = Command::new("icacls")
        .arg(path)
        .args(["/grant", "*S-1-5-32-545:(R)"])
        .stdin(Stdio::null())
        .output()
        .unwrap();
    assert!(output.status.success(), "{output:?}");
}

fn setup(root: &Path, census: &Path, fixture: &Path, actions: &Value) {
    for action in actions.as_array().unwrap() {
        match action["action"].as_str().unwrap() {
            "usb" => fs::write(census, serde_json::to_vec(&action["devices"]).unwrap()).unwrap(),
            "write" => {
                assert_eq!(action["mode"], "600");
                write_private(
                    &daemon_path(root, action["path"].as_str().unwrap()),
                    &fs::read(fixture.join(action["input"].as_str().unwrap())).unwrap(),
                );
            }
            "remove" => {
                fs::remove_file(daemon_path(root, action["path"].as_str().unwrap())).unwrap()
            }
            "chmod" => set_mode(
                &daemon_path(root, action["path"].as_str().unwrap()),
                action["mode"].as_str().unwrap(),
            ),
            action => panic!("an unexpected alias setup: {action}"),
        }
    }
}

fn alias_file(name: &str) -> bool {
    name == ALIAS
        || name == ".rockchip-post-flash-hdc-binding.lock"
        || name.starts_with("post-flash-superseded-")
}

fn assert_files(root: &Path, fixture: &Path, exchange: &Value) {
    let name = exchange["name"].as_str().unwrap();
    let index = exchange["index"].as_u64().unwrap();
    let files = exchange["files"].as_array().unwrap();
    let mut actual: Vec<String> = fs::read_dir(root)
        .unwrap()
        .map(|entry| entry.unwrap().file_name().into_string().unwrap())
        .filter(|name| alias_file(name))
        .collect();
    let mut expected: Vec<String> = files
        .iter()
        .map(|file| file["path"].as_str().unwrap().to_owned())
        .collect();
    actual.sort();
    expected.sort();
    assert_eq!(actual, expected, "{name}: alias file names");
    let directory = HostDirectory::open(root).unwrap();
    for file in files {
        let path = file["path"].as_str().unwrap();
        let bytes = fs::read(root.join(path)).unwrap();
        assert_eq!(file["kind"], "file");
        assert_eq!(bytes.len() as u64, file["bytes"].as_u64().unwrap());
        let private = directory.owner_only_document(path);
        match file["mode"].as_str().unwrap() {
            "600" => assert!(private.is_ok(), "{name}: {path} is private: {private:?}"),
            "644" => assert!(private.is_err(), "{name}: {path} is shared"),
            mode => panic!("an unexpected alias file mode: {mode}"),
        }
        let expected = if path.starts_with('.') {
            Vec::new()
        } else {
            fs::read(fixture.join(format!("steps/{index:02}-{name}/{path}"))).unwrap()
        };
        assert_eq!(bytes, expected, "{name}: {path} bytes");
    }
}

fn arguments(params: &Value) -> Vec<String> {
    let mut arguments = vec!["flash".into(), "reconcile-alias".into()];
    if let Some(target) = params["targetId"].as_str() {
        arguments.extend(["--target".into(), target.into()]);
    }
    if let Some(revision) = params.get("expectedBindingRevision") {
        arguments.extend(["--expected-binding-revision".into(), revision.to_string()]);
    }
    arguments
}

#[test]
fn the_signed_cli_reconciles_aliases_as_the_swift_host_reads_oracle() {
    let _turn = crate::turn();
    let scratch = Scratch(signed_daemon::temporary("flash-alias-cli"));
    let Some((executable, pin)) = signed_daemon::signed_copy(&scratch.0.join("signed-bin")) else {
        return;
    };
    let (root, fake_root, census) = (
        scratch.0.join("state"),
        scratch.0.join("fake"),
        scratch.0.join("alias-census.json"),
    );
    HostDirectory::open_or_create_private(&root).unwrap();
    fs::create_dir_all(&fake_root).unwrap();
    fs::write(&census, b"[]").unwrap();
    let fixture = signed_daemon::fixtures("flash-host-reads");
    let fake_fixture = signed_daemon::fixtures("debug-hap");
    let variables = [
        (CENSUS, census.to_str().unwrap().to_owned()),
        (
            signed_daemon::CLOCK,
            "2026-09-25T00:00:00Z|2026-09-25T00:00:00.000Z".into(),
        ),
    ];
    let start = || {
        SignedDaemon::start_with(
            &executable,
            &pin,
            &root,
            &fake_fixture,
            &fake_root,
            &variables,
        )
    };
    let mut daemon = start();
    let cases = document(&fixture.join("cases.json"));
    let exchanges: Vec<&Value> = cases["exchanges"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|exchange| exchange["method"] == "flash.reconcile-alias")
        .collect();
    assert_eq!(exchanges.len(), 21);
    for exchange in exchanges {
        let name = exchange["name"].as_str().unwrap();
        setup(&root, &census, &fixture, &exchange["setup"]);
        if name == "alias.repeated" {
            // The successful archive and republished alias survive a new
            // process; the same lineage cannot be reconciled again.
            daemon.stop();
            daemon = start();
        }
        let arguments = arguments(&exchange["params"]);
        let arguments: Vec<&str> = arguments.iter().map(String::as_str).collect();
        let (status, envelope) = daemon.cli(&arguments);
        assert_eq!(
            envelope["command"], "flash.reconcile-alias",
            "{name}: {envelope}"
        );
        let parser_error = match name {
            "alias.noParameters" => Some("`flash reconcile-alias` requires --target <target-id>"),
            "alias.noRevision" => {
                Some("`flash reconcile-alias` requires --expected-binding-revision <n>")
            }
            "alias.zeroRevision" => {
                Some("`flash reconcile-alias` --expected-binding-revision must be 1 or greater")
            }
            _ => None,
        };
        if let Some(message) = parser_error {
            assert_ne!(status, Some(0), "{name}: {envelope}");
            assert_eq!(
                envelope["error"]["code"], "invalidOption",
                "{name}: {envelope}"
            );
            assert_eq!(envelope["error"]["message"], message, "{name}: {envelope}");
        } else {
            assert_eq!(
                status == Some(0),
                exchange["answer"]["ok"] == true,
                "{name}: {envelope}"
            );
            assert_eq!(
                crate::gj23_replay::wire(&envelope),
                exchange["answer"],
                "{name}"
            );
        }
        assert_files(&root, &fixture, exchange);
        assert!(
            crate::gj1_device_leaves::calls(&fake_root).is_empty(),
            "{name}: no HDC dispatch"
        );
    }
    daemon.stop();
    crate::gj1_device_leaves::assert_windows_status(&["flash.reconcile-alias"], "implemented");
}

#[test]
fn the_signed_cli_republishes_the_post_flash_alias_oracles_lineage_bytes() {
    let _turn = crate::turn();
    let scratch = Scratch(signed_daemon::temporary("post-flash-alias-cli"));
    let Some((executable, pin)) = signed_daemon::signed_copy(&scratch.0.join("signed-bin")) else {
        return;
    };
    let (root, fake_root, census) = (
        scratch.0.join("state"),
        scratch.0.join("fake"),
        scratch.0.join("alias-census.json"),
    );
    HostDirectory::open_or_create_private(&root).unwrap();
    fs::create_dir_all(&fake_root).unwrap();
    let fixture = signed_daemon::fixtures("post-flash-alias");
    let cases = document(&fixture.join("cases.json"));
    let case = cases
        .as_array()
        .unwrap()
        .iter()
        .find(|case| case["step"] == "reissue-reconciled")
        .unwrap();
    let input = &case["input"];
    write_private(
        &root.join("targets-state/targets.json"),
        &serde_json::to_vec(&json!({"schemaVersion": "1.0.0", "targets": [input["target"]]}))
            .unwrap(),
    );
    write_private(
        &root.join(ALIAS),
        &fs::read(
            fixture
                .join("steps/06-rotate-serial-same-revision")
                .join(ALIAS),
        )
        .unwrap(),
    );
    fs::write(&census, serde_json::to_vec(&json!([{
        "serial": input["observedHDCConnectKey"], "topology": input["observedUSBTopology"],
        "registryEntryId": 42, "vendorId": arkdeck_provider_hdc::ROCKUSB_VENDOR_ID,
        "productId": arkdeck_provider_hdc::DAYU200_NORMAL_PRODUCT_ID, "productName": "HDC Device"
    }])).unwrap()).unwrap();
    let now = input["nowUTC"].as_str().unwrap();
    let daemon = SignedDaemon::start_with(
        &executable,
        &pin,
        &root,
        &signed_daemon::fixtures("debug-hap"),
        &fake_root,
        &[
            (CENSUS, census.to_str().unwrap().into()),
            (signed_daemon::CLOCK, format!("{now}|{now}")),
        ],
    );
    let (status, envelope) = daemon.cli(&[
        "flash",
        "reconcile-alias",
        "--target",
        "TGT-HOST",
        "--expected-binding-revision",
        "2",
    ]);
    assert_eq!(status, Some(0), "{envelope}");
    assert_eq!(
        envelope["result"],
        json!({
            "targetId": "TGT-HOST", "reconciled": true, "archivedBindingRevision": 4,
            "bindingRevision": 2, "hdcIdentitySha256": case["outcome"]["reconciled"]["hdcIdentitySHA256"],
        })
    );
    let directory = HostDirectory::open(&root).unwrap();
    for (name, step) in [
        (ALIAS, "07-reissue-reconciled"),
        (
            "post-flash-superseded-20260819T000000Z.json",
            "07-reissue-reconciled",
        ),
    ] {
        assert_eq!(
            fs::read(root.join(name)).unwrap(),
            fs::read(fixture.join("steps").join(step).join(name)).unwrap(),
            "{name}"
        );
        assert!(
            directory.owner_only_document(name).is_ok(),
            "{name} is private"
        );
    }
    assert!(
        crate::gj1_device_leaves::calls(&fake_root).is_empty(),
        "no HDC dispatch"
    );
    daemon.stop();
}
