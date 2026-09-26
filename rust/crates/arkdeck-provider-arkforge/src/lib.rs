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
//! and its half of the dual-source Loader observation. The Runtime's Flash
//! execution reaches a lane through `FlashLane`. Behind it, `authority`
//! signs the StepPermits that let the daemon write, `managed_control` builds
//! the receipts this authority answers the daemon's control requests with,
//! and `authority_support` the key that binds this authority build to an
//! executable plan; the controller surface that plans and drives a Job
//! follows in later slices.

#![forbid(unsafe_code)]

pub mod authority;
pub mod authority_support;
mod device_access;
mod flash_lane;
pub mod flash_session;
#[cfg(target_os = "macos")]
mod lane;
mod loader;
pub mod managed_control;

pub use device_access::{
    DEVICE_ACCESS_TIMEOUT, DeviceAccessFailure, DeviceAccessObserver, DeviceMode,
};
pub use flash_lane::{
    ActionReceipt, DeviceBinding, Execution, FlashLane, HostAction, HostReceipt, LaneArtifact,
    LaneFailure, PrewarmReceipt, RockchipHost, Terminal, canonical_facts_digest,
    validate_completion,
};
#[cfg(target_os = "macos")]
pub use lane::{
    Absence, BUNDLE_PATH_KEY, CAMPAIGN_KEY, DAYU200_PROFILE, DaemonStop, Lane, LaneInputs,
    NATIVE_ROCKUSB_TOOLCHAIN, RETIRED_KEYS, daemon_arguments, device_profile_selector,
    verify_readiness,
};
pub use loader::{
    LOADER_OBSERVATION_TIMEOUT, SelectionFailure, confirm_loader, select, topology_digest,
    usable_loader,
};
