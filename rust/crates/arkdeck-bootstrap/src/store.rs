//! The Bootstrap store's one lock protocol, as Swift's `BootstrapBundleRegistry.
//! locked`/`withSharedStore` runs it for every family: the store directory
//! created owner-only where it is missing, its `.lock` taken without waiting
//! and bound to the directory, and each index read strictly — published empty
//! first only when it is absent and nothing it would describe is retained.
//! The bundle references and the HDC selection ledger both read the bundle
//! index through here, so the CLI and the Runtime initialize it identically.
use arkdeck_contract::WireError;
use arkdeck_platform::{DocumentPublishError, HostDirectory, HostReadLock};
use serde_json::{Map, json};
use std::{io, os::unix::fs::DirBuilderExt, path::Path};

pub(crate) const MAX_INDEX: usize = 4 * 1024 * 1024;
pub(crate) const BUNDLES: &str = "bundles.json";
pub(crate) const TOOLS: &str = "tools.json";
const EMPTY_BUNDLES: &[u8] = b"{\"records\":[],\"schemaVersion\":\"arkdeck.bootstrap-bundles/1\"}";
const EMPTY_TOOLS: &[u8] = b"{\"records\":[],\"schemaVersion\":\"arkdeck.bootstrap-tools/2\"}";

pub(crate) fn failure(code: &str, message: &str) -> WireError {
    WireError {
        code: code.into(),
        message: message.into(),
        details: Some(Map::from_iter([
            ("phase".into(), json!("bootstrapRegistryOwner")),
            ("newDispatchCount".into(), json!(0)),
        ])),
    }
}

/// Swift `openDirectory(root, create: true, privateLeaf: true)` for a writer
/// that may be the store's first: every missing directory of `path` created
/// owner-only; the store must then be the caller's own private directory,
/// reached through no link.
pub fn create_store(path: &Path) -> Result<(), WireError> {
    if !path.is_absolute() {
        return Err(failure(
            "invalidInput",
            "bundle and registry locations must be absolute local paths",
        ));
    }
    std::fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(path)
        .map_err(|_| failure("ioFailure", "cannot create private registry directory"))?;
    if path.canonicalize().is_ok_and(|canonical| canonical != path) {
        return Err(failure("fileIdentityChanged", "directory is symbolic"));
    }
    HostDirectory::open(path).map(|_| ()).map_err(|error| {
        if error.kind() == io::ErrorKind::InvalidData {
            failure(
                "fileIdentityChanged",
                "registry must be owned by the current user with private permissions",
            )
        } else {
            failure("ioFailure", "directory is absent or inaccessible")
        }
    })
}

/// Swift `locked`: the store still at its path, its `.lock` taken without
/// waiting (another holder is a refusal, never a wait), and the lock bound to
/// the store.
pub(crate) fn lock(root: &HostDirectory, path: &Path) -> Result<HostReadLock, WireError> {
    root.validate_path(path)
        .map_err(|_| failure("fileIdentityChanged", "bootstrap store directory changed"))?;
    let lock = root.lock_document(".lock").map_err(|error| {
        if error.kind() == io::ErrorKind::WouldBlock {
            failure(
                "resourceConflict",
                "another bootstrap operation holds the store; retry after it completes",
            )
        } else {
            failure("recordUnreadable", "bootstrap owner lock is unsafe")
        }
    })?;
    binding(root, path, &lock)?;
    Ok(lock)
}

/// The lock still the store's `.lock`, and the store still at its path.
pub(crate) fn binding(
    root: &HostDirectory,
    path: &Path,
    lock: &HostReadLock,
) -> Result<(), WireError> {
    lock.validate_link(root, ".lock")
        .map_err(|_| failure("fileIdentityChanged", "bootstrap lock was replaced"))?;
    root.validate_path(path)
        .map_err(|_| failure("fileIdentityChanged", "bootstrap store directory changed"))
}

/// Swift `readIndex(_:create:)` of either index: an absent one is created
/// empty only when nothing it would describe is in the store.
pub(crate) fn index_bytes(
    root: &HostDirectory,
    path: &Path,
    lock: &HostReadLock,
    name: &str,
) -> Result<Vec<u8>, WireError> {
    let (missing, unreadable) = if name == BUNDLES {
        (
            "bundle index is missing beside retained bootstrap state",
            "bundle index failed bounded schema and identity validation",
        )
    } else {
        (
            "tool index is missing beside retained tool state",
            "tool index failed bounded schema and identity validation",
        )
    };
    match root.read(name, MAX_INDEX) {
        Ok(bytes) => Ok(bytes),
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            let names = root
                .names(65_536)
                .map_err(|_| failure("recordUnreadable", unreadable))?;
            let occupied = if name == BUNDLES {
                names.iter().any(|name| name != ".lock")
            } else {
                names
                    .iter()
                    .any(|name| name.starts_with("tool-") || name.starts_with(".tool-"))
            };
            if occupied {
                return Err(failure("recordUnreadable", missing));
            }
            binding(root, path, lock)?;
            let empty = if name == BUNDLES {
                EMPTY_BUNDLES
            } else {
                EMPTY_TOOLS
            };
            root.publish_document(name, empty, MAX_INDEX)
                .map_err(initialization)?;
            Ok(empty.to_vec())
        }
        Err(_) => Err(failure("recordUnreadable", unreadable)),
    }
}

/// An index's first, empty publication failing, in the tool ledger's words.
fn initialization(error: DocumentPublishError) -> WireError {
    match error {
        DocumentPublishError::BeforePublication(_) => {
            failure("ioFailure", "cannot publish tool index")
        }
        DocumentPublishError::OutcomeUnknown(_) => failure(
            "outcomeUnknown",
            "host tool index was published but durable completion is unconfirmed",
        ),
    }
}
