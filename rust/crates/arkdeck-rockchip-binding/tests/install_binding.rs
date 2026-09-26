//! Swift's `flash install-binding` below its rendering, replayed from its
//! oracle (`rust/tests/fixtures/rockchip-binding-install`,
//! `RockchipBindingInstallOracleContractTests`, whose owners are
//! `RockchipProductBindingBootstrap.installCurrentTarget`,
//! `RockchipProductUSBProbe.singleDAYU200` and
//! `RockchipProductBindingStore.install`) over the same root, serialized with
//! the Swift oracle by one `flock`: each step's setup performed as recorded —
//! the identities the census answers, a file written, removed, hard-linked or
//! re-moded, a directory or a symbolic link made — the install answered as
//! Swift answered it, the receipt or the refusal as its CLI interpolates it,
//! and the root left as Swift left it: every entry's kind and mode, a file's
//! size, a link's destination, and every file byte for byte.
#![cfg(target_os = "macos")]

use arkdeck_platform::{RegistryUnavailable, UsbHostDevice};
use arkdeck_rockchip_binding::{RockchipBindingStore, install_current_target};
use serde_json::{Value, json};
use std::fs::{self, OpenOptions};
use std::os::unix::fs::{PermissionsExt, symlink};
use std::path::{Path, PathBuf};

const ROOT: &str = "/private/tmp/arkdeck-binding-install-oracle";
const LOCK: &str = "/private/tmp/arkdeck-binding-install-oracle.lock";

fn fixture() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/fixtures/rockchip-binding-install")
}

/// The oracle's record of one census entry.
fn device(value: &Value) -> UsbHostDevice {
    UsbHostDevice {
        serial: value["serial"].as_str().unwrap().into(),
        vendor_id: u16::try_from(value["vendorId"].as_u64().unwrap()).unwrap(),
        product_id: u16::try_from(value["productId"].as_u64().unwrap()).unwrap(),
        topology: value["topology"].as_str().unwrap().into(),
        product_name: value["productName"].as_str().map(str::to_owned),
        registry_entry_id: value["registryEntryId"].as_u64(),
    }
}

fn mode(action: &Value) -> fs::Permissions {
    fs::Permissions::from_mode(u32::from_str_radix(action["mode"].as_str().unwrap(), 8).unwrap())
}

/// Every entry below `root` in path order without following a link, as the
/// oracle lists them, and each file's bytes.
fn entries(
    root: &Path,
    relative: &str,
    listing: &mut Vec<Value>,
    files: &mut Vec<(String, Vec<u8>)>,
) {
    let directory = if relative.is_empty() {
        root.to_path_buf()
    } else {
        root.join(relative)
    };
    let mut names: Vec<String> = fs::read_dir(&directory)
        .unwrap()
        .map(|entry| entry.unwrap().file_name().into_string().unwrap())
        .collect();
    names.sort();
    for name in names {
        let path = if relative.is_empty() {
            name
        } else {
            format!("{relative}/{name}")
        };
        let metadata = fs::symlink_metadata(root.join(&path)).unwrap();
        let mode = format!("{:o}", metadata.permissions().mode() & 0o777);
        if metadata.file_type().is_symlink() {
            let destination = fs::read_link(root.join(&path)).unwrap();
            listing.push(json!({"path": path, "kind": "link",
                "destination": destination.to_str().unwrap()}));
        } else if metadata.is_dir() {
            listing.push(json!({"path": path, "mode": mode, "kind": "directory"}));
            entries(root, &path, listing, files);
        } else {
            listing.push(json!({"path": path, "mode": mode, "kind": "file",
                "bytes": metadata.len()}));
            files.push((path.clone(), fs::read(root.join(&path)).unwrap()));
        }
    }
}

/// The root removed however the replay ends.
struct Root(PathBuf);

impl Drop for Root {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

#[test]
fn every_install_step_is_swifts() {
    let lock = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .open(LOCK)
        .unwrap();
    lock.lock().unwrap();
    let root = Root(PathBuf::from(ROOT));
    let _ = fs::remove_dir_all(&root.0);
    fs::create_dir(&root.0).unwrap();
    fs::set_permissions(&root.0, fs::Permissions::from_mode(0o700)).unwrap();
    let store = RockchipBindingStore::new(&root.0.join("ArkDeck"));
    let cases: Value =
        serde_json::from_slice(&fs::read(fixture().join("cases.json")).unwrap()).unwrap();
    let mut census: Option<Vec<UsbHostDevice>> = Some(Vec::new());
    let mut differences = Vec::new();
    let steps = cases["steps"].as_array().unwrap();
    assert_eq!(steps.len(), 35);
    for step in steps {
        let name = step["name"].as_str().unwrap();
        for action in step["setup"].as_array().unwrap() {
            let path = || root.0.join(action["path"].as_str().unwrap());
            match action["action"].as_str().unwrap() {
                "usb" => {
                    census = action["devices"]
                        .as_array()
                        .map(|devices| devices.iter().map(device).collect());
                }
                "write" => {
                    let bytes =
                        fs::read(fixture().join(action["input"].as_str().unwrap())).unwrap();
                    let _ = fs::remove_file(path());
                    fs::write(path(), bytes).unwrap();
                    fs::set_permissions(path(), mode(action)).unwrap();
                }
                "remove" => {
                    if fs::symlink_metadata(path()).unwrap().is_dir() {
                        fs::remove_dir_all(path()).unwrap();
                    } else {
                        fs::remove_file(path()).unwrap();
                    }
                }
                "chmod" => fs::set_permissions(path(), mode(action)).unwrap(),
                "mkdir" => {
                    fs::create_dir(path()).unwrap();
                    fs::set_permissions(path(), mode(action)).unwrap();
                }
                "symlink" => symlink(action["destination"].as_str().unwrap(), path()).unwrap(),
                "link" => {
                    fs::hard_link(root.0.join(action["existing"].as_str().unwrap()), path())
                        .unwrap();
                }
                other => panic!("{name}: an unknown setup action {other}"),
            }
        }
        let devices = census.clone();
        let rebind = step["rebind"].as_bool().unwrap();
        let answer = match install_current_target(
            move || devices.ok_or(RegistryUnavailable::Matching),
            &store,
            rebind,
        ) {
            Ok(installed) => json!({"receipt": {
                "revision": installed.revision, "usbTopology": installed.usb_topology,
                "serialDigestSha256": installed.serial_digest_sha256, "created": installed.created}}),
            Err(error) => json!({"error": error}),
        };
        if answer != step["answer"] {
            differences.push(format!("{name}: swift {} rust {answer}", step["answer"]));
        }
        let (mut listing, mut files) = (Vec::new(), Vec::new());
        entries(&root.0, "", &mut listing, &mut files);
        let listing = Value::Array(listing);
        if listing != step["entries"] {
            differences.push(format!("{name}: swift {} rust {listing}", step["entries"]));
        }
        let prefix = format!("steps/{:02}-{name}", step["index"].as_u64().unwrap());
        for (path, bytes) in files {
            if fs::read(fixture().join(&prefix).join(&path))
                .ok()
                .as_deref()
                != Some(&bytes[..])
            {
                differences.push(format!("{name}: {path} is not Swift's"));
            }
        }
    }
    assert!(differences.is_empty(), "{}", differences.join("\n"));
}
