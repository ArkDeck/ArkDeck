//! Read-only macOS signing metadata used by bootstrap content inspection.
//! This does not assess execution, clear quarantine or grant Provider support.
use sha2::{Digest, Sha256};
use std::{
    ffi::c_void,
    fs, io,
    os::unix::{ffi::OsStrExt, fs::MetadataExt},
    path::Path,
    ptr,
};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NativeCodeSignature {
    pub signature: &'static str,
    pub identifier: Option<String>,
    pub team_identifier: Option<String>,
    pub code_directory_sha256: Option<String>,
}

#[repr(C)]
struct Range {
    location: isize,
    length: isize,
}

#[link(name = "CoreFoundation", kind = "framework")]
unsafe extern "C" {
    fn CFURLCreateFromFileSystemRepresentation(
        allocator: *const c_void,
        bytes: *const u8,
        length: isize,
        directory: u8,
    ) -> *const c_void;
    fn CFRelease(value: *const c_void);
    fn CFGetTypeID(value: *const c_void) -> usize;
    fn CFDictionaryGetTypeID() -> usize;
    fn CFDictionaryGetValue(dictionary: *const c_void, key: *const c_void) -> *const c_void;
    fn CFNumberGetTypeID() -> usize;
    fn CFNumberGetValue(number: *const c_void, kind: isize, output: *mut c_void) -> u8;
    fn CFStringGetTypeID() -> usize;
    fn CFStringGetLength(string: *const c_void) -> isize;
    fn CFStringGetBytes(
        string: *const c_void,
        range: Range,
        encoding: u32,
        loss: u8,
        external: u8,
        buffer: *mut u8,
        maximum: isize,
        used: *mut isize,
    ) -> isize;
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
    static kSecCodeInfoFlags: *const c_void;
    static kSecCodeInfoIdentifier: *const c_void;
    static kSecCodeInfoTeamIdentifier: *const c_void;
    static kSecCodeInfoUnique: *const c_void;
}

struct Owned(*const c_void);
impl Drop for Owned {
    fn drop(&mut self) {
        // SAFETY: every Owned is a nonnull create/copy-rule CoreFoundation object.
        unsafe { CFRelease(self.0) };
    }
}
fn refusal() -> io::Error {
    io::Error::new(
        io::ErrorKind::PermissionDenied,
        "native code signing inspection failed",
    )
}

fn string_field(dictionary: &Owned, key: *const c_void) -> io::Result<Option<String>> {
    // SAFETY: dictionary was type-checked and lives through all borrowed fields;
    // the bounded output buffer and CFRange agree for the entire call.
    unsafe {
        let value = CFDictionaryGetValue(dictionary.0, key);
        if value.is_null() {
            return Ok(None);
        }
        if CFGetTypeID(value) != CFStringGetTypeID() {
            return Err(refusal());
        }
        let length = CFStringGetLength(value);
        if !(1..=256).contains(&length) {
            return Err(refusal());
        }
        let mut buffer = [0u8; 1024];
        let mut used = 0;
        let converted = CFStringGetBytes(
            value,
            Range {
                location: 0,
                length,
            },
            0x08000100,
            0,
            0,
            buffer.as_mut_ptr(),
            buffer.len() as isize,
            &mut used,
        );
        if converted != length || !(1..=256).contains(&used) {
            return Err(refusal());
        }
        let text = std::str::from_utf8(&buffer[..used as usize]).map_err(|_| refusal())?;
        if text.chars().any(|c| c < ' ' || c == '\u{7f}') {
            return Err(refusal());
        }
        Ok(Some(text.to_owned()))
    }
}

/// Inspect a physical file or bundle using the same strict/all-architectures
/// Security.framework flags as BootstrapToolTrust. Callers must additionally
/// bind the complete content digest across this call before publishing trust.
pub fn inspect_native_code_signature(path: &Path) -> io::Result<NativeCodeSignature> {
    inspect_with_flags(path, (1 << 4) | 1)
}

/// DevEco's existing publisher check binds native pages/CMS while its four
/// allowlisted resources are checked separately against signed CodeResources.
/// This API cannot accept another publisher or an unsigned/ad-hoc signature.
pub fn inspect_deveco_publisher_signature(path: &Path) -> io::Result<NativeCodeSignature> {
    let trust = inspect_with_flags(path, (1 << 4) | 1 | (1 << 2))?;
    if trust.signature != "verified"
        || trust.identifier.as_deref() != Some("com.huawei.devecostudio.ds")
        || trust.team_identifier.as_deref() != Some("TZEA3TN37Q")
    {
        return Err(refusal());
    }
    Ok(trust)
}
fn inspect_with_flags(path: &Path, validation_flags: u32) -> io::Result<NativeCodeSignature> {
    if !path.is_absolute()
        || path.as_os_str().as_bytes().contains(&0)
        || path.canonicalize()? != path
    {
        return Err(refusal());
    }
    let before = fs::symlink_metadata(path)?;
    if !before.is_file() && !before.is_dir() {
        return Err(refusal());
    }
    let bytes = path.as_os_str().as_bytes();
    if bytes.len() > 16_384 {
        return Err(refusal());
    }
    // SAFETY: input bytes remain live; nonnull create/copy outputs receive RAII
    // owners. Every returned CF field is type-checked before typed access.
    let result = unsafe {
        let url = CFURLCreateFromFileSystemRepresentation(
            ptr::null(),
            bytes.as_ptr(),
            bytes.len() as isize,
            u8::from(before.is_dir()),
        );
        if url.is_null() {
            return Err(refusal());
        }
        let url = Owned(url);
        let mut code = ptr::null();
        if SecStaticCodeCreateWithPath(url.0, 0, &mut code) != 0 || code.is_null() {
            return Err(refusal());
        }
        let code = Owned(code);
        // SecStaticCode.h: kSecCSStrictValidate | kSecCSCheckAllArchitectures.
        let status = SecStaticCodeCheckValidity(code.0, validation_flags, ptr::null());
        if status == -67062 {
            // errSecCSUnsigned
            NativeCodeSignature {
                signature: "unsigned",
                identifier: None,
                team_identifier: None,
                code_directory_sha256: None,
            }
        } else {
            if status != 0 {
                return Err(refusal());
            }
            let mut dictionary = ptr::null();
            // SecCode.h: kSecCSSigningInformation.
            if SecCodeCopySigningInformation(code.0, 1 << 1, &mut dictionary) != 0
                || dictionary.is_null()
            {
                return Err(refusal());
            }
            let dictionary = Owned(dictionary);
            if CFGetTypeID(dictionary.0) != CFDictionaryGetTypeID() {
                return Err(refusal());
            }
            let raw_flags = CFDictionaryGetValue(dictionary.0, kSecCodeInfoFlags);
            if raw_flags.is_null() || CFGetTypeID(raw_flags) != CFNumberGetTypeID() {
                return Err(refusal());
            }
            let mut flags: i64 = 0;
            if CFNumberGetValue(raw_flags, 4, (&mut flags as *mut i64).cast()) == 0
                || !(0..=u32::MAX as i64).contains(&flags)
            {
                return Err(refusal());
            }
            let unique = CFDictionaryGetValue(dictionary.0, kSecCodeInfoUnique);
            let code_directory_sha256 = if unique.is_null() {
                None
            } else {
                if CFGetTypeID(unique) != CFDataGetTypeID() {
                    return Err(refusal());
                }
                let length = CFDataGetLength(unique);
                if !(0..=4096).contains(&length) {
                    return Err(refusal());
                }
                let pointer = CFDataGetBytePtr(unique);
                if length > 0 && pointer.is_null() {
                    return Err(refusal());
                }
                let bytes = if length == 0 {
                    &[]
                } else {
                    std::slice::from_raw_parts(pointer, length as usize)
                };
                Some(format!("{:x}", Sha256::digest(bytes)))
            };
            NativeCodeSignature {
                signature: if flags & 2 != 0 { "adHoc" } else { "verified" },
                identifier: string_field(&dictionary, kSecCodeInfoIdentifier)?,
                team_identifier: string_field(&dictionary, kSecCodeInfoTeamIdentifier)?,
                code_directory_sha256,
            }
        }
    };
    let after = fs::symlink_metadata(path)?;
    if path.canonicalize()? != path
        || before.dev() != after.dev()
        || before.ino() != after.ino()
        || before.mode() != after.mode()
        || before.len() != after.len()
        || before.mtime() != after.mtime()
        || before.mtime_nsec() != after.mtime_nsec()
        || before.ctime() != after.ctime()
        || before.ctime_nsec() != after.ctime_nsec()
    {
        return Err(refusal());
    }
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn inspects_actual_system_signature_without_executing_the_file() {
        let path = Path::new("/usr/bin/true").canonicalize().unwrap();
        let actual = inspect_native_code_signature(&path).unwrap();
        assert_eq!(actual.signature, "verified");
        assert!(actual.identifier.as_ref().is_some_and(|s| !s.is_empty()));
        assert!(
            actual
                .code_directory_sha256
                .as_ref()
                .is_some_and(|s| s.len() == 64)
        );
        assert_eq!(actual, inspect_native_code_signature(&path).unwrap());
        assert!(inspect_native_code_signature(Path::new("relative-path")).is_err());
    }
}
