//! The Rockchip post-flash HDC observation over the shared fake HDC driver
//! (TASK-XPA-016, M4): the waits and the one build/model read, dispatched as
//! real subprocesses through `ProcessDispatch` with the argv asserted from the
//! driver's log (T1). No HDC is launched and no device is contacted; the USB
//! identities are doubles of the port the ArkForge lane serves.
#![cfg(target_os = "macos")]

mod common;

use arkdeck_provider_hdc::{
    HdcIdentity, LoaderIdentity, POST_FLASH_BUILD_PROPERTIES_COMMAND, ReconnectExpectation,
    RockchipHdcFailure, RockchipHdcObserver, SystemClock, UsbProbe, WaitBudget,
};
use common::{CONNECT_KEY, SharedFake};
use sha2::{Digest, Sha256};
use std::time::{Duration, Instant};

/// The answers this test needs, by mode: `normal` lists the fixture's device,
/// `absent` prints the `[Empty]` sentinel, `malformedFirst` answers the first
/// read with a line outside the registered family and the rest with the
/// registered row. The post-flash command is answered for the fixture's key
/// by its exact single token; everything else is unregistered (exit 23), as
/// the Swift fixture does.
const ANSWERS: &str = r#"key=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
case "$*" in
"list targets -v")
  calls=$(( $(wc -l < "$root/hdc-invocations.log") ))
  case "$mode" in
  absent) printf '[Empty]\n' ;;
  malformedFirst)
    if [ "$calls" -le 1 ]; then printf '%s\tUSB\tConnected\n' "$key"
    else printf '%s\t\tUSB\tConnected\tlocalhost\n' "$key"; fi ;;
  *) printf '%s\t\tUSB\tConnected\tlocalhost\n' "$key" ;;
  esac ;;
"-t $key shell param get const.ohos.fullname; param get const.product.model")
  printf 'const.ohos.fullname = OpenHarmony-4.1-release\nconst.product.model = ohos\n' ;;
*)
  printf 'unregistered fixture output\n' >&2
  exit 23 ;;
esac
"#;

const LIST_LINE: &[u8] = b"list\x1ftargets\x1f-v\x1f\n";

fn sha256_hex(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}

fn properties_line(connect_key: &str) -> Vec<u8> {
    format!("-t\u{1f}{connect_key}\u{1f}shell\u{1f}{POST_FLASH_BUILD_PROPERTIES_COMMAND}\u{1f}\n")
        .into_bytes()
}

/// A wait that reads quickly and gives up soon: the deadlines are the
/// executor's business, the reads are what is exercised here.
fn budget(deadline: Duration) -> WaitBudget {
    WaitBudget {
        deadline,
        command_timeout: Duration::from_secs(15),
        poll: Duration::from_millis(100),
    }
}

/// One HDC-normal device at the recorded topology `42`, under the given
/// connect key — the flash rotated the serial, the port still holds it.
struct AtTopology(&'static str);

impl AtTopology {
    fn identity(&self) -> HdcIdentity {
        HdcIdentity {
            connect_key: self.0.to_owned(),
            serial_digest_sha256: sha256_hex(self.0.as_bytes()),
            topology: "42".to_owned(),
        }
    }
}

impl UsbProbe for AtTopology {
    fn single_hdc_normal(&self, _: &str) -> Result<LoaderIdentity, String> {
        Err("DAYU200 target unavailable".into())
    }

    fn single_hdc_normal_at(&self, usb_topology: &str) -> Result<HdcIdentity, String> {
        if usb_topology != "42" {
            return Err("DAYU200 target unavailable".into());
        }
        Ok(self.identity())
    }
}

fn expectation() -> ReconnectExpectation {
    ReconnectExpectation {
        previous_connect_key: "previous-serial".to_owned(),
        previous_identity_sha256: sha256_hex(b"previous-serial"),
        usb_topology: "42".to_owned(),
    }
}

/// After a serial rotation the bound reconnect proves the device at its
/// recorded topology, and the build is read once on the new key: two
/// subprocesses, in Swift's order, the command's single token intact.
#[test]
fn the_bound_reconnect_after_a_serial_rotation_reads_the_build_once() {
    let fake = SharedFake::with_answers(ANSWERS, None);
    let port = AtTopology(CONNECT_KEY);
    let observer = RockchipHdcObserver::new(&fake.dispatch, &port, &SystemClock);
    let (identity, receipts) = observer
        .wait_for_bound_hdc(&expectation(), &budget(Duration::from_secs(10)))
        .unwrap();
    assert_eq!(identity, port.identity());
    assert_eq!(receipts.len(), 1);
    assert_eq!(fake.invocations(), LIST_LINE);

    fake.clear_invocations();
    let verified = observer
        .verify_bound_build(
            &expectation(),
            Some(&identity),
            "ohos",
            "OpenHarmony-4.1-release",
            &budget(Duration::from_secs(10)),
        )
        .unwrap();
    assert_eq!(verified.identity, identity);
    assert_eq!(verified.readback.build_version, "OpenHarmony-4.1-release");
    assert_eq!(verified.readback.product_model, "ohos");
    // The cached route revalidated, so no second target list was read.
    assert_eq!(verified.receipts.len(), 1);
    assert_eq!(fake.invocations(), properties_line(CONNECT_KEY));

    fake.clear_invocations();
    let refused = observer
        .verify_bound_build(
            &expectation(),
            None,
            "ohos",
            "OpenHarmony-7.0.0.37",
            &budget(Duration::from_secs(10)),
        )
        .unwrap_err();
    assert_eq!(
        refused,
        RockchipHdcFailure::Failed(
            "post-flash build readback does not match the published profile".into()
        )
    );
    assert_eq!(
        fake.invocations(),
        [LIST_LINE, properties_line(CONNECT_KEY).as_slice()].concat()
    );
}

/// One malformed read is a moment in time: the reconnect wait re-polls it and
/// returns on the registered row that follows.
#[test]
fn a_transient_malformed_list_is_re_polled() {
    let fake = SharedFake::with_answers(ANSWERS, Some("malformedFirst"));
    let port = AtTopology(CONNECT_KEY);
    let observer = RockchipHdcObserver::new(&fake.dispatch, &port, &SystemClock);
    let receipts = observer
        .wait_for_hdc(CONNECT_KEY, true, &budget(Duration::from_secs(10)))
        .unwrap();
    assert_eq!(receipts.len(), 2);
    assert_eq!(fake.invocations(), [LIST_LINE, LIST_LINE].concat());
}

/// A disconnect is proved by the `[Empty]` sentinel; a device that stays
/// listed is not disconnected when the deadline passes.
#[test]
fn the_disconnect_wait_needs_the_empty_sentinel() {
    let fake = SharedFake::with_answers(ANSWERS, Some("absent"));
    let port = AtTopology(CONNECT_KEY);
    let observer = RockchipHdcObserver::new(&fake.dispatch, &port, &SystemClock);
    let receipts = observer
        .wait_for_hdc(CONNECT_KEY, false, &budget(Duration::from_secs(10)))
        .unwrap();
    assert_eq!(receipts.len(), 1);
    assert_eq!(fake.invocations(), LIST_LINE);

    fake.set_mode("normal");
    fake.clear_invocations();
    let started = Instant::now();
    let refused = observer
        .wait_for_hdc(CONNECT_KEY, false, &budget(Duration::from_millis(600)))
        .unwrap_err();
    assert_eq!(
        refused,
        RockchipHdcFailure::Failed(
            "descriptor-bound HDC target did not disconnect before the deadline".into()
        )
    );
    assert!(started.elapsed() >= Duration::from_millis(600));
    let reads = fake
        .invocations()
        .split(|byte| *byte == b'\n')
        .filter(|line| !line.is_empty())
        .count();
    assert!(reads >= 2, "{reads} reads");
}

/// A read the fake does not register (exit 23 with stderr) is a read without
/// a clean receipt — named by its reasons, never by its output — not a
/// verdict about the device.
#[test]
fn an_unregistered_read_fails_with_its_reasons() {
    let fake = SharedFake::with_answers(ANSWERS, None);
    let port = AtTopology("other-key");
    let observer = RockchipHdcObserver::new(&fake.dispatch, &port, &SystemClock);
    let cached = port.identity();
    let refused = observer
        .verify_bound_build(
            &expectation(),
            Some(&cached),
            "ohos",
            "OpenHarmony-4.1-release",
            &budget(Duration::from_secs(10)),
        )
        .unwrap_err();
    assert_eq!(
        refused,
        RockchipHdcFailure::Failed(
            "typed command lacked a clean, complete semantic receipt (exitStatus=23, \
             stderrByteCount=28, stdoutCapturedBytes=0); last output: "
                .into()
        )
    );
    // The cached route revalidated at its port, so the only read was the
    // property command for the cached key.
    assert_eq!(fake.invocations(), properties_line("other-key"));
}
