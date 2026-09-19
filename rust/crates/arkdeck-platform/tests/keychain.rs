//! `KeychainItems` against a real file-based keychain created with
//! `security create-keychain` in a temporary directory (SPK-10,
//! TASK-XPA-015). Nothing here writes to the login keychain or the Data
//! Protection Keychain: the fixture scope adds to and searches only its own
//! keychain, and the Data Protection scope is only ever asked, read-only,
//! from this unentitled test binary.
#![cfg(target_os = "macos")]

use arkdeck_platform::{
    DAEMON_KEYCHAIN_ACCESS_GROUP, KeychainError, KeychainItems, KeychainPresence, random_bytes,
};
use std::path::{Path, PathBuf};
use std::process::Command;

const SERVICE: &str = "dev.arkdeck.openharmony-local-signing";
const ERR_SEC_ITEM_NOT_FOUND: i32 = -25300;
const ERR_SEC_MISSING_ENTITLEMENT: i32 = -34018;

/// A keychain file that exists for one test and is deleted with it.
struct FixtureKeychain {
    directory: PathBuf,
    path: PathBuf,
}

impl FixtureKeychain {
    fn create() -> Self {
        let token: String = random_bytes::<8>()
            .unwrap()
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect();
        let directory = std::env::temp_dir()
            .canonicalize()
            .unwrap()
            .join(format!("arkdeck-keychain-{token}"));
        std::fs::create_dir(&directory).unwrap();
        let path = directory.join("fixture.keychain-db");
        // The fixture keychain's own password protects nothing; it is not a
        // signing secret and is discarded with the file.
        let status = Command::new("/usr/bin/security")
            .args(["create-keychain", "-p", &token])
            .arg(&path)
            .status()
            .unwrap();
        assert!(status.success(), "security create-keychain failed");
        // No automatic lock while the test runs, so that no read can ever
        // wait on an unlock prompt.
        let status = Command::new("/usr/bin/security")
            .arg("set-keychain-settings")
            .arg(&path)
            .status()
            .unwrap();
        assert!(status.success(), "security set-keychain-settings failed");
        Self { directory, path }
    }

    fn items(&self) -> KeychainItems {
        KeychainItems::file_keychain(SERVICE, &self.path).unwrap()
    }
}

impl Drop for FixtureKeychain {
    fn drop(&mut self) {
        let _ = Command::new("/usr/bin/security")
            .arg("delete-keychain")
            .arg(&self.path)
            .status();
        let _ = std::fs::remove_dir_all(&self.directory);
    }
}

fn user_search_list() -> String {
    let output = Command::new("/usr/bin/security")
        .args(["list-keychains", "-d", "user"])
        .output()
        .unwrap();
    assert!(output.status.success());
    String::from_utf8(output.stdout).unwrap()
}

/// Swift `set`/`read`/`presence`/`remove` on one item: an add, a value-only
/// update, the value read back without interaction, the three-way presence,
/// and a deletion that reports whether anything was there.
#[test]
fn an_item_is_added_updated_read_and_removed_in_the_fixture_keychain_only() {
    let search_list = user_search_list();
    let keychain = FixtureKeychain::create();
    assert_eq!(
        user_search_list(),
        search_list,
        "creating the fixture keychain must not change the user's search list"
    );
    let items = keychain.items();
    let account = "openharmony-release@1|secret-envelope-0e7f2a8c-1d7b-4c52-9d0c-6a8e2f7b5c31";

    assert_eq!(items.presence(account), KeychainPresence::Absent);
    assert!(!items.contains(account));
    assert_eq!(
        items.read(account).unwrap_err(),
        KeychainError::Status(ERR_SEC_ITEM_NOT_FOUND)
    );
    assert_eq!(items.remove(account), Ok(false));

    items.set(account, b"first-value").unwrap();
    assert_eq!(items.presence(account), KeychainPresence::Present);
    assert!(items.contains(account));
    assert_eq!(items.read(account).unwrap().as_bytes(), b"first-value");

    items.set(account, b"second-value").unwrap();
    assert_eq!(items.read(account).unwrap().as_bytes(), b"second-value");

    // Another account of the same service is a different item.
    assert_eq!(items.presence("other-account"), KeychainPresence::Absent);

    assert_eq!(items.remove(account), Ok(true));
    assert_eq!(items.presence(account), KeychainPresence::Absent);
    assert_eq!(items.remove(account), Ok(false));
    assert_eq!(
        user_search_list(),
        search_list,
        "the fixture never joins the user's search list"
    );
}

/// The fixture keychain's items are not visible outside it: a store over a
/// second keychain sees none of them.
#[test]
fn an_item_is_only_searched_in_its_own_keychain() {
    let first = FixtureKeychain::create();
    let second = FixtureKeychain::create();
    first
        .items()
        .set("shared-account", b"only-in-first")
        .unwrap();
    assert_eq!(
        second.items().presence("shared-account"),
        KeychainPresence::Absent
    );
    assert_eq!(
        first.items().read("shared-account").unwrap().as_bytes(),
        b"only-in-first"
    );
}

/// Names and values outside the closed bounds are refused before any
/// Security call; nothing is added.
#[test]
fn unusable_names_and_values_are_refused_before_the_keychain_is_asked() {
    let keychain = FixtureKeychain::create();
    let items = keychain.items();
    for (account, value) in [
        ("", b"value".as_slice()),
        ("with\0nul", b"value".as_slice()),
        ("account", b"".as_slice()),
    ] {
        assert!(matches!(
            items.set(account, value),
            Err(KeychainError::Refused(_))
        ));
    }
    let oversized = vec![b'x'; 64 * 1024 + 1];
    assert!(matches!(
        items.set("account", &oversized),
        Err(KeychainError::Refused(_))
    ));
    assert_eq!(items.presence("account"), KeychainPresence::Absent);
    assert!(matches!(
        KeychainItems::file_keychain(SERVICE, Path::new("relative.keychain-db")),
        Err(KeychainError::Refused(_))
    ));
    assert!(matches!(
        KeychainItems::file_keychain(SERVICE, &keychain.directory.join("absent.keychain-db")),
        Err(KeychainError::Refused(_))
    ));
}

/// The removal-only scope outside the Data Protection Keychain never writes
/// or reads a value, as Swift only ever deletes there.
#[test]
fn the_scope_outside_data_protection_neither_writes_nor_reads() {
    let items = KeychainItems::outside_data_protection(SERVICE).unwrap();
    assert!(matches!(
        items.set("account", b"value"),
        Err(KeychainError::Refused(_))
    ));
    assert!(matches!(
        items.read("account"),
        Err(KeychainError::Refused(_))
    ));
}

/// The production scope from a process without the access group's
/// entitlement: the Keychain refuses to look, so presence is `Unreadable`
/// — never `Absent` — and a read fails with the same status. Only read-only
/// questions are asked of the real Keychain.
#[test]
fn the_data_protection_keychain_is_unreadable_without_the_group_entitlement() {
    let items = KeychainItems::data_protection(SERVICE, DAEMON_KEYCHAIN_ACCESS_GROUP).unwrap();
    let account = "openharmony-release@1|secret-envelope-00000000-0000-4000-8000-000000000000";
    assert_eq!(
        items.presence(account),
        KeychainPresence::Unreadable(ERR_SEC_MISSING_ENTITLEMENT)
    );
    assert!(!items.contains(account));
    assert_eq!(
        items.read(account).unwrap_err(),
        KeychainError::Status(ERR_SEC_MISSING_ENTITLEMENT)
    );
}
