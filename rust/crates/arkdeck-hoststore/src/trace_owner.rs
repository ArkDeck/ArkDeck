//! Read-only owner of a fixed host cache inventory. It cannot select request
//! paths, purge entries, prepare databases or change lease ownership.
use arkdeck_contract::WireError;
use arkdeck_platform::HostDirectory;
use serde_json::{Value, json};
use std::{
    io,
    path::{Path, PathBuf},
};

pub struct TraceCacheStore {
    path: PathBuf,
    root: HostDirectory,
}

impl TraceCacheStore {
    pub fn open(path: &Path) -> io::Result<Self> {
        Ok(Self {
            path: path.to_owned(),
            root: HostDirectory::open(path)?,
        })
    }

    pub fn status(&self) -> Result<Value, WireError> {
        let read = || -> io::Result<Value> {
            self.root.validate_path(&self.path)?;
            let inventory = crate::trace_inventory(&self.path)?;
            self.root.validate_path(&self.path)?;
            Ok(inventory)
        };
        read().map_err(|_| WireError {
            code: "recordUnreadable".into(),
            message: "Trace cache inventory is unavailable".into(),
            details: Some(
                json!({"phase":"traceCacheOwner", "newDispatchCount":0,
                "purgeScope":"inactiveDerivedDatabases"})
                .as_object()
                .unwrap()
                .clone(),
            ),
        })
    }
}
