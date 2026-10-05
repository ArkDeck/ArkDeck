//! Fixed-root Bootstrap inventory, snapshots, registration and metadata retirement.
//! No selection, installation, process launch or execution authority is exposed.
use arkdeck_contract::WireError;
use arkdeck_control::BootstrapRegistryKind;
use arkdeck_hoststore::{
    BootstrapListPage, BundleRegistryReadStore, DevEcoRegistryStore, ToolRegistryStore,
};
use serde_json::Value;
use std::{io, path::Path};

/// The published identity of a Windows HDC digest: the registered tuple's
/// reported version, naming no profile, or none for any other digest
/// (CHG-2026-078 registers DevEco Studio 26.0.0.43's `hdc.exe` only). The
/// Windows composition identifies an HDC by its own tuple table
/// ([`BootstrapReaders::open_existing_identified`]), which in production is
/// this one.
#[cfg(all(windows, test))]
pub(crate) fn windows_hdc_identity(sha256: &str) -> Option<Value> {
    arkdeck_provider_hdc::windows_tuple(sha256).map(
        |tuple| serde_json::json!({"version": tuple.reported_version, "profileReferences": []}),
    )
}

pub struct BootstrapReaders {
    tools: ToolRegistryStore,
    bundles: BundleRegistryReadStore,
    deveco: DevEcoRegistryStore,
}
impl BootstrapReaders {
    #[cfg(target_os = "macos")]
    pub fn open_existing(root: &Path) -> io::Result<Self> {
        Self::over(root, ToolRegistryStore::open_existing(root)?)
    }
    /// The Windows readers: an HDC is admitted and identified only by a
    /// registered Windows tuple (CHG-2026-078), naming no published profile,
    /// by the tuple table of the composition that serves it
    /// (`windows_lifecycle`), so that registration admits exactly the digests
    /// its selection admits: the registered tuples in production.
    #[cfg(windows)]
    pub fn open_existing_identified(
        root: &Path,
        identities: arkdeck_hoststore::PublishedIdentities,
    ) -> io::Result<Self> {
        Self::over(
            root,
            ToolRegistryStore::open_existing(root)?.with_published_identities(identities),
        )
    }
    fn over(root: &Path, tools: ToolRegistryStore) -> io::Result<Self> {
        Ok(Self {
            tools,
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
