//! The DAYU200's durable cross-mode binding and the USB personalities it
//! binds, below both of their writers: the Runtime, which reads the binding
//! and moves it along a Loader's lineage, and the CLI's `flash
//! install-binding`, which installs it in its own process as Swift's does.
//! One document, one lock and one implementation of each write serve both;
//! the CLI links no Runtime store (协调会话 2026-09-26), so they live here,
//! over the contract and platform crates alone.
//!
//! What a binding's evidence means — its lineage edge, a reactivation, its
//! HDC-normal alias, whether it covers a Target — is the Runtime's
//! (`arkdeck-hoststore`).
mod identity;
pub use identity::{
    DAYU200_LOADER_PRODUCT_ID, DAYU200_NORMAL_PRODUCT_ID, ROCKUSB_VENDOR_ID, is_dayu200_hdc_normal,
    is_dayu200_loader, registered_dayu200_devices,
};

#[cfg(target_os = "macos")]
mod store;
#[cfg(target_os = "macos")]
pub use store::{
    BindingError, BindingInstallation, BindingSnapshot, RockchipBindingStore,
    install_current_target, refuse,
};
