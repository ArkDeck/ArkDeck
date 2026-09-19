//! Generic-password items through the Security framework's `SecItem*` C API,
//! as Swift `LoginKeychainSigningSecretStore` keeps the OpenHarmony signing
//! envelope (SPK-10, TASK-XPA-015): the Data Protection Keychain bound to one
//! access group, a value-only update before an add, reads that never ask for
//! user interaction, and a presence probe that keeps "the Keychain answered
//! that there is no such item" apart from "this process could not look".
//!
//! The non-interactive policy is Swift's own object: a `LocalAuthentication`
//! `LAContext` whose `interactionNotAllowed` is set, passed as
//! `kSecUseAuthenticationContext`. It is created through the Objective-C
//! runtime's C entry points, so no Swift or Objective-C code is involved; the
//! deprecated `kSecUseAuthenticationUI` option is not used, as in Swift.
//!
//! A file-based keychain at an exact path is a fixture scope: items are added
//! to it with `kSecUseKeychain` and searched only in it with
//! `kSecMatchSearchList`, so a test never reaches the login keychain or the
//! Data Protection Keychain. Every error carries the Security framework's
//! status or a fixed refusal, never an item's value.
use crate::Secret;
use sha2::{Digest, Sha256};
use std::ffi::{CString, c_char, c_void};
use std::fmt;
use std::io::{self, Read};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::MetadataExt;
use std::path::Path;
use std::ptr;

use crate::host_bundle_signature::DAEMON_CODE_REQUIREMENT;
pub use crate::host_bundle_signature::DAEMON_KEYCHAIN_ACCESS_GROUP;

type CFTypeRef = *const c_void;

const ERR_SEC_SUCCESS: i32 = 0;
const ERR_SEC_ITEM_NOT_FOUND: i32 = -25300;
const UTF8: u32 = 0x0800_0100;
const MAX_NAME_BYTES: usize = 1024;
const MAX_VALUE_BYTES: usize = 64 * 1024;
const MAX_READ_BYTES: usize = 1024 * 1024;
// Current SDK SecStaticCode.h: kSecCSStrictValidate | kSecCSCheckAllArchitectures,
// the flags Swift passes; resources are validated (no kSecCSDoNotValidateResources).
const VALIDATION_FLAGS: u32 = (1 << 4) | 1;
// kSecCSSigningInformation.
const SIGNING_INFORMATION: u32 = 1 << 1;
const FINGERPRINT_DOMAIN: &[u8] = b"arkdeck-keychain-trusted-application-v1\0";

#[repr(C)]
struct CFDictionaryKeyCallBacks {
    version: isize,
    retain: *const c_void,
    release: *const c_void,
    copy_description: *const c_void,
    equal: *const c_void,
    hash: *const c_void,
}

#[repr(C)]
struct CFDictionaryValueCallBacks {
    version: isize,
    retain: *const c_void,
    release: *const c_void,
    copy_description: *const c_void,
    equal: *const c_void,
}

#[repr(C)]
struct CFArrayCallBacks {
    version: isize,
    retain: *const c_void,
    release: *const c_void,
    copy_description: *const c_void,
    equal: *const c_void,
}

#[link(name = "CoreFoundation", kind = "framework")]
unsafe extern "C" {
    static kCFTypeDictionaryKeyCallBacks: CFDictionaryKeyCallBacks;
    static kCFTypeDictionaryValueCallBacks: CFDictionaryValueCallBacks;
    static kCFTypeArrayCallBacks: CFArrayCallBacks;
    static kCFBooleanTrue: CFTypeRef;
    static kCFBooleanFalse: CFTypeRef;
    fn CFDictionaryCreate(
        allocator: *const c_void,
        keys: *const CFTypeRef,
        values: *const CFTypeRef,
        count: isize,
        key_callbacks: *const CFDictionaryKeyCallBacks,
        value_callbacks: *const CFDictionaryValueCallBacks,
    ) -> *const c_void;
    fn CFArrayCreate(
        allocator: *const c_void,
        values: *const CFTypeRef,
        count: isize,
        callbacks: *const CFArrayCallBacks,
    ) -> *const c_void;
    fn CFStringCreateWithBytes(
        allocator: *const c_void,
        bytes: *const u8,
        length: isize,
        encoding: u32,
        external: u8,
    ) -> *const c_void;
    fn CFDataCreate(allocator: *const c_void, bytes: *const u8, length: isize) -> *const c_void;
    fn CFDataGetTypeID() -> usize;
    fn CFDataGetLength(data: *const c_void) -> isize;
    fn CFDataGetBytePtr(data: *const c_void) -> *const u8;
    fn CFDictionaryGetTypeID() -> usize;
    fn CFDictionaryGetValue(dictionary: *const c_void, key: *const c_void) -> *const c_void;
    fn CFGetTypeID(value: *const c_void) -> usize;
    fn CFRelease(value: *const c_void);
    fn CFURLCreateFromFileSystemRepresentation(
        allocator: *const c_void,
        bytes: *const u8,
        length: isize,
        directory: u8,
    ) -> *const c_void;
}

#[link(name = "Security", kind = "framework")]
unsafe extern "C" {
    static kSecClass: CFTypeRef;
    static kSecClassGenericPassword: CFTypeRef;
    static kSecAttrService: CFTypeRef;
    static kSecAttrAccount: CFTypeRef;
    static kSecAttrAccessGroup: CFTypeRef;
    static kSecAttrAccessible: CFTypeRef;
    static kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly: CFTypeRef;
    static kSecUseDataProtectionKeychain: CFTypeRef;
    static kSecUseAuthenticationContext: CFTypeRef;
    static kSecUseKeychain: CFTypeRef;
    static kSecMatchSearchList: CFTypeRef;
    static kSecMatchLimit: CFTypeRef;
    static kSecMatchLimitOne: CFTypeRef;
    static kSecReturnData: CFTypeRef;
    static kSecReturnAttributes: CFTypeRef;
    static kSecValueData: CFTypeRef;
    static kSecCodeInfoUnique: *const c_void;
    fn SecItemCopyMatching(query: *const c_void, result: *mut CFTypeRef) -> i32;
    fn SecItemAdd(attributes: *const c_void, result: *mut CFTypeRef) -> i32;
    fn SecItemUpdate(query: *const c_void, attributes: *const c_void) -> i32;
    fn SecItemDelete(query: *const c_void) -> i32;
    // Deprecated with the file-based keychain it opens; used only for the
    // fixture scope.
    fn SecKeychainOpen(path: *const c_char, keychain: *mut CFTypeRef) -> i32;
    fn SecStaticCodeCreateWithPath(
        path: *const c_void,
        flags: u32,
        output: *mut *const c_void,
    ) -> i32;
    fn SecRequirementCreateWithString(
        text: *const c_void,
        flags: u32,
        output: *mut *const c_void,
    ) -> i32;
    fn SecStaticCodeCheckValidity(
        code: *const c_void,
        flags: u32,
        requirement: *const c_void,
    ) -> i32;
    fn SecCodeCopySigningInformation(
        code: *const c_void,
        flags: u32,
        output: *mut *const c_void,
    ) -> i32;
}

#[link(name = "objc")]
unsafe extern "C" {
    fn objc_getClass(name: *const c_char) -> *mut c_void;
    fn sel_registerName(name: *const c_char) -> *mut c_void;
    fn objc_msgSend();
}

// Linking one symbol of the framework keeps its load command, so that the
// runtime knows the `LAContext` class by name.
#[link(name = "LocalAuthentication", kind = "framework")]
unsafe extern "C" {
    static LAErrorDomain: *const c_void;
}

/// Why a Keychain call did not produce what was asked. Carries the Security
/// framework's status or a fixed refusal, never an item's value.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum KeychainError {
    /// The Security framework answered with this `OSStatus`.
    Status(i32),
    /// Refused before or after the Security call: an unusable name, value or
    /// scope, or an answer of the wrong shape.
    Refused(&'static str),
}

impl fmt::Display for KeychainError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Status(status) => write!(formatter, "Keychain status {status}"),
            Self::Refused(reason) => write!(formatter, "Keychain request refused: {reason}"),
        }
    }
}

impl std::error::Error for KeychainError {}

/// What a presence probe established about one account (Swift
/// `OpenHarmonySigningSecretPresence`). `Absent` is the Keychain positively
/// answering `errSecItemNotFound`; every other failure — a missing
/// entitlement, a refused interaction — is `Unreadable` with its status and
/// says nothing about the item.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum KeychainPresence {
    Present,
    Absent,
    Unreadable(i32),
}

enum Scope {
    DataProtection { access_group: Owned },
    OutsideDataProtection,
    File { keychain: Owned, search_list: Owned },
}

/// The generic-password items of one service in one Keychain scope.
pub struct KeychainItems {
    service: Owned,
    scope: Scope,
}

// SAFETY: the retained CoreFoundation objects are immutable strings, a
// keychain reference and an array; the Security calls that read them are
// thread-safe, and nothing here mutates them after construction.
unsafe impl Send for KeychainItems {}
// SAFETY: as above; `&KeychainItems` exposes no mutation.
unsafe impl Sync for KeychainItems {}

impl KeychainItems {
    /// The production scope: the Data Protection Keychain restricted to
    /// `access_group`, which only a process signed with that group's
    /// entitlement can reach.
    pub fn data_protection(service: &str, access_group: &str) -> Result<Self, KeychainError> {
        Ok(Self {
            service: cf_string(service)?,
            scope: Scope::DataProtection {
                access_group: cf_string(access_group)?,
            },
        })
    }

    /// Items outside the Data Protection Keychain, in the default search list.
    /// Swift touches this scope only to delete, when an explicit uninstall
    /// clears what an earlier build may have left; `set` and `read` refuse it.
    pub fn outside_data_protection(service: &str) -> Result<Self, KeychainError> {
        Ok(Self {
            service: cf_string(service)?,
            scope: Scope::OutsideDataProtection,
        })
    }

    /// A fixture scope: one file-based keychain at an exact absolute path, the
    /// only keychain its items are added to and searched in.
    pub fn file_keychain(service: &str, keychain: &Path) -> Result<Self, KeychainError> {
        if !keychain.is_absolute()
            || !std::fs::symlink_metadata(keychain).is_ok_and(|metadata| metadata.is_file())
        {
            return Err(KeychainError::Refused(
                "a fixture keychain is an existing regular file at an absolute path",
            ));
        }
        let path = CString::new(keychain.as_os_str().as_bytes())
            .map_err(|_| KeychainError::Refused("keychain path contains NUL"))?;
        let mut raw = ptr::null();
        // SAFETY: `path` is NUL-terminated and `raw` a live out pointer.
        let status = unsafe { SecKeychainOpen(path.as_ptr(), &mut raw) };
        if status != ERR_SEC_SUCCESS {
            return Err(KeychainError::Status(status));
        }
        let keychain = Owned::new(raw).ok_or(KeychainError::Refused("no keychain reference"))?;
        let values = [keychain.0];
        // SAFETY: one live value; the array retains it through its callbacks.
        let search_list = Owned::new(unsafe {
            CFArrayCreate(ptr::null(), values.as_ptr(), 1, &kCFTypeArrayCallBacks)
        })
        .ok_or(KeychainError::Refused("could not build the search list"))?;
        Ok(Self {
            service: cf_string(service)?,
            scope: Scope::File {
                keychain,
                search_list,
            },
        })
    }

    /// Swift `set(_:account:)`: rewrite the value of the existing item only,
    /// and add the item when the Keychain answers that it is absent. The
    /// added item is readable after first unlock on this device only.
    pub fn set(&self, account: &str, value: &[u8]) -> Result<(), KeychainError> {
        if matches!(self.scope, Scope::OutsideDataProtection) {
            return Err(KeychainError::Refused(
                "nothing is written outside the Data Protection Keychain",
            ));
        }
        if value.is_empty() || value.len() > MAX_VALUE_BYTES {
            return Err(KeychainError::Refused("value is empty or unbounded"));
        }
        let account = cf_string(account)?;
        let data = cf_data(value)?;
        let identity = self.identity(&account);
        let query = dictionary(&identity)?;
        // SAFETY: statics are initialised framework constants.
        let update = dictionary(&[(unsafe { kSecValueData }, data.0)])?;
        // SAFETY: both dictionaries are live for the call.
        let status = unsafe { SecItemUpdate(query.0, update.0) };
        if status == ERR_SEC_SUCCESS {
            return Ok(());
        }
        if status != ERR_SEC_ITEM_NOT_FOUND {
            return Err(KeychainError::Status(status));
        }
        let mut add = self.addition(&account);
        // SAFETY: statics are initialised framework constants.
        unsafe {
            add.push((kSecValueData, data.0));
            add.push((
                kSecAttrAccessible,
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ));
        }
        let add = dictionary(&add)?;
        // SAFETY: the dictionary is live; no result is requested.
        let status = unsafe { SecItemAdd(add.0, ptr::null_mut()) };
        if status == ERR_SEC_SUCCESS {
            Ok(())
        } else {
            Err(KeychainError::Status(status))
        }
    }

    /// Swift `read(account:)` without user interaction: the item's value, or
    /// the status that refused it.
    pub fn read(&self, account: &str) -> Result<Secret, KeychainError> {
        if matches!(self.scope, Scope::OutsideDataProtection) {
            return Err(KeychainError::Refused(
                "nothing is read outside the Data Protection Keychain",
            ));
        }
        let account = cf_string(account)?;
        let context = NonInteractiveContext::new()?;
        let mut query = self.identity(&account);
        // SAFETY: statics are initialised framework constants.
        unsafe {
            query.push((kSecReturnData, kCFBooleanTrue));
            query.push((kSecMatchLimit, kSecMatchLimitOne));
            query.push((kSecUseAuthenticationContext, context.as_value()));
        }
        let query = dictionary(&query)?;
        let mut result = ptr::null();
        // SAFETY: the query is live and `result` a live out pointer.
        let status = unsafe { SecItemCopyMatching(query.0, &mut result) };
        let result = Owned::new(result);
        if status != ERR_SEC_SUCCESS {
            return Err(KeychainError::Status(status));
        }
        let result = result.ok_or(KeychainError::Refused("the Keychain returned no value"))?;
        // SAFETY: `result` is a live CF object; its type is checked before
        // the data accessors, and the bytes are copied while it is retained.
        unsafe {
            if CFGetTypeID(result.0) != CFDataGetTypeID() {
                return Err(KeychainError::Refused("the Keychain value is not data"));
            }
            let length = CFDataGetLength(result.0);
            let length = usize::try_from(length).unwrap_or(0);
            if length == 0 || length > MAX_READ_BYTES {
                return Err(KeychainError::Refused(
                    "the Keychain value is empty or unbounded",
                ));
            }
            let bytes = std::slice::from_raw_parts(CFDataGetBytePtr(result.0), length);
            Ok(Secret::from_slice(bytes))
        }
    }

    /// Swift `presence(of:)`: attributes only, so no value is ever decrypted
    /// for a read-only question, without user interaction.
    pub fn presence(&self, account: &str) -> KeychainPresence {
        match self.presence_status(account) {
            Ok(ERR_SEC_SUCCESS) => KeychainPresence::Present,
            Ok(ERR_SEC_ITEM_NOT_FOUND) => KeychainPresence::Absent,
            Ok(status) => KeychainPresence::Unreadable(status),
            Err(_) => KeychainPresence::Unreadable(0),
        }
    }

    /// Swift `contains(account:)`: `false` both for an absent item and for a
    /// Keychain this process could not read; the three-way answer is
    /// [`KeychainItems::presence`].
    pub fn contains(&self, account: &str) -> bool {
        self.presence(account) == KeychainPresence::Present
    }

    /// Swift `remove(account:)`: `true` when an item was deleted, `false` when
    /// the Keychain answered that there was none.
    pub fn remove(&self, account: &str) -> Result<bool, KeychainError> {
        let account = cf_string(account)?;
        let query = dictionary(&self.identity(&account))?;
        // SAFETY: the query is live for the call.
        match unsafe { SecItemDelete(query.0) } {
            ERR_SEC_SUCCESS => Ok(true),
            ERR_SEC_ITEM_NOT_FOUND => Ok(false),
            status => Err(KeychainError::Status(status)),
        }
    }

    fn presence_status(&self, account: &str) -> Result<i32, KeychainError> {
        let account = cf_string(account)?;
        let context = NonInteractiveContext::new()?;
        let mut query = self.identity(&account);
        // SAFETY: statics are initialised framework constants.
        unsafe {
            query.push((kSecReturnAttributes, kCFBooleanTrue));
            query.push((kSecReturnData, kCFBooleanFalse));
            query.push((kSecMatchLimit, kSecMatchLimitOne));
            query.push((kSecUseAuthenticationContext, context.as_value()));
        }
        let query = dictionary(&query)?;
        let mut result = ptr::null();
        // SAFETY: the query is live and `result` a live out pointer.
        let status = unsafe { SecItemCopyMatching(query.0, &mut result) };
        let result = Owned::new(result);
        if status == ERR_SEC_SUCCESS
            // SAFETY: the returned object is live while `result` holds it.
            && !result.is_some_and(|result| unsafe {
                CFGetTypeID(result.0) == CFDictionaryGetTypeID()
            })
        {
            return Err(KeychainError::Refused(
                "the Keychain answered no attributes",
            ));
        }
        Ok(status)
    }

    /// Swift `query(account:dataProtection:)`: the item's identity in this
    /// scope, the query of an update and a deletion.
    fn identity(&self, account: &Owned) -> Vec<(CFTypeRef, CFTypeRef)> {
        // SAFETY: statics are initialised framework constants.
        let mut query = unsafe {
            vec![
                (kSecClass, kSecClassGenericPassword),
                (kSecAttrService, self.service.0),
                (kSecAttrAccount, account.0),
            ]
        };
        match &self.scope {
            // SAFETY: as above.
            Scope::DataProtection { access_group } => unsafe {
                query.push((kSecAttrAccessGroup, access_group.0));
                query.push((kSecUseDataProtectionKeychain, kCFBooleanTrue));
            },
            Scope::OutsideDataProtection => {}
            // SAFETY: as above.
            Scope::File { search_list, .. } => unsafe {
                query.push((kSecMatchSearchList, search_list.0));
            },
        }
        query
    }

    /// The identity of an item being added: the search list of the fixture
    /// scope becomes the keychain the item is added to.
    fn addition(&self, account: &Owned) -> Vec<(CFTypeRef, CFTypeRef)> {
        // SAFETY: statics are initialised framework constants.
        let mut attributes = unsafe {
            vec![
                (kSecClass, kSecClassGenericPassword),
                (kSecAttrService, self.service.0),
                (kSecAttrAccount, account.0),
            ]
        };
        match &self.scope {
            // SAFETY: as above.
            Scope::DataProtection { access_group } => unsafe {
                attributes.push((kSecAttrAccessGroup, access_group.0));
                attributes.push((kSecUseDataProtectionKeychain, kCFBooleanTrue));
            },
            Scope::OutsideDataProtection => {}
            // SAFETY: as above.
            Scope::File { keychain, .. } => unsafe {
                attributes.push((kSecUseKeychain, keychain.0));
            },
        }
        attributes
    }
}

/// A `LocalAuthentication` `LAContext` with `interactionNotAllowed` set, as
/// Swift `LoginKeychainSigningSecretStore.nonInteractiveReadOptions()` builds
/// it for every read; released when dropped.
struct NonInteractiveContext(*mut c_void);

type SendObject = unsafe extern "C" fn(*mut c_void, *mut c_void) -> *mut c_void;
type SendSetFlag = unsafe extern "C" fn(*mut c_void, *mut c_void, i8);
type SendGetFlag = unsafe extern "C" fn(*mut c_void, *mut c_void) -> i8;
type SendVoid = unsafe extern "C" fn(*mut c_void, *mut c_void);

fn selector(name: &'static [u8]) -> *mut c_void {
    // SAFETY: every name is a NUL-terminated literal.
    unsafe { sel_registerName(name.as_ptr().cast()) }
}

impl NonInteractiveContext {
    fn new() -> Result<Self, KeychainError> {
        // SAFETY: reading an initialised framework constant; the read keeps
        // the framework linked, and the class below is known through it.
        let linked = !std::hint::black_box(unsafe { LAErrorDomain }).is_null();
        // SAFETY: a NUL-terminated class name; nil when the class is unknown.
        let class = unsafe { objc_getClass(c"LAContext".as_ptr()) };
        if !linked || class.is_null() {
            return Err(KeychainError::Refused("LocalAuthentication is unavailable"));
        }
        // SAFETY: objc_msgSend is called through the exact prototype of each
        // message: `+new` returns a retained object, the setter takes one
        // BOOL, the getter returns one.
        unsafe {
            let send_object =
                std::mem::transmute::<unsafe extern "C" fn(), SendObject>(objc_msgSend);
            let context = send_object(class, selector(b"new\0"));
            if context.is_null() {
                return Err(KeychainError::Refused("LAContext could not be created"));
            }
            let context = Self(context);
            let set_flag = std::mem::transmute::<unsafe extern "C" fn(), SendSetFlag>(objc_msgSend);
            set_flag(context.0, selector(b"setInteractionNotAllowed:\0"), 1);
            if !context.interaction_not_allowed() {
                return Err(KeychainError::Refused(
                    "LAContext did not keep interaction disallowed",
                ));
            }
            Ok(context)
        }
    }

    fn interaction_not_allowed(&self) -> bool {
        // SAFETY: the getter's prototype returns one BOOL; the object is live.
        unsafe {
            let get_flag = std::mem::transmute::<unsafe extern "C" fn(), SendGetFlag>(objc_msgSend);
            get_flag(self.0, selector(b"interactionNotAllowed\0")) != 0
        }
    }

    fn as_value(&self) -> CFTypeRef {
        self.0.cast_const()
    }
}

impl Drop for NonInteractiveContext {
    fn drop(&mut self) {
        // SAFETY: the object came from `+new` and is released exactly once.
        unsafe {
            let release = std::mem::transmute::<unsafe extern "C" fn(), SendVoid>(objc_msgSend);
            release(self.0, selector(b"release\0"));
        }
    }
}

/// A retained CoreFoundation object, released when dropped.
struct Owned(*const c_void);

impl Owned {
    fn new(value: *const c_void) -> Option<Self> {
        // Lazily: an `Owned` of a null pointer must never exist, since its
        // drop would release it.
        (!value.is_null()).then(|| Self(value))
    }
}

impl Drop for Owned {
    fn drop(&mut self) {
        // SAFETY: every Owned is a nonnull create/copy-rule reference.
        unsafe { CFRelease(self.0) };
    }
}

fn cf_string(value: &str) -> Result<Owned, KeychainError> {
    if value.is_empty() || value.len() > MAX_NAME_BYTES || value.contains('\0') {
        return Err(KeychainError::Refused(
            "a Keychain name is empty, unbounded or contains NUL",
        ));
    }
    // SAFETY: the bytes are live for the call and the length is theirs.
    Owned::new(unsafe {
        CFStringCreateWithBytes(ptr::null(), value.as_ptr(), value.len() as isize, UTF8, 0)
    })
    .ok_or(KeychainError::Refused("could not build a Keychain name"))
}

fn cf_data(value: &[u8]) -> Result<Owned, KeychainError> {
    // SAFETY: the bytes are live for the call and the length is theirs; the
    // data object copies them.
    Owned::new(unsafe { CFDataCreate(ptr::null(), value.as_ptr(), value.len() as isize) })
        .ok_or(KeychainError::Refused("could not build a Keychain value"))
}

fn dictionary(pairs: &[(CFTypeRef, CFTypeRef)]) -> Result<Owned, KeychainError> {
    let keys: Vec<CFTypeRef> = pairs.iter().map(|pair| pair.0).collect();
    let values: Vec<CFTypeRef> = pairs.iter().map(|pair| pair.1).collect();
    if keys.iter().chain(&values).any(|value| value.is_null()) {
        return Err(KeychainError::Refused("a Keychain query entry is missing"));
    }
    // SAFETY: both arrays hold `pairs.len()` live objects; the dictionary
    // retains keys and values through the CFType callbacks.
    Owned::new(unsafe {
        CFDictionaryCreate(
            ptr::null(),
            keys.as_ptr(),
            values.as_ptr(),
            pairs.len() as isize,
            &kCFTypeDictionaryKeyCallBacks,
            &kCFTypeDictionaryValueCallBacks,
        )
    })
    .ok_or(KeychainError::Refused("could not build a Keychain query"))
}

/// Swift `LoginKeychainSigningSecretStore.trustedDaemonApplicationSHA256()`
/// without its memo: the installed daemon at `executable` must be a private,
/// executable regular file of this user at its own physical path, statically
/// valid for every architecture under the ArkDeck daemon requirement; the
/// fingerprint binds the Security framework's unique code identity
/// (`kSecCodeInfoUnique`) to the SHA-256 of the executable's bytes:
/// `SHA-256("arkdeck-keychain-trusted-application-v1\0" ‖ unique ‖ SHA-256(bytes))`,
/// lowercase hex. A signing receipt records it at installation and signing
/// refuses when it no longer matches.
///
/// An absent or unsafe file is `PermissionDenied`; a signature that does not
/// validate or an identity that cannot be read is `Other`.
pub fn trusted_daemon_fingerprint(executable: &Path) -> io::Result<String> {
    let unsafe_file = || {
        io::Error::new(
            io::ErrorKind::PermissionDenied,
            "installed arkdeck-agentd helper is absent or unsafe",
        )
    };
    let refused = |message: &'static str| io::Error::other(message);
    let metadata = std::fs::symlink_metadata(executable).map_err(|_| unsafe_file())?;
    if !executable.is_absolute()
        || executable.canonicalize().map_err(|_| unsafe_file())? != executable
        || !metadata.file_type().is_file()
        || metadata.uid() != crate::effective_user_id()
        || metadata.mode() & 0o077 != 0
        || !crate::executable_by_caller(executable)
    {
        return Err(unsafe_file());
    }
    let bytes = executable.as_os_str().as_bytes();
    // SAFETY: the path bytes are live for the call.
    let url = Owned::new(unsafe {
        CFURLCreateFromFileSystemRepresentation(
            ptr::null(),
            bytes.as_ptr(),
            bytes.len() as isize,
            0,
        )
    })
    .ok_or_else(|| refused("could not inspect arkdeck-agentd signing identity"))?;
    let mut raw = ptr::null();
    // SAFETY: the URL is live and `raw` a live out pointer.
    let status = unsafe { SecStaticCodeCreateWithPath(url.0, 0, &mut raw) };
    let code = Owned::new(raw);
    let code = match code {
        Some(code) if status == ERR_SEC_SUCCESS => code,
        _ => return Err(refused("could not inspect arkdeck-agentd signing identity")),
    };
    let requirement_text = cf_string(DAEMON_CODE_REQUIREMENT)
        .map_err(|_| refused("could not construct the ArkDeck daemon code requirement"))?;
    let mut raw = ptr::null();
    // SAFETY: the text is live and `raw` a live out pointer.
    let status = unsafe { SecRequirementCreateWithString(requirement_text.0, 0, &mut raw) };
    let requirement = match Owned::new(raw) {
        Some(requirement) if status == ERR_SEC_SUCCESS => requirement,
        _ => {
            return Err(refused(
                "could not construct the ArkDeck daemon code requirement",
            ));
        }
    };
    // SAFETY: code and requirement are live for the call.
    if unsafe { SecStaticCodeCheckValidity(code.0, VALIDATION_FLAGS, requirement.0) }
        != ERR_SEC_SUCCESS
    {
        return Err(refused("arkdeck-agentd code signature is invalid"));
    }
    let mut raw = ptr::null();
    // SAFETY: the code is live and `raw` a live out pointer.
    let status = unsafe { SecCodeCopySigningInformation(code.0, SIGNING_INFORMATION, &mut raw) };
    let information = match Owned::new(raw) {
        Some(information) if status == ERR_SEC_SUCCESS => information,
        _ => return Err(refused("could not read arkdeck-agentd code identity")),
    };
    // SAFETY: the dictionary is live and type-checked before the lookup; the
    // borrowed value lives while the dictionary does and is copied out.
    let unique = unsafe {
        if CFGetTypeID(information.0) != CFDictionaryGetTypeID() {
            return Err(refused("could not read arkdeck-agentd code identity"));
        }
        let value = CFDictionaryGetValue(information.0, kSecCodeInfoUnique);
        if value.is_null() || CFGetTypeID(value) != CFDataGetTypeID() {
            return Err(refused("could not read arkdeck-agentd code identity"));
        }
        let length = usize::try_from(CFDataGetLength(value)).unwrap_or(0);
        if length == 0 || length > 1024 {
            return Err(refused("could not read arkdeck-agentd code identity"));
        }
        std::slice::from_raw_parts(CFDataGetBytePtr(value), length).to_vec()
    };
    let mut file = std::fs::File::open(executable)?;
    let mut hasher = Sha256::new();
    let mut buffer = vec![0u8; 64 * 1024];
    loop {
        let count = file.read(&mut buffer)?;
        if count == 0 {
            break;
        }
        hasher.update(&buffer[..count]);
    }
    let executable_sha256 = hasher.finalize();
    let mut fingerprint = Sha256::new();
    fingerprint.update(FINGERPRINT_DOMAIN);
    fingerprint.update(&unique);
    fingerprint.update(executable_sha256);
    Ok(fingerprint
        .finalize()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect())
}

#[cfg(test)]
mod tests {
    use super::NonInteractiveContext;

    /// Swift `testLoginKeychainReadsUseOnlyModernNonInteractiveAuthenticationContext`:
    /// every read carries an `LAContext` that refuses interaction.
    #[test]
    fn the_read_policy_is_an_lacontext_that_disallows_interaction() {
        let context = NonInteractiveContext::new().expect("LAContext");
        assert!(context.interaction_not_allowed());
        assert!(!context.as_value().is_null());
    }
}
