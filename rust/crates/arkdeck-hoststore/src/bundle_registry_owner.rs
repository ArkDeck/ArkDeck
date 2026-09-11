//! Read-only list/inspect owner of an existing initialized Bootstrap registry.
//! Holds the same existing exclusive lock as Swift. It does not initialize a
//! registry, write snapshots, retain references, select, install or activate.
use crate::{
    bundle_content::{BundleContent, verify_bundle_content},
    decode_bundles,
};
use arkdeck_platform::HostDirectory;
use serde_json::Value;
use std::{
    io,
    path::{Path, PathBuf},
};
const MAXIMUM_INDEX: usize = 4 * 1024 * 1024;
pub struct BundleRegistryReadStore {
    root: HostDirectory,
    path: PathBuf,
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
impl BundleRegistryReadStore {
    /// Requires a pre-existing private root, index and lock. The Swift owner's
    /// implicit initialization is deliberately outside this read-only API.
    pub fn open_existing(path: &Path) -> io::Result<Self> {
        Ok(Self {
            root: HostDirectory::open(path)?,
            path: path.into(),
        })
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
        let decoded = decode_bundles(&bytes).map_err(|_| corrupt())?;
        let document: Value = serde_json::from_slice(&decoded.document).map_err(|_| corrupt())?;
        for record in document["records"].as_array().ok_or_else(corrupt)? {
            if reference.is_some_and(|value| record["reference"] != value) {
                continue;
            }
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
            )?;
        }
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
        Ok(decoded
            .projection
            .as_array()
            .ok_or_else(corrupt)?
            .iter()
            .filter(|row| reference.is_none_or(|value| row["bundleRef"] == value))
            .cloned()
            .collect())
    }
}
