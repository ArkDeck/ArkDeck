//! HDC tool registration on Windows, which refuses before the store is locked
//! or any source byte is read: nothing is captured, published, selected or
//! run. (A daemon Bundle registers on Windows as its release-candidate
//! package tree, `bundle_registration.rs`.)
//!
//! * An HDC tool: a Windows HDC is identified by its executable's SHA-256 and
//!   the exact bytes its `-v` prints (CHG-2026-078 §1). Until a Windows HDC
//!   tuple is registered, no HDC is registered; no macOS identity, layout or
//!   value stands in for one.
use crate::ToolRegistryStore;
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
