//! The Windows counterpart of `keychain.rs` (TASK-XPA-011, gate inventory
//! G13): the signing envelope as one generic credential of this user in
//! Credential Manager, whose blob Windows protects with DPAPI under the
//! user's logon key, with the same public surface and answers as the macOS
//! `SecItem*` store.
//!
//! - **Identity.** A macOS item is the triple (access group, service,
//!   account). Credential Manager keys a generic credential by its target name
//!   alone, so the triple is the target name
//!   `ArkDeck/<access group>/<service>/<account>`, and the account is also the
//!   credential's user name, which every read compares. The access group and
//!   service may not contain `/`, so the target name has exactly one parse.
//! - **Persistence.** `CRED_PERSIST_LOCAL_MACHINE`: the credential belongs to
//!   this Windows user and survives logoff, but does not roam to other
//!   computers with a roaming profile (`CRED_PERSIST_ENTERPRISE` would) — the
//!   counterpart of `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.
//!   `CRED_PERSIST_SESSION` would not survive logoff. Credential Manager has
//!   no machine-wide generic credential: "LOCAL_MACHINE" names the roaming
//!   scope, not the owner. A read refuses a credential persisted any other
//!   way, since ArkDeck never wrote it.
//! - **Interaction.** `CredReadW` never prompts, so the non-interactive
//!   Runtime policy holds by construction; the maintenance constructor keeps
//!   its flag for parity and changes nothing on Windows.
//! - **Presence.** Credential Manager has no attribute-only query: `CredReadW`
//!   and `CredEnumerateW` both return the decrypted blob. The presence probe
//!   therefore reads, never copies the blob, and overwrites it in the API's
//!   own buffer before `CredFree`. The console challenge of WM3 is the
//!   interactive existence check above this layer.
//! - **Size.** Credential Manager stores at most `CRED_MAX_CREDENTIAL_BLOB_SIZE`
//!   (2560) bytes per generic credential; a larger value is refused before
//!   any call, where macOS accepts up to 64 KiB.
//! - **Legacy scope.** No earlier Windows build wrote outside this namespace,
//!   so `outside_data_protection` answers "absent" and "nothing removed"
//!   without an OS call; `set` and `read` refuse it as on macOS.
//!
//! `set` succeeds only when the credential reads back with the value, account
//! and persistence written; otherwise it refuses ("Credential Manager did not
//! keep the written credential"), so a session that does not keep credentials
//! is reported, not silently lost.
//!
//! - **One call at a time.** Credential Manager loses updates when one
//!   user's credentials are changed concurrently. Measured on the Windows
//!   reference host (TASK-XPA-005), each thread writing, reading back and
//!   deleting its own credentials:
//!   - 8 processes of 8 threads lost 28 written credentials and brought back
//!     320 deleted ones in five runs;
//!   - 8 threads of one process lost no written credential, but brought
//!     back 12–14 deleted ones in two of three runs;
//!   - with every call taking turns, nothing was lost or brought back.
//!
//!   Every call here therefore takes this user's Credential Manager turn, a
//!   named mutex in the session namespace
//!   (`Local\ArkDeck.CredentialManager.<user SID>`, owner-only, as the
//!   daemon's single-instance guard). It serializes the threads of one
//!   process and the ArkDeck processes alike. `set` holds it from the write
//!   through the read-back, so no other ArkDeck call can undo the write or
//!   answer between. Programs other than ArkDeck do not take the turn.
//!
//! Every error carries the Win32 error code or a fixed refusal, never a value.
//! An absent credential is `Status(ERROR_NOT_FOUND)` on `read`,
//! [`KeychainPresence::Absent`] on `presence` and `Ok(false)` on `remove`, as
//! macOS answers `errSecItemNotFound`.
use super::identity::{Token, owned_by_current_user};
use super::{Handle, SecurityDescriptor};
use crate::Secret;
use std::fmt;
use std::marker::PhantomData;
use std::ptr;
use std::time::Duration;
use windows_sys::Win32::Foundation::{
    ERROR_NOT_FOUND, GetLastError, WAIT_ABANDONED, WAIT_OBJECT_0, WAIT_TIMEOUT,
};
use windows_sys::Win32::Security::Authorization::SE_KERNEL_OBJECT;
use windows_sys::Win32::Security::Credentials::{
    CRED_MAX_CREDENTIAL_BLOB_SIZE, CRED_MAX_USERNAME_LENGTH, CRED_PERSIST_LOCAL_MACHINE,
    CRED_TYPE_GENERIC, CREDENTIALW, CredDeleteW, CredFree, CredReadW, CredWriteW,
};
use windows_sys::Win32::System::Threading::{CreateMutexW, ReleaseMutex, WaitForSingleObject};

/// The macOS access group, kept as the namespace component of every
/// production target name so that both platforms name one item alike. It must
/// equal `host_bundle_signature::DAEMON_KEYCHAIN_ACCESS_GROUP`.
pub const DAEMON_KEYCHAIN_ACCESS_GROUP: &str = "8AQTYW5FKR.com.arkdeck.shared";

/// The Win32 error `read` answers for an absent credential.
pub const CREDENTIAL_NOT_FOUND: i32 = ERROR_NOT_FOUND as i32;

const MAX_NAME_BYTES: usize = 1024;
const MAX_VALUE_BYTES: usize = CRED_MAX_CREDENTIAL_BLOB_SIZE as usize;
const TARGET_PREFIX: &str = "ArkDeck/";
const FIXTURE_PREFIX: &str = "ArkDeck-fixture/";

/// Why a credential call did not produce what was asked. Carries the Win32
/// error code or a fixed refusal, never a credential's value.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum KeychainError {
    /// Credential Manager answered with this Win32 error code.
    Status(i32),
    /// Refused before or after the Credential Manager call: an unusable name,
    /// value or scope, or an answer of the wrong shape.
    Refused(&'static str),
}

impl fmt::Display for KeychainError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Status(status) => write!(formatter, "Credential Manager status {status}"),
            Self::Refused(reason) => {
                write!(formatter, "Credential Manager request refused: {reason}")
            }
        }
    }
}

impl std::error::Error for KeychainError {}

/// What a presence probe established about one account. `Absent` is
/// Credential Manager positively answering `ERROR_NOT_FOUND`; every other
/// failure is `Unreadable` with its Win32 code (0 for a refusal of this
/// layer) and says nothing about the credential.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum KeychainPresence {
    Present,
    Absent,
    Unreadable(i32),
}

enum Scope {
    /// `ArkDeck/<access group>/`.
    Namespaced(String),
    OutsideDataProtection,
}

/// The generic credentials of one service in one namespace.
pub struct KeychainItems {
    service: String,
    allows_interaction: bool,
    scope: Scope,
}

impl KeychainItems {
    /// The production scope: this user's Credential Manager, namespaced by
    /// `access_group` exactly as the macOS Data Protection Keychain item.
    pub fn data_protection(service: &str, access_group: &str) -> Result<Self, KeychainError> {
        Ok(Self {
            service: component(service)?.to_owned(),
            allows_interaction: false,
            scope: Scope::Namespaced(format!("{TARGET_PREFIX}{}/", component(access_group)?)),
        })
    }

    /// Explicit maintenance CLI only. Credential Manager never prompts on a
    /// read, so the flag is kept for parity and changes no call.
    pub fn data_protection_for_maintenance(
        service: &str,
        access_group: &str,
    ) -> Result<Self, KeychainError> {
        let mut items = Self::data_protection(service, access_group)?;
        items.allows_interaction = true;
        Ok(items)
    }

    /// The macOS legacy scope. No Windows build ever wrote there: presence is
    /// `Absent` and removal `Ok(false)` by construction; `set` and `read`
    /// refuse it.
    pub fn outside_data_protection(service: &str) -> Result<Self, KeychainError> {
        Ok(Self {
            service: component(service)?.to_owned(),
            allows_interaction: false,
            scope: Scope::OutsideDataProtection,
        })
    }

    /// A fixture scope: target names under `ArkDeck-fixture/<namespace>/`,
    /// apart from every production name, so a test that picks a unique
    /// namespace reaches only the credentials it created.
    pub fn fixture_namespace(service: &str, namespace: &str) -> Result<Self, KeychainError> {
        Ok(Self {
            service: component(service)?.to_owned(),
            allows_interaction: false,
            scope: Scope::Namespaced(format!("{FIXTURE_PREFIX}{}/", component(namespace)?)),
        })
    }

    /// The target name of `account` in this scope, as written to Credential
    /// Manager; `None` for the legacy scope.
    pub fn target_name(&self, account: &str) -> Result<Option<String>, KeychainError> {
        let account = account_name(account)?;
        Ok(match &self.scope {
            Scope::Namespaced(prefix) => Some(format!("{prefix}{}/{account}", self.service)),
            Scope::OutsideDataProtection => None,
        })
    }

    /// macOS `set`: creates the credential or replaces its value.
    /// `CredWriteW` replaces a credential of the same target in one call.
    pub fn set(&self, account: &str, value: &[u8]) -> Result<(), KeychainError> {
        let target = self.target_name(account)?.ok_or(KeychainError::Refused(
            "nothing is written outside the Data Protection Keychain",
        ))?;
        if value.is_empty() || value.len() > MAX_VALUE_BYTES {
            return Err(KeychainError::Refused("value is empty or unbounded"));
        }
        let mut target_wide = wide(&target);
        let mut user = wide(account);
        let credential = CREDENTIALW {
            Type: CRED_TYPE_GENERIC,
            TargetName: target_wide.as_mut_ptr(),
            CredentialBlobSize: value.len() as u32,
            // CredWriteW only reads the blob; it copies and encrypts it.
            CredentialBlob: value.as_ptr().cast_mut(),
            Persist: CRED_PERSIST_LOCAL_MACHINE,
            UserName: user.as_mut_ptr(),
            ..CREDENTIALW::default()
        };
        let _turn = CredentialTurn::take()?;
        // SAFETY: the structure and every buffer it points to are live for
        // the call; no flags.
        if unsafe { CredWriteW(&credential, 0) } == 0 {
            return Err(last_status());
        }
        // A write is reported only once it reads back as written, so that a
        // session whose Credential Manager did not keep it, or a writer that
        // replaced it at once, is a typed refusal and never a silent loss.
        let lost = KeychainError::Refused("Credential Manager did not keep the written credential");
        let written = ReadCredential::read(&target).map_err(|error| match error {
            KeychainError::Status(CREDENTIAL_NOT_FOUND) => lost,
            error => error,
        })?;
        written.check(account)?;
        if written.blob() != value {
            return Err(lost);
        }
        Ok(())
    }

    /// macOS `read`: the credential's value, or the status that refused it.
    pub fn read(&self, account: &str) -> Result<Secret, KeychainError> {
        let target = self.target_name(account)?.ok_or(KeychainError::Refused(
            "nothing is read outside the Data Protection Keychain",
        ))?;
        let credential = CredentialTurn::take().and_then(|_turn| ReadCredential::read(&target))?;
        credential.check(account)?;
        Ok(Secret::from_slice(credential.blob()))
    }

    /// macOS `presence`: never copies the value (see the module notes).
    pub fn presence(&self, account: &str) -> KeychainPresence {
        let target = match self.target_name(account) {
            Ok(Some(target)) => target,
            Ok(None) => return KeychainPresence::Absent,
            Err(_) => return KeychainPresence::Unreadable(0),
        };
        match CredentialTurn::take().and_then(|_turn| ReadCredential::read(&target)) {
            Ok(credential) => match credential.check(account) {
                Ok(()) => KeychainPresence::Present,
                Err(_) => KeychainPresence::Unreadable(0),
            },
            Err(KeychainError::Status(CREDENTIAL_NOT_FOUND)) => KeychainPresence::Absent,
            Err(KeychainError::Status(status)) => KeychainPresence::Unreadable(status),
            Err(KeychainError::Refused(_)) => KeychainPresence::Unreadable(0),
        }
    }

    /// macOS `contains`: `false` both for an absent credential and for one
    /// this process could not read.
    pub fn contains(&self, account: &str) -> bool {
        self.presence(account) == KeychainPresence::Present
    }

    /// macOS `remove`: `true` when a credential was deleted, `false` when
    /// Credential Manager answered that there was none.
    pub fn remove(&self, account: &str) -> Result<bool, KeychainError> {
        let Some(target) = self.target_name(account)? else {
            return Ok(false);
        };
        let target = wide(&target);
        let turn = CredentialTurn::take()?;
        // SAFETY: a NUL-terminated target name live for the call.
        let deleted = unsafe { CredDeleteW(target.as_ptr(), CRED_TYPE_GENERIC, 0) } != 0;
        // Read before the turn's release can overwrite the last error.
        let status = last_status();
        drop(turn);
        if deleted {
            return Ok(true);
        }
        match status {
            KeychainError::Status(CREDENTIAL_NOT_FOUND) => Ok(false),
            error => Err(error),
        }
    }
}

/// Runs `call` holding this user's Credential Manager turn (see the module
/// notes), for code that must call Credential Manager itself, as a test
/// writing a credential ArkDeck never writes.
pub fn with_credential_manager_turn<R>(call: impl FnOnce() -> R) -> Result<R, KeychainError> {
    let _turn = CredentialTurn::take()?;
    Ok(call())
}

/// How long a call waits for another ArkDeck process's Credential Manager
/// call; a turn lasts one call (a write and its read-back for `set`).
const TURN_WAIT: Duration = Duration::from_secs(30);

/// This user's Credential Manager turn, held by one thread of one ArkDeck
/// process at a time. Thread-affine like every mutex, so neither sent nor
/// shared; released when dropped, and a holder that died leaves it to the
/// next.
struct CredentialTurn {
    mutex: Handle,
    _thread: PhantomData<*const ()>,
}

impl CredentialTurn {
    /// An existing object that is not this user's refuses, as the daemon's
    /// single-instance guard does.
    fn take() -> Result<Self, KeychainError> {
        let unusable = |_| KeychainError::Refused("the Credential Manager turn is unusable");
        let user = Token::current()
            .and_then(|token| token.user())
            .and_then(|sid| sid.text())
            .map_err(unusable)?;
        let security =
            SecurityDescriptor::from_sddl(&format!("O:{user}D:P(A;;GA;;;{user})(A;;GA;;;SY)"))
                .map_err(unusable)?;
        let attributes = security.attributes();
        let name = wide(&format!(r"Local\ArkDeck.CredentialManager.{user}"));
        // SAFETY: NUL-terminated name and security attributes alive for the
        // call; the handle is owned at once.
        let mutex = Handle::new(unsafe { CreateMutexW(&attributes, 0, name.as_ptr()) })
            .map_err(unusable)?;
        if !owned_by_current_user(mutex.raw(), SE_KERNEL_OBJECT).map_err(unusable)? {
            return Err(KeychainError::Refused(
                "the Credential Manager turn is owned by another account",
            ));
        }
        let millis = TURN_WAIT.as_millis() as u32;
        // SAFETY: live mutex handle with SYNCHRONIZE access.
        match unsafe { WaitForSingleObject(mutex.raw(), millis) } {
            // A holder that died made at most one call, which is complete
            // or was never made.
            WAIT_OBJECT_0 | WAIT_ABANDONED => Ok(Self {
                mutex,
                _thread: PhantomData,
            }),
            WAIT_TIMEOUT => Err(KeychainError::Refused(
                "another ArkDeck process held the Credential Manager turn too long",
            )),
            _ => Err(last_status()),
        }
    }
}

impl Drop for CredentialTurn {
    fn drop(&mut self) {
        // SAFETY: this thread owns the mutex (the turn cannot leave it).
        unsafe {
            ReleaseMutex(self.mutex.raw());
        }
    }
}

/// A credential returned by `CredReadW`; its blob is overwritten in place
/// and the whole block freed with `CredFree` when dropped.
struct ReadCredential(*mut CREDENTIALW);

impl ReadCredential {
    fn read(target: &str) -> Result<Self, KeychainError> {
        let target = wide(target);
        let mut raw = ptr::null_mut();
        // SAFETY: a NUL-terminated target name and a live out pointer.
        if unsafe { CredReadW(target.as_ptr(), CRED_TYPE_GENERIC, 0, &mut raw) } == 0 {
            return Err(last_status());
        }
        if raw.is_null() {
            return Err(KeychainError::Refused(
                "Credential Manager returned no credential",
            ));
        }
        Ok(Self(raw))
    }

    fn credential(&self) -> &CREDENTIALW {
        // SAFETY: a nonnull block from a successful CredReadW, live until drop.
        unsafe { &*self.0 }
    }

    fn blob(&self) -> &[u8] {
        let credential = self.credential();
        if credential.CredentialBlob.is_null() {
            return &[];
        }
        // SAFETY: the API's blob of exactly `CredentialBlobSize` bytes.
        unsafe {
            std::slice::from_raw_parts(
                credential.CredentialBlob,
                credential.CredentialBlobSize as usize,
            )
        }
    }

    /// The credential is ArkDeck's for `account`: generic, this computer only,
    /// the account's user name, and a bounded nonempty value.
    fn check(&self, account: &str) -> Result<(), KeychainError> {
        let credential = self.credential();
        if credential.Type != CRED_TYPE_GENERIC || credential.Persist != CRED_PERSIST_LOCAL_MACHINE
        {
            return Err(KeychainError::Refused(
                "the credential is not a generic credential of this computer only",
            ));
        }
        if credential.UserName.is_null() {
            return Err(KeychainError::Refused(
                "the credential names another account",
            ));
        }
        // SAFETY: a NUL-terminated string inside the API's block.
        let user = unsafe { wide_until_nul(credential.UserName) };
        if user.iter().copied().ne(account.encode_utf16()) {
            return Err(KeychainError::Refused(
                "the credential names another account",
            ));
        }
        let length = self.blob().len();
        if length == 0 || length > MAX_VALUE_BYTES {
            return Err(KeychainError::Refused(
                "the credential value is empty or unbounded",
            ));
        }
        Ok(())
    }
}

impl Drop for ReadCredential {
    fn drop(&mut self) {
        let credential = self.credential();
        if !credential.CredentialBlob.is_null() {
            // SAFETY: the API's own writable blob of `CredentialBlobSize` bytes.
            crate::wipe(unsafe {
                std::slice::from_raw_parts_mut(
                    credential.CredentialBlob,
                    credential.CredentialBlobSize as usize,
                )
            });
        }
        // SAFETY: the block came from CredReadW and is freed exactly once.
        unsafe { CredFree(self.0.cast_const().cast()) };
    }
}

/// # Safety
/// `value` is a live NUL-terminated UTF-16 string.
unsafe fn wide_until_nul<'a>(value: *const u16) -> &'a [u16] {
    let mut length = 0;
    // SAFETY: the caller guarantees a terminator within the allocation.
    while unsafe { *value.add(length) } != 0 {
        length += 1;
    }
    // SAFETY: `length` units precede the terminator.
    unsafe { std::slice::from_raw_parts(value, length) }
}

fn last_status() -> KeychainError {
    // SAFETY: reads this thread's last-error value.
    KeychainError::Status(unsafe { GetLastError() } as i32)
}

fn wide(value: &str) -> Vec<u16> {
    value.encode_utf16().chain(Some(0)).collect()
}

fn bounded(value: &str) -> Result<&str, KeychainError> {
    if value.is_empty() || value.len() > MAX_NAME_BYTES || value.contains('\0') {
        return Err(KeychainError::Refused(
            "a Keychain name is empty, unbounded or contains NUL",
        ));
    }
    Ok(value)
}

/// A namespace or service: bounded, and without the target name's separator.
fn component(value: &str) -> Result<&str, KeychainError> {
    let value = bounded(value)?;
    if value.contains('/') {
        return Err(KeychainError::Refused(
            "a credential namespace or service contains '/'",
        ));
    }
    Ok(value)
}

/// An account, which is also the credential's user name.
fn account_name(value: &str) -> Result<&str, KeychainError> {
    let value = bounded(value)?;
    if value.encode_utf16().count() > CRED_MAX_USERNAME_LENGTH as usize {
        return Err(KeychainError::Refused(
            "an account is longer than a credential user name",
        ));
    }
    Ok(value)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_explicit_maintenance_allows_keychain_interaction() {
        let runtime = KeychainItems::data_protection("fixture", "fixture.group").unwrap();
        let maintenance =
            KeychainItems::data_protection_for_maintenance("fixture", "fixture.group").unwrap();
        assert!(!runtime.allows_interaction);
        assert!(maintenance.allows_interaction);
    }

    #[test]
    fn target_names_carry_the_macos_item_identity() {
        let items = KeychainItems::data_protection(
            "dev.arkdeck.openharmony-local-signing",
            DAEMON_KEYCHAIN_ACCESS_GROUP,
        )
        .unwrap();
        assert_eq!(
            items.target_name("preset|secret-envelope-1").unwrap(),
            Some(
                "ArkDeck/8AQTYW5FKR.com.arkdeck.shared/dev.arkdeck.openharmony-local-signing/\
                 preset|secret-envelope-1"
                    .to_owned()
            )
        );
        let fixture = KeychainItems::fixture_namespace("service", "run-1").unwrap();
        assert_eq!(
            fixture.target_name("a/b").unwrap(),
            Some("ArkDeck-fixture/run-1/service/a/b".to_owned())
        );
        let legacy = KeychainItems::outside_data_protection("service").unwrap();
        assert_eq!(legacy.target_name("account").unwrap(), None);
    }

    #[test]
    fn names_that_would_make_the_target_ambiguous_or_unbounded_are_refused() {
        for (service, group) in [
            ("", "g"),
            ("s", ""),
            ("a/b", "g"),
            ("s", "g/h"),
            ("s\0", "g"),
        ] {
            assert!(matches!(
                KeychainItems::data_protection(service, group),
                Err(KeychainError::Refused(_))
            ));
        }
        let items = KeychainItems::fixture_namespace("service", "names").unwrap();
        let long = "x".repeat(CRED_MAX_USERNAME_LENGTH as usize + 1);
        for account in ["", "nul\0", long.as_str()] {
            assert!(matches!(
                items.target_name(account),
                Err(KeychainError::Refused(_))
            ));
        }
    }

    #[test]
    fn the_legacy_scope_never_writes_or_reads() {
        let items = KeychainItems::outside_data_protection("service").unwrap();
        assert!(matches!(
            items.set("account", b"value"),
            Err(KeychainError::Refused(_))
        ));
        assert!(matches!(
            items.read("account"),
            Err(KeychainError::Refused(_))
        ));
        assert_eq!(items.presence("account"), KeychainPresence::Absent);
        assert_eq!(items.remove("account"), Ok(false));
    }
}
