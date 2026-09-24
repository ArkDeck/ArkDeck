//! The ArkForge lane of the Rust Runtime (lane D).
//!
//! ArkForge is the device-neutral flash mechanism: `arkforged` owns the USB
//! transport and the firmware formats, and ArkDeck stays the only authority
//! that may permit a write. This crate talks to it through ArkForge's own
//! Rust client crates, taken at the revision `Packages/ArkDeckKit/Package.swift`
//! pins for the Swift SDK, so both lanes speak one protocol revision.
//!
//! It composes the lane — one owned, paired `arkforged` generation — and reads
//! through the daemon's public socket: which Rockchip flashing modes it sees,
//! and its half of the dual-source Loader observation. The controller surface
//! that plans and permits follows in later slices.

#![forbid(unsafe_code)]

mod device_access;
#[cfg(target_os = "macos")]
mod lane;
mod loader;

pub use device_access::{
    DEVICE_ACCESS_TIMEOUT, DeviceAccessFailure, DeviceAccessObserver, DeviceMode,
};
#[cfg(target_os = "macos")]
pub use lane::{
    Absence, BUNDLE_PATH_KEY, CAMPAIGN_KEY, DAYU200_PROFILE, Lane, LaneInputs,
    NATIVE_ROCKUSB_TOOLCHAIN, RETIRED_KEYS, daemon_arguments, device_profile_selector,
    verify_readiness,
};
pub use loader::{
    LOADER_OBSERVATION_TIMEOUT, SelectionFailure, confirm_loader, select, topology_digest,
    usable_loader,
};
