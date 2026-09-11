//! Fixed-root Bootstrap inventory, private list snapshots and DevEco metadata registration.
//! No selection, installation, process launch or execution authority is exposed.
use arkdeck_contract::WireError;
use arkdeck_control::BootstrapRegistryKind;
use arkdeck_hoststore::{BundleRegistryReadStore, DevEcoRegistryStore, ToolRegistryStore};
use serde_json::Value;
use std::{io, path::Path};

pub struct BootstrapReaders {
    tools: ToolRegistryStore,
    bundles: BundleRegistryReadStore,
    deveco: DevEcoRegistryStore,
}
impl BootstrapReaders {
    pub fn open_existing(root: &Path) -> io::Result<Self> {
        Ok(Self {
            tools: ToolRegistryStore::open_existing(root)?,
            bundles: BundleRegistryReadStore::open_existing(root)?,
            deveco: DevEcoRegistryStore::open_existing(root)?,
        })
    }
    pub fn bundle_list(&self, page_size: usize, cursor: Option<&str>) -> Result<Value, WireError> {
        self.bundles.list_page(page_size, cursor)
    }
    pub fn inspect(
        &self,
        kind: BootstrapRegistryKind,
        reference: &str,
    ) -> Result<Value, WireError> {
        let result = match kind {
            BootstrapRegistryKind::Bundle => self.bundles.inspect(reference),
            BootstrapRegistryKind::Tool if reference.starts_with("toolchain:sha256:") => {
                self.deveco.inspect(reference)
            }
            BootstrapRegistryKind::Tool => self.tools.inspect(reference),
        };
        result.map_err(|error| {
            let (code, message) = match error.kind() {
                io::ErrorKind::InvalidInput => (
                    "invalidParams",
                    "one exact bootstrap resource reference is required",
                ),
                io::ErrorKind::NotFound => (
                    "resourceNotFound",
                    "bootstrap resource reference does not exist",
                ),
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
            WireError {
                code: code.into(),
                message: message.into(),
                details: Some(serde_json::Map::from_iter([
                    ("phase".into(), serde_json::json!("bootstrapRegistryOwner")),
                    ("newDispatchCount".into(), serde_json::json!(0)),
                ])),
            }
        })
    }
    pub fn register_deveco(&self, source: &Path, now: &str) -> Result<Value, WireError> {
        self.deveco.register(source, now)
    }
}
