//! Fresh, bounded content and production-signature checks for daemon Bundles.
//! Digest metadata is measured from bytes; no registration or trust is written.
//!
//! On macOS a daemon Bundle is the helper `.app`, checked against the
//! production helper policy. On Windows it is a release-candidate package
//! tree (`windows/scripts/package-rc.ps1`): its `rc-manifest.json` names every
//! other file with its size and SHA-256 and the tree holds exactly those, and
//! its `arkdeck-agentd.exe` must be signed as the running Runtime is
//! (maintainer ruling 17: the same development signer's leaf, or the same
//! production publisher). The Windows content digest adds `"platform":
//! "windows"`, so a Windows reference never equals a macOS one.
use arkdeck_contract::{canonical_json, sha256_hex};
use arkdeck_platform::{BootstrapTree, inspect_bootstrap_tree};
#[cfg(target_os = "macos")]
use arkdeck_platform::{bootstrap_bundle_version, validate_production_daemon_bundle};
use serde_json::{Value, json};
use std::io::Read;
use std::{
    io,
    path::{Path, PathBuf},
};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BundleContent {
    pub digest: String,
    pub byte_count: u64,
    pub entry_count: usize,
    pub version: Option<String>,
    /// The Windows daemon image's signer name; none on macOS.
    pub signer: Option<String>,
}

/// The store's name for a retained Bundle's content.
pub(crate) fn retained_name(digest: &str) -> String {
    if cfg!(windows) {
        format!("bundle-{digest}.rc")
    } else {
        format!("bundle-{digest}.app")
    }
}
/// Whether a store entry is retained Bundle content.
pub(crate) fn is_retained_name(name: &str) -> bool {
    name.starts_with("bundle-") && name.ends_with(if cfg!(windows) { ".rc" } else { ".app" })
}

fn unreadable() -> io::Error {
    io::Error::new(
        io::ErrorKind::InvalidData,
        "registered bundle content or identity is unreadable",
    )
}
#[cfg(target_os = "macos")]
fn version(tree: &BootstrapTree, root: &Path) -> io::Result<Option<String>> {
    let file = tree
        .open_relative_file(root, "Contents/Info.plist")
        .map_err(|_| unreadable())?;
    if file.metadata()?.len() > 64 * 1024 {
        return Err(unreadable());
    }
    let mut bytes = Vec::new();
    file.take(64 * 1024 + 1).read_to_end(&mut bytes)?;
    bootstrap_bundle_version(&bytes).map_err(|_| unreadable())
}

/// The release-candidate manifest (`arkdeck.windows-rc-package/1`) at the
/// tree's root, checked against the tree: it names exactly the tree's other
/// files, each with its size and SHA-256, the daemon among them. The
/// package's version, printable and bounded.
#[cfg(windows)]
const MANIFEST: &str = "rc-manifest.json";
#[cfg(windows)]
pub(crate) const DAEMON: &str = "arkdeck-agentd.exe";
#[cfg(windows)]
fn version(tree: &BootstrapTree, root: &Path) -> io::Result<Option<String>> {
    let file = tree
        .open_relative_file(root, MANIFEST)
        .map_err(|_| unreadable())?;
    if file.metadata()?.len() > 16 * 1024 * 1024 {
        return Err(unreadable());
    }
    let mut bytes = Vec::new();
    file.take(16 * 1024 * 1024 + 1).read_to_end(&mut bytes)?;
    let manifest: Value = serde_json::from_slice(&bytes).map_err(|_| unreadable())?;
    if manifest["schemaVersion"] != "arkdeck.windows-rc-package/1" {
        return Err(unreadable());
    }
    let mut named: Vec<(String, u64, String)> = manifest["files"]
        .as_array()
        .ok_or_else(unreadable)?
        .iter()
        .map(|file| {
            Some((
                file["path"].as_str()?.to_owned(),
                file["bytes"].as_u64()?,
                file["sha256"].as_str()?.to_owned(),
            ))
        })
        .collect::<Option<_>>()
        .ok_or_else(unreadable)?;
    named.sort_by(|a, b| a.0.as_bytes().cmp(b.0.as_bytes()));
    let present: Vec<(String, u64, String)> = tree
        .entries
        .iter()
        .filter(|entry| !entry.directory && entry.path != MANIFEST)
        .map(|entry| {
            (
                entry.path.clone(),
                entry.byte_count,
                entry.sha256.clone().unwrap_or_default(),
            )
        })
        .collect();
    if named != present || !present.iter().any(|(path, _, _)| path == DAEMON) {
        return Err(unreadable());
    }
    match manifest["version"].as_str() {
        Some(version)
            if !version.is_empty()
                && version.len() <= 128
                && version.bytes().all(|b| (32..127).contains(&b)) =>
        {
            Ok(Some(version.to_owned()))
        }
        _ => Err(unreadable()),
    }
}

fn content(
    tree: &BootstrapTree,
    version: Option<String>,
    signer: Option<String>,
) -> io::Result<BundleContent> {
    let entries: Vec<Value> = tree
        .entries
        .iter()
        .map(|entry| {
            json!({
                "path":entry.path,"kind":if entry.directory {"directory"} else {"file"},
                "executable":entry.executable,"quarantineSHA256":entry.quarantine_sha256,
                "byteCount":entry.byte_count.to_string(),"sha256":entry.sha256,
            })
        })
        .collect();
    let document = if cfg!(windows) {
        json!({"schemaVersion":"arkdeck.bundle-content/1","platform":"windows","entries":entries})
    } else {
        json!({"schemaVersion":"arkdeck.bundle-content/1","entries":entries})
    };
    let bytes = canonical_json(&document).map_err(|_| unreadable())?;
    Ok(BundleContent {
        digest: sha256_hex(&bytes),
        byte_count: tree.byte_count,
        entry_count: tree.entries.len(),
        version,
        signer,
    })
}

/// The Windows daemon image's signer, once the store's policy admitted the
/// tree: the name its Authenticode leaf carries.
#[cfg(windows)]
fn signer(path: &Path) -> io::Result<Option<String>> {
    let trust = arkdeck_platform::inspect_native_code_signature(&path.join(DAEMON))?;
    trust
        .identifier
        .filter(|_| trust.signature == "verified")
        .map(Some)
        .ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::PermissionDenied,
                "the daemon image is not signed",
            )
        })
}
#[cfg(not(windows))]
fn signer(_path: &Path) -> io::Result<Option<String>> {
    Ok(None)
}

fn inspect(
    path: &Path,
    expected: Option<&BundleContent>,
    validate: &dyn Fn(&Path) -> io::Result<PathBuf>,
) -> io::Result<BundleContent> {
    let before = inspect_bootstrap_tree(path).map_err(|_| unreadable())?;
    let version = version(&before, path)?;
    // Native Security (macOS) or Authenticode (Windows) checks the whole
    // Bundle, with its exact production requirement. A durable record cannot
    // substitute for this fresh check. On macOS the measurement is compared
    // first; on Windows the signer a record names is read from the daemon
    // image only once the policy admitted it.
    let measured = if cfg!(windows) {
        if validate(path)? != path {
            return Err(unreadable());
        }
        content(&before, version, signer(path)?)?
    } else {
        content(&before, version, None)?
    };
    if expected.is_some_and(|value| value != &measured) {
        return Err(unreadable());
    }
    if !cfg!(windows) && validate(path)? != path {
        return Err(unreadable());
    }
    let after = inspect_bootstrap_tree(path).map_err(|_| unreadable())?;
    if after != before || self::version(&after, path)? != measured.version {
        return Err(unreadable());
    }
    Ok(measured)
}

/// The Windows daemon-package policy: the tree's `arkdeck-agentd.exe` is
/// signed as this Runtime's own image is (`arkdeck_platform::same_signer`);
/// an unsigned Runtime admits none. A refusal is `PermissionDenied`, as the
/// macOS helper policy refuses an untrusted Bundle.
#[cfg(windows)]
pub fn validate_windows_daemon_package(path: &Path) -> io::Result<PathBuf> {
    arkdeck_platform::same_signer(&path.join(DAEMON), &std::env::current_exe()?)?;
    Ok(path.to_path_buf())
}

/// The Bundle's content measured and checked against the production policy
/// (`validate_production_daemon_bundle` on macOS,
/// `validate_windows_daemon_package` on Windows).
pub fn inspect_bundle_content(path: &Path) -> io::Result<BundleContent> {
    #[cfg(target_os = "macos")]
    let policy = validate_production_daemon_bundle;
    #[cfg(windows)]
    let policy = validate_windows_daemon_package;
    inspect(path, None, &policy)
}
/// The same measurement, checked against `validate`: the policy a store
/// holds its retained Bundles to (`BundleRegistryReadStore::
/// with_bundle_validator`).
pub fn inspect_bundle_content_with(
    path: &Path,
    validate: &dyn Fn(&Path) -> io::Result<PathBuf>,
) -> io::Result<BundleContent> {
    inspect(path, None, validate)
}
pub(crate) fn verify_bundle_content(
    path: &Path,
    expected: &BundleContent,
    validate: &dyn Fn(&Path) -> io::Result<PathBuf>,
) -> io::Result<()> {
    inspect(path, Some(expected), validate).map(|_| ())
}
