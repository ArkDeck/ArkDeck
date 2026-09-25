//! The current-user Bootstrap registry's bundle and HDC tool owners (Swift
//! `ArkDeckBootstrap`: `BootstrapBundleRegistry` and `BootstrapToolRegistry`
//! over `…/ArkDeck/Bootstrap/v1`).
//!
//! The Runtime and the CLI both write this one store: the Runtime registers,
//! retires, lists and selects; the CLI's zero-Runtime service install pins
//! the exact bundle and publishes the first HDC selection before any daemon
//! exists. Every writer therefore uses this one implementation — the frozen
//! index codecs, the fresh content checks, the store's shared `.lock` and its
//! atomic document publication (`arkdeck-platform`) — so that neither can
//! write a document the other reads differently or outside the other's lock.
//! Nothing here launches a tool or a daemon, and nothing grants device or
//! Runtime authority: the store holds content and references only.
//!
//! The Runtime's paged inventories (the Session snapshot pager) and the
//! DevEco toolchain registry, which retires through this crate's shared
//! retirement binding, stay in `arkdeck-hoststore`, over the owners here.

use serde::{Serialize, de::DeserializeOwned};
use serde_json::Value;

#[derive(Debug, PartialEq, Eq)]
pub enum DecodeError {
    Size,
    Shape,
    Header,
}

pub struct DecodedStore {
    pub document: Vec<u8>,
    pub projection: Value,
}

/// Decode a frozen document's field set and re-encode it: the document must
/// equal its own re-encoding as a JSON value, and the durable bytes are that
/// re-encoding (with a final LF when `newline`). The host store's other
/// frozen decoders share it.
pub fn roundtrip<T: DeserializeOwned + Serialize>(
    bytes: &[u8],
    maximum: usize,
    newline: bool,
) -> Result<(T, Vec<u8>), DecodeError> {
    if bytes.is_empty() || bytes.len() > maximum {
        return Err(DecodeError::Size);
    }
    let doc: T = serde_json::from_slice(bytes).map_err(|_| DecodeError::Shape)?;
    let raw: Value = serde_json::from_slice(bytes).map_err(|_| DecodeError::Shape)?;
    let encoded = serde_json::to_value(&doc).map_err(|_| DecodeError::Shape)?;
    if raw != encoded {
        return Err(DecodeError::Shape);
    }
    let mut document = serde_json::to_vec(&encoded).map_err(|_| DecodeError::Shape)?;
    if newline {
        document.push(b'\n');
    }
    Ok((doc, document))
}

mod registry;
pub use registry::{decode_bundles, decode_tool_identity, decode_tools};

#[cfg(target_os = "macos")]
mod tool_content;
#[cfg(target_os = "macos")]
pub mod tool_macho;
#[cfg(target_os = "macos")]
pub use tool_content::{ToolContent, ToolDependency, inspect_tool_content};
#[cfg(target_os = "macos")]
mod tool_registration;
#[cfg(target_os = "macos")]
mod tool_registry_owner;
#[cfg(target_os = "macos")]
mod tool_retirement;
#[cfg(target_os = "macos")]
mod tool_selection_ledger;
#[cfg(target_os = "macos")]
pub use tool_registry_owner::{PublishedIdentities, ToolRegistryStore};
#[cfg(target_os = "macos")]
pub use tool_retirement::{IndexSnapshot, RetirementRoot};
#[cfg(target_os = "macos")]
pub use tool_selection_ledger::{
    DurableSelectionOutcome, SelectionCandidate, SelectionSnapshot, StartupSelection,
    cutover_pending_selection,
};

#[cfg(target_os = "macos")]
mod store;
#[cfg(target_os = "macos")]
pub use store::create_store;

#[cfg(target_os = "macos")]
pub mod bundle_content;
#[cfg(target_os = "macos")]
mod bundle_references;
#[cfg(target_os = "macos")]
mod bundle_registration;
#[cfg(target_os = "macos")]
mod bundle_registry_owner;
#[cfg(target_os = "macos")]
mod bundle_retirement;
#[cfg(target_os = "macos")]
pub use bundle_references::ReferenceOwner;
#[cfg(target_os = "macos")]
pub use bundle_registry_owner::{BundleRegistryReadStore, BundleValidator};
