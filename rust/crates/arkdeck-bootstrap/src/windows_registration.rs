//! Registration of Bootstrap content on Windows, not built yet: the Windows
//! forms of a daemon Bundle and of an HDC tool (per maintainer ruling
//! 2026-09-30, the macOS content, trust and capture logic with Authenticode,
//! PE and NTFS equivalents) are the next slice. Until then both refuse before
//! the store is locked or any source byte is read, and nothing is captured,
//! published, selected or run.
use crate::{BundleRegistryReadStore, ToolRegistryStore};
use arkdeck_contract::WireError;
use serde_json::{Value, json};
use std::path::Path;

fn unavailable(message: &str) -> WireError {
    WireError {
        code: "operationUnavailable".into(),
        message: message.into(),
        details: Some(serde_json::Map::from_iter([
            ("phase".into(), json!("bootstrapRegistryOwner")),
            ("newDispatchCount".into(), json!(0)),
        ])),
    }
}

/// The published identity (`version`, `profileReferences`) a Windows HDC
/// executable's SHA-256 matches, the Windows counterpart of the macOS
/// `published_identity`: none until the Windows HDC registration is built.
pub(crate) fn windows_published_identity(_sha256: &str) -> Option<Value> {
    None
}

impl BundleRegistryReadStore {
    /// Refused before the store is locked or the source is opened.
    pub fn register(&self, _source: &Path, _now: &str) -> Result<Value, WireError> {
        Err(unavailable(
            "daemon bundle registration is not built on Windows yet; nothing was registered",
        ))
    }
}

impl ToolRegistryStore {
    /// Refused before the store is locked or the source is opened.
    pub fn register(&self, _source: &Path, _now: &str) -> Result<Value, WireError> {
        Err(unavailable(
            "HDC registration is not built on Windows yet; nothing was captured",
        ))
    }
}
