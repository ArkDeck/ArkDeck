//! The Rockchip live-mode probe over the shared fake HDC driver (TASK-XPA-016,
//! M4): the two read-only commands Swift's `FoundationRockchipLiveModeProbe`
//! runs, dispatched as real subprocesses through `ProcessDispatch`, answered
//! by the fake exactly as the Swift oracle recorded it, and the argv it was
//! given asserted from its log (T1). No HDC is launched and no device is
//! contacted; the Loader and USB observations are fixed doubles of the two
//! ports the ArkForge lane serves.
#![cfg(target_os = "macos")]

mod common;

use arkdeck_provider_hdc::{
    DeviceMode, LiveModeFailure, LiveModeObservation, LiveModeProbe, LoaderIdentity,
    LoaderObserver, UsbProbe,
};
use common::{CONNECT_KEY, SharedFake};
use sha2::{Digest, Sha256};

const STABLE_IDENTITY: &str = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";

struct FixedLoader(&'static str);

impl LoaderObserver for FixedLoader {
    fn observe_loader(
        &self,
        stable_identity_sha256: &str,
        expected_usb_topology: Option<&str>,
        request_id: &str,
    ) -> Result<LoaderIdentity, String> {
        assert!(request_id.starts_with("live-mode-"), "{request_id}");
        if stable_identity_sha256 != STABLE_IDENTITY || expected_usb_topology.is_some() {
            return Err("IOKit Loader identity does not match the bound target".into());
        }
        Ok(LoaderIdentity {
            serial_digest_sha256: STABLE_IDENTITY.to_owned(),
            topology: self.0.to_owned(),
        })
    }
}

struct RefusingLoader(&'static str);

impl LoaderObserver for RefusingLoader {
    fn observe_loader(&self, _: &str, _: Option<&str>, _: &str) -> Result<LoaderIdentity, String> {
        Err(self.0.to_owned())
    }
}

/// One HDC-normal device: the fixture's connect key, at a fixed port.
struct NormalOnlyUsb(&'static str);

impl UsbProbe for NormalOnlyUsb {
    fn single_loader(&self, _: &str) -> Result<LoaderIdentity, String> {
        Err("fixture has no Loader".into())
    }

    fn single_hdc_normal(&self, stable_identity_sha256: &str) -> Result<LoaderIdentity, String> {
        let identity = format!("{:x}", Sha256::digest(CONNECT_KEY.as_bytes()));
        if stable_identity_sha256 != identity {
            return Err("identity mismatch".into());
        }
        Ok(LoaderIdentity {
            serial_digest_sha256: identity,
            topology: self.0.to_owned(),
        })
    }
}

const LIST_LINE: &[u8] = b"list\x1ftargets\x1f-v\x1f\n";
const BUILD_LINE: &[u8] =
    b"-t\x1faaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\x1fshell\x1fparam\x1fget\x1fconst.ohos.fullname\x1f\n";

/// The fixture's device on HDC: the mode from `list targets -v`, the build
/// from the allowlisted `param get`, the port from the exact HDC-normal
/// identity — two subprocesses, in Swift's order, with Swift's argv.
#[test]
fn the_shared_fake_in_hdc_normal_names_the_mode_the_build_and_the_port() {
    let fake = SharedFake::from_fixture(None);
    let usb = NormalOnlyUsb("44");
    let observation = LiveModeProbe::new(
        &fake.dispatch,
        &RefusingLoader("fixture is HDC-normal"),
        Some(&usb),
    )
    .observe(CONNECT_KEY, STABLE_IDENTITY)
    .unwrap();
    assert_eq!(
        observation,
        LiveModeObservation {
            device_mode: DeviceMode::Hdc,
            build_fingerprint: Some("OpenHarmony-4.1-release".to_owned()),
            usb_topology: Some("44".to_owned()),
        }
    );
    assert_eq!(fake.invocations(), [LIST_LINE, BUILD_LINE].concat());
}

/// The list names another device: HDC does not see this target, so the
/// Loader observer decides for the exact bound identity — and only the list
/// was read, never the build.
#[test]
fn the_shared_fake_listing_another_device_leaves_the_mode_to_the_loader_observer() {
    let fake = SharedFake::from_fixture(Some("otherDevice"));
    let observation = LiveModeProbe::new(&fake.dispatch, &FixedLoader("42"), None)
        .observe(CONNECT_KEY, STABLE_IDENTITY)
        .unwrap();
    assert_eq!(
        observation,
        LiveModeObservation {
            device_mode: DeviceMode::Loader,
            build_fingerprint: None,
            usb_topology: Some("42".to_owned()),
        }
    );
    assert_eq!(fake.invocations(), LIST_LINE);

    let refused = LiveModeProbe::new(&fake.dispatch, &RefusingLoader("no Loader"), None)
        .observe(CONNECT_KEY, STABLE_IDENTITY)
        .unwrap_err();
    assert_eq!(
        refused,
        LiveModeFailure::NotObservable(
            "ArkForge dual-source Loader observation failed: no Loader".into()
        )
    );
    assert_eq!(
        refused.to_string(),
        "the bound Rockchip target is not observable: ArkForge dual-source Loader observation \
         failed: no Loader"
    );
    assert_eq!(fake.invocations(), [LIST_LINE, LIST_LINE].concat());
}

/// A fake that answers the list with an unregistered exit: not absence, not
/// observable, and the Loader observer is never consulted.
#[test]
fn a_list_the_fake_refuses_is_not_observable() {
    // Nothing is registered for any argv, so the fake exits 23 as
    // `ArkDeckFakeHDCFixture` does.
    let fake = SharedFake::with_answers(
        "printf 'unregistered fixture output\\n' >&2\nexit 23\n",
        Some("normal"),
    );
    let refused = LiveModeProbe::new(&fake.dispatch, &RefusingLoader("not reached"), None)
        .observe(CONNECT_KEY, STABLE_IDENTITY)
        .unwrap_err();
    assert_eq!(
        refused,
        LiveModeFailure::NotObservable("read-only probe command exited 23".into())
    );
    assert_eq!(fake.invocations(), LIST_LINE);
}
