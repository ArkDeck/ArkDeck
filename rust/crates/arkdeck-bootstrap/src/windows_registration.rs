//! Registration of Bootstrap content on Windows. Both refuse before the store
//! is locked or any source byte is read, and nothing is captured, published,
//! selected or run.
//!
//! * A daemon Bundle: the Windows daemon is installed as the signed
//!   release-candidate package and started by its client (decision 11);
//!   `runtime service install` and `update`, which consume registered Bundles
//!   on macOS, are macOS-only.
//! * An HDC tool: a Windows HDC is identified by its executable's SHA-256 and
//!   the exact bytes its `-v` prints (CHG-2026-078 §1). Until a Windows HDC
//!   tuple is registered, no HDC is registered; no macOS identity, layout or
//!   value stands in for one.
use crate::{BundleRegistryReadStore, ToolRegistryStore};
use arkdeck_contract::WireError;
use serde_json::{Value, json};
use std::path::Path;

fn failure(code: &str, message: &str) -> WireError {
    WireError {
        code: code.into(),
        message: message.into(),
        details: Some(serde_json::Map::from_iter([
            ("phase".into(), json!("bootstrapRegistryOwner")),
            ("newDispatchCount".into(), json!(0)),
        ])),
    }
}

/// The published identity (`version`, `profileReferences`) a Windows HDC
/// executable's SHA-256 matches, the Windows counterpart of the macOS
/// `published_identity`: none while no Windows HDC tuple is registered.
pub(crate) fn windows_published_identity(_sha256: &str) -> Option<Value> {
    None
}

impl BundleRegistryReadStore {
    /// No Windows daemon Bundle is registered: the refusal comes before the
    /// store is locked or the source is opened.
    pub fn register(&self, _source: &Path, _now: &str) -> Result<Value, WireError> {
        Err(failure(
            "operationUnavailable",
            "daemon bundle registration is unavailable on Windows: the Runtime is installed as a signed package",
        ))
    }
}

impl ToolRegistryStore {
    /// No Windows HDC tuple is registered (CHG-2026-078): every registration
    /// is refused before the store is locked or the source is opened.
    pub fn register(&self, _source: &Path, _now: &str) -> Result<Value, WireError> {
        Err(failure(
            "admissionDenied",
            "no Windows HDC tuple is registered (CHG-2026-078); nothing was captured",
        ))
    }
}
