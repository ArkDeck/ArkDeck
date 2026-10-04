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
//!
//! On Windows (TASK-XPA-010) the same steps replay over a root of their own
//! below the temporary directory, with no Swift producer to serialize with:
//! an owner-only (0600/0700) entry is the store's private DACL, a shared mode
//! is a read entry for the local Users group (removed again when the oracle
//! restores an owner-only mode), and a symbolic link is a file or directory
//! link to the same relative destination. Every answer and every byte must
//! still be Swift's; each entry's kind, size and link destination too, but
//! not its mode, which Windows does not have.
#![cfg(any(target_os = "macos", windows))]

use arkdeck_platform::{RegistryUnavailable, UsbHostDevice};
use arkdeck_rockchip_binding::{RockchipBindingStore, install_current_target};
use serde_json::{Value, json};
use std::fs;
#[cfg(unix)]
use std::fs::OpenOptions;
#[cfg(unix)]
use std::os::unix::fs::{PermissionsExt, symlink};
use std::path::{Path, PathBuf};

#[cfg(unix)]
const ROOT: &str = "/private/tmp/arkdeck-binding-install-oracle";
#[cfg(unix)]
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

#[cfg(unix)]
fn set_mode(path: &Path, action: &Value) {
    fs::set_permissions(
        path,
        fs::Permissions::from_mode(
            u32::from_str_radix(action["mode"].as_str().unwrap(), 8).unwrap(),
        ),
    )
    .unwrap();
}

/// A recorded mode, the Windows way: owner-only is the private DACL an entry
/// inherits from its private directory; anything wider gives the local Users
/// group read access, which owner-only takes away again.
#[cfg(windows)]
fn set_mode(path: &Path, action: &Value) {
    let text = action["mode"].as_str().unwrap();
    let arguments: &[&str] = if text == "600" || text == "700" {
        &["/remove:g", "*S-1-5-32-545"]
    } else {
        &["/grant", "*S-1-5-32-545:(R)"]
    };
    let status = std::process::Command::new("icacls")
        .arg(path)
        .args(arguments)
        .stdout(std::process::Stdio::null())
        .status()
        .unwrap();
    assert!(status.success(), "icacls {}", path.display());
}

/// A link to `destination`, relative to the link's directory.
#[cfg(windows)]
fn symlink(destination: &str, path: PathBuf) -> std::io::Result<()> {
    let directory = path.parent().unwrap().join(destination).is_dir();
    if directory {
        std::os::windows::fs::symlink_dir(destination, path)
    } else {
        std::os::windows::fs::symlink_file(destination, path)
    }
}

/// Removes a file; on Windows one the store wrote read-only is made
/// writable first, as `unlink` ignores the mode on macOS.
fn remove_file(path: &Path) {
    // A Windows directory link is removed as a directory.
    #[cfg(windows)]
    if fs::symlink_metadata(path).is_ok_and(|metadata| metadata.file_type().is_symlink())
        && fs::metadata(path).is_ok_and(|metadata| metadata.is_dir())
    {
        fs::remove_dir(path).unwrap_or_else(|error| panic!("{}: {error}", path.display()));
        return;
    }
    #[cfg(windows)]
    if let Ok(metadata) = fs::symlink_metadata(path)
        && metadata.is_file()
        && metadata.permissions().readonly()
    {
        let mut permissions = metadata.permissions();
        #[allow(clippy::permissions_set_readonly_false)]
        permissions.set_readonly(false);
        fs::set_permissions(path, permissions).unwrap();
    }
    fs::remove_file(path).unwrap_or_else(|error| panic!("{}: {error}", path.display()));
}

/// An entry's mode as the oracle records it (Windows has none).
fn mode_of(metadata: &fs::Metadata) -> String {
    #[cfg(unix)]
    return format!("{:o}", metadata.permissions().mode() & 0o777);
    #[cfg(windows)]
    {
        let _ = metadata;
        "-".to_owned()
    }
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
        let mode = mode_of(&metadata);
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

/// The oracle's root, owner-only: on macOS its fixed path, serialized with
/// the Swift producer by one `flock`; on Windows a root of its own.
#[cfg(unix)]
fn oracle_root() -> (Root, Option<fs::File>) {
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
    (root, Some(lock))
}

#[cfg(windows)]
fn oracle_root() -> (Root, Option<fs::File>) {
    let temporary = std::env::temp_dir().canonicalize().unwrap();
    let temporary = temporary
        .to_str()
        .and_then(|text| text.strip_prefix(r"\\?\"))
        .map_or(temporary.clone(), PathBuf::from);
    let root = Root(temporary.join(format!(
        "arkdeck-binding-install-oracle-{:x}",
        u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap())
    )));
    arkdeck_platform::HostDirectory::open_or_create_private(&root.0).unwrap();
    (root, None)
}

/// The entries as this host lists them: on Windows each mode is `-`.
fn recorded_entries(entries: &Value) -> Value {
    #[cfg(unix)]
    return entries.clone();
    #[cfg(windows)]
    {
        let mut entries = entries.clone();
        for entry in entries.as_array_mut().unwrap() {
            if entry.get("mode").is_some() {
                entry["mode"] = json!("-");
            }
        }
        entries
    }
}

#[test]
fn every_install_step_is_swifts() {
    let (root, _lock) = oracle_root();
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
                    if fs::symlink_metadata(path()).is_ok() {
                        remove_file(&path());
                    }
                    fs::write(path(), bytes).unwrap();
                    set_mode(&path(), action);
                }
                "remove" => {
                    if fs::symlink_metadata(path()).unwrap().is_dir() {
                        fs::remove_dir_all(path()).unwrap();
                    } else {
                        remove_file(&path());
                    }
                }
                "chmod" => set_mode(&path(), action),
                "mkdir" => {
                    fs::create_dir(path()).unwrap();
                    set_mode(&path(), action);
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
        let recorded = recorded_entries(&step["entries"]);
        if listing != recorded {
            differences.push(format!("{name}: swift {recorded} rust {listing}"));
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
