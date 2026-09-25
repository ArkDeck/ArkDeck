//! The ArkForge lane's place in this Runtime.
//!
//! Swift's daemon creates the lane's runtime directory at its start, beside
//! its Job state, owner-only and best effort, and reads the lane daemon's
//! public socket there whether or not a lane was composed. When one validated
//! release bundle is named, it composes the lane: it starts and pairs one
//! `arkforged` generation in that directory, proves it ready, and stops it
//! after its own drain (`main.swift` 1118-1200, 1617-1629). Absent is the
//! normal state, written once to the log with what it means.
use arkdeck_hoststore::NativeRockUsbIdentity;
use arkdeck_provider_arkforge::{Absence, Lane, LaneInputs};
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

/// What the lane composition found.
pub(crate) struct Composed {
    pub(crate) runtime_directory: PathBuf,
    /// The bundle's inputs, read whether or not its daemon started: the
    /// flash facts measure the configured `arkforged` from them, as Swift's
    /// `rockchipResolver` does.
    pub(crate) inputs: Option<LaneInputs>,
    pub(crate) lane: Result<Lane, Absence>,
}

impl Composed {
    /// Swift's native RockUSB identity for the facts: the configured daemon
    /// and its measured digest, or none.
    pub(crate) fn rockusb(&self) -> NativeRockUsbIdentity {
        match &self.inputs {
            Some(inputs) => NativeRockUsbIdentity::configured(
                Some(inputs.daemon_path.to_string_lossy().into_owned()),
                Some(inputs.daemon_sha256.clone()),
            ),
            None => NativeRockUsbIdentity::unconfigured(),
        }
    }

    /// Swift's start-up lines: the profile the lane was composed for and,
    /// without a campaign, why it may not flash; or why there is no lane.
    pub(crate) fn report(&self) {
        match &self.lane {
            Ok(lane) => {
                eprintln!("arkforge lane: composed for {}", lane.profile_reference());
                if let Some(reason) = lane.assessment_only_reason() {
                    eprintln!("arkforge Flash: {reason}");
                }
            }
            Err(absence) => eprintln!("{absence}"),
        }
    }

    /// Swift's Flash planning over this lane (`flash_planning`): why there is
    /// no lane, or why a lane without a campaign may not flash, and the
    /// lane's toolchain, which its StepPermits bind.
    pub(crate) fn planning(&self, state: &Path, hdc: bool) -> arkdeck_hoststore::FlashPlanning {
        let (unavailable, toolchain) = match &self.lane {
            Ok(lane) => (
                lane.assessment_only_reason().map(str::to_owned),
                Some(lane.daemon_sha256().to_owned()),
            ),
            Err(absence) => (Some(absence.to_string()), None),
        };
        flash_planning(unavailable, toolchain, self.rockusb(), state, hdc)
    }

    /// Stops the lane's daemon, once, after the owner's drain.
    pub(crate) fn stop(&self) {
        if let Ok(lane) = &self.lane
            && let Some(stopped) = lane.stop()
        {
            eprintln!("arkdeck-agentd: stopped arkforged ({:?})", stopped.exit);
        }
    }
}

/// Swift's Flash planning as `main.swift` composes the ArkForge provider and
/// the Rockchip dispatcher: the provider's availability (`unavailable`, none
/// when it may flash) and the lane's `toolchain`, and the dispatcher's
/// reason over the configured `arkforged` (`identity`) and, with a
/// descriptor-bound HDC (`hdc`), the per-action host's record root
/// `<state>/rockchip-runtime`.
pub(crate) fn flash_planning(
    unavailable: Option<String>,
    toolchain: Option<String>,
    identity: NativeRockUsbIdentity,
    state: &Path,
    hdc: bool,
) -> arkdeck_hoststore::FlashPlanning {
    let records = hdc.then(|| state.join("rockchip-runtime"));
    arkdeck_hoststore::FlashPlanning::new(
        unavailable,
        move || arkdeck_hoststore::rockchip_dispatch_unavailable(&identity, records.as_deref()),
        toolchain,
    )
}

/// The digest of this very executable, the authority the lane's permits will
/// name; empty when it cannot be measured, which refuses the lane.
fn authority_implementation_sha256() -> String {
    std::env::current_exe()
        .and_then(std::fs::read)
        .map(|bytes| arkdeck_contract::sha256_hex(&bytes))
        .unwrap_or_default()
}

/// Swift's lane composition over `state`, the environment `variable` reads
/// and the managed-control HDC's digest.
pub(crate) fn compose(
    state: &Path,
    variable: impl Fn(&str) -> Option<String>,
    managed_control_tool_sha256: Option<&str>,
) -> Composed {
    let runtime_directory = runtime_directory(state);
    let inputs = LaneInputs::read(variable);
    let lane = match &inputs {
        Err(absence) => Err(absence.clone()),
        Ok(inputs) => arkdeck_platform::random_bytes::<32>()
            .map_err(|error| {
                Absence::DaemonUnavailable(format!("no pairing secret could be drawn: {error}"))
            })
            .and_then(|secret| {
                let epoch = std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .map_or(0, |since| since.as_secs());
                Lane::compose(
                    inputs,
                    &runtime_directory,
                    epoch,
                    &secret,
                    &authority_implementation_sha256(),
                    managed_control_tool_sha256.unwrap_or_default(),
                )
            }),
    };
    Composed {
        runtime_directory,
        inputs: inputs.ok(),
        lane,
    }
}
