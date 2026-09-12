//! Fixed-root Bootstrap inventory, snapshots, registration and metadata retirement.
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
    pub fn tool_remove(&self, reference: &str, generation: &str) -> Result<Value, WireError> {
        if reference.starts_with("toolchain:sha256:") {
            self.deveco.retire(reference, generation)
        } else {
            self.tools.retire(reference, generation)
        }
    }
    pub fn tool_list(&self, page_size: usize, cursor: Option<&str>) -> Result<Value, WireError> {
        self.tools.list_page(page_size, cursor)
    }
    pub fn bundle_list(&self, page_size: usize, cursor: Option<&str>) -> Result<Value, WireError> {
        self.bundles.list_page(page_size, cursor)
    }
    pub fn bundle_remove(&self, reference: &str, generation: &str) -> Result<Value, WireError> {
        self.bundles.retire(reference, generation)
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
    pub fn register_bundle(&self, source: &Path, now: &str) -> Result<Value, WireError> {
        self.bundles.register(source, now)
    }
    pub fn register_hdc(&self, source: &Path, now: &str) -> Result<Value, WireError> {
        self.tools.register(source, now)
    }
    pub fn register_deveco(&self, source: &Path, now: &str) -> Result<Value, WireError> {
        self.deveco.register(source, now)
    }
}
