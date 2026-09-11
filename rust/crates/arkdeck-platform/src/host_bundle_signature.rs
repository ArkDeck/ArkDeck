//! Static production-daemon Bundle validation, matching LaunchAgentService.
//!
//! No candidate is executed, assessed for notarization, installed or signed.
//! Callers must bind the complete tree and root identity before/after this step.
use std::{
    ffi::{CString, c_void},
    fs::File,
    io::{self, Read},
    os::unix::{ffi::OsStrExt, fs::OpenOptionsExt},
    path::{Path, PathBuf},
    ptr,
};

pub const DAEMON_TEAM_IDENTIFIER: &str = "8AQTYW5FKR";
pub const DAEMON_BUNDLE_IDENTIFIER: &str = "com.arkdeck.agentd";
pub const DAEMON_EXECUTABLE_NAME: &str = "arkdeck-agentd";
pub const DAEMON_APPLICATION_IDENTIFIER: &str = "8AQTYW5FKR.com.arkdeck.agentd";
pub const DAEMON_KEYCHAIN_ACCESS_GROUP: &str = "8AQTYW5FKR.com.arkdeck.shared";
pub const DAEMON_CODE_REQUIREMENT: &str = "anchor apple generic and certificate leaf[subject.OU] = \"8AQTYW5FKR\" and identifier \"com.arkdeck.agentd\"";
const MAX_INFO_BYTES: usize = 1024 * 1024;
const MAX_PATH_BYTES: usize = 16_384;
const MAX_KEYCHAIN_GROUPS: isize = 1024;
const MAX_GROUP_UTF16: isize = 4096;
const UTF8: u32 = 0x08000100;
// Current SDK SecStaticCode.h: strict validation and every architecture;
// deliberately do not set kSecCSDoNotValidateResources.
const VALIDATION_FLAGS: u32 = (1 << 4) | 1;
const SIGNING_INFORMATION: u32 = 1 << 1;
const HARDENED_RUNTIME: u32 = 0x0001_0000;

#[link(name = "CoreFoundation", kind = "framework")]
unsafe extern "C" {
    fn CFRelease(value: *const c_void);
    fn CFGetTypeID(value: *const c_void) -> usize;
    fn CFEqual(left: *const c_void, right: *const c_void) -> u8;
    fn CFURLCreateFromFileSystemRepresentation(
        allocator: *const c_void,
        bytes: *const u8,
        length: isize,
        directory: u8,
    ) -> *const c_void;
    fn CFStringCreateWithBytes(
        allocator: *const c_void,
        bytes: *const u8,
        length: isize,
        encoding: u32,
        external: u8,
    ) -> *const c_void;
    fn CFStringGetTypeID() -> usize;
    fn CFStringGetLength(value: *const c_void) -> isize;
    fn CFStringGetCString(value: *const c_void, buffer: *mut i8, size: isize, encoding: u32) -> u8;
    fn CFDataCreate(allocator: *const c_void, bytes: *const u8, length: isize) -> *const c_void;
    fn CFPropertyListCreateWithData(
        allocator: *const c_void,
        data: *const c_void,
        options: usize,
        format: *mut isize,
        error: *mut *const c_void,
    ) -> *const c_void;
    fn CFDictionaryGetTypeID() -> usize;
    fn CFDictionaryGetValue(dictionary: *const c_void, key: *const c_void) -> *const c_void;
    fn CFArrayGetTypeID() -> usize;
    fn CFArrayGetCount(array: *const c_void) -> isize;
    fn CFArrayGetValueAtIndex(array: *const c_void, index: isize) -> *const c_void;
    fn CFNumberGetTypeID() -> usize;
    fn CFNumberGetValue(number: *const c_void, kind: isize, output: *mut c_void) -> u8;
}
#[link(name = "Security", kind = "framework")]
unsafe extern "C" {
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
    static kSecCodeInfoTeamIdentifier: *const c_void;
    static kSecCodeInfoEntitlementsDict: *const c_void;
    static kSecCodeInfoFlags: *const c_void;
}
struct Owned(*const c_void);
impl Owned {
    fn new(value: *const c_void) -> io::Result<Self> {
        if value.is_null() {
            Err(refused("native Bundle metadata is unreadable"))
        } else {
            Ok(Self(value))
        }
    }
}
impl Drop for Owned {
    fn drop(&mut self) {
        // SAFETY: Owned is exclusively a nonnull CF create/copy-rule reference.
        unsafe { CFRelease(self.0) };
    }
}
fn refused(message: impl Into<Box<dyn std::error::Error + Send + Sync>>) -> io::Error {
    io::Error::new(io::ErrorKind::PermissionDenied, message)
}
fn string(value: &str) -> io::Result<Owned> {
    // SAFETY: all callers pass bounded literals; bytes are live for this call.
    Owned::new(unsafe {
        CFStringCreateWithBytes(ptr::null(), value.as_ptr(), value.len() as isize, UTF8, 0)
    })
}
// Borrowed CF values never leave the scope of their owning dictionary or plist.
fn string_equals(value: *const c_void, expected: &Owned, expected_length: usize) -> bool {
    // SAFETY: value is null or a live borrowed dictionary/array entry. Type and
    // exact length are checked before CFEqual; the expected value is owned.
    unsafe {
        !value.is_null()
            && CFGetTypeID(value) == CFStringGetTypeID()
            && CFStringGetLength(value) == expected_length as isize
            && CFEqual(value, expected.0) != 0
    }
}
fn dictionary(value: *const c_void) -> io::Result<*const c_void> {
    // SAFETY: value is null or a live CF result or borrowed dictionary entry.
    if unsafe { value.is_null() || CFGetTypeID(value) != CFDictionaryGetTypeID() } {
        Err(refused("Bundle metadata is not a dictionary"))
    } else {
        Ok(value)
    }
}
fn info_identity(bytes: &[u8]) -> io::Result<()> {
    if bytes.is_empty() || bytes.len() > MAX_INFO_BYTES {
        return Err(refused("helper Info.plist exceeds its byte bound"));
    }
    // SAFETY: bounded input buffer; plist and data use immutable create-rule
    // objects. No untrusted dictionary is enumerated or converted to Rust data.
    unsafe {
        let data = Owned::new(CFDataCreate(
            ptr::null(),
            bytes.as_ptr(),
            bytes.len() as isize,
        ))?;
        let plist = Owned::new(CFPropertyListCreateWithData(
            ptr::null(),
            data.0,
            0,
            ptr::null_mut(),
            ptr::null_mut(),
        ))?;
        let fields = dictionary(plist.0)?;
        for (key, expected) in [
            ("CFBundleIdentifier", DAEMON_BUNDLE_IDENTIFIER),
            ("CFBundleExecutable", DAEMON_EXECUTABLE_NAME),
        ] {
            let key = string(key)?;
            let expected_cf = string(expected)?;
            if !string_equals(
                CFDictionaryGetValue(fields, key.0),
                &expected_cf,
                expected.len(),
            ) {
                return Err(refused(
                    "arkdeck-agentd helper Info.plist identity is invalid",
                ));
            }
        }
    }
    Ok(())
}
/// Parse only the current Bundle registry's optional version field. Input is
/// bounded before CF parsing; output is printable ASCII with at most 128 bytes.
pub fn bootstrap_bundle_version(bytes: &[u8]) -> io::Result<Option<String>> {
    if bytes.is_empty() || bytes.len() > 64 * 1024 {
        return Err(refused("bundle Info.plist exceeds its version-read bound"));
    }
    // SAFETY: bounded immutable CFData/plist objects have RAII owners; all
    // borrowed fields are type checked before bounded CString conversion.
    unsafe {
        let data = Owned::new(CFDataCreate(
            ptr::null(),
            bytes.as_ptr(),
            bytes.len() as isize,
        ))?;
        let plist = Owned::new(CFPropertyListCreateWithData(
            ptr::null(),
            data.0,
            0,
            ptr::null_mut(),
            ptr::null_mut(),
        ))?;
        let fields = dictionary(plist.0)?;
        let key = string("CFBundleShortVersionString")?;
        let value = CFDictionaryGetValue(fields, key.0);
        if value.is_null() {
            return Ok(None);
        }
        if CFGetTypeID(value) != CFStringGetTypeID()
            || !(1..=128).contains(&CFStringGetLength(value))
        {
            return Err(refused(
                "bundle version is outside the bounded string schema",
            ));
        }
        let mut buffer = [0u8; 129];
        if CFStringGetCString(
            value,
            buffer.as_mut_ptr().cast(),
            buffer.len() as isize,
            UTF8,
        ) == 0
        {
            return Err(refused("bundle version exceeds its byte bound"));
        }
        let length = CFStringGetLength(value) as usize;
        if !buffer[..length].iter().all(|byte| (32..127).contains(byte)) || buffer[length] != 0 {
            return Err(refused("bundle version must contain printable ASCII"));
        }
        Ok(Some(
            std::str::from_utf8(&buffer[..length])
                .map_err(|_| refused("bundle version is unreadable"))?
                .to_owned(),
        ))
    }
}

fn read_info(path: &Path) -> io::Result<Vec<u8>> {
    // O_NONBLOCK prevents a hostile FIFO from blocking before its type check.
    // Symlink resolution follows the Swift validator; the owner binds the tree.
    let file = File::options()
        .read(true)
        .custom_flags(libc::O_NONBLOCK)
        .open(path)?;
    let metadata = file.metadata()?;
    if !metadata.is_file() || metadata.len() > MAX_INFO_BYTES as u64 {
        return Err(refused(
            "helper Info.plist exceeds its regular-file byte bound",
        ));
    }
    let mut bytes = Vec::new();
    file.take(MAX_INFO_BYTES as u64 + 1)
        .read_to_end(&mut bytes)?;
    if bytes.len() > MAX_INFO_BYTES {
        return Err(refused("helper Info.plist exceeds its byte bound"));
    }
    Ok(bytes)
}
fn signing_information(code: &Owned) -> io::Result<()> {
    // SAFETY: code is owned. Every borrowed field is type checked before access;
    // all string comparison and array iteration is explicitly bounded.
    unsafe {
        let mut raw = ptr::null();
        let status = SecCodeCopySigningInformation(code.0, SIGNING_INFORMATION, &mut raw);
        let information = Owned::new(raw)?;
        if status != 0 {
            return Err(refused(format!(
                "helper signing information is unreadable (status {status})"
            )));
        }
        let fields = dictionary(information.0)?;
        let team = string(DAEMON_TEAM_IDENTIFIER)?;
        if !string_equals(
            CFDictionaryGetValue(fields, kSecCodeInfoTeamIdentifier),
            &team,
            DAEMON_TEAM_IDENTIFIER.len(),
        ) {
            return Err(refused("helper signing team does not match ArkDeck"));
        }
        let entitlements = dictionary(CFDictionaryGetValue(fields, kSecCodeInfoEntitlementsDict))?;
        let application_key = string("com.apple.application-identifier")?;
        let application = string(DAEMON_APPLICATION_IDENTIFIER)?;
        if !string_equals(
            CFDictionaryGetValue(entitlements, application_key.0),
            &application,
            DAEMON_APPLICATION_IDENTIFIER.len(),
        ) {
            return Err(refused(
                "helper application identifier entitlement does not match ArkDeck",
            ));
        }
        let groups_key = string("keychain-access-groups")?;
        let groups = CFDictionaryGetValue(entitlements, groups_key.0);
        if groups.is_null() || CFGetTypeID(groups) != CFArrayGetTypeID() {
            return Err(refused(
                "helper shared Keychain group entitlement is unreadable",
            ));
        }
        let count = CFArrayGetCount(groups);
        if !(1..=MAX_KEYCHAIN_GROUPS).contains(&count) {
            return Err(refused("helper Keychain groups exceed their array bound"));
        }
        let expected = string(DAEMON_KEYCHAIN_ACCESS_GROUP)?;
        let mut found = false;
        for index in 0..count {
            let value = CFArrayGetValueAtIndex(groups, index);
            if value.is_null()
                || CFGetTypeID(value) != CFStringGetTypeID()
                || !(0..=MAX_GROUP_UTF16).contains(&CFStringGetLength(value))
            {
                return Err(refused("helper Keychain groups must be bounded strings"));
            }
            found |= string_equals(value, &expected, DAEMON_KEYCHAIN_ACCESS_GROUP.len());
        }
        if !found {
            return Err(refused("helper lacks the shared Keychain group"));
        }
        let flags = CFDictionaryGetValue(fields, kSecCodeInfoFlags);
        if flags.is_null() || CFGetTypeID(flags) != CFNumberGetTypeID() {
            return Err(refused("helper signing flags are unreadable"));
        }
        let mut value = 0i64;
        // kCFNumberSInt64Type = 4, as in the current CoreFoundation headers.
        if CFNumberGetValue(flags, 4, (&mut value as *mut i64).cast()) == 0
            || !(0..=u32::MAX as i64).contains(&value)
            || value as u32 & HARDENED_RUNTIME == 0
        {
            return Err(refused("helper lacks hardened runtime"));
        }
    }
    Ok(())
}

/// Validate the current ArkDeck production-daemon Bundle and return its resolved
/// path. This is one static check inside the owner's before/after tree snapshot;
/// it does not itself prove content stability or mint a durable trust record.
pub fn validate_production_daemon_bundle(candidate: &Path) -> io::Result<PathBuf> {
    if !candidate.is_absolute()
        || candidate.as_os_str().as_bytes().len() > MAX_PATH_BYTES
        || candidate.as_os_str().as_bytes().contains(&0)
    {
        return Err(refused(
            "arkdeck-agentd helper bundle path must be bounded and absolute",
        ));
    }
    let canonical = candidate.canonicalize()?;
    if !canonical.is_dir() || canonical.extension().is_none_or(|ext| ext != "app") {
        return Err(refused(
            "arkdeck-agentd must be supplied as an app-like helper bundle",
        ));
    }
    let path_bytes = canonical.as_os_str().as_bytes();
    if path_bytes.len() > MAX_PATH_BYTES {
        return Err(refused(
            "resolved helper bundle path exceeds its byte bound",
        ));
    }
    info_identity(&read_info(&canonical.join("Contents/Info.plist"))?)?;
    let executable = canonical
        .join("Contents/MacOS")
        .join(DAEMON_EXECUTABLE_NAME);
    let executable_path = CString::new(executable.as_os_str().as_bytes())
        .map_err(|_| refused("helper executable path is invalid"))?;
    // SAFETY: NUL-terminated path. access performs a permission query only.
    if executable.metadata()?.is_dir()
        || unsafe { libc::access(executable_path.as_ptr(), libc::X_OK) } != 0
    {
        return Err(refused(
            "arkdeck-agentd helper executable is missing or is not executable",
        ));
    }
    // SAFETY: paths/literals remain live, and every nonnull create-rule result
    // receives an RAII owner. Validation is of the Bundle, not just its binary.
    unsafe {
        let url = Owned::new(CFURLCreateFromFileSystemRepresentation(
            ptr::null(),
            path_bytes.as_ptr(),
            path_bytes.len() as isize,
            1,
        ))?;
        let mut raw = ptr::null();
        let status = SecStaticCodeCreateWithPath(url.0, 0, &mut raw);
        let code = Owned::new(raw)?;
        if status != 0 {
            return Err(refused(format!(
                "helper signature is unreadable (status {status})"
            )));
        }
        let requirement_text = string(DAEMON_CODE_REQUIREMENT)?;
        let mut raw = ptr::null();
        let status = SecRequirementCreateWithString(requirement_text.0, 0, &mut raw);
        let requirement = Owned::new(raw)?;
        if status != 0 {
            return Err(refused(format!(
                "helper requirement is invalid (status {status})"
            )));
        }
        let status = SecStaticCodeCheckValidity(code.0, VALIDATION_FLAGS, requirement.0);
        if status != 0 {
            return Err(refused(format!(
                "arkdeck-agentd helper signature does not match ArkDeck (status {status})"
            )));
        }
        signing_information(&code)?;
    }
    // Match the current acceptance condition: presence only. Profile parsing or
    // notarization would introduce a new condition and is intentionally absent.
    if !canonical
        .join("Contents/embedded.provisionprofile")
        .exists()
    {
        return Err(refused("helper lacks its embedded provisioning profile"));
    }
    Ok(canonical)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{fs, os::unix::fs::PermissionsExt};
    struct Bundle(PathBuf);
    impl Bundle {
        fn new() -> Self {
            let nonce = crate::random_bytes::<16>()
                .unwrap()
                .iter()
                .map(|b| format!("{b:02x}"))
                .collect::<String>();
            let root = PathBuf::from(format!("/private/tmp/arkdeck-bundle-trust-{nonce}.app"));
            fs::create_dir_all(root.join("Contents/MacOS")).unwrap();
            Self(root)
        }
        fn info(&self, bytes: &[u8]) {
            fs::write(self.0.join("Contents/Info.plist"), bytes).unwrap();
        }
    }
    impl Drop for Bundle {
        fn drop(&mut self) {
            fs::remove_dir_all(&self.0).unwrap();
        }
    }
    fn info(id: &str, executable: &str) -> Vec<u8> {
        format!("<?xml version=\"1.0\" encoding=\"UTF-8\"?><!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\"><plist version=\"1.0\"><dict><key>CFBundleIdentifier</key><string>{id}</string><key>CFBundleExecutable</key><string>{executable}</string></dict></plist>").into_bytes()
    }
    #[test]
    fn info_plist_requires_dictionary_and_exact_typed_identity_with_a_byte_bound() {
        info_identity(&info(DAEMON_BUNDLE_IDENTIFIER, DAEMON_EXECUTABLE_NAME)).unwrap();
        for bytes in [
            vec![],
            b"not a plist".to_vec(),
            b"<plist><array/></plist>".to_vec(),
            info("com.apple.true", DAEMON_EXECUTABLE_NAME),
            info(DAEMON_BUNDLE_IDENTIFIER, "caller-executable"),
            info(DAEMON_BUNDLE_IDENTIFIER, DAEMON_EXECUTABLE_NAME)[..40].to_vec(),
            vec![b' '; MAX_INFO_BYTES + 1],
        ] {
            assert!(info_identity(&bytes).is_err());
        }
        assert!(info_identity(b"<plist><dict><key>CFBundleIdentifier</key><integer>1</integer><key>CFBundleExecutable</key><string>arkdeck-agentd</string></dict></plist>").is_err());
    }
    #[test]
    fn bundle_version_matches_the_optional_ascii_swift_schema() {
        assert_eq!(
            bootstrap_bundle_version(b"<plist><dict/></plist>").unwrap(),
            None
        );
        for value in ["1.2.3".to_owned(), "a".repeat(128)] {
            let bytes = format!(
                "<plist><dict><key>CFBundleShortVersionString</key><string>{value}</string></dict></plist>"
            );
            assert_eq!(
                bootstrap_bundle_version(bytes.as_bytes()).unwrap(),
                Some(value)
            );
        }
        for value in [
            "".to_owned(),
            "é".to_owned(),
            "a".repeat(129),
            "line\nfeed".to_owned(),
        ] {
            let bytes = format!(
                "<plist><dict><key>CFBundleShortVersionString</key><string>{value}</string></dict></plist>"
            );
            assert!(bootstrap_bundle_version(bytes.as_bytes()).is_err());
        }
        for bytes in [b"<plist><array/></plist>".as_slice(),b"<plist><dict><key>CFBundleShortVersionString</key><integer>1</integer></dict></plist>".as_slice()] {
            assert!(bootstrap_bundle_version(bytes).is_err());
        }
        assert!(bootstrap_bundle_version(&vec![b' '; 64 * 1024 + 1]).is_err());
    }

    #[test]
    fn malformed_bundle_and_nonexecutable_are_refused_before_signing() {
        assert!(validate_production_daemon_bundle(Path::new("relative.app")).is_err());
        assert!(validate_production_daemon_bundle(Path::new("/usr/bin/true")).is_err());
        let bundle = Bundle::new();
        bundle.info(b"broken plist");
        assert!(validate_production_daemon_bundle(&bundle.0).is_err());
        bundle.info(&info(DAEMON_BUNDLE_IDENTIFIER, DAEMON_EXECUTABLE_NAME));
        assert!(validate_production_daemon_bundle(&bundle.0).is_err());
        let executable = bundle.0.join("Contents/MacOS/arkdeck-agentd");
        fs::write(&executable, b"not executable").unwrap();
        fs::set_permissions(&executable, fs::Permissions::from_mode(0o600)).unwrap();
        assert!(
            validate_production_daemon_bundle(&bundle.0)
                .unwrap_err()
                .to_string()
                .contains("not executable")
        );
        fs::write(
            bundle.0.join("Contents/Info.plist"),
            vec![b' '; MAX_INFO_BYTES + 1],
        )
        .unwrap();
        assert!(
            validate_production_daemon_bundle(&bundle.0)
                .unwrap_err()
                .to_string()
                .contains("byte bound")
        );
    }
    #[test]
    fn actual_wrong_signed_identity_cannot_become_daemon_by_renaming_or_info_plist() {
        let bundle = Bundle::new();
        bundle.info(&info(DAEMON_BUNDLE_IDENTIFIER, DAEMON_EXECUTABLE_NAME));
        // Copy a real, Apple-signed system binary solely as a negative fixture.
        // No signer is injected and the copied program is never launched.
        let executable = bundle.0.join("Contents/MacOS/arkdeck-agentd");
        fs::copy("/usr/bin/true", &executable).unwrap();
        let original = fs::read(&executable).unwrap();
        let error = validate_production_daemon_bundle(&bundle.0).unwrap_err();
        assert!(error.to_string().contains("signature"), "{error}");
        assert_eq!(fs::read(&executable).unwrap(), original);
        fs::write(&executable, b"damaged Mach-O").unwrap();
        assert!(validate_production_daemon_bundle(&bundle.0).is_err());
    }
    #[test]
    #[ignore = "requires an existing real signed daemon Bundle, never a signing fixture"]
    fn explicitly_provided_real_daemon_bundle_is_statically_validated() {
        let path = std::env::var_os("ARKDECK_TEST_SIGNED_DAEMON_BUNDLE")
            .expect("provide the existing real daemon Bundle path");
        let path = PathBuf::from(path);
        let resolved = validate_production_daemon_bundle(&path).unwrap();
        assert_eq!(resolved, path.canonicalize().unwrap());
        println!(
            "Real daemon Bundle passed static production identity validation: {}",
            resolved.display()
        );
    }
}
