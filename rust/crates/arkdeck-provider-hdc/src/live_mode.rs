//! Swift's `FoundationRockchipLiveModeProbe` (`RockchipLiveModeProbe.swift`):
//! the read-only observation of a bound Rockchip target's current mode and
//! build that stands behind the flash facts of milestone M4.
//!
//! Everything here is E0: one `hdc list targets -v`, one allowlisted `param
//! get`, and two observations another owner serves through the ports below —
//! the current USB port of the exact HDC-normal identity, and ArkForge's
//! dual-source Loader observation. Nothing here transitions a device and
//! nothing here is an admission gate: a probe that cannot see the device
//! fails, and the facts port that consumes it encodes that as `deviceMode:
//! "absent"` so that device-absent planOnly and draft keep working with no
//! device attached. The fail-closed gates are the engine's fresh readback and
//! reservation at the consume point, not this portrait.
//!
//! The HDC reads run through an [`HdcDispatch`]; this module starts nothing
//! itself and resolves no executable. Swift resolves `hdc` inside the probe
//! and reports a missing tool as not observable; here the tool is resolved
//! before an `HdcDispatch` exists, and [`LiveModeFailure::unavailable_tool`]
//! keeps that report's wording for the composer.
use crate::{
    DispatchFailure, HdcDispatch, ParseError, ProcessPlan, Property, parse_target_list,
    property_value,
};
use sha2::{Digest, Sha256};
use std::fmt;
use std::time::Duration;
use unicode_segmentation::UnicodeSegmentation;

/// Swift `FoundationRockchipLiveModeProbe.read`: every probe read has 15 s…
const READ_TIMEOUT: Duration = Duration::from_secs(15);
/// …and a 64 KiB capture. (Swift also passes `criticalNonInterruptible:
/// false`; the runner behind an `HdcDispatch` has no such flag.)
const READ_CAPTURE_BYTES: usize = 64 * 1024;
/// Swift `buildFingerprint`: a longer readback is not a build.
const MAXIMUM_BUILD_CHARACTERS: usize = 400;
/// The registered tool version Swift parses the live target list with
/// (`profile: .openHarmony320Family, toolVersion: "3.2.0f"`).
const TARGET_LIST_VERSION: &str = "3.2.0f";

/// The mode the live probe can name. Swift documents `maskrom` as a third
/// value, but its probe never emits it: the RockUSB arm reports `loader`, and
/// Maskrom is outside the native RockUSB product scope. Absence is not a mode:
/// a probe that cannot see the device fails instead.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DeviceMode {
    Hdc,
    Loader,
}

impl DeviceMode {
    /// The `deviceMode` fact as Swift spells it.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Hdc => "hdc",
            Self::Loader => "loader",
        }
    }
}

impl fmt::Display for DeviceMode {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

/// Swift `RockchipLiveModeObservation`: one read-only observation of the
/// bound target's current mode and build.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct LiveModeObservation {
    pub device_mode: DeviceMode,
    /// Exact `const.ohos.fullname` readback. Only the HDC surface exposes a
    /// build at all, so Loader leaves this `None` rather than carrying an
    /// inferred or stale value — and so does an HDC readback that failed: a
    /// known mode with an unknown build, never a guess.
    pub build_fingerprint: Option<String>,
    /// Fresh USB location of the exact identity observed. Intentionally
    /// ephemeral: moving a cable does not rewrite durable target identity, but
    /// the next ArkForge materialization must address the port the bound
    /// device occupies now. `None` when no port could be attributed to this
    /// target.
    pub usb_topology: Option<String>,
}

/// Swift `RockchipLiveModeProbeFailure`.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum LiveModeFailure {
    NotObservable(String),
}

impl LiveModeFailure {
    /// Swift `resolve(_:providerID:)`: the probe's executable could not be
    /// resolved, so nothing was observed and nothing was searched for on the
    /// PATH. The composer that resolves `hdc` before building an
    /// [`HdcDispatch`] reports its failure with this so the facts read alike.
    pub fn unavailable_tool(provider_id: &str, detail: &dyn fmt::Display) -> Self {
        Self::NotObservable(format!(
            "{provider_id} executable is unavailable to the facts probe: {detail}"
        ))
    }
}

impl fmt::Display for LiveModeFailure {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::NotObservable(detail) => {
                write!(f, "the bound Rockchip target is not observable: {detail}")
            }
        }
    }
}

impl std::error::Error for LiveModeFailure {}

/// Swift `RockchipRuntimeLoaderIdentity`: the SHA-256 (lowercase hex) of the
/// serial the observer saw, and the USB topology it saw it at.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct LoaderIdentity {
    pub serial_digest_sha256: String,
    pub topology: String,
}

/// Swift `RockchipRuntimeHDCIdentity`: an HDC-normal device seen at a USB
/// topology — its connect key, the SHA-256 (lowercase hex) of that key's
/// exact bytes, and the topology.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct HdcIdentity {
    pub connect_key: String,
    pub serial_digest_sha256: String,
    pub topology: String,
}

/// Swift `ArkForgeLoaderObserving.observeLoader(stableIdentitySHA256:
/// expectedUSBTopology:requestID:)`: the dual-source proof that the device at
/// the bound identity is a settled DAYU200 RockUSB Loader — the host's USB
/// enumeration for the exact serial and location, ArkForge's independently
/// enumerated `discoverDevices` for the provider and mode. It is the ArkForge
/// lane's to implement over `arkforged`; the reason it refuses with is free
/// text that this probe quotes.
pub trait LoaderObserver {
    fn observe_loader(
        &self,
        stable_identity_sha256: &str,
        expected_usb_topology: Option<&str>,
        request_id: &str,
    ) -> Result<LoaderIdentity, String>;
}

/// Swift `RockchipRuntimeUSBProbing`'s HDC-normal lookups: exactly one
/// HDC-normal DAYU200 whose serial digest is the given identity, or exactly
/// one at the given USB topology, each with its current topology. ArkDeck no
/// longer owns the enumeration (design: `arkforged discoverDevices`), so this
/// is a port; the callers discard the reason a lookup refuses with, as
/// Swift's `try?` does.
pub trait UsbProbe {
    /// `singleHDCNormal(stableIdentitySHA256:)`.
    fn single_hdc_normal(&self, stable_identity_sha256: &str) -> Result<LoaderIdentity, String>;

    /// `singleHDCNormal(usbTopology:)`, with Swift's default refusal for a
    /// probe that cannot look a port up by topology.
    fn single_hdc_normal_at(&self, usb_topology: &str) -> Result<HdcIdentity, String> {
        let _ = usb_topology;
        Err("topology-bound HDC observation is unavailable".to_owned())
    }
}

/// Swift `FoundationRockchipLiveModeProbe`, over an [`HdcDispatch`] and the two
/// observation ports. HDC first, because it names the target by its connect
/// key; only once HDC says that personality is absent may RockUSB name the
/// mode, and only for the exact bound identity.
pub struct LiveModeProbe<'a> {
    hdc: &'a dyn HdcDispatch,
    loader_observer: &'a dyn LoaderObserver,
    usb_probe: Option<&'a dyn UsbProbe>,
}

impl<'a> LiveModeProbe<'a> {
    /// `usb_probe` is optional as in Swift: without it an HDC observation
    /// carries no topology, and the facts layer retains its durable route.
    pub fn new(
        hdc: &'a dyn HdcDispatch,
        loader_observer: &'a dyn LoaderObserver,
        usb_probe: Option<&'a dyn UsbProbe>,
    ) -> Self {
        Self {
            hdc,
            loader_observer,
            usb_probe,
        }
    }

    /// Swift `observe(connectKey:stableIdentitySHA256:)`.
    pub fn observe(
        &self,
        connect_key: &str,
        stable_identity_sha256: &str,
    ) -> Result<LiveModeObservation, LiveModeFailure> {
        if self.is_connected_over_hdc(connect_key)? {
            // The HDC-normal identity is the digest of the connect key's exact
            // bytes (`SHA256Hex.string(of: Data(connectKey.utf8))`), not the
            // lowercased adoption identity.
            let hdc_identity = sha256_hex(connect_key.as_bytes());
            let usb_topology = self
                .usb_probe
                .and_then(|probe| probe.single_hdc_normal(&hdc_identity).ok())
                .map(|identity| identity.topology);
            return Ok(LiveModeObservation {
                device_mode: DeviceMode::Hdc,
                // The mode was observed even when the build readback fails;
                // that is a known mode with an unknown build, never a guess.
                build_fingerprint: self.build_fingerprint(connect_key).ok(),
                usb_topology,
            });
        }
        self.observe_rockusb_mode(stable_identity_sha256)
    }

    /// Swift `isConnectedOverHDC`: exactly one `Connected` row with this
    /// connect key. An empty list is "not on HDC"; a list the registered
    /// parser cannot read is never downgraded to "the device is not there".
    fn is_connected_over_hdc(&self, connect_key: &str) -> Result<bool, LiveModeFailure> {
        let receipt = self.read(target_list_plan())?;
        match parse_target_list(&receipt.stdout, TARGET_LIST_VERSION, receipt.truncated) {
            Ok(rows) => Ok(rows
                .iter()
                .filter(|row| row.connect_key == connect_key && row.state == "Connected")
                .count()
                == 1),
            Err(ParseError::Empty) => Ok(false),
            Err(ParseError::UnsupportedVersion(version)) => Err(not_observable(format!(
                "HDC target parser does not support {version}"
            ))),
            Err(ParseError::InvalidEncoding) => Err(not_observable("HDC target list is not UTF-8")),
            Err(ParseError::Truncated) => {
                Err(not_observable("HDC target list exceeded its byte budget"))
            }
            Err(ParseError::Malformed(reason)) => Err(not_observable(format!(
                "HDC target list is malformed: {reason}"
            ))),
        }
    }

    /// Swift `buildFingerprint`: the same param the post-flash verifier pins
    /// against a published profile's `runtimeBuildVersion`. Any other
    /// property would produce a fingerprint no published profile can match.
    fn build_fingerprint(&self, connect_key: &str) -> Result<String, LiveModeFailure> {
        let receipt = self.read(build_property_plan(connect_key))?;
        let text = std::str::from_utf8(&receipt.stdout)
            .map_err(|_| not_observable("build property readback is not UTF-8"))?;
        let value = property_value(text, Property::FullBuildVersion.key());
        if value.is_empty() || value.graphemes(true).count() > MAXIMUM_BUILD_CHARACTERS {
            return Err(not_observable(
                "build property readback is empty or oversized",
            ));
        }
        Ok(value.to_owned())
    }

    /// Swift `observeRockUSBMode`: the Loader observer must match the target's
    /// stable identity before the tool's mode can become a fact; no admitted
    /// topology is expected here, the observed one is reported.
    fn observe_rockusb_mode(
        &self,
        stable_identity_sha256: &str,
    ) -> Result<LiveModeObservation, LiveModeFailure> {
        let request_id = format!("live-mode-{}", uuid_v4()?);
        let loader = self
            .loader_observer
            .observe_loader(stable_identity_sha256, None, &request_id)
            .map_err(|reason| {
                not_observable(format!(
                    "ArkForge dual-source Loader observation failed: {reason}"
                ))
            })?;
        Ok(LiveModeObservation {
            device_mode: DeviceMode::Loader,
            build_fingerprint: None,
            usb_topology: Some(loader.topology),
        })
    }

    /// Swift `read(executable:arguments:)`: a read that did not complete or
    /// did not exit zero observed nothing.
    fn read(&self, plan: ProcessPlan) -> Result<crate::Receipt, LiveModeFailure> {
        let receipt = self.hdc.dispatch(&plan).map_err(|failure| {
            let detail = match &failure {
                DispatchFailure::Refused(detail) | DispatchFailure::Unobservable(detail) => detail,
            };
            not_observable(format!(
                "read-only probe command did not complete: {detail}"
            ))
        })?;
        if receipt.exit_status != 0 {
            return Err(not_observable(format!(
                "read-only probe command exited {}",
                receipt.exit_status
            )));
        }
        Ok(receipt)
    }
}

fn target_list_plan() -> ProcessPlan {
    read_plan(&["list", "targets", "-v"])
}

fn build_property_plan(connect_key: &str) -> ProcessPlan {
    read_plan(&[
        "-t",
        connect_key,
        "shell",
        "param",
        "get",
        Property::FullBuildVersion.key(),
    ])
}

fn read_plan(arguments: &[&str]) -> ProcessPlan {
    ProcessPlan {
        arguments: arguments.iter().map(|value| (*value).to_owned()).collect(),
        timeout: READ_TIMEOUT,
        capture_bytes: READ_CAPTURE_BYTES,
    }
}

fn not_observable(detail: impl Into<String>) -> LiveModeFailure {
    LiveModeFailure::NotObservable(detail.into())
}

pub(crate) fn sha256_hex(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

/// Swift `UUID().uuidString.lowercased()` for the Loader observer's request
/// id: a version-4 UUID from the platform's entropy. Entropy that cannot be
/// read leaves the device unobserved rather than correlating under a
/// fabricated id.
fn uuid_v4() -> Result<String, LiveModeFailure> {
    let mut bytes = arkdeck_platform::random_bytes::<16>().map_err(|error| {
        not_observable(format!("live-mode request id could not be minted: {error}"))
    })?;
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    let hex: String = bytes.iter().map(|byte| format!("{byte:02x}")).collect();
    Ok(format!(
        "{}-{}-{}-{}-{}",
        &hex[..8],
        &hex[8..12],
        &hex[12..16],
        &hex[16..20],
        &hex[20..]
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::Receipt;
    use std::cell::RefCell;
    use std::collections::VecDeque;

    const CONNECT_KEY: &str = "device-1";
    const STABLE_IDENTITY: &str =
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const CONNECTED_ROW: &str = "device-1\t\tUSB\tConnected\tlocalhost\n";
    const BUILD_ROW: &str = "const.ohos.fullname = OpenHarmony-7.0.0.35-20260728_180253\n";
    const BUILD: &str = "OpenHarmony-7.0.0.35-20260728_180253";

    /// Swift's `ProbeCommandRunner`: scripted answers, recorded plans.
    enum Answer {
        Out(&'static str),
        Bytes(Vec<u8>),
        Exit(i32),
        Truncated(&'static str),
        Fail(DispatchFailure),
    }

    struct Scripted {
        answers: RefCell<VecDeque<Answer>>,
        plans: RefCell<Vec<ProcessPlan>>,
    }

    impl Scripted {
        fn new(answers: Vec<Answer>) -> Self {
            Self {
                answers: RefCell::new(answers.into()),
                plans: RefCell::new(Vec::new()),
            }
        }

        fn arguments(&self) -> Vec<Vec<String>> {
            self.plans
                .borrow()
                .iter()
                .map(|plan| plan.arguments.clone())
                .collect()
        }

        fn plans(&self) -> Vec<ProcessPlan> {
            self.plans.borrow().clone()
        }
    }

    impl HdcDispatch for Scripted {
        fn dispatch(&self, plan: &ProcessPlan) -> Result<Receipt, DispatchFailure> {
            self.plans.borrow_mut().push(plan.clone());
            let answer = self
                .answers
                .borrow_mut()
                .pop_front()
                .expect("no scripted answer remains");
            let receipt = |exit_status: i32, stdout: Vec<u8>, truncated: bool| Receipt {
                exit_status,
                stdout,
                stderr: Vec::new(),
                truncated,
                duration: Duration::ZERO,
            };
            match answer {
                Answer::Out(stdout) => Ok(receipt(0, stdout.into(), false)),
                Answer::Bytes(stdout) => Ok(receipt(0, stdout, false)),
                Answer::Exit(status) => Ok(receipt(status, Vec::new(), false)),
                Answer::Truncated(stdout) => Ok(receipt(0, stdout.into(), true)),
                Answer::Fail(failure) => Err(failure),
            }
        }
    }

    /// Swift's `FixedArkForgeLoaderObserver`, plus the request ids it was
    /// asked with.
    struct FixedLoader {
        identity: &'static str,
        topology: &'static str,
        requests: RefCell<Vec<(Option<String>, String)>>,
    }

    impl FixedLoader {
        fn new(identity: &'static str, topology: &'static str) -> Self {
            Self {
                identity,
                topology,
                requests: RefCell::new(Vec::new()),
            }
        }
    }

    impl LoaderObserver for FixedLoader {
        fn observe_loader(
            &self,
            stable_identity_sha256: &str,
            expected_usb_topology: Option<&str>,
            request_id: &str,
        ) -> Result<LoaderIdentity, String> {
            self.requests.borrow_mut().push((
                expected_usb_topology.map(str::to_owned),
                request_id.to_owned(),
            ));
            if stable_identity_sha256 != self.identity
                || !expected_usb_topology.is_none_or(|topology| topology == self.topology)
            {
                return Err("IOKit Loader identity does not match the bound target".into());
            }
            Ok(LoaderIdentity {
                serial_digest_sha256: self.identity.to_owned(),
                topology: self.topology.to_owned(),
            })
        }
    }

    /// Swift's `RefusingArkForgeLoaderObserver`.
    struct RefusingLoader(&'static str);

    impl LoaderObserver for RefusingLoader {
        fn observe_loader(
            &self,
            _: &str,
            _: Option<&str>,
            _: &str,
        ) -> Result<LoaderIdentity, String> {
            Err(self.0.to_owned())
        }
    }

    /// Swift's `NormalOnlyUSBProbe`: one HDC-normal device whose identity is
    /// the digest of a connect key's exact bytes.
    struct NormalOnlyUsb {
        identity: String,
        topology: &'static str,
    }

    impl NormalOnlyUsb {
        fn new(connect_key: &str, topology: &'static str) -> Self {
            Self {
                identity: sha256_hex(connect_key.as_bytes()),
                topology,
            }
        }
    }

    impl UsbProbe for NormalOnlyUsb {
        fn single_hdc_normal(
            &self,
            stable_identity_sha256: &str,
        ) -> Result<LoaderIdentity, String> {
            if stable_identity_sha256 != self.identity {
                return Err("identity mismatch".into());
            }
            Ok(LoaderIdentity {
                serial_digest_sha256: self.identity.clone(),
                topology: self.topology.to_owned(),
            })
        }
    }

    fn observe(
        hdc: &Scripted,
        loader: &dyn LoaderObserver,
        usb: Option<&dyn UsbProbe>,
    ) -> Result<LiveModeObservation, LiveModeFailure> {
        LiveModeProbe::new(hdc, loader, usb).observe(CONNECT_KEY, STABLE_IDENTITY)
    }

    fn detail(result: Result<LiveModeObservation, LiveModeFailure>) -> String {
        match result {
            Err(LiveModeFailure::NotObservable(detail)) => detail,
            Ok(observation) => panic!("observed {observation:?}"),
        }
    }

    #[test]
    fn connected_over_hdc_names_the_mode_the_build_and_the_current_port() {
        let hdc = Scripted::new(vec![Answer::Out(CONNECTED_ROW), Answer::Out(BUILD_ROW)]);
        let usb = NormalOnlyUsb::new(CONNECT_KEY, "44");
        let observation =
            observe(&hdc, &RefusingLoader("fixture is HDC-normal"), Some(&usb)).unwrap();
        assert_eq!(
            observation,
            LiveModeObservation {
                device_mode: DeviceMode::Hdc,
                build_fingerprint: Some(BUILD.to_owned()),
                usb_topology: Some("44".to_owned()),
            }
        );
        assert_eq!(
            hdc.arguments(),
            [
                vec!["list", "targets", "-v"],
                vec![
                    "-t",
                    "device-1",
                    "shell",
                    "param",
                    "get",
                    "const.ohos.fullname"
                ],
            ]
        );
        for plan in hdc.plans() {
            assert_eq!(plan.timeout, Duration::from_secs(15));
            assert_eq!(plan.capture_bytes, 64 * 1024);
        }
        assert_eq!(observation.device_mode.as_str(), "hdc");
    }

    #[test]
    fn without_a_usb_probe_the_hdc_observation_carries_no_port() {
        let hdc = Scripted::new(vec![Answer::Out(CONNECTED_ROW), Answer::Out(BUILD_ROW)]);
        let observation = observe(&hdc, &RefusingLoader("fixture is HDC-normal"), None).unwrap();
        assert_eq!(observation.device_mode, DeviceMode::Hdc);
        assert_eq!(observation.build_fingerprint.as_deref(), Some(BUILD));
        assert_eq!(observation.usb_topology, None);
    }

    #[test]
    fn a_failed_build_readback_is_a_known_mode_with_an_unknown_build() {
        let oversized = format!("const.ohos.fullname = {}\n", "x".repeat(401));
        let oversized: &'static str = Box::leak(oversized.into_boxed_str());
        let unreadable: Vec<Answer> = vec![
            Answer::Exit(1),
            Answer::Bytes(vec![0xff, 0xfe]),
            Answer::Out("const.ohos.fullname =   \n"),
            Answer::Out(oversized),
            Answer::Fail(DispatchFailure::Unobservable("process timed out".into())),
        ];
        for answer in unreadable {
            let hdc = Scripted::new(vec![Answer::Out(CONNECTED_ROW), answer]);
            let observation =
                observe(&hdc, &RefusingLoader("fixture is HDC-normal"), None).unwrap();
            assert_eq!(observation.device_mode, DeviceMode::Hdc);
            assert_eq!(observation.build_fingerprint, None);
            assert_eq!(hdc.arguments().len(), 2);
        }
        let exactly_400 = format!("const.ohos.fullname = {}\n", "y".repeat(400));
        let hdc = Scripted::new(vec![
            Answer::Out(CONNECTED_ROW),
            Answer::Out(Box::leak(exactly_400.into_boxed_str())),
        ]);
        let observation = observe(&hdc, &RefusingLoader("fixture is HDC-normal"), None).unwrap();
        assert_eq!(observation.build_fingerprint, Some("y".repeat(400)));
    }

    #[test]
    fn a_mismatched_hdc_identity_lends_no_port_to_the_target() {
        let hdc = Scripted::new(vec![Answer::Out(CONNECTED_ROW), Answer::Out(BUILD_ROW)]);
        let usb = NormalOnlyUsb::new("another-device", "44");
        let observation =
            observe(&hdc, &RefusingLoader("fixture is HDC-normal"), Some(&usb)).unwrap();
        assert_eq!(observation.device_mode, DeviceMode::Hdc);
        assert_eq!(observation.usb_topology, None);
        assert_eq!(observation.build_fingerprint.as_deref(), Some(BUILD));
    }

    #[test]
    fn not_on_hdc_the_loader_observer_names_loader_for_the_bound_identity() {
        let hdc = Scripted::new(vec![Answer::Out("[Empty]\n")]);
        let loader = FixedLoader::new(STABLE_IDENTITY, "42");
        let observation = observe(&hdc, &loader, None).unwrap();
        assert_eq!(
            observation,
            LiveModeObservation {
                device_mode: DeviceMode::Loader,
                build_fingerprint: None,
                usb_topology: Some("42".to_owned()),
            }
        );
        assert_eq!(hdc.arguments(), [vec!["list", "targets", "-v"]]);
        let requests = loader.requests.borrow();
        assert_eq!(requests.len(), 1);
        let (expected_topology, request_id) = &requests[0];
        assert_eq!(expected_topology, &None);
        let uuid = request_id
            .strip_prefix("live-mode-")
            .expect("live-mode request id");
        assert_eq!(uuid.len(), 36);
        assert!(uuid.bytes().enumerate().all(|(index, byte)| {
            if [8, 13, 18, 23].contains(&index) {
                byte == b'-'
            } else {
                byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte)
            }
        }));
        assert_eq!(&uuid[14..15], "4");
        assert_eq!(observation.device_mode.to_string(), "loader");
    }

    #[test]
    fn a_loader_that_is_not_the_bound_target_is_not_observable() {
        let hdc = Scripted::new(vec![Answer::Out("[Empty]\n")]);
        let loader = FixedLoader::new(
            "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            "42",
        );
        assert_eq!(
            detail(observe(&hdc, &loader, None)),
            "ArkForge dual-source Loader observation failed: IOKit Loader identity does not \
             match the bound target"
        );
        assert_eq!(hdc.arguments(), [vec!["list", "targets", "-v"]]);

        // An ambiguous Loader set, and nothing on either surface: the observer's
        // reason is quoted, the list is read once and the build never.
        for reason in ["arkforged observed an ambiguous Loader set", "no Loader"] {
            let hdc = Scripted::new(vec![Answer::Out("[Empty]\n"), Answer::Exit(1)]);
            assert_eq!(
                detail(observe(&hdc, &RefusingLoader(reason), None)),
                format!("ArkForge dual-source Loader observation failed: {reason}")
            );
            assert_eq!(hdc.arguments().len(), 1);
        }
    }

    #[test]
    fn only_exactly_one_connected_row_with_the_key_is_on_hdc() {
        // Two rows with the key, an Offline row, and another device's row are
        // all "not on HDC": the RockUSB arm decides, here refusing.
        let lists = [
            "device-1\t\tUSB\tConnected\tlocalhost\ndevice-1\t\tUSB\tConnected\tlocalhost\n",
            "device-1\t\tUSB\tOffline\tlocalhost\n",
            "device-2\t\tUSB\tConnected\tlocalhost\n",
            "",
        ];
        for list in lists {
            let hdc = Scripted::new(vec![Answer::Out(list)]);
            assert_eq!(
                detail(observe(&hdc, &RefusingLoader("no Loader"), None)),
                "ArkForge dual-source Loader observation failed: no Loader",
                "{list:?}"
            );
            assert_eq!(hdc.arguments().len(), 1);
        }
    }

    #[test]
    fn a_target_list_the_parser_cannot_read_is_never_absence() {
        let refusing = RefusingLoader("not reached");
        let cases: Vec<(Answer, &str)> = vec![
            (
                Answer::Out("device-1\tUSB\tConnected\n"),
                "HDC target list is malformed: target line is not the registered 5-column family",
            ),
            (
                Answer::Truncated(CONNECTED_ROW),
                "HDC target list exceeded its byte budget",
            ),
            (
                Answer::Bytes(vec![0xff, b'\n']),
                "HDC target list is not UTF-8",
            ),
            (Answer::Exit(2), "read-only probe command exited 2"),
            (
                Answer::Fail(DispatchFailure::Refused("dispatch refused: budget".into())),
                "read-only probe command did not complete: dispatch refused: budget",
            ),
            (
                Answer::Fail(DispatchFailure::Unobservable(
                    "process timed out before completion".into(),
                )),
                "read-only probe command did not complete: process timed out before completion",
            ),
        ];
        for (answer, expected) in cases {
            let hdc = Scripted::new(vec![answer]);
            assert_eq!(detail(observe(&hdc, &refusing, None)), expected);
            assert_eq!(hdc.arguments().len(), 1);
        }
    }

    #[test]
    fn the_failure_reads_as_swift_s() {
        assert_eq!(
            LiveModeFailure::NotObservable("no Loader".into()).to_string(),
            "the bound Rockchip target is not observable: no Loader"
        );
        assert_eq!(
            LiveModeFailure::unavailable_tool("hdc", &"no hdc registered"),
            LiveModeFailure::NotObservable(
                "hdc executable is unavailable to the facts probe: no hdc registered".into()
            )
        );
    }

    #[test]
    fn the_hdc_identity_is_the_digest_of_the_exact_connect_key() {
        // Swift `SHA256Hex.string(of: Data(connectKey.utf8))`: no lowercasing,
        // unlike the adoption identity `stable_identity_sha256`.
        let hdc = Scripted::new(vec![
            Answer::Out("Device-1\t\tUSB\tConnected\tlocalhost\n"),
            Answer::Out(BUILD_ROW),
        ]);
        let exact = NormalOnlyUsb::new("Device-1", "7");
        let observation = LiveModeProbe::new(&hdc, &RefusingLoader("hdc"), Some(&exact))
            .observe("Device-1", STABLE_IDENTITY)
            .unwrap();
        assert_eq!(observation.usb_topology.as_deref(), Some("7"));
        assert_ne!(
            sha256_hex(b"Device-1"),
            crate::stable_identity_sha256("Device-1")
        );
        assert_eq!(
            sha256_hex(b"device-1"),
            crate::stable_identity_sha256("Device-1")
        );
    }
}
