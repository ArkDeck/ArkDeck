//! The ArkForge lane of the Rust Runtime (lane D).
//!
//! ArkForge is the device-neutral flash mechanism: `arkforged` owns the USB
//! transport and the firmware formats, and ArkDeck stays the only authority
//! that may permit a write. This crate talks to it through ArkForge's own
//! Rust client crates, taken at the revision `Packages/ArkDeckKit/Package.swift`
//! pins for the Swift SDK, so both lanes speak one protocol revision.
//!
//! It reads only, so far: which Rockchip flashing modes the lane's daemon sees
//! attached, through its public socket. Spawning and pairing `arkforged`, and
//! the controller surface that plans and permits, follow in later slices.

#![forbid(unsafe_code)]

mod device_access;

pub use device_access::{
    DEVICE_ACCESS_TIMEOUT, DeviceAccessFailure, DeviceAccessObserver, DeviceMode,
};
