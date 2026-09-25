//! The Runtime's paged Bootstrap bundle inventory over the shared owner
//! (`arkdeck_bootstrap::BundleRegistryReadStore`): paged discovery holds the
//! Bootstrap lock through the frozen snapshot pager and may initialize a
//! genuinely empty registry. No content is selected or run.
use crate::{BundleRegistryReadStore, snapshot_pager::SnapshotPager};
use arkdeck_contract::WireError;
use serde_json::{Value, json};
use std::io;
const MAXIMUM_INDEX: usize = 4 * 1024 * 1024;
/// A Bootstrap registry's inventory as the Runtime pages it:
/// `runtime.bundle.list` and `runtime.tool.list`.
pub trait BootstrapListPage {
    /// Swift's `list` through the snapshot pager: every current record scanned
    /// before the page size or cursor is validated, including on
    /// continuation requests, under the one cross-process lock.
    fn list_page(&self, page_size: usize, cursor: Option<&str>) -> Result<Value, WireError>;
}
fn corrupt() -> io::Error {
    io::Error::new(
        io::ErrorKind::InvalidData,
        "bootstrap bundle registry or content is unreadable",
    )
}
fn map_read_error(error: io::Error) -> io::Error {
    if matches!(
        error.kind(),
        io::ErrorKind::WouldBlock | io::ErrorKind::PermissionDenied
    ) {
        error
    } else {
        corrupt()
    }
}
fn wire_error(error: io::Error) -> WireError {
    let (code, message) = match error.kind() {
        io::ErrorKind::WouldBlock => ("resourceConflict", "bootstrap owner lock is held"),
        io::ErrorKind::PermissionDenied => (
            "admissionDenied",
            "bootstrap resource failed its native trust policy",
        ),
        _ => (
            "recordUnreadable",
            "bootstrap registry or retained content is unreadable",
        ),
    };
    bootstrap_error(WireError {
        code: code.into(),
        message: message.into(),
        details: None,
    })
}
fn bootstrap_error(mut error: WireError) -> WireError {
    let details = error.details.get_or_insert_default();
    details.insert("phase".into(), json!("bootstrapRegistryOwner"));
    details.insert("newDispatchCount".into(), json!(0));
    // The shared pager's diagnostics name Session storage; preserve its code
    // while describing the Bootstrap composition that actually failed.
    if error.message.starts_with("Session snapshot") {
        error.message = "Bootstrap snapshot storage is unreadable or unsafe".into();
    }
    error
}
impl BootstrapListPage for BundleRegistryReadStore {
    /// Swift `BootstrapBundleRegistry.list` scans every current record before
    /// validating page size or cursor, including on continuation requests. The
    /// same cross-process lock covers scanning and snapshot publication/read.
    fn list_page(&self, page_size: usize, cursor: Option<&str>) -> Result<Value, WireError> {
        list_page_with_checkpoint(self, page_size, cursor, |_| {})
    }
}
fn list_page_with_checkpoint(
    store: &BundleRegistryReadStore,
    page_size: usize,
    cursor: Option<&str>,
    checkpoint: impl Fn(&str),
) -> Result<Value, WireError> {
    store
        .root()
        .validate_path(store.path())
        .map_err(|_| wire_error(corrupt()))?;
    let lock = store.root().lock_document(".lock").map_err(|error| {
        wire_error(if error.kind() == io::ErrorKind::WouldBlock {
            error
        } else {
            corrupt()
        })
    })?;
    store
        .root()
        .validate_path(store.path())
        .map_err(|_| wire_error(corrupt()))?;
    let bytes = match store.root().read("bundles.json", MAXIMUM_INDEX) {
        Ok(bytes) => bytes,
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            // Swift permits only `.lock` beside a missing initial index.
            // Never infer an empty registry from surviving content or pages.
            if store
                .root()
                .names(4096)
                .map_err(|_| wire_error(corrupt()))?
                != [".lock"]
            {
                return Err(wire_error(corrupt()));
            }
            let bytes = br#"{"records":[],"schemaVersion":"arkdeck.bootstrap-bundles/1"}"#;
            lock.validate_link(store.root(), ".lock")
                .map_err(|_| wire_error(corrupt()))?;
            store
                .root()
                .validate_path(store.path())
                .map_err(|_| wire_error(corrupt()))?;
            store
                .root()
                .publish_document("bundles.json", bytes, MAXIMUM_INDEX)
                .map_err(|_| wire_error(corrupt()))?;
            store
                .root()
                .read("bundles.json", MAXIMUM_INDEX)
                .map_err(|_| wire_error(corrupt()))?
        }
        Err(_) => return Err(wire_error(corrupt())),
    };
    let identity = store
        .root()
        .document_metadata("bundles.json")
        .map_err(|_| wire_error(corrupt()))?;
    store
        .validate_index(&bytes, &identity)
        .map_err(|_| wire_error(corrupt()))?;
    let rows = store
        .verify_index(&bytes, None)
        .map_err(|error| wire_error(map_read_error(error)))?;
    store
        .validate_index(&bytes, &identity)
        .map_err(|_| wire_error(corrupt()))?;
    lock.validate_link(store.root(), ".lock")
        .map_err(|_| wire_error(corrupt()))?;
    store
        .root()
        .validate_path(store.path())
        .map_err(|_| wire_error(corrupt()))?;
    let snapshots_path = store.path().join("bundle-snapshots");
    let snapshots = store
        .root()
        .private_child("bundle-snapshots")
        .map_err(|_| wire_error(corrupt()))?;
    snapshots
        .validate_path(&snapshots_path)
        .map_err(|_| wire_error(corrupt()))?;
    let pager = SnapshotPager::open(&snapshots_path).map_err(|_| wire_error(corrupt()))?;
    checkpoint("beforePager");
    let result = pager
        .page(
            "runtime.bundle.list",
            "bundleRef:asc",
            page_size,
            cursor,
            || Ok(rows),
        )
        .map_err(bootstrap_error);
    checkpoint("afterPager");
    // Validate even after a pager error: never mask a changed registry or
    // replaced namespace with an ordinary bad-cursor result.
    store
        .validate_index(&bytes, &identity)
        .map_err(|_| wire_error(corrupt()))?;
    lock.validate_link(store.root(), ".lock")
        .map_err(|_| wire_error(corrupt()))?;
    store
        .root()
        .validate_path(store.path())
        .map_err(|_| wire_error(corrupt()))?;
    snapshots
        .validate_path(&snapshots_path)
        .map_err(|_| wire_error(corrupt()))?;
    result
}

#[cfg(test)]
#[path = "bundle_list_owner_tests.rs"]
mod list_tests;
