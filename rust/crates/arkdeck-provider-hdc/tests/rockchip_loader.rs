//! The Rockchip Loader transition over the shared fake HDC driver
//! (TASK-XPA-016, M4): the one mutating HDC command of the flash flow,
//! dispatched as a real subprocess through `ProcessDispatch`, its argv
//! asserted from the driver's log (T1) and its stderr carried into the
//! evidence clause. No HDC is launched and no device is contacted; the USB and
//! ArkForge observations are doubles of the ports the ArkForge lane serves.
#![cfg(target_os = "macos")]

mod common;

use arkdeck_provider_hdc::{
    FlashRuntimeDiagnostic, HdcIdentity, LoaderIdentity, LoaderObserver, LoaderTransitionFailure,
    ReadbackBudget, RockchipLoaderTransition, SystemClock, Transition, TransitionRequest, UsbProbe,
};
use common::{CONNECT_KEY, SharedFake};
use sha2::{Digest, Sha256};
use std::cell::Cell;
use std::time::Duration;

/// `reboot loader` for the fixture's key: clean in `normal` mode, the
/// board's real refusal in `refuse` mode; everything else unregistered.
const ANSWERS: &str = r#"key=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
case "$*" in
"-t $key shell reboot loader")
  case "$mode" in
  refuse) printf '[Fail]Not match target and connect key\nretry later\n' >&2; exit 1 ;;
  *) exit 0 ;;
  esac ;;
*)
  printf 'unregistered fixture output\n' >&2
  exit 23 ;;
esac
"#;

const REBOOT_LINE: &[u8] =
    b"-t\x1faaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\x1fshell\x1freboot\x1floader\x1f\n";
const STABLE: &str = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";

fn sha256_hex(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}

/// A board that reaches Loader after the command: not in Loader for the
/// first `refusals` lookups, then the exact bound Loader at `42`; on HDC-normal
/// at `42` before that when `normal` is set.
struct Board {
    refusals: Cell<usize>,
    normal: bool,
}

impl UsbProbe for Board {
    fn single_loader(&self, _: &str) -> Result<LoaderIdentity, String> {
        let left = self.refusals.get();
        if left > 0 {
            self.refusals.set(left - 1);
            return Err("DAYU200 target unavailable".into());
        }
        Ok(LoaderIdentity {
            serial_digest_sha256: STABLE.to_owned(),
            topology: "42".to_owned(),
        })
    }

    fn single_hdc_normal(&self, stable_identity_sha256: &str) -> Result<LoaderIdentity, String> {
        if !self.normal || stable_identity_sha256 != sha256_hex(CONNECT_KEY.as_bytes()) {
            return Err("DAYU200 target unavailable".into());
        }
        Ok(LoaderIdentity {
            serial_digest_sha256: stable_identity_sha256.to_owned(),
            topology: "42".to_owned(),
        })
    }

    fn single_hdc_normal_at(&self, _: &str) -> Result<HdcIdentity, String> {
        Err("topology-bound HDC observation is unavailable".into())
    }
}

struct Confirming;

impl LoaderObserver for Confirming {
    fn observe_loader(&self, _: &str, _: Option<&str>, _: &str) -> Result<LoaderIdentity, String> {
        Err("the transition confirms, it does not observe".into())
    }

    fn confirm_loader(
        &self,
        identity: &LoaderIdentity,
        stable_identity_sha256: &str,
        expected_usb_topology: Option<&str>,
        request_id: &str,
    ) -> Result<LoaderIdentity, String> {
        assert_eq!(stable_identity_sha256, STABLE);
        assert_eq!(expected_usb_topology, Some("42"));
        assert!(request_id.ends_with("-post-transition"), "{request_id}");
        Ok(identity.clone())
    }
}

fn request() -> TransitionRequest<'static> {
    TransitionRequest {
        connect_key: CONNECT_KEY,
        stable_identity_sha256: STABLE,
        job_id: "job-1",
        step_id: "enter-loader-mode",
    }
}

fn budget(deadline: Duration) -> ReadbackBudget {
    ReadbackBudget {
        deadline,
        poll: Duration::from_millis(100),
    }
}

/// The command runs once with Swift's argv, returns cleanly, and the
/// transition is believed only when the exact bound Loader appears.
#[test]
fn a_clean_reboot_loader_is_proved_by_the_loader_readback() {
    let fake = SharedFake::with_answers(ANSWERS, None);
    let board = Board {
        refusals: Cell::new(2),
        normal: false,
    };
    let transition =
        RockchipLoaderTransition::new(&fake.dispatch, &board, &Confirming, &SystemClock)
            .enter_loader(&request(), &budget(Duration::from_secs(10)))
            .unwrap();
    assert_eq!(transition.transition, Transition::NormalToLoader);
    assert_eq!(transition.loader.topology, "42");
    assert_eq!(transition.receipts.len(), 1);
    assert_eq!(transition.receipts[0].exit_status, 0);
    assert!(transition.receipts[0].stderr.is_empty());
    assert_eq!(fake.invocations(), REBOOT_LINE);
    assert_eq!(transition.summary()["transition"], "normal-to-loader");
}

/// The board refuses the command on stderr and stays on HDC-normal: the
/// transition is confirmed not executed, and the refusal travels in the
/// evidence clause as one line.
#[test]
fn a_refused_reboot_loader_is_confirmed_not_executed_with_its_stderr() {
    let fake = SharedFake::with_answers(ANSWERS, Some("refuse"));
    let board = Board {
        refusals: Cell::new(usize::MAX),
        normal: true,
    };
    let failure = RockchipLoaderTransition::new(&fake.dispatch, &board, &Confirming, &SystemClock)
        .enter_loader(&request(), &budget(Duration::ZERO))
        .unwrap_err();
    assert_eq!(
        failure,
        LoaderTransitionFailure::ConfirmedNotExecuted {
            detail: "exact bound HDC-normal USB readback proves the Loader transition did not \
                     complete at topology 42 [hdcExitStatus=1 hdcStderr=\"[Fail]Not match \
                     target and connect key retry later\" hdcFailure=HDC reboot-loader \
                     returned no clean semantic receipt]"
                .to_owned(),
            diagnostic: FlashRuntimeDiagnostic::EnterLoaderHdcNoCleanReceipt,
        }
    );
    assert_eq!(fake.invocations(), REBOOT_LINE);
}
