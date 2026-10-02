//! `KeychainItems` against this user's real Credential Manager (TASK-XPA-011,
//! G13). Every test works in its own fixture namespace,
//! `ArkDeck-fixture/<random>/…`, and a guard deletes each target the test
//! may have created on every path, panics included; no production or other
//! credential is ever read, written or deleted. The tests' own Credential
//! Manager calls take the same turn as `KeychainItems`.
#![cfg(windows)]

use arkdeck_platform::{
    CREDENTIAL_NOT_FOUND, KeychainError, KeychainItems, KeychainPresence, Secret, random_bytes,
    with_credential_manager_turn,
};
use windows_sys::Win32::Security::Credentials::{
    CRED_PERSIST_LOCAL_MACHINE, CRED_PERSIST_SESSION, CRED_TYPE_GENERIC, CREDENTIALW, CredDeleteW,
    CredWriteW,
};

const SERVICE: &str = "dev.arkdeck.openharmony-local-signing";
const BLOB_LIMIT: usize = 2560;

/// The tests of this file run one at a time (see
/// `concurrent_writers_keep_each_others_credentials`).
static SERIAL: std::sync::Mutex<()> = std::sync::Mutex::new(());

/// One fixture namespace and the accounts it may hold, deleted on drop.
struct Fixture {
    items: KeychainItems,
    targets: Vec<Vec<u16>>,
    // Released after `Drop::drop` has deleted the targets.
    _serial: std::sync::MutexGuard<'static, ()>,
}

impl Fixture {
    fn new() -> Self {
        Self::in_namespace(&fixture_namespace())
    }

    fn in_namespace(namespace: &str) -> Self {
        let serial = SERIAL
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        Self {
            items: KeychainItems::fixture_namespace(SERVICE, namespace).unwrap(),
            targets: Vec::new(),
            _serial: serial,
        }
    }

    /// Registers `account` for cleanup before anything can create it.
    fn account<'a>(&mut self, account: &'a str) -> &'a str {
        self.register(account);
        account
    }

    fn register(&mut self, account: &str) {
        let target = self.items.target_name(account).unwrap().unwrap();
        assert!(target.starts_with("ArkDeck-fixture/test-"));
        self.targets
            .push(target.encode_utf16().chain(Some(0)).collect());
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        for target in &self.targets {
            // SAFETY: a NUL-terminated fixture target name. An absent
            // credential is the expected answer for most of them. A turn
            // not taken in time is asked for again: a skipped delete would
            // leave the credential behind.
            for _ in 0..10 {
                if with_credential_manager_turn(|| unsafe {
                    CredDeleteW(target.as_ptr(), CRED_TYPE_GENERIC, 0)
                })
                .is_ok()
                {
                    break;
                }
            }
        }
    }
}

fn fixture_namespace() -> String {
    let token: String = random_bytes::<8>()
        .unwrap()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect();
    format!("test-{}-{token}", std::process::id())
}

#[test]
fn a_credential_round_trips_and_is_removed() {
    let mut fixture = Fixture::new();
    let account = fixture.account("preset-1|secret-envelope-1");
    let items = &fixture.items;
    assert_eq!(items.presence(account), KeychainPresence::Absent);
    assert!(!items.contains(account));
    assert_eq!(
        items.read(account).unwrap_err(),
        KeychainError::Status(CREDENTIAL_NOT_FOUND)
    );
    assert_eq!(items.remove(account), Ok(false));

    items.set(account, b"first value").unwrap();
    assert_eq!(items.presence(account), KeychainPresence::Present);
    assert!(items.contains(account));
    assert_eq!(items.read(account).unwrap().as_bytes(), b"first value");
    // A second set replaces the value, as the macOS update does.
    items.set(account, "zweiter Wert ✓".as_bytes()).unwrap();
    assert_eq!(
        items.read(account).unwrap().as_bytes(),
        "zweiter Wert ✓".as_bytes()
    );
    // Other accounts in the namespace stay absent.
    let other = fixture.account("preset-1|secret-envelope-2");
    assert_eq!(fixture.items.presence(other), KeychainPresence::Absent);

    let items = &fixture.items;
    assert_eq!(items.remove(account), Ok(true));
    assert_eq!(items.remove(account), Ok(false));
    assert_eq!(items.presence(account), KeychainPresence::Absent);
    assert_eq!(
        items.read(account).unwrap_err(),
        KeychainError::Status(CREDENTIAL_NOT_FOUND)
    );
}

#[test]
fn the_largest_value_credential_manager_keeps_round_trips_and_larger_is_refused() {
    let mut fixture = Fixture::new();
    let account = fixture.account("bounded");
    let items = &fixture.items;
    let largest = vec![0xA5; BLOB_LIMIT];
    items.set(account, &largest).unwrap();
    assert_eq!(items.read(account).unwrap().as_bytes(), largest.as_slice());
    for value in [Vec::new(), vec![0x5A; BLOB_LIMIT + 1]] {
        assert_eq!(
            items.set(account, &value),
            Err(KeychainError::Refused("value is empty or unbounded"))
        );
    }
    // The refused writes left the stored value alone.
    assert_eq!(items.read(account).unwrap().as_bytes(), largest.as_slice());
    assert_eq!(items.remove(account), Ok(true));
}

#[test]
fn invalid_names_are_refused_before_any_call() {
    let fixture = Fixture::new();
    let items = &fixture.items;
    let long = "x".repeat(1025);
    for account in ["", "nul\0account", long.as_str()] {
        assert!(matches!(
            items.set(account, b"value"),
            Err(KeychainError::Refused(_))
        ));
        assert!(matches!(
            items.read(account),
            Err(KeychainError::Refused(_))
        ));
        assert!(matches!(
            items.remove(account),
            Err(KeychainError::Refused(_))
        ));
        assert_eq!(items.presence(account), KeychainPresence::Unreadable(0));
    }
    for namespace in ["", "a/b", "nul\0"] {
        assert!(matches!(
            KeychainItems::fixture_namespace(SERVICE, namespace),
            Err(KeychainError::Refused(_))
        ));
    }
}

/// Writes a credential at `account`'s exact fixture target the way ArkDeck
/// never does, to prove that `read` refuses it.
fn write_foreign(fixture: &Fixture, account: &str, user: &str, persist: u32) {
    let mut target: Vec<u16> = fixture
        .items
        .target_name(account)
        .unwrap()
        .unwrap()
        .encode_utf16()
        .chain(Some(0))
        .collect();
    let mut user: Vec<u16> = user.encode_utf16().chain(Some(0)).collect();
    let value = b"foreign value";
    let credential = CREDENTIALW {
        Type: CRED_TYPE_GENERIC,
        TargetName: target.as_mut_ptr(),
        CredentialBlobSize: value.len() as u32,
        CredentialBlob: value.as_ptr().cast_mut(),
        Persist: persist,
        UserName: user.as_mut_ptr(),
        ..CREDENTIALW::default()
    };
    // SAFETY: every buffer is live for the call.
    assert_ne!(
        with_credential_manager_turn(|| unsafe { CredWriteW(&credential, 0) }).unwrap(),
        0
    );
}

#[test]
fn a_credential_arkdeck_did_not_write_is_refused_and_not_reported_present() {
    let mut fixture = Fixture::new();
    let account = fixture.account("foreign-user");
    write_foreign(
        &fixture,
        account,
        "someone-else",
        CRED_PERSIST_LOCAL_MACHINE,
    );
    assert_eq!(
        fixture.items.read(account).unwrap_err(),
        KeychainError::Refused("the credential names another account")
    );
    assert_eq!(
        fixture.items.presence(account),
        KeychainPresence::Unreadable(0)
    );

    let account = fixture.account("session-only");
    write_foreign(&fixture, account, account, CRED_PERSIST_SESSION);
    assert!(matches!(
        fixture.items.read(account),
        Err(KeychainError::Refused(_))
    ));
    assert_eq!(
        fixture.items.presence(account),
        KeychainPresence::Unreadable(0)
    );
    // `remove` still deletes the exact target it names.
    assert_eq!(fixture.items.remove(account), Ok(true));
}

#[test]
fn neither_the_value_nor_its_errors_print_the_secret() {
    let mut fixture = Fixture::new();
    let account = fixture.account("printing");
    fixture.items.set(account, b"do-not-print").unwrap();
    let secret: Secret = fixture.items.read(account).unwrap();
    assert_eq!(format!("{secret:?}"), "Secret(12 bytes)");
    let refused = fixture
        .items
        .set(account, &[b'x'; BLOB_LIMIT + 1])
        .unwrap_err();
    for text in [format!("{refused}"), format!("{refused:?}")] {
        assert!(!text.contains("do-not-print") && !text.contains("xxxx"));
    }
    assert_eq!(fixture.items.remove(account), Ok(true));
    let absent = fixture.items.read(account).unwrap_err();
    assert_eq!(
        format!("{absent}"),
        format!("Credential Manager status {CREDENTIAL_NOT_FOUND}")
    );
}

/// Writes `value` at `account`'s fixture target with any user name and
/// persistence, as another program could; the Win32 error on failure.
fn write_raw(
    items: &KeychainItems,
    account: &str,
    user: &str,
    persist: u32,
    value: &[u8],
) -> Result<(), u32> {
    let mut target: Vec<u16> = items
        .target_name(account)
        .unwrap()
        .unwrap()
        .encode_utf16()
        .chain(Some(0))
        .collect();
    let mut user: Vec<u16> = user.encode_utf16().chain(Some(0)).collect();
    let credential = CREDENTIALW {
        Type: CRED_TYPE_GENERIC,
        TargetName: target.as_mut_ptr(),
        CredentialBlobSize: value.len() as u32,
        CredentialBlob: value.as_ptr().cast_mut(),
        Persist: persist,
        UserName: user.as_mut_ptr(),
        ..CREDENTIALW::default()
    };
    // SAFETY: every buffer is live for the call; the last error is read
    // before the turn is released.
    with_credential_manager_turn(|| unsafe {
        if CredWriteW(&credential, 0) == 0 {
            Err(windows_sys::Win32::Foundation::GetLastError())
        } else {
            Ok(())
        }
    })
    .unwrap()
}

/// How the churning threads write their own credentials.
#[derive(Clone, Copy, Debug)]
enum Churn {
    /// `KeychainItems::set` with a short value.
    Short,
    /// `KeychainItems::set` with the largest value Credential Manager keeps.
    Largest,
    /// Another user name, `CRED_PERSIST_LOCAL_MACHINE`.
    ForeignUser,
    /// `CRED_PERSIST_SESSION`.
    Session,
}

/// Churns `rounds` credentials of its own next to one kept credential and
/// counts how often the kept one was no longer present.
fn churn(
    items: &KeychainItems,
    keep: &str,
    prefix: &str,
    rounds: usize,
    kind: Churn,
) -> (usize, Vec<String>) {
    let mut lost = 0;
    let mut errors = Vec::new();
    let largest = vec![0xA5; BLOB_LIMIT];
    for round in 0..rounds {
        let account = format!("{prefix}-{round}");
        let written = match kind {
            Churn::Short => items
                .set(&account, b"churn")
                .map_err(|error| format!("{error:?}")),
            Churn::Largest => items
                .set(&account, &largest)
                .map_err(|error| format!("{error:?}")),
            Churn::ForeignUser => write_raw(
                items,
                &account,
                "someone-else",
                CRED_PERSIST_LOCAL_MACHINE,
                b"churn",
            )
            .map_err(|error| format!("{error}")),
            Churn::Session => write_raw(items, &account, &account, CRED_PERSIST_SESSION, b"churn")
                .map_err(|error| format!("{error}")),
        };
        if let Err(error) = written {
            errors.push(format!("set {error}"));
        }
        if let Err(error) = items.remove(&account) {
            errors.push(format!("remove {error:?}"));
        }
        let presence = items.presence(keep);
        if presence != KeychainPresence::Present {
            lost += 1;
            errors.push(format!("round {round}: kept {presence:?}"));
            let _ = items.set(keep, b"kept");
        }
    }
    (lost, errors)
}

/// Eight threads each keep one credential while churning their own; every
/// way of writing is measured on its own, then all of them at once. After
/// each phase every churned credential is still deleted: without the
/// Credential Manager turn, deleted ones came back.
#[test]
fn concurrent_writers_keep_each_others_credentials() {
    const THREADS: usize = 8;
    const ROUNDS: usize = 10;
    const KINDS: [Churn; 4] = [
        Churn::Short,
        Churn::Largest,
        Churn::ForeignUser,
        Churn::Session,
    ];
    let mut fixture = Fixture::new();
    for thread in 0..THREADS {
        fixture.register(&format!("kept-{thread}"));
        for round in 0..ROUNDS {
            fixture.register(&format!("churn-{thread}-{round}"));
        }
    }
    let items = &fixture.items;
    let mut report = Vec::new();
    let mut total = 0;
    let phases: Vec<(String, Vec<Churn>)> = KINDS
        .iter()
        .map(|kind| (format!("{kind:?}"), vec![*kind; THREADS]))
        .chain(Some((
            "mixed".to_owned(),
            (0..THREADS)
                .map(|thread| KINDS[thread % KINDS.len()])
                .collect(),
        )))
        .collect();
    for (phase, kinds) in phases {
        let results: Vec<(usize, Vec<String>)> = std::thread::scope(|scope| {
            let handles: Vec<_> = kinds
                .iter()
                .enumerate()
                .map(|(thread, kind)| {
                    let kind = *kind;
                    scope.spawn(move || {
                        let keep = format!("kept-{thread}");
                        items.set(&keep, b"kept").unwrap();
                        churn(items, &keep, &format!("churn-{thread}"), ROUNDS, kind)
                    })
                })
                .collect();
            handles
                .into_iter()
                .map(|handle| handle.join().unwrap())
                .collect()
        });
        let lost: usize = results.iter().map(|(lost, _)| lost).sum();
        let back: Vec<String> = (0..THREADS)
            .flat_map(|thread| (0..ROUNDS).map(move |round| format!("churn-{thread}-{round}")))
            .filter_map(|churned| match items.presence(&churned) {
                KeychainPresence::Absent => None,
                presence => Some(format!("{churned}: {presence:?}")),
            })
            .collect();
        total += lost + back.len();
        let errors: Vec<&String> = results
            .iter()
            .flat_map(|(_, errors)| errors.iter().take(2))
            .collect();
        report.push(format!(
            "{phase}: lost {lost} {errors:?}; deleted and back {back:?}"
        ));
    }
    assert!(total == 0, "credentials lost: {report:#?}");
}

/// The child side of `concurrent_processes_keep_each_others_credentials`,
/// named by this variable: `<namespace> <child index>`.
const CHURN_CHILD: &str = "ARKDECK_CREDENTIAL_CHURN_CHILD";

/// Eight processes of four threads each keep one credential while churning
/// their own through `KeychainItems`. Credential Manager loses concurrent
/// updates of different processes (see `credential.rs`): without the
/// Credential Manager turn this failed 4 runs in 5, with deleted credentials
/// back. Afterwards every kept credential is present and every churned one
/// absent. A measurement, not run by default: a program outside ArkDeck
/// changing credentials at the same time is not held off by the turn, and
/// under load this still failed 2 runs in 30 (TASK-XPA-005).
#[test]
#[ignore = "a measurement: programs outside ArkDeck do not take the Credential Manager turn"]
fn concurrent_processes_keep_each_others_credentials() {
    const CHILDREN: usize = 8;
    const THREADS: usize = 4;
    const ROUNDS: usize = 10;
    if let Ok(assignment) = std::env::var(CHURN_CHILD) {
        let (namespace, child) = assignment.split_once(' ').unwrap();
        let items = KeychainItems::fixture_namespace(SERVICE, namespace).unwrap();
        let lost: Vec<String> = std::thread::scope(|scope| {
            let handles: Vec<_> = (0..THREADS)
                .map(|thread| {
                    let items = &items;
                    scope.spawn(move || {
                        let keep = format!("kept-{child}-{thread}");
                        items.set(&keep, b"kept").unwrap();
                        let prefix = format!("churn-{child}-{thread}");
                        churn(items, &keep, &prefix, ROUNDS, Churn::Short).1
                    })
                })
                .collect();
            handles
                .into_iter()
                .flat_map(|handle| handle.join().unwrap())
                .collect()
        });
        assert!(lost.is_empty(), "child {child}: {lost:?}");
        return;
    }
    let namespace = fixture_namespace();
    let mut fixture = Fixture::in_namespace(&namespace);
    for child in 0..CHILDREN {
        for thread in 0..THREADS {
            fixture.register(&format!("kept-{child}-{thread}"));
            for round in 0..ROUNDS {
                fixture.register(&format!("churn-{child}-{thread}-{round}"));
            }
        }
    }
    let executable = std::env::current_exe().unwrap();
    let children: Vec<_> = (0..CHILDREN)
        .map(|child| {
            std::process::Command::new(&executable)
                .args([
                    "--exact",
                    "concurrent_processes_keep_each_others_credentials",
                    "--include-ignored",
                    "--nocapture",
                ])
                .env(CHURN_CHILD, format!("{namespace} {child}"))
                .stdout(std::process::Stdio::piped())
                .stderr(std::process::Stdio::piped())
                .spawn()
                .unwrap()
        })
        .collect();
    let mut failures = Vec::new();
    for (child, process) in children.into_iter().enumerate() {
        let output = process.wait_with_output().unwrap();
        if !output.status.success() {
            let text = String::from_utf8_lossy(&output.stdout).into_owned()
                + &String::from_utf8_lossy(&output.stderr);
            let reason: Vec<&str> = text
                .lines()
                .filter(|line| line.contains("child") || line.contains("panicked"))
                .take(3)
                .collect();
            failures.push(format!("child {child}: {reason:?}"));
        }
    }
    let items = &fixture.items;
    for child in 0..CHILDREN {
        for thread in 0..THREADS {
            let keep = format!("kept-{child}-{thread}");
            let presence = items.presence(&keep);
            if presence != KeychainPresence::Present {
                failures.push(format!("{keep}: {presence:?}"));
            }
            for round in 0..ROUNDS {
                let churned = format!("churn-{child}-{thread}-{round}");
                let presence = items.presence(&churned);
                if presence != KeychainPresence::Absent {
                    failures.push(format!("{churned}: {presence:?} after its deletion"));
                }
            }
        }
    }
    assert!(
        failures.is_empty(),
        "{} failures: {failures:#?}",
        failures.len()
    );
}
