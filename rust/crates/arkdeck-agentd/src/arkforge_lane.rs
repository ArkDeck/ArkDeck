//! The ArkForge lane's place in this Runtime.
//!
//! Swift's daemon creates the lane's runtime directory at its start, beside
//! its Job state, owner-only and best effort, and reads the lane daemon's
//! public socket there whether or not a lane was composed. When one validated
//! release bundle is named, it composes the lane: it starts and pairs one
//! `arkforged` generation in that directory, proves it ready, and stops it
//! after its own drain (`main.swift` 1118-1200, 1617-1629), or after its
//! managed HDC server when a start fails once the lane is composed
//! (1595-1602). Absent is the normal state, written once to the log with
//! what it means.
use arkdeck_hoststore::NativeRockUsbIdentity;
use arkdeck_platform::ServerExit;
use arkdeck_provider_arkforge::{Absence, DaemonStop, Lane, LaneInputs};
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

    /// Swift's lane plan previewer, composed only with a lane: the profile
    /// the lane was composed for (`main.swift` 1410-1414).
    pub(crate) fn lane_plan_preview(&self) -> Option<String> {
        self.lane
            .as_ref()
            .ok()
            .map(|lane| lane.profile_reference().to_owned())
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

/// A daemon that ends without its drain — a start that fails once the lane
/// is composed, or serving that ends in an error — drops this, and the drop
/// stops the lane's daemon there and then, as Swift's failed start stops it
/// (`DaemonLifecycle.stop`, `main.swift` 1595-1602): its end of input, then
/// TERM to its group, then KILL, each with its half second, and reaped. It
/// names on stderr the process it stopped and how that ended, as the daemon
/// does for its managed HDC server (`managed_hdc::Launched`). After the
/// drain's own `stop` there is nothing left to stop, and nothing is written.
impl Drop for Composed {
    fn drop(&mut self) {
        if let Ok(lane) = &self.lane
            && let Some(stopped) = lane.stop_daemon()
        {
            eprintln!("arkdeck-agentd: {}", stopped_line(&stopped));
        }
    }
}

/// What a daemon ending without its drain reports of the `arkforged` it
/// stopped: its PID, as its launch recorded it, and its end, or why the stop
/// failed.
fn stopped_line(stopped: &DaemonStop) -> String {
    match &stopped.stopped {
        Ok(stop) => format!(
            "stopped the arkforged this daemon launched (pid {}), which {}",
            stopped.pid,
            match stop.exit {
                ServerExit::Exited(status) => format!("exited with status {status}"),
                ServerExit::Signalled(signal) => format!("ended on signal {signal}"),
            }
        ),
        Err(error) => format!(
            "the arkforged this daemon launched (pid {}) did not stop: {error}",
            stopped.pid
        ),
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

#[cfg(test)]
mod tests {
    use super::*;
    use arkdeck_platform::ServerStop;

    /// What a daemon ending without its drain writes of the `arkforged` it
    /// stopped, beside the managed HDC server's line
    /// (`managed_hdc::Stop::report`).
    #[test]
    fn a_daemon_ending_without_its_drain_names_the_arkforged_it_stopped() {
        let stopped = |exit| DaemonStop {
            pid: 4242,
            stopped: Ok(ServerStop {
                stdout: Vec::new(),
                stderr: Vec::new(),
                truncated: false,
                exit,
            }),
        };
        assert_eq!(
            stopped_line(&stopped(ServerExit::Exited(11))),
            "stopped the arkforged this daemon launched (pid 4242), which exited with status 11"
        );
        assert_eq!(
            stopped_line(&stopped(ServerExit::Signalled(9))),
            "stopped the arkforged this daemon launched (pid 4242), which ended on signal 9"
        );
        assert_eq!(
            stopped_line(&DaemonStop {
                pid: 4242,
                stopped: Err(std::io::Error::other(
                    "server did not end after termination"
                )),
            }),
            "the arkforged this daemon launched (pid 4242) did not stop: server did not end \
             after termination"
        );
    }
}
