//! The Windows HDC identity a store matches unless its composer supplies
//! others. A Windows HDC is identified by its executable's SHA-256 and the
//! exact bytes its `-v` prints (CHG-2026-078 §1); the registered tuples live
//! in `arkdeck-provider-hdc` (`WINDOWS_HDC_TUPLES`), which the daemon
//! composes into the store (`ToolRegistryStore::with_published_identities`).
//! This crate holds no table of its own, and no macOS identity, layout or
//! value stands in for a Windows one.
use serde_json::Value;

/// The published identity (`version`, `profileReferences`) a Windows HDC
/// executable's SHA-256 matches, the Windows counterpart of the macOS
/// `published_identity`: none, so a store its composer gave no identities
/// admits no HDC registration (`tool_registration.rs`).
pub(crate) fn windows_published_identity(_sha256: &str) -> Option<Value> {
    None
}
