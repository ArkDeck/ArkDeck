//! The ArkForge lane's place in this Runtime's state.
//!
//! Swift's daemon creates the lane's runtime directory at its start, beside
//! its Job state, owner-only and best effort, and reads the lane daemon's
//! public socket there whether or not a lane was composed: without one,
//! nothing answers and device access is refused. This Runtime does the same;
//! spawning and pairing `arkforged` in that directory is not ported yet.
use std::os::unix::fs::DirBuilderExt;
use std::path::{Path, PathBuf};

/// `<state>/arkforge`, created owner-only when it is missing. An existing
/// directory keeps its mode, as Swift's `createDirectory` leaves it.
pub(crate) fn runtime_directory(state: &Path) -> PathBuf {
    let directory = state.join("arkforge");
    let _ = std::fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(&directory);
    directory
}
