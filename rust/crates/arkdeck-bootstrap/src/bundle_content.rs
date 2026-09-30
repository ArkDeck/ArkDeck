//! Fresh, bounded content and production-signature checks for daemon Bundles.
//! Digest metadata is measured from bytes; no registration or trust is written.
#[cfg(target_os = "macos")]
use arkdeck_contract::{canonical_json, sha256_hex};
#[cfg(target_os = "macos")]
use arkdeck_platform::{
    BootstrapTree, bootstrap_bundle_version, inspect_bootstrap_tree,
    validate_production_daemon_bundle,
};
#[cfg(target_os = "macos")]
use serde_json::{Value, json};
#[cfg(target_os = "macos")]
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
}
#[cfg(target_os = "macos")]
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
#[cfg(target_os = "macos")]
fn content(tree: &BootstrapTree, version: Option<String>) -> io::Result<BundleContent> {
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
    let bytes =
        canonical_json(&json!({"schemaVersion":"arkdeck.bundle-content/1","entries":entries}))
            .map_err(|_| unreadable())?;
    Ok(BundleContent {
        digest: sha256_hex(&bytes),
        byte_count: tree.byte_count,
        entry_count: tree.entries.len(),
        version,
    })
}
#[cfg(target_os = "macos")]
fn inspect(
    path: &Path,
    expected: Option<&BundleContent>,
    validate: &dyn Fn(&Path) -> io::Result<PathBuf>,
) -> io::Result<BundleContent> {
    let before = inspect_bootstrap_tree(path).map_err(|_| unreadable())?;
    let measured = content(&before, version(&before, path)?)?;
    if expected.is_some_and(|value| value != &measured) {
        return Err(unreadable());
    }
    // Native Security checks the whole Bundle, with its exact production
    // requirement. A durable record cannot substitute for this fresh check.
    if validate(path)? != path {
        return Err(unreadable());
    }
    let after = inspect_bootstrap_tree(path).map_err(|_| unreadable())?;
    if after != before || version(&after, path)? != measured.version {
        return Err(unreadable());
    }
    Ok(measured)
}
/// The Bundle's content measured and checked against the production helper
/// policy (`validate_production_daemon_bundle`).
#[cfg(target_os = "macos")]
pub fn inspect_bundle_content(path: &Path) -> io::Result<BundleContent> {
    inspect(path, None, &validate_production_daemon_bundle)
}
/// The same measurement, checked against `validate`: the policy a store
/// holds its retained Bundles to (`BundleRegistryReadStore::
/// with_bundle_validator`).
#[cfg(target_os = "macos")]
pub fn inspect_bundle_content_with(
    path: &Path,
    validate: &dyn Fn(&Path) -> io::Result<PathBuf>,
) -> io::Result<BundleContent> {
    inspect(path, None, validate)
}
#[cfg(target_os = "macos")]
pub(crate) fn verify_bundle_content(
    path: &Path,
    expected: &BundleContent,
    validate: &dyn Fn(&Path) -> io::Result<PathBuf>,
) -> io::Result<()> {
    inspect(path, Some(expected), validate).map(|_| ())
}
/// A retained Bundle on Windows: the store's policy decides before any content
/// is measured, and until the Windows daemon-bundle checks are built
/// (`windows_registration`) the Windows policy (`no_windows_bundle_policy`)
/// admits none.
#[cfg(windows)]
pub(crate) fn verify_bundle_content(
    path: &Path,
    _expected: &BundleContent,
    validate: &dyn Fn(&Path) -> io::Result<PathBuf>,
) -> io::Result<()> {
    validate(path).map(|_| ())
}
/// The Windows daemon-bundle policy until its checks are built: nothing is
/// admitted; a refusal is `PermissionDenied`, as the macOS helper policy
/// refuses an untrusted Bundle.
#[cfg(windows)]
pub fn no_windows_bundle_policy(_path: &Path) -> io::Result<PathBuf> {
    Err(io::Error::new(
        io::ErrorKind::PermissionDenied,
        "the Windows daemon-bundle checks are not built yet",
    ))
}
