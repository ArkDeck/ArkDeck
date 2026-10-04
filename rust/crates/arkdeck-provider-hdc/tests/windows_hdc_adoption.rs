//! The Windows consumers of the registered HDC tuple (CHG-2026-074
//! TASK-XPA-005, adopting CHG-2026-078): the `device candidates` read, the
//! `observe.device` confirmation and the `target adopt` bootstrap read a
//! registered Windows tuple's output by the Windows registry's grammars,
//! replayed here from the redacted capture of 2026-10-04
//! (`rust/tests/fixtures/hdc-windows/c2/`). An in-process dispatch stands in
//! for the registered executable: a fake can never have its hash, so the
//! dispatch names the tuple it is pinned to, as `ProcessDispatch` does for
//! the real one. The macOS grammars are unchanged, and a dispatch pinned to
//! no Windows tuple is read by them, as before.
use std::fs;
use std::path::{Path, PathBuf};
#[cfg(windows)]
use std::time::Duration;

#[cfg(windows)]
use arkdeck_provider_hdc::{
    Action, DispatchFailure, Expected, HdcDispatch, Outcome, ProcessPlan, Receipt, WindowsHdcTuple,
    list_candidates, observe_device_identity, observe_tool_version, windows_tuple,
};
use arkdeck_provider_hdc::{
    DeviceCandidate, ParseError, parse_host_client_version, parse_windows_target_list,
};

#[cfg(windows)]
const C2_SHA256: &str = "c79518498aaf4e719733961216444e70c3eb53c8ba7006b933e6d7f2e1c6101e";
const KEY: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

fn fixture(path: &str) -> Vec<u8> {
    let root: PathBuf =
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/fixtures/hdc-windows/c2");
    fs::read(root.join(path)).unwrap()
}

const VERSION: &str = "no-board/version.stdout.bin";
const UART_ONLY: &str = "no-board/list-targets-empty.stdout.bin";
const CONNECTED: &str = "board-connected/list-targets-board-connected.stdout.bin";
const REMOVED: &str = "board-removed/list-targets-board-removed.stdout.bin";

/// An HDC replaying the c2 capture: `-v` and `list targets -v` answer with
/// the redacted bytes, pinned (or not) to the registered tuple.
#[cfg(windows)]
struct Replay {
    tuple: Option<&'static WindowsHdcTuple>,
    list: &'static str,
}

#[cfg(windows)]
impl HdcDispatch for Replay {
    fn dispatch(&self, plan: &ProcessPlan) -> Result<Receipt, DispatchFailure> {
        let stdout = match plan.arguments.join(" ").as_str() {
            "-v" => fixture(VERSION),
            "list targets -v" => fixture(self.list),
            other => panic!("the replay has no {other}"),
        };
        Ok(Receipt {
            exit_status: 0,
            stdout,
            stderr: Vec::new(),
            truncated: false,
            duration: Duration::from_millis(5),
        })
    }

    fn registered_windows_tuple(&self) -> Option<&'static WindowsHdcTuple> {
        self.tuple
    }
}

#[cfg(windows)]
fn c2(list: &'static str) -> Replay {
    Replay {
        tuple: Some(windows_tuple(C2_SHA256).unwrap()),
        list,
    }
}

fn candidate(state: &str) -> DeviceCandidate {
    DeviceCandidate {
        connect_key: KEY.into(),
        transport: "usb".into(),
        state: state.into(),
    }
}

#[test]
fn the_windows_candidate_list_reads_the_registered_rows_only() {
    assert_eq!(
        parse_windows_target_list(&fixture(CONNECTED), false),
        Ok(vec![candidate("Connected")])
    );
    assert_eq!(
        parse_windows_target_list(&fixture(REMOVED), false),
        Ok(vec![candidate("Offline")])
    );
    assert_eq!(
        parse_windows_target_list(&fixture(UART_ONLY), false),
        Ok(vec![])
    );
    assert_eq!(
        parse_windows_target_list(&fixture(CONNECTED), true),
        Err(ParseError::Truncated)
    );
    assert_eq!(
        parse_windows_target_list(b"", false),
        Err(ParseError::Empty)
    );
    for refused in [
        b"[Empty]\r\n".as_slice(),
        b"aaaa\t\tUSB\tConnected\tlocalhost\n",
        b"aaaa\t\tUSB\tUnauthorized\tlocalhost\thdc\r\n",
        b"aaaa\t\tUSB\tConnected\tlocalhost\tflashd\r\n",
        b"COM1\t\tUART\tConnected\tunknown...\thdc\r\n",
        b"aaaa\t\tTCP\tConnected\tlocalhost\thdc\r\n",
    ] {
        assert!(
            matches!(
                parse_windows_target_list(refused, false),
                Err(ParseError::Malformed(_))
            ),
            "{:?}",
            String::from_utf8_lossy(refused)
        );
    }
}

#[test]
fn only_a_windows_host_reads_the_registered_version_bytes() {
    let version = fixture(VERSION);
    if cfg!(windows) {
        assert_eq!(
            parse_host_client_version(&version, false).unwrap(),
            "3.2.0g"
        );
    } else {
        assert!(parse_host_client_version(&version, false).is_err());
    }
    // Candidate 1's bytes are no registered version on any host, and the
    // macOS family is read as before.
    assert!(parse_host_client_version(b"Ver: 3.2.0b\r\n", false).is_err());
    assert!(parse_host_client_version(&version, true).is_err());
    assert_eq!(
        parse_host_client_version(b"Ver: 3.2.0f\n", false).unwrap(),
        "3.2.0f"
    );
}

#[cfg(windows)]
#[test]
fn a_registered_windows_tuple_is_observed_and_confirmed_by_its_own_family() {
    // `device candidates`: the board, and no UART row.
    assert_eq!(
        list_candidates(&c2(CONNECTED)).unwrap(),
        vec![candidate("Connected")]
    );
    assert_eq!(list_candidates(&c2(UART_ONLY)).unwrap(), vec![]);
    assert_eq!(
        list_candidates(&c2(REMOVED)).unwrap(),
        vec![candidate("Offline")]
    );

    // `target adopt`'s bootstrap: the tool's version, then the exact row.
    assert_eq!(observe_tool_version(&c2(CONNECTED)).unwrap(), "3.2.0g");
    let readback = observe_device_identity(&c2(CONNECTED), KEY, Expected::default()).unwrap();
    assert_eq!(readback.get("serial").map(String::as_str), Some(KEY));
    // A removed board, or no board, is not confirmed.
    assert!(observe_device_identity(&c2(REMOVED), KEY, Expected::default()).is_err());
    assert!(observe_device_identity(&c2(UART_ONLY), KEY, Expected::default()).is_err());

    // `observe.device`'s confirmation step, with the version its tool step
    // observed.
    let receipt = c2(CONNECTED)
        .dispatch(&Action::ObserveDevice.lower("observe", Some(KEY)).unwrap())
        .unwrap();
    let expected = Expected {
        connect_key: Some(KEY),
        identity_sha256: None,
        tool_version: Some("3.2.0g"),
    };
    assert!(matches!(
        Action::ObserveDevice.verify(&receipt, expected),
        Outcome::Verified(_)
    ));
}

#[cfg(windows)]
#[test]
fn a_dispatch_pinned_to_no_windows_tuple_is_read_by_the_macos_grammar() {
    // The same Windows bytes, from an executable that is no registered
    // Windows tuple: the macOS grammar refuses the six-column rows, so
    // nothing is listed or confirmed.
    let unpinned = Replay {
        tuple: None,
        list: CONNECTED,
    };
    assert!(list_candidates(&unpinned).is_err());
    assert!(observe_device_identity(&unpinned, KEY, Expected::default()).is_err());
    // And a macOS version names no Windows family for the confirmation.
    let receipt = unpinned
        .dispatch(&Action::ObserveDevice.lower("observe", Some(KEY)).unwrap())
        .unwrap();
    let expected = Expected {
        connect_key: Some(KEY),
        identity_sha256: None,
        tool_version: Some("3.2.0f"),
    };
    assert!(!matches!(
        Action::ObserveDevice.verify(&receipt, expected),
        Outcome::Verified(_)
    ));
}

/// `probeHDCServer` on a registered Windows tuple is the commandless server
/// observation (CHG-2026-078 `serverIdentityGeneration`), never
/// `checkserver`: the step verifies the tuple's version as the client's and
/// the server's once the registered executable's own server is observed,
/// and is unknown otherwise. An unpinned dispatch keeps Swift's
/// `checkserver`, and a dispatch with no observation of its own refuses it.
#[cfg(windows)]
#[test]
fn the_server_probe_of_a_registered_tuple_is_the_commandless_observation() {
    use arkdeck_provider_hdc::ServerObservation;
    let tuple = windows_tuple(C2_SHA256).unwrap();
    assert!(Action::ObserveServer.observes_server_commandlessly(&c2(CONNECTED)));
    let unpinned = Replay {
        tuple: None,
        list: CONNECTED,
    };
    assert!(!Action::ObserveServer.observes_server_commandlessly(&unpinned));
    assert!(!Action::ObserveDevice.observes_server_commandlessly(&c2(CONNECTED)));
    assert_eq!(
        Action::ObserveServer
            .lower("probe", None)
            .unwrap()
            .arguments,
        ["checkserver"],
        "the process lowering itself is Swift's"
    );
    assert_eq!(
        Action::verify_server_observation(tuple, &ServerObservation::Observed),
        Outcome::Verified(
            [
                ("clientVersion".to_owned(), "3.2.0g".to_owned()),
                ("serverVersion".to_owned(), "3.2.0g".to_owned()),
            ]
            .into()
        )
    );
    assert_eq!(
        Action::verify_server_observation(tuple, &ServerObservation::Unknown("absent".into())),
        Outcome::Unknown("absent".into())
    );
    assert!(matches!(
        c2(CONNECTED).observe_server(),
        Err(DispatchFailure::Refused(_))
    ));
}
