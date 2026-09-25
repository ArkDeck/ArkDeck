//! Combined immutable HDC and DevEco inventory. A single Bootstrap lock binds
//! every current index and native check through snapshot publication/read.
use crate::{
    BootstrapListPage, ToolRegistryStore, decode_bundles, decode_tools, deveco_content,
    deveco_registry, snapshot_pager::SnapshotPager,
};
use arkdeck_contract::WireError;
use arkdeck_platform::{DocumentPublishError, HostReadLock};
use serde_json::{Value, json};
use std::{fs::Metadata, io, os::unix::fs::MetadataExt};
const MAX_INDEX: usize = 4 * 1024 * 1024;
const BUNDLES: &str = "bundles.json";
const TOOLS: &str = "tools.json";
const DEVECO: &str = "deveco-toolchains.json";
fn failure(code: &str, message: &str) -> WireError {
    stamp(WireError {
        code: code.into(),
        message: message.into(),
        details: None,
    })
}
fn stamp(mut error: WireError) -> WireError {
    let details = error.details.get_or_insert_default();
    details.insert("phase".into(), json!("bootstrapRegistryOwner"));
    details.insert("newDispatchCount".into(), json!(0));
    if error.message.starts_with("Session snapshot") {
        error.message = "Bootstrap snapshot storage is unreadable or unsafe".into();
    }
    error
}
fn unreadable(_: impl std::fmt::Debug) -> WireError {
    failure(
        "recordUnreadable",
        "Bootstrap tool registry or retained content is unreadable",
    )
}
fn same_document(a: &Metadata, b: &Metadata) -> bool {
    a.dev() == b.dev()
        && a.ino() == b.ino()
        && a.mode() == b.mode()
        && a.uid() == b.uid()
        && a.gid() == b.gid()
        && a.nlink() == b.nlink()
        && a.len() == b.len()
        && a.mtime() == b.mtime()
        && a.mtime_nsec() == b.mtime_nsec()
        && a.ctime() == b.ctime()
        && a.ctime_nsec() == b.ctime_nsec()
}
struct Index {
    name: &'static str,
    bytes: Vec<u8>,
    identity: Metadata,
}
impl BootstrapListPage for ToolRegistryStore {
    /// Fresh inventory validation precedes page-size/cursor validation on every
    /// call. Continuations still return the original immutable snapshot rows.
    fn list_page(&self, page_size: usize, cursor: Option<&str>) -> Result<Value, WireError> {
        list_page_checkpoint(self, page_size, cursor, |_| {})
    }
}
fn list_page_checkpoint(
    store: &ToolRegistryStore,
    page_size: usize,
    cursor: Option<&str>,
    checkpoint: impl Fn(&str),
) -> Result<Value, WireError> {
    store
        .root()
        .validate_path(store.path())
        .map_err(unreadable)?;
    let lock = store.root().lock_document(".lock").map_err(|error| {
        if error.kind() == io::ErrorKind::WouldBlock {
            failure(
                "resourceConflict",
                "another Bootstrap owner holds the store",
            )
        } else {
            unreadable(error)
        }
    })?;
    list_binding(store, &lock)?;
    let bundles = list_load(store, &lock, BUNDLES)?;
    decode_bundles(&bundles.bytes).map_err(unreadable)?;
    let tools = list_load(store, &lock, TOOLS)?;
    let decoded = decode_tools(&tools.bytes).map_err(unreadable)?;
    let document: Value = serde_json::from_slice(&decoded.document).map_err(unreadable)?;
    for record in document["records"]
        .as_array()
        .ok_or_else(|| unreadable("records"))?
    {
        // Swift HDC wraps every trust/content error, and verifies removed
        // copies too because retired HDC bytes remain retained.
        store.verify_record(record).map_err(unreadable)?;
    }
    checkpoint("afterHDC");
    let deveco = list_load(store, &lock, DEVECO)?;
    let (index, _) = deveco_registry::read_index(&deveco.bytes).map_err(unreadable)?;
    for record in &index.records {
        if record.state == "available" {
            deveco_content::verify(record).map_err(deveco_error)?;
        }
    }
    let mut rows = decoded
        .projection
        .as_array()
        .ok_or_else(|| unreadable("projection"))?
        .clone();
    rows.extend(index.records.iter().map(|record| record.value()));
    rows.sort_by(|a, b| a["toolRef"].as_str().cmp(&b["toolRef"].as_str()));
    let indexes = [bundles, tools, deveco];
    for index in &indexes {
        list_validate(store, index)?;
    }
    list_binding(store, &lock)?;
    let snapshots_path = store.path().join("tool-snapshots");
    let snapshots = store
        .root()
        .private_child("tool-snapshots")
        .map_err(unreadable)?;
    snapshots
        .validate_path(&snapshots_path)
        .map_err(unreadable)?;
    let pager = SnapshotPager::open(&snapshots_path).map_err(unreadable)?;
    checkpoint("beforePager");
    let result = pager
        .page(
            "runtime.tool.list",
            "toolRef:asc",
            page_size,
            cursor,
            || Ok(rows),
        )
        .map_err(stamp);
    checkpoint("afterPager");
    // Changed namespaces must not become a harmless cursor error, including
    // when a pager call already failed. No fallback inventory is published.
    for index in &indexes {
        list_validate(store, index)?;
    }
    list_binding(store, &lock)?;
    snapshots
        .validate_path(&snapshots_path)
        .map_err(unreadable)?;
    result
}
fn list_binding(store: &ToolRegistryStore, lock: &HostReadLock) -> Result<(), WireError> {
    lock.validate_link(store.root(), ".lock")
        .map_err(unreadable)?;
    store.root().validate_path(store.path()).map_err(unreadable)
}
fn list_validate(store: &ToolRegistryStore, index: &Index) -> Result<(), WireError> {
    if store
        .root()
        .read(index.name, MAX_INDEX)
        .map_err(unreadable)?
        != index.bytes
        || !same_document(
            &index.identity,
            &store
                .root()
                .document_metadata(index.name)
                .map_err(unreadable)?,
        )
    {
        return Err(unreadable("shared index changed"));
    }
    Ok(())
}
fn list_load(
    store: &ToolRegistryStore,
    lock: &HostReadLock,
    name: &'static str,
) -> Result<Index, WireError> {
    match store.root().document_metadata(name) {
        Ok(_) => (),
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            let names = store.root().names(4096).map_err(unreadable)?;
            let safe = match name {
                BUNDLES => names == [".lock"],
                TOOLS => !names
                    .iter()
                    .any(|v| v.starts_with("tool-") || v.starts_with(".tool-")),
                _ => true,
            };
            if !safe {
                return Err(unreadable("index missing beside retained state"));
            }
            let bytes = match name {
                BUNDLES => {
                    br#"{"records":[],"schemaVersion":"arkdeck.bootstrap-bundles/1"}"#.as_slice()
                }
                TOOLS => {
                    br#"{"records":[],"schemaVersion":"arkdeck.bootstrap-tools/2"}"#.as_slice()
                }
                _ => br#"{"records":[],"schemaVersion":"arkdeck.bootstrap-deveco-toolchains/1"}"#
                    .as_slice(),
            };
            list_binding(store, lock)?;
            store
                .root()
                .publish_document(name, bytes, MAX_INDEX)
                .map_err(|error| match error {
                    DocumentPublishError::OutcomeUnknown(_) => failure(
                        "outcomeUnknown",
                        "Bootstrap index initialization outcome is uncertain",
                    ),
                    DocumentPublishError::BeforePublication(_) if name != BUNDLES => {
                        failure("ioFailure", "cannot initialize tool index")
                    }
                    DocumentPublishError::BeforePublication(error) => unreadable(error),
                })?;
            list_binding(store, lock).map_err(|_| {
                failure(
                    "outcomeUnknown",
                    "Bootstrap index initialization outcome is uncertain",
                )
            })?;
        }
        Err(error) => return Err(unreadable(error)),
    }
    let identity = store.root().document_metadata(name).map_err(unreadable)?;
    let bytes = store.root().read(name, MAX_INDEX).map_err(unreadable)?;
    let index = Index {
        name,
        bytes,
        identity,
    };
    list_validate(store, &index)?;
    Ok(index)
}
fn deveco_error(error: io::Error) -> WireError {
    let code = if error
        .get_ref()
        .is_some_and(|inner| inner.is::<arkdeck_platform::DevEcoIdentityChanged>())
    {
        "fileIdentityChanged"
    } else if error
        .get_ref()
        .is_some_and(|inner| inner.is::<arkdeck_platform::DevEcoInputTooLarge>())
    {
        "inputTooLarge"
    } else if error.raw_os_error().is_some() {
        "ioFailure"
    } else {
        match error.kind() {
            io::ErrorKind::PermissionDenied => "admissionDenied",
            _ => "recordUnreadable",
        }
    };
    failure(
        code,
        "registered DevEco root, manifests or child tools failed verification",
    )
}
#[cfg(test)]
#[path = "tool_list_owner_tests.rs"]
mod tests;
