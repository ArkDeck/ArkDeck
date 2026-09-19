//! The workspace provider's signing and credential layer (SPK-10,
//! TASK-XPA-015), ported from Swift `OpenHarmonyLocalSigning.swift`,
//! `DevEcoPasswordDecoder.swift` and the signing dispatcher in
//! `ArkDeckWorkflows/WorkspaceProvider`.
//!
//! - [`deveco_password`] decodes the password ciphertext DevEco Studio writes
//!   beside its generated keystore (PBKDF2-HMAC-SHA256, AES-128-GCM), at the
//!   install and re-key boundaries only.
//! - [`signing_preset`] reads and validates the one published signing preset
//!   (`preset-v1.json`, `arkdeck-openharmony-signing/v1`) with the exact Swift
//!   key set, remeasures every pinned file, and resolves its passwords from a
//!   [`signing_preset::SigningSecrets`] source; [`secret_envelope`] is the
//!   Keychain value both passwords travel in.
//! - [`signing_action`] is the durable `workspace.sign-openharmony-hap@1`
//!   action: its attempt paths and the exact `sign-app` / `verify-app` argv.
//! - `signer` (macOS) signs through the registered Java and hap-sign-tool
//!   identities: the JAR and the staged input are bound by their inodes, both
//!   passwords go only through a pseudo-terminal, and the product is verified
//!   and recorded as `signing-result.json` (`arkdeck-openharmony-signing-result/v1`).
//! - `keychain_secrets` (macOS) is the production secret source over the Data
//!   Protection Keychain and the installed daemon's code identity.
//!
//! No secret is ever placed in an argument, an environment, a receipt, a
//! record, an error or a log; secrets live in [`arkdeck_platform::Secret`]
//! buffers that are wiped when dropped.

mod base64;
#[cfg(target_os = "macos")]
mod canonical_json;
pub mod deveco_password;
mod error;
#[cfg(unix)]
mod file_identity;
pub mod secret_envelope;
pub mod signing_action;
pub mod signing_preset;

#[cfg(target_os = "macos")]
pub mod keychain_secrets;
#[cfg(target_os = "macos")]
pub mod signer;

pub use error::SigningError;
#[cfg(unix)]
pub use file_identity::{foundation_resolved_path, measure, remeasure};
pub use signing_preset::SigningFileIdentity;
