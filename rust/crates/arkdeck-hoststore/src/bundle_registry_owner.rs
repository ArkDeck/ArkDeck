//! Bootstrap inventory owner. Existing list/inspect never initialize or write.
//! Paged discovery holds the Bootstrap lock through the frozen snapshot pager
//! and may initialize a genuinely empty registry. No content is selected or run.
use crate::{
    bundle_content::{BundleContent, verify_bundle_content},
    decode_bundles,
    snapshot_pager::SnapshotPager,
};
use arkdeck_contract::WireError;
use arkdeck_platform::HostDirectory;
use serde_json::{Value, json};
use std::{
    fs::Metadata,
    io,
    os::unix::fs::MetadataExt,
    path::{Path, PathBuf},
};
const MAXIMUM_INDEX: usize = 4 * 1024 * 1024;
pub struct BundleRegistryReadStore {
    pub(crate) root: HostDirectory,
    pub(crate) path: PathBuf,
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
fn same_document(left: &Metadata, right: &Metadata) -> bool {
    left.dev() == right.dev()
        && left.ino() == right.ino()
        && left.mode() == right.mode()
        && left.uid() == right.uid()
        && left.gid() == right.gid()
        && left.nlink() == right.nlink()
        && left.len() == right.len()
        && left.mtime() == right.mtime()
        && left.mtime_nsec() == right.mtime_nsec()
        && left.ctime() == right.ctime()
        && left.ctime_nsec() == right.ctime_nsec()
}
impl BundleRegistryReadStore {
    /// Requires a pre-existing private root, index and lock. The Swift owner's
    /// implicit initialization is deliberately outside this read-only API.
    pub fn open_existing(path: &Path) -> io::Result<Self> {
        Ok(Self {
            root: HostDirectory::open(path)?,
            path: path.into(),
        })
    }
    /// Optional Runtime composition helper: create only a fixed private leaf
    /// below an already existing private state directory. Registry metadata is
    /// still initialized only by a paged list or registration, never by construction.
    pub fn open_or_create(path: &Path) -> io::Result<Self> {
        match Self::open_existing(path) {
            Ok(store) => Ok(store),
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                let parent = path.parent().ok_or_else(corrupt)?;
                let name = path
                    .file_name()
                    .and_then(|name| name.to_str())
                    .ok_or_else(corrupt)?;
                let held = HostDirectory::open(parent)?;
                let root = held.private_child(name)?;
                held.validate_path(parent)?;
                root.validate_path(path)?;
                Ok(Self {
                    root,
                    path: path.into(),
                })
            }
            Err(error) => Err(error),
        }
    }
    /// Swift `BootstrapBundleRegistry.list` scans every current record before
    /// validating page size or cursor, including on continuation requests. The
    /// same cross-process lock covers scanning and snapshot publication/read.
    pub fn list_page(&self, page_size: usize, cursor: Option<&str>) -> Result<Value, WireError> {
        self.list_page_with_checkpoint(page_size, cursor, |_| {})
    }
    fn list_page_with_checkpoint(
        &self,
        page_size: usize,
        cursor: Option<&str>,
        checkpoint: impl Fn(&str),
    ) -> Result<Value, WireError> {
        self.root
            .validate_path(&self.path)
            .map_err(|_| wire_error(corrupt()))?;
        let lock = self.root.lock_document(".lock").map_err(|error| {
            wire_error(if error.kind() == io::ErrorKind::WouldBlock {
                error
            } else {
                corrupt()
            })
        })?;
        self.root
            .validate_path(&self.path)
            .map_err(|_| wire_error(corrupt()))?;
        let bytes = match self.root.read("bundles.json", MAXIMUM_INDEX) {
            Ok(bytes) => bytes,
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                // Swift permits only `.lock` beside a missing initial index.
                // Never infer an empty registry from surviving content or pages.
                if self.root.names(4096).map_err(|_| wire_error(corrupt()))? != [".lock"] {
                    return Err(wire_error(corrupt()));
                }
                let bytes = br#"{"records":[],"schemaVersion":"arkdeck.bootstrap-bundles/1"}"#;
                lock.validate_link(&self.root, ".lock")
                    .map_err(|_| wire_error(corrupt()))?;
                self.root
                    .validate_path(&self.path)
                    .map_err(|_| wire_error(corrupt()))?;
                self.root
                    .publish_document("bundles.json", bytes, MAXIMUM_INDEX)
                    .map_err(|_| wire_error(corrupt()))?;
                self.root
                    .read("bundles.json", MAXIMUM_INDEX)
                    .map_err(|_| wire_error(corrupt()))?
            }
            Err(_) => return Err(wire_error(corrupt())),
        };
        let identity = self
            .root
            .document_metadata("bundles.json")
            .map_err(|_| wire_error(corrupt()))?;
        self.validate_index(&bytes, &identity)
            .map_err(|_| wire_error(corrupt()))?;
        let rows = self
            .verify_index(&bytes, None)
            .map_err(|error| wire_error(map_read_error(error)))?;
        self.validate_index(&bytes, &identity)
            .map_err(|_| wire_error(corrupt()))?;
        lock.validate_link(&self.root, ".lock")
            .map_err(|_| wire_error(corrupt()))?;
        self.root
            .validate_path(&self.path)
            .map_err(|_| wire_error(corrupt()))?;
        let snapshots_path = self.path.join("bundle-snapshots");
        let snapshots = self
            .root
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
        self.validate_index(&bytes, &identity)
            .map_err(|_| wire_error(corrupt()))?;
        lock.validate_link(&self.root, ".lock")
            .map_err(|_| wire_error(corrupt()))?;
        self.root
            .validate_path(&self.path)
            .map_err(|_| wire_error(corrupt()))?;
        snapshots
            .validate_path(&snapshots_path)
            .map_err(|_| wire_error(corrupt()))?;
        result
    }
    pub(crate) fn validate_index(&self, bytes: &[u8], identity: &Metadata) -> io::Result<()> {
        if self.root.read("bundles.json", MAXIMUM_INDEX)? != bytes
            || !same_document(identity, &self.root.document_metadata("bundles.json")?)
        {
            return Err(corrupt());
        }
        Ok(())
    }
    pub fn list(&self) -> io::Result<Vec<Value>> {
        self.read(None).map_err(map_read_error)
    }
    pub fn inspect(&self, reference: &str) -> io::Result<Value> {
        if !reference
            .strip_prefix("bundle:sha256:")
            .is_some_and(|digest| {
                digest.len() == 64
                    && digest
                        .bytes()
                        .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
            })
        {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "exact content-addressed daemon bundle reference is required",
            ));
        }
        self.read(Some(reference))
            .map_err(map_read_error)?
            .into_iter()
            .next()
            .ok_or_else(|| {
                io::Error::new(io::ErrorKind::NotFound, "bundle reference does not exist")
            })
    }
    fn read(&self, reference: Option<&str>) -> io::Result<Vec<Value>> {
        self.root.validate_path(&self.path).map_err(|_| corrupt())?;
        let lock = self
            .root
            .try_lock_existing_strict(".lock")
            .map_err(|_| corrupt())?
            .ok_or_else(|| {
                io::Error::new(
                    io::ErrorKind::WouldBlock,
                    "bootstrap owner lock unavailable",
                )
            })?;
        let bytes = self
            .root
            .read("bundles.json", MAXIMUM_INDEX)
            .map_err(|_| corrupt())?;
        let rows = self.verify_index(&bytes, reference)?;
        if self
            .root
            .read("bundles.json", MAXIMUM_INDEX)
            .map_err(|_| corrupt())?
            != bytes
        {
            return Err(corrupt());
        }
        lock.validate_link(&self.root, ".lock")
            .map_err(|_| corrupt())?;
        self.root.validate_path(&self.path).map_err(|_| corrupt())?;
        Ok(rows)
    }
    fn verify_index(&self, bytes: &[u8], reference: Option<&str>) -> io::Result<Vec<Value>> {
        let decoded = decode_bundles(bytes).map_err(|_| corrupt())?;
        let document: Value = serde_json::from_slice(&decoded.document).map_err(|_| corrupt())?;
        for record in document["records"].as_array().ok_or_else(corrupt)? {
            if reference.is_some_and(|value| record["reference"] != value) {
                continue;
            }
            self.verify_record(record)?;
        }
        Ok(decoded
            .projection
            .as_array()
            .ok_or_else(corrupt)?
            .iter()
            .filter(|row| reference.is_none_or(|value| row["bundleRef"] == value))
            .cloned()
            .collect())
    }
    pub(crate) fn verify_record(&self, record: &Value) -> io::Result<()> {
        let measured = BundleContent {
            digest: record["digest"].as_str().ok_or_else(corrupt)?.to_owned(),
            byte_count: record["byteCount"].as_u64().ok_or_else(corrupt)?,
            entry_count: record["entryCount"].as_u64().ok_or_else(corrupt)? as usize,
            version: record
                .get("version")
                .and_then(Value::as_str)
                .map(str::to_owned),
        };
        // The strict decoder already proved the digest is exactly 64 hex
        // bytes. The content reader binds this root and every child inode.
        verify_bundle_content(
            &self.path.join(format!("bundle-{}.app", measured.digest)),
            &measured,
        )
    }
}

#[cfg(test)]
#[path = "bundle_list_owner_tests.rs"]
mod list_tests;
