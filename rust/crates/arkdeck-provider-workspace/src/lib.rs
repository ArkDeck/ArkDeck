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
//! - `signer` (macOS, Windows) signs through the registered Java and
//!   hap-sign-tool identities: the JAR and the staged input are bound by their
//!   inodes (macOS) or held with their namespace (Windows), both passwords go
//!   only through a pseudo-terminal or pseudo console, and the product is
//!   verified and recorded as `signing-result.json`
//!   (`arkdeck-openharmony-signing-result/v1`).
//! - `keychain_secrets` is the production secret source over the Data
//!   Protection Keychain and the installed daemon's code identity (macOS); on
//!   Windows only its scope-bound form over Credential Manager, bound to no
//!   daemon identity.
//! - `credential_owner` (macOS, Windows) is the ledger of the workspace
//!   signing presets that pin the installed credential by its content
//!   reference, and their resolution to its receipt; `signing_install`,
//!   `signing_rekey`, `signing_removal` and `sdk_release` are its explicit
//!   maintenance.
//!
//! No secret is ever placed in an argument, an environment, a receipt, a
//! record, an error or a log; secrets live in [`arkdeck_platform::Secret`]
//! buffers that are wiped when dropped.

mod base64;
// Portable: Foundation's canonical JSON spellings, proven on every host by
// its own tests. Its writers (the install, re-key and credential-owner
// leaves) are built on macOS and Windows, so on Linux nothing calls it yet.
#[cfg_attr(not(any(target_os = "macos", windows)), allow(dead_code))]
mod canonical_json;
pub mod deveco_password;
mod error;
#[cfg(any(unix, windows))]
mod file_identity;
#[cfg(any(target_os = "macos", windows))]
pub mod sdk_release;
#[cfg(any(target_os = "macos", windows))]
mod sdk_release_profile;
pub mod secret_envelope;
pub mod signing_action;
#[cfg(any(target_os = "macos", windows))]
pub mod signing_install;
pub mod signing_preset;
#[cfg(any(target_os = "macos", windows))]
pub mod signing_rekey;
#[cfg(any(target_os = "macos", windows))]
pub mod signing_removal;

#[cfg(any(target_os = "macos", windows))]
pub mod credential_owner;
#[cfg(any(target_os = "macos", windows))]
pub mod keychain_secrets;
#[cfg(any(target_os = "macos", windows))]
pub mod signer;
#[cfg(all(test, any(target_os = "macos", windows)))]
mod test_fixture;

pub use error::SigningError;
#[cfg(any(unix, windows))]
pub use file_identity::{foundation_resolved_path, measure, remeasure};
pub use signing_preset::SigningFileIdentity;
