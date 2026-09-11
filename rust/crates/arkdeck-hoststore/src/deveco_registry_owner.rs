//! Read-only owner of existing DevEco registrations. Available records require
//! fresh external content verification; removed records are historical metadata
//! and deliberately do not require externally retained content (Swift parity).
use crate::{
    decode_bundles, deveco_content,
    deveco_registry::{digest, read_index},
};
use arkdeck_platform::HostDirectory;
use serde_json::Value;
use std::{
    io,
    path::{Path, PathBuf},
};
const MAX_INDEX: usize = 4 * 1024 * 1024;
pub struct DevEcoRegistryReadStore {
    root: HostDirectory,
    path: PathBuf,
}
fn corrupt() -> io::Error {
    io::Error::new(
        io::ErrorKind::InvalidData,
        "DevEco index failed schema or identity validation",
    )
}
fn read_error(error: io::Error) -> io::Error {
    if matches!(
        error.kind(),
        io::ErrorKind::WouldBlock | io::ErrorKind::PermissionDenied
    ) {
        error
    } else {
        corrupt()
    }
}
impl DevEcoRegistryReadStore {
    pub fn open_existing(path: &Path) -> io::Result<Self> {
        Ok(Self {
            root: HostDirectory::open(path)?,
            path: path.into(),
        })
    }
    pub fn list(&self) -> io::Result<Vec<Value>> {
        self.read(None).map_err(read_error)
    }
    pub fn inspect(&self, reference: &str) -> io::Result<Value> {
        if !reference
            .strip_prefix("toolchain:sha256:")
            .is_some_and(digest)
        {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "exact content-addressed toolchain reference is required",
            ));
        }
        self.read(Some(reference))
            .map_err(read_error)?
            .into_iter()
            .next()
            .ok_or_else(|| {
                io::Error::new(
                    io::ErrorKind::NotFound,
                    "toolchain reference does not exist",
                )
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
        // withSharedStore validates the existing bundle index before reading any
        // other resource family. No empty index is synthesized or written.
        let bundles = self
            .root
            .read("bundles.json", MAX_INDEX)
            .map_err(|_| corrupt())?;
        decode_bundles(&bundles).map_err(|_| corrupt())?;
        let bytes = self
            .root
            .read("deveco-toolchains.json", MAX_INDEX)
            .map_err(|_| corrupt())?;
        let (index, _) = read_index(&bytes).map_err(|_| corrupt())?;
        let mut values = Vec::new();
        for record in &index.records {
            if reference.is_some_and(|r| r != record.reference) {
                continue;
            }
            if record.state == "available" {
                deveco_content::verify(record)?;
            }
            values.push(record.value());
        }
        if self
            .root
            .read("deveco-toolchains.json", MAX_INDEX)
            .map_err(|_| corrupt())?
            != bytes
            || self
                .root
                .read("bundles.json", MAX_INDEX)
                .map_err(|_| corrupt())?
                != bundles
        {
            return Err(corrupt());
        }
        lock.validate_link(&self.root, ".lock")
            .map_err(|_| corrupt())?;
        self.root.validate_path(&self.path).map_err(|_| corrupt())?;
        Ok(values)
    }
}
