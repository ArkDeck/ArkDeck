//! The Rockchip live-mode probe over the shared fake HDC driver (TASK-XPA-016,
//! M4): the two read-only commands Swift's `FoundationRockchipLiveModeProbe`
//! runs, dispatched as real subprocesses through `ProcessDispatch`, answered
//! by the fake exactly as the Swift oracle recorded it, and the argv it was
//! given asserted from its log (T1). No HDC is launched and no device is
//! contacted; the Loader and USB observations are fixed doubles of the two
//! ports the ArkForge lane serves.
#![cfg(target_os = "macos")]

use arkdeck_platform::VerifiedTool;
use arkdeck_provider_hdc::{
    DeviceMode, LiveModeFailure, LiveModeObservation, LiveModeProbe, LoaderIdentity,
    LoaderObserver, ProcessDispatch, UsbProbe,
};
use sha2::{Digest, Sha256};
use std::fs::{self, File, OpenOptions};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

/// `HDCOracleFake`'s fixed root and lock, which the fake's driver names.
const ROOT: &str = "/private/tmp/arkdeck-hdc-oracle";
const LOCK: &str = "/private/tmp/arkdeck-hdc-oracle.lock";
/// The observe fixture's one device.
const CONNECT_KEY: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const STABLE_IDENTITY: &str = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";

fn observe_fixture() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/fixtures/observe-device")
}

/// The shared fake at its fixed root, in the named answer mode, under the
/// fake's lock for the life of the value.
struct SharedFake {
    _lock: File,
    root: PathBuf,
    dispatch: ProcessDispatch,
}

impl SharedFake {
    fn new(mode: Option<&str>) -> Self {
        let lock = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .open(LOCK)
            .unwrap();
        lock.lock().unwrap();
        let fixture = observe_fixture();
        let root = PathBuf::from(ROOT);
        let _ = fs::remove_dir_all(&root);
        fs::create_dir(&root).unwrap();
        fs::set_permissions(&root, fs::Permissions::from_mode(0o700)).unwrap();
        fs::copy(fixture.join("hdc"), root.join("hdc")).unwrap();
        fs::set_permissions(root.join("hdc"), fs::Permissions::from_mode(0o700)).unwrap();
        fs::copy(fixture.join("hdc-answers.sh"), root.join("hdc-answers.sh")).unwrap();
        File::create(root.join("hdc-invocations.log")).unwrap();
        if let Some(mode) = mode {
            fs::write(root.join("hdc-mode"), format!("{mode}\n")).unwrap();
        }
        let digest = format!("{:x}", Sha256::digest(fs::read(root.join("hdc")).unwrap()));
        let dispatch =
            ProcessDispatch::new(VerifiedTool::open(root.join("hdc"), &digest).unwrap(), None);
        Self {
            _lock: lock,
            root,
            dispatch,
        }
    }

    fn invocations(&self) -> Vec<u8> {
        fs::read(self.root.join("hdc-invocations.log")).unwrap()
    }
}

impl Drop for SharedFake {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

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
    let fake = SharedFake::new(None);
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
    let fake = SharedFake::new(Some("otherDevice"));
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
    let fake = SharedFake::new(Some("normal"));
    // The driver answers `-v` and `checkserver`; nothing else is registered
    // for this argv, so the fake exits 23 as `ArkDeckFakeHDCFixture` does.
    fs::write(
        fake.root.join("hdc-answers.sh"),
        "printf 'unregistered fixture output\\n' >&2\nexit 23\n",
    )
    .unwrap();
    let refused = LiveModeProbe::new(&fake.dispatch, &RefusingLoader("not reached"), None)
        .observe(CONNECT_KEY, STABLE_IDENTITY)
        .unwrap_err();
    assert_eq!(
        refused,
        LiveModeFailure::NotObservable("read-only probe command exited 23".into())
    );
    assert_eq!(fake.invocations(), LIST_LINE);
}
