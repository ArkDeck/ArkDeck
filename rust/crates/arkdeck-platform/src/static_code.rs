//! Swift `ProductionArkTraceDistributionTrustChecker.validateCode`: one
//! signed bundle or executable checked by the Security framework against a
//! code requirement (strict validation, every architecture, nested code when
//! asked), then its signing information held to what a reviewer pinned — the
//! team, the hardened runtime, the code directory hash, the leaf
//! certificate's subject summary and SHA-1, and the identifier when one is
//! named. Nothing is executed or assessed beyond the static signature.
use std::ffi::c_void;
use std::os::unix::ffi::OsStrExt;
use std::path::Path;
use std::ptr;

#[link(name = "CoreFoundation", kind = "framework")]
unsafe extern "C" {
    fn CFRelease(value: *const c_void);
    fn CFGetTypeID(value: *const c_void) -> usize;
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
    fn CFStringGetMaximumSizeForEncoding(length: isize, encoding: u32) -> isize;
    fn CFStringGetCString(value: *const c_void, buffer: *mut i8, size: isize, encoding: u32) -> u8;
    fn CFDictionaryGetTypeID() -> usize;
    fn CFDictionaryGetValue(dictionary: *const c_void, key: *const c_void) -> *const c_void;
    fn CFArrayGetTypeID() -> usize;
    fn CFArrayGetCount(array: *const c_void) -> isize;
    fn CFArrayGetValueAtIndex(array: *const c_void, index: isize) -> *const c_void;
    fn CFNumberGetTypeID() -> usize;
    fn CFNumberGetValue(number: *const c_void, kind: isize, output: *mut c_void) -> u8;
    fn CFDataGetTypeID() -> usize;
    fn CFDataGetLength(data: *const c_void) -> isize;
    fn CFDataGetBytePtr(data: *const c_void) -> *const u8;
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
    fn SecCertificateCopySubjectSummary(certificate: *const c_void) -> *const c_void;
    fn SecCertificateCopyData(certificate: *const c_void) -> *const c_void;
    static kSecCodeInfoTeamIdentifier: *const c_void;
    static kSecCodeInfoFlags: *const c_void;
    static kSecCodeInfoUnique: *const c_void;
    static kSecCodeInfoCertificates: *const c_void;
    static kSecCodeInfoIdentifier: *const c_void;
}

unsafe extern "C" {
    /// CommonCrypto's SHA-1, in libSystem.
    fn CC_SHA1(data: *const c_void, length: u32, digest: *mut u8) -> *mut u8;
}

/// `kCFStringEncodingUTF8`.
const UTF8: u32 = 0x0800_0100;
/// `kCFNumberSInt64Type`.
const SINT64: isize = 4;
/// `kSecCSCheckAllArchitectures`, `kSecCSCheckNestedCode`, `kSecCSStrictValidate`.
const CHECK_ALL_ARCHITECTURES: u32 = 1 << 0;
const CHECK_NESTED_CODE: u32 = 1 << 3;
const STRICT_VALIDATE: u32 = 1 << 4;
/// `kSecCSSigningInformation | kSecCSRequirementInformation`.
const SIGNING_AND_REQUIREMENT_INFORMATION: u32 = (1 << 1) | (1 << 2);
/// `kSecCodeSignatureRuntime`.
const HARDENED_RUNTIME: i64 = 0x0001_0000;

struct Owned(*const c_void);
impl Drop for Owned {
    fn drop(&mut self) {
        // SAFETY: constructed only for a nonnull create- or copy-rule object.
        unsafe { CFRelease(self.0) };
    }
}

fn owned(value: *const c_void) -> Option<Owned> {
    (!value.is_null()).then_some(Owned(value))
}

fn cf_string(text: &str) -> Option<Owned> {
    // SAFETY: the bytes are live for the call; the result is owned.
    owned(unsafe {
        CFStringCreateWithBytes(ptr::null(), text.as_ptr(), text.len() as isize, UTF8, 0)
    })
}

/// A borrowed CFString's UTF-8 text.
fn text(value: *const c_void) -> Option<String> {
    // SAFETY: value is null or a live borrowed object; its type is checked
    // before it is read as a string, into a buffer of the size it asks for.
    unsafe {
        if value.is_null() || CFGetTypeID(value) != CFStringGetTypeID() {
            return None;
        }
        let size = CFStringGetMaximumSizeForEncoding(CFStringGetLength(value), UTF8) + 1;
        let mut buffer = vec![0i8; usize::try_from(size).ok()?];
        if CFStringGetCString(value, buffer.as_mut_ptr(), size, UTF8) == 0 {
            return None;
        }
        let bytes: Vec<u8> = buffer
            .iter()
            .take_while(|byte| **byte != 0)
            .map(|byte| *byte as u8)
            .collect();
        String::from_utf8(bytes).ok()
    }
}

/// A borrowed CFData's bytes.
fn data(value: *const c_void) -> Option<Vec<u8>> {
    // SAFETY: value is null or a live borrowed object; its type is checked
    // before its bytes are copied.
    unsafe {
        if value.is_null() || CFGetTypeID(value) != CFDataGetTypeID() {
            return None;
        }
        let length = usize::try_from(CFDataGetLength(value)).ok()?;
        let bytes = CFDataGetBytePtr(value);
        if bytes.is_null() {
            return (length == 0).then(Vec::new);
        }
        Some(std::slice::from_raw_parts(bytes, length).to_vec())
    }
}

fn number(value: *const c_void) -> Option<i64> {
    // SAFETY: value is null or a live borrowed object; its type is checked
    // before it is read into an owned 64-bit integer.
    unsafe {
        if value.is_null() || CFGetTypeID(value) != CFNumberGetTypeID() {
            return None;
        }
        let mut output: i64 = 0;
        (CFNumberGetValue(value, SINT64, (&mut output as *mut i64).cast()) != 0).then_some(output)
    }
}

fn hex(bytes: &[u8], uppercase: bool) -> String {
    bytes
        .iter()
        .map(|byte| {
            if uppercase {
                format!("{byte:02X}")
            } else {
                format!("{byte:02x}")
            }
        })
        .collect()
}

/// What one signature must be, besides valid against `requirement`.
pub struct StaticCodeExpectation<'a> {
    /// A code requirement in the Security framework's language.
    pub requirement: &'a str,
    /// The leaf certificate's subject summary.
    pub identity: &'a str,
    pub team_identifier: &'a str,
    /// The leaf certificate's SHA-1, uppercase hexadecimal.
    pub certificate_sha1: &'a str,
    /// The code directory hash (`kSecCodeInfoUnique`), lowercase hexadecimal.
    pub code_directory_hash: &'a str,
    /// Validate nested code too (`kSecCSCheckNestedCode`), as for a bundle.
    pub check_nested_code: bool,
    /// The signing identifier, when one is required.
    pub identifier: Option<&'a str>,
}

/// Swift `validateCode(at:requirement:...)`: `true` only when every check
/// holds. `directory` is the URL's directory hint.
pub fn static_code_holds(
    path: &Path,
    directory: bool,
    expected: &StaticCodeExpectation<'_>,
) -> bool {
    let bytes = path.as_os_str().as_bytes();
    // SAFETY: every Core Foundation and Security call receives live, typed
    // objects; each create- or copy-rule result is owned and released, and
    // each borrowed value is read within its owner's lifetime after its type
    // is checked.
    unsafe {
        let Some(url) = owned(CFURLCreateFromFileSystemRepresentation(
            ptr::null(),
            bytes.as_ptr(),
            bytes.len() as isize,
            u8::from(directory),
        )) else {
            return false;
        };
        let mut code = ptr::null();
        if SecStaticCodeCreateWithPath(url.0, 0, &mut code) != 0 {
            return false;
        }
        let Some(code) = owned(code) else {
            return false;
        };
        let Some(requirement_text) = cf_string(expected.requirement) else {
            return false;
        };
        let mut requirement = ptr::null();
        if SecRequirementCreateWithString(requirement_text.0, 0, &mut requirement) != 0 {
            return false;
        }
        let Some(requirement) = owned(requirement) else {
            return false;
        };
        let mut flags = STRICT_VALIDATE | CHECK_ALL_ARCHITECTURES;
        if expected.check_nested_code {
            flags |= CHECK_NESTED_CODE;
        }
        if SecStaticCodeCheckValidity(code.0, flags, requirement.0) != 0 {
            return false;
        }
        let mut information = ptr::null();
        if SecCodeCopySigningInformation(
            code.0,
            SIGNING_AND_REQUIREMENT_INFORMATION,
            &mut information,
        ) != 0
        {
            return false;
        }
        let Some(information) = owned(information) else {
            return false;
        };
        if CFGetTypeID(information.0) != CFDictionaryGetTypeID() {
            return false;
        }
        let field = |key: *const c_void| CFDictionaryGetValue(information.0, key);
        if text(field(kSecCodeInfoTeamIdentifier)).as_deref() != Some(expected.team_identifier) {
            return false;
        }
        if !number(field(kSecCodeInfoFlags)).is_some_and(|flags| flags & HARDENED_RUNTIME != 0) {
            return false;
        }
        if data(field(kSecCodeInfoUnique))
            .map(|unique| hex(&unique, false))
            .as_deref()
            != Some(expected.code_directory_hash)
        {
            return false;
        }
        let certificates = field(kSecCodeInfoCertificates);
        if certificates.is_null()
            || CFGetTypeID(certificates) != CFArrayGetTypeID()
            || CFArrayGetCount(certificates) < 1
        {
            return false;
        }
        let leaf = CFArrayGetValueAtIndex(certificates, 0);
        if leaf.is_null() {
            return false;
        }
        let Some(summary) = owned(SecCertificateCopySubjectSummary(leaf)) else {
            return false;
        };
        if text(summary.0).as_deref() != Some(expected.identity) {
            return false;
        }
        let Some(certificate) = owned(SecCertificateCopyData(leaf)) else {
            return false;
        };
        let Some(certificate) = data(certificate.0) else {
            return false;
        };
        let Ok(length) = u32::try_from(certificate.len()) else {
            return false;
        };
        let mut digest = [0u8; 20];
        CC_SHA1(certificate.as_ptr().cast(), length, digest.as_mut_ptr());
        if hex(&digest, true) != expected.certificate_sha1 {
            return false;
        }
        match expected.identifier {
            Some(identifier) => text(field(kSecCodeInfoIdentifier)).as_deref() == Some(identifier),
            None => true,
        }
    }
}
