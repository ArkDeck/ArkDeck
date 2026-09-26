//! Swift `ArkForgeLaneComposition`: the ArkForge lane from what an operator
//! installed, or why there is none.
//!
//! Absent is the normal state. One validated ArkForge release bundle, named
//! by `ARKDECK_ARKFORGE_BUNDLE_PATH`, selects and binds the daemon and the
//! DeviceProfile; nothing is assembled from separate values. A composed lane
//! owns exactly one `arkforged` generation: started in its own process group
//! from the bundle's measured bytes, handed a fresh pairing secret on stdin
//! and nothing else, and stopped — its end of input first — on every failure
//! and at the owner's own stop.
//!
//! This composes and proves the lane; plans, permits and execution through it
//! are later slices.

use arkdeck_contract::{arkforge_bundle, sha256_hex};
use arkdeck_platform::{ManagedServer, ServerStop, VerifiedTool};
use arkforge_client::{ControllerClient, PublicClient, PublicRuntimeInfo};
use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, PoisonError};
use std::time::{Duration, Instant};

/// The one environment value that selects a lane.
pub const BUNDLE_PATH_KEY: &str = "ARKDECK_ARKFORGE_BUNDLE_PATH";
/// Retired lane names: refused by name, never read.
pub const RETIRED_KEYS: [&str; 3] = [
    "ARKDECK_ARKFORGED_PATH",
    "ARKDECK_ARKFORGED_SHA256",
    "ARKDECK_ARKFORGE_PROFILE_PATH",
];
/// The acceptance campaign the lane may run, if any; unset is the normal,
/// assessment-only state.
pub const CAMPAIGN_KEY: &str = "ARKDECK_ARKFORGE_CAMPAIGN";
/// The DeviceProfile the bundle must publish.
pub const DAYU200_PROFILE: &str = "org.openharmony.dayu200";
/// The native RockUSB toolchain `arkforged` must report as bound.
pub const NATIVE_ROCKUSB_TOOLCHAIN: &str = "arkforged-native-rockusb";

/// Swift waits ten seconds for the controller socket, looking every 50 ms.
const SOCKET_DEADLINE: Duration = Duration::from_secs(10);
const SOCKET_POLL: Duration = Duration::from_millis(50);
/// What the owner keeps of the daemon's own output, per stream.
const CAPTURE_BYTES: usize = 1 << 20;

/// Swift `ArkForgeLaneComposition.Absence`: why no lane was composed, each in
/// words an operator can act on.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Absence {
    NotConfigured,
    PartiallyConfigured(Vec<String>),
    RetiredConfiguration(Vec<String>),
    DaemonUnavailable(String),
}

impl std::fmt::Display for Absence {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::NotConfigured => write!(
                f,
                "no ArkForge lane: {BUNDLE_PATH_KEY} is unset, so this daemon performs no \
                 Rockchip writes. canonical ArkForge Flash refuses before authorization"
            ),
            Self::PartiallyConfigured(missing) => write!(
                f,
                "no ArkForge lane: {} missing. A partial configuration is refused rather than \
                 half-applied — a lane composed from some of its inputs is one nobody chose",
                missing.join(", ")
            ),
            Self::RetiredConfiguration(keys) => write!(
                f,
                "no ArkForge lane: {} is retired configuration. Reconfigure this installation \
                 with `runtime service update --arkforge-bundle` so one validated \
                 {BUNDLE_PATH_KEY} is published",
                keys.join(", ")
            ),
            Self::DaemonUnavailable(detail) => write!(f, "no ArkForge lane: {detail}"),
        }
    }
}

/// Swift `ArkForgeLaneComposition.Inputs`: all a lane needs, all of it from
/// one verified bundle.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LaneInputs {
    pub daemon_path: PathBuf,
    /// The daemon's bytes measured again, not the manifest's word for them.
    pub daemon_sha256: String,
    pub device_profile_path: PathBuf,
    /// Empty when the lane runs no campaign.
    pub campaign: String,
}

impl LaneInputs {
    /// Swift `Inputs.read` over the environment `variable` reads: a retired
    /// name refuses, no bundle path is no lane, and everything else comes
    /// from the verified bundle.
    pub fn read(variable: impl Fn(&str) -> Option<String>) -> Result<Self, Absence> {
        let retired: Vec<String> = RETIRED_KEYS
            .iter()
            .filter(|key| variable(key).is_some())
            .map(|key| (*key).to_owned())
            .collect();
        if !retired.is_empty() {
            return Err(Absence::RetiredConfiguration(retired));
        }
        let Some(configured) = variable(BUNDLE_PATH_KEY) else {
            return Err(Absence::NotConfigured);
        };
        if configured.is_empty() {
            return Err(Absence::PartiallyConfigured(vec![
                BUNDLE_PATH_KEY.to_owned(),
            ]));
        }
        let bundle = arkforge_bundle::load(Path::new(&configured)).map_err(|error| {
            Absence::DaemonUnavailable(format!("ArkForge.bundle is invalid: {error}"))
        })?;
        let Some(profile) = bundle.profiles.get(DAYU200_PROFILE) else {
            return Err(Absence::DaemonUnavailable(format!(
                "ArkForge.bundle does not publish {DAYU200_PROFILE}"
            )));
        };
        let daemon_sha256 = std::fs::read(&bundle.daemon)
            .map(|bytes| sha256_hex(&bytes))
            .map_err(|error| {
                Absence::DaemonUnavailable(format!("cannot remeasure arkforged: {error}"))
            })?;
        Ok(Self {
            daemon_path: bundle.daemon,
            daemon_sha256,
            device_profile_path: profile.clone(),
            campaign: variable(CAMPAIGN_KEY).unwrap_or_default(),
        })
    }
}

/// Foundation's `CharacterSet.whitespaces`: the space separators and the tab.
fn swift_whitespace(character: char) -> bool {
    character == '\t'
        || (character.is_whitespace()
            && !matches!(
                character,
                '\n' | '\u{0B}' | '\u{0C}' | '\r' | '\u{85}' | '\u{2028}' | '\u{2029}'
            ))
}

/// Swift `deviceProfileSelector(inDocument:)`: exactly one `profile.id` and one
/// `profile.version` in the `profile:` block, read as the two scalars they
/// are; `None` for any other shape, duplicate or empty fields included.
pub fn device_profile_selector(document: &str) -> Option<(String, String)> {
    let mut inside = false;
    let (mut id, mut version) = (None, None);
    for line in document.split('\n') {
        if line.starts_with('#') {
            continue;
        }
        if line == "profile:" {
            inside = true;
            continue;
        }
        // Any other column-zero key ends the block.
        if inside
            && line
                .chars()
                .next()
                .is_some_and(|first| first != ' ' && first != '\t')
        {
            inside = false;
        }
        if !inside {
            continue;
        }
        let trimmed = line.trim_matches(swift_whitespace);
        for (key, slot) in [("id:", &mut id), ("version:", &mut version)] {
            if let Some(value) = trimmed.strip_prefix(key) {
                let value = value.trim_matches(swift_whitespace);
                if slot.is_some() || value.is_empty() {
                    return None;
                }
                *slot = Some(value.to_owned());
                break;
            }
        }
    }
    Some((id?, version?))
}

/// Swift `daemonArguments`: the runtime directory, the bundle's profile and
/// the pairing epoch; the campaign only when one is named. The secret is not
/// among them by construction.
pub fn daemon_arguments(
    inputs: &LaneInputs,
    runtime_directory: &Path,
    pairing_epoch: u64,
) -> Vec<OsString> {
    let mut arguments: Vec<OsString> = vec![
        "--runtime-dir".into(),
        runtime_directory.as_os_str().to_owned(),
        "--profile".into(),
        inputs.device_profile_path.as_os_str().to_owned(),
        "--pair-from-stdin".into(),
        pairing_epoch.to_string().into(),
    ];
    if !inputs.campaign.is_empty() {
        arguments.push("--hardware-campaign".into());
        arguments.push(inputs.campaign.clone().into());
    }
    arguments
}

/// Swift `ArkForgeLaneHost.verifyReadiness`: both standing facts, checked
/// before any job exists — a daemon ready to execute, bound to the native
/// RockUSB toolchain whose digest is the bundle's daemon.
pub fn verify_readiness(info: &PublicRuntimeInfo, daemon_sha256: &str) -> Result<(), String> {
    if !info.execution_ready {
        return Err(format!(
            "arkforged is not ready to execute: {}. Nothing was dispatched — this is a standing \
             fact about the daemon, not a fault of this job",
            info.execution_blockers.join(", ")
        ));
    }
    if info.toolchain_id != NATIVE_ROCKUSB_TOOLCHAIN {
        return Err(format!(
            "the daemon bound toolchain {}, while this lane expects {NATIVE_ROCKUSB_TOOLCHAIN}; \
             the backend identity is part of the published maturity combination",
            info.toolchain_id
        ));
    }
    let bound = info.toolchain_sha256.to_lowercase();
    let expected = daemon_sha256.to_lowercase();
    if bound != expected {
        return Err(format!(
            "the daemon bound {bound}, while this lane publishes plans for {expected}; the \
             backend digest is part of the maturity combination"
        ));
    }
    Ok(())
}

/// Swift `ArkForgeLaneHost.digestBytes` accepts exactly 64 hex digits.
fn digest(value: &str) -> bool {
    value.len() == 64 && value.bytes().all(|byte| byte.is_ascii_hexdigit())
}

/// A composed lane: the one `arkforged` generation it owns and what it was
/// composed for.
pub struct Lane {
    daemon: Mutex<Option<ManagedServer>>,
    _tool: VerifiedTool,
    runtime_directory: PathBuf,
    profile_reference: String,
    daemon_sha256: String,
    campaign: String,
}

impl Lane {
    /// Swift `ArkForgeLaneComposition.compose`, with the real launch, connect
    /// and readiness: the DeviceProfile read before anything starts, the
    /// authority's two digests present, stale sockets removed, the daemon
    /// launched with `secret`, its controller socket awaited, a controller
    /// session opened and its readiness proved. Any failure after the launch
    /// stops the generation it started before refusing.
    pub fn compose(
        inputs: &LaneInputs,
        runtime_directory: &Path,
        pairing_epoch: u64,
        secret: &[u8],
        authority_implementation_sha256: &str,
        managed_control_tool_sha256: &str,
    ) -> Result<Self, Absence> {
        let unavailable = |detail: String| Absence::DaemonUnavailable(detail);
        let source = std::fs::read_to_string(&inputs.device_profile_path).map_err(|_| {
            unavailable(format!(
                "cannot read the DeviceProfile at {}",
                inputs.device_profile_path.display()
            ))
        })?;
        let Some((id, version)) = device_profile_selector(&source) else {
            return Err(unavailable(format!(
                "the DeviceProfile at {} must declare exactly one profile.id and \
                 profile.version; materializePlan addresses a loaded profile by id@version, and \
                 this lane will not guess either field",
                inputs.device_profile_path.display()
            )));
        };
        if id != DAYU200_PROFILE {
            return Err(unavailable(format!(
                "the bundle manifest selected {DAYU200_PROFILE}, but the DeviceProfile declares \
                 {id}"
            )));
        }
        if !digest(authority_implementation_sha256) {
            return Err(unavailable(
                "cannot bind ArkForge authority support: the exact running arkdeck-agentd \
                 digest is absent or malformed"
                    .into(),
            ));
        }
        if !digest(managed_control_tool_sha256) {
            return Err(unavailable(
                "cannot bind ArkForge authority support: the managed-control HDC digest is \
                 absent or malformed"
                    .into(),
            ));
        }
        // A leftover socket exists at once, so the wait below would reach the
        // previous generation's daemon; without them, only the one launched
        // here can bind.
        for name in ["controller.sock", "public.sock"] {
            let _ = std::fs::remove_file(runtime_directory.join(name));
        }
        let started = VerifiedTool::open(&inputs.daemon_path, &inputs.daemon_sha256.to_lowercase())
            .and_then(|tool| {
                ManagedServer::launch_paired(
                    &tool,
                    &daemon_arguments(inputs, runtime_directory, pairing_epoch),
                    &[],
                    runtime_directory,
                    secret,
                    CAPTURE_BYTES,
                )
                .map(|daemon| (tool, daemon))
            });
        let (tool, daemon) =
            started.map_err(|error| unavailable(format!("arkforged did not start: {error}")))?;
        let lane = Self {
            daemon: Mutex::new(Some(daemon)),
            _tool: tool,
            runtime_directory: runtime_directory.to_path_buf(),
            profile_reference: format!("{id}@{version}"),
            daemon_sha256: inputs.daemon_sha256.to_lowercase(),
            campaign: inputs.campaign.clone(),
        };
        let refuse = |lane: Self, detail: String| {
            lane.stop();
            Err(unavailable(detail))
        };
        if !lane.await_controller_socket() {
            return refuse(
                lane,
                "arkforged started but never opened its controller socket; the owned process \
                 generation was stopped before returning the failure"
                    .into(),
            );
        }
        if let Err(error) = ControllerClient::connect(runtime_directory) {
            return refuse(
                lane,
                format!("could not open a controller session: {}", error.message),
            );
        }
        // ArkForge's Rust controller client keeps no acknowledgement; the
        // daemon publishes the same standing readiness on every session.
        let readiness = PublicClient::connect(runtime_directory)
            .map_err(|error| format!("could not read the daemon's readiness: {}", error.message))
            .and_then(|client| verify_readiness(client.runtime_info(), &lane.daemon_sha256));
        if let Err(detail) = readiness {
            return refuse(lane, detail);
        }
        Ok(lane)
    }

    fn await_controller_socket(&self) -> bool {
        let socket = self.runtime_directory.join("controller.sock");
        let deadline = Instant::now() + SOCKET_DEADLINE;
        while Instant::now() < deadline {
            if socket.exists() {
                return true;
            }
            // A daemon that already ended will never open it.
            if let Ok(mut daemon) = self.daemon.lock()
                && daemon
                    .as_mut()
                    .is_some_and(|daemon| matches!(daemon.exit(), Ok(Some(_))))
            {
                return false;
            }
            std::thread::sleep(SOCKET_POLL);
        }
        socket.exists()
    }

    /// `id@version`, the exact profile the daemon loaded.
    pub fn profile_reference(&self) -> &str {
        &self.profile_reference
    }

    /// The daemon's measured digest, which it reported as its bound toolchain.
    pub fn daemon_sha256(&self) -> &str {
        &self.daemon_sha256
    }

    /// The named acceptance campaign, empty when there is none.
    pub fn campaign(&self) -> &str {
        &self.campaign
    }

    /// Swift's reason a connected lane without a campaign may not flash.
    pub fn assessment_only_reason(&self) -> Option<&'static str> {
        self.campaign.is_empty().then_some(
            "ArkForge is connected for assessment only (hardwareGated). Flash is unavailable: \
             this configuration has no reviewed production support record or named hardware \
             acceptance campaign.",
        )
    }

    /// The runtime directory whose sockets the daemon serves.
    pub fn runtime_directory(&self) -> &Path {
        &self.runtime_directory
    }

    /// Stops the owned generation, once: its end of input, then TERM to its
    /// group, then KILL. What it wrote comes back the first time.
    pub fn stop(&self) -> Option<ServerStop> {
        self.stop_daemon()?.stopped.ok()
    }

    /// [`Lane::stop`], naming the process it stopped and how that ended, or
    /// why the stop failed; `None` once the generation was stopped. A lock a
    /// panic poisoned still hands the daemon over, to be stopped in the same
    /// order.
    pub fn stop_daemon(&self) -> Option<DaemonStop> {
        let daemon = self
            .daemon
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .take()?;
        let pid = daemon.launch_record().pid;
        Some(DaemonStop {
            pid,
            stopped: daemon.stop(),
        })
    }
}

/// What stopping a lane's daemon left: the process its launch recorded, and
/// what its stop collected, or why the stop failed.
#[derive(Debug)]
pub struct DaemonStop {
    pub pid: i32,
    pub stopped: std::io::Result<ServerStop>,
}

impl Drop for Lane {
    fn drop(&mut self) {
        self.stop();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_profile_selector_reads_exactly_two_scalars_of_the_profile_block() {
        let document = "# DAYU200\nschema: arkforge.device-profile/v1\nprofile:\n  id: \
                        org.openharmony.dayu200\n  version: 1.0.0\nusbIdentities:\n  id: \
                        elsewhere\n";
        assert_eq!(
            device_profile_selector(document),
            Some(("org.openharmony.dayu200".into(), "1.0.0".into()))
        );
        for refused in [
            "profile:\n  id: a\n",
            "profile:\n  version: 1\n",
            "profile:\n  id: a\n  id: b\n  version: 1\n",
            "profile:\n  id:\n  version: 1\n",
            "id: a\nversion: 1\n",
            "profile:\r\n  id: a\n  version: 1\n",
        ] {
            assert_eq!(device_profile_selector(refused), None, "{refused:?}");
        }
        // A comment at column zero neither ends the block nor counts.
        assert_eq!(
            device_profile_selector("profile:\n  id: a\n# note\n  version: 1\n"),
            Some(("a".into(), "1".into()))
        );
        assert_eq!(
            device_profile_selector("profile:\n\tid:\ta \t\n  version: 1\n"),
            Some(("a".into(), "1".into()))
        );
    }

    #[test]
    fn the_daemon_is_started_with_the_directory_the_profile_and_the_epoch_only() {
        let mut inputs = LaneInputs {
            daemon_path: "/b/Contents/MacOS/arkforged".into(),
            daemon_sha256: "0".repeat(64),
            device_profile_path: "/b/Contents/Resources/profiles/dayu200.yaml".into(),
            campaign: String::new(),
        };
        let run = Path::new("/state/arkforge");
        assert_eq!(
            daemon_arguments(&inputs, run, 1_770_000_000),
            [
                "--runtime-dir",
                "/state/arkforge",
                "--profile",
                "/b/Contents/Resources/profiles/dayu200.yaml",
                "--pair-from-stdin",
                "1770000000"
            ]
            .map(OsString::from)
        );
        inputs.campaign = "HW-2026-09".into();
        assert_eq!(
            daemon_arguments(&inputs, run, 7)[6..],
            ["--hardware-campaign", "HW-2026-09"].map(OsString::from)
        );
    }

    #[test]
    fn readiness_refuses_in_swifts_words() {
        let ready = PublicRuntimeInfo {
            protocol_major: 1,
            protocol_minor: 0,
            daemon_version: "0.1.0".into(),
            execution_ready: true,
            execution_blockers: Vec::new(),
            toolchain_id: NATIVE_ROCKUSB_TOOLCHAIN.into(),
            toolchain_sha256: "AB".repeat(32),
        };
        assert_eq!(verify_readiness(&ready, &"ab".repeat(32)), Ok(()));
        let not_ready = PublicRuntimeInfo {
            execution_ready: false,
            execution_blockers: vec!["NO_PAIRED_AUTHORITY".into(), "NO_DISPATCHER".into()],
            ..ready.clone()
        };
        assert_eq!(
            verify_readiness(&not_ready, &"ab".repeat(32)).unwrap_err(),
            "arkforged is not ready to execute: NO_PAIRED_AUTHORITY, NO_DISPATCHER. Nothing was \
             dispatched — this is a standing fact about the daemon, not a fault of this job"
        );
        let replay = PublicRuntimeInfo {
            toolchain_id: "replay".into(),
            ..ready.clone()
        };
        assert_eq!(
            verify_readiness(&replay, &"ab".repeat(32)).unwrap_err(),
            "the daemon bound toolchain replay, while this lane expects \
             arkforged-native-rockusb; the backend identity is part of the published maturity \
             combination"
        );
        assert_eq!(
            verify_readiness(&ready, &"cd".repeat(32)).unwrap_err(),
            format!(
                "the daemon bound {}, while this lane publishes plans for {}; the backend \
                 digest is part of the maturity combination",
                "ab".repeat(32),
                "cd".repeat(32)
            )
        );
    }

    #[test]
    fn the_inputs_come_from_one_bundle_and_retired_names_refuse() {
        let variable = |pairs: &'static [(&'static str, &'static str)]| {
            move |key: &str| {
                pairs
                    .iter()
                    .find(|(name, _)| *name == key)
                    .map(|(_, value)| (*value).to_owned())
            }
        };
        assert_eq!(LaneInputs::read(variable(&[])), Err(Absence::NotConfigured));
        assert_eq!(
            LaneInputs::read(variable(&[(BUNDLE_PATH_KEY, "")])),
            Err(Absence::PartiallyConfigured(vec![BUNDLE_PATH_KEY.into()]))
        );
        assert_eq!(
            LaneInputs::read(variable(&[
                (BUNDLE_PATH_KEY, "/nowhere"),
                ("ARKDECK_ARKFORGED_SHA256", "x"),
                ("ARKDECK_ARKFORGED_PATH", "/x"),
            ])),
            Err(Absence::RetiredConfiguration(vec![
                "ARKDECK_ARKFORGED_PATH".into(),
                "ARKDECK_ARKFORGED_SHA256".into()
            ]))
        );
        let Err(Absence::DaemonUnavailable(detail)) =
            LaneInputs::read(variable(&[(BUNDLE_PATH_KEY, "/nowhere/ArkForge.bundle")]))
        else {
            panic!("a missing bundle is no lane");
        };
        assert!(
            detail.starts_with("ArkForge.bundle is invalid: "),
            "{detail}"
        );
        assert_eq!(
            Absence::NotConfigured.to_string(),
            "no ArkForge lane: ARKDECK_ARKFORGE_BUNDLE_PATH is unset, so this daemon performs \
             no Rockchip writes. canonical ArkForge Flash refuses before authorization"
        );
    }
}
