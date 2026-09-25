//! Bootstrap bundle inventory owner. Existing list/inspect never initialize
//! or write. The Runtime's paged discovery (`arkdeck-hoststore`) holds this
//! owner's lock through its frozen snapshot pager and may initialize a
//! genuinely empty registry. No content is selected or run.
use crate::{
    bundle_content::{BundleContent, verify_bundle_content},
    decode_bundles,
};
use arkdeck_platform::HostDirectory;
use serde_json::Value;
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
    /// The store's directory, held open since construction.
    pub fn root(&self) -> &HostDirectory {
        &self.root
    }
    /// The path the store was opened at.
    pub fn path(&self) -> &Path {
        &self.path
    }
    /// Whether `bundles.json` still holds `bytes` as the document `identity`
    /// describes: the same content, inode and times.
    pub fn validate_index(&self, bytes: &[u8], identity: &Metadata) -> io::Result<()> {
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
    /// The strictly decoded index `bytes`' rows (only `reference`'s, when
    /// given), each record's retained content freshly verified first.
    pub fn verify_index(&self, bytes: &[u8], reference: Option<&str>) -> io::Result<Vec<Value>> {
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
    /// The record's retained content measured again and checked, natively,
    /// against the production helper policy.
    pub fn verify_record(&self, record: &Value) -> io::Result<()> {
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
