//! Runtime owner of fixed Trace inventory and leased inactive derived-data purge.
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
    maintenance: std::sync::Mutex<()>,
}

impl TraceCacheStore {
    pub fn open(path: &Path) -> io::Result<Self> {
        Ok(Self {
            path: path.to_owned(),
            root: HostDirectory::open(path)?,
            maintenance: std::sync::Mutex::new(()),
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

impl TraceCacheStore {
    /// The Runtime holds its authoritative Job activity census across this call.
    /// Any retained Job conservatively retains all Trace data in this phase.
    pub fn purge(&self, retain_all: bool) -> Result<Value, WireError> {
        let action = || -> io::Result<Value> {
            let _guard = self
                .maintenance
                .lock()
                .map_err(|_| io::Error::other("trace owner poisoned"))?;
            self.root.validate_path(&self.path)?;
            let result = crate::trace_maintenance::purge(&self.path, retain_all, &|_| Ok(()))?;
            self.root.validate_path(&self.path)?;
            Ok(result)
        };
        action().map_err(|_| Self::purge_refusal("Trace cache purge outcome is unknown"))
    }
    pub fn purge_refusal(message: &str) -> WireError {
        WireError { code: "outcomeUnknown".into(), message: message.into(), details: Some(json!({"phase":"traceCacheOwner", "newDispatchCount":0, "purgeScope":"inactiveDerivedDatabases"}).as_object().unwrap().clone()) }
    }
}
