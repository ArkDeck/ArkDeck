//! Security.framework operations for the updater. The caller supplies the
//! product requirement and binds the artifact's bytes across these calls.
use super::*;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HostUpdateSigningError {
    RunningApplicationUnsigned,
    InvalidRequirement,
    StaticCodeUnavailable,
    UnsignedOrInvalidArtifact,
    RequirementFailed,
}
use HostUpdateSigningError as Error;

#[link(name = "CoreFoundation", kind = "framework")]
unsafe extern "C" {
    fn CFStringCreateWithBytes(
        allocator: *const c_void,
        bytes: *const u8,
        length: isize,
        encoding: u32,
        external: u8,
    ) -> *const c_void;
}
#[link(name = "Security", kind = "framework")]
unsafe extern "C" {
    fn SecCodeCopySelf(flags: u32, output: *mut *const c_void) -> i32;
    fn SecCodeCheckValidity(code: *const c_void, flags: u32, requirement: *const c_void) -> i32;
    fn SecCodeCopyStaticCode(code: *const c_void, flags: u32, output: *mut *const c_void) -> i32;
    fn SecRequirementCreateWithString(
        text: *const c_void,
        flags: u32,
        output: *mut *const c_void,
    ) -> i32;
}

fn running_code() -> Result<Owned, Error> {
    let mut code = ptr::null();
    // SAFETY: writable out pointer; a successful copy-rule reference is owned.
    if unsafe { SecCodeCopySelf(0, &mut code) } != 0 || code.is_null() {
        return Err(Error::RunningApplicationUnsigned);
    }
    Ok(Owned(code))
}

fn requirement(source: &str) -> Result<Owned, Error> {
    if source.is_empty() || source.len() > 4096 || source.contains('\0') {
        return Err(Error::InvalidRequirement);
    }
    // SAFETY: live UTF-8 bytes and exact length; both created objects use RAII.
    unsafe {
        let string = CFStringCreateWithBytes(
            ptr::null(),
            source.as_ptr(),
            source.len() as isize,
            0x08000100,
            0,
        );
        if string.is_null() {
            return Err(Error::InvalidRequirement);
        }
        let string = Owned(string);
        let mut requirement = ptr::null();
        if SecRequirementCreateWithString(string.0, 0, &mut requirement) != 0
            || requirement.is_null()
        {
            return Err(Error::InvalidRequirement);
        }
        Ok(Owned(requirement))
    }
}

fn team(code: &Owned) -> Result<Option<String>, Error> {
    let mut dictionary = ptr::null();
    // SAFETY: retained static code; dictionary is checked before field access.
    unsafe {
        if SecCodeCopySigningInformation(code.0, 1 << 1, &mut dictionary) != 0
            || dictionary.is_null()
        {
            return Err(Error::UnsignedOrInvalidArtifact);
        }
        let dictionary = Owned(dictionary);
        if CFGetTypeID(dictionary.0) != CFDictionaryGetTypeID() {
            return Err(Error::UnsignedOrInvalidArtifact);
        }
        string_field(&dictionary, kSecCodeInfoTeamIdentifier)
            .map_err(|_| Error::UnsignedOrInvalidArtifact)
    }
}

pub fn running_update_team() -> Result<Option<String>, Error> {
    let code = running_code()?;
    // SAFETY: retained running-code object; static output is checked and owned.
    unsafe {
        if SecCodeCheckValidity(code.0, 0, ptr::null()) != 0 {
            return Err(Error::RunningApplicationUnsigned);
        }
        let mut static_code = ptr::null();
        if SecCodeCopyStaticCode(code.0, 0, &mut static_code) != 0 || static_code.is_null() {
            return Err(Error::RunningApplicationUnsigned);
        }
        team(&Owned(static_code))
    }
}

pub fn validate_running_update_code(source: &str) -> Result<(), Error> {
    let requirement = requirement(source)?;
    let code = running_code()?;
    // SAFETY: retained code and requirement. SDK kSecCSStrictValidate = 1 << 4.
    if unsafe { SecCodeCheckValidity(code.0, 1 << 4, requirement.0) } != 0 {
        return Err(Error::RunningApplicationUnsigned);
    }
    Ok(())
}

pub fn validate_update_code(path: &Path, source: &str) -> Result<Option<String>, Error> {
    let requirement = requirement(source)?;
    let bytes = path.as_os_str().as_bytes();
    if !path.is_absolute() || bytes.contains(&0) || bytes.len() > 16_384 {
        return Err(Error::StaticCodeUnavailable);
    }
    // SAFETY: bounded live filesystem bytes and retained create/copy objects.
    unsafe {
        let url = CFURLCreateFromFileSystemRepresentation(
            ptr::null(),
            bytes.as_ptr(),
            bytes.len() as isize,
            0,
        );
        if url.is_null() {
            return Err(Error::StaticCodeUnavailable);
        }
        let url = Owned(url);
        let mut code = ptr::null();
        if SecStaticCodeCreateWithPath(url.0, 0, &mut code) != 0 || code.is_null() {
            return Err(Error::StaticCodeUnavailable);
        }
        let code = Owned(code);
        // Local SDK SecStaticCode.h: strict, every architecture, nested code.
        let status = SecStaticCodeCheckValidity(code.0, (1 << 4) | 1 | (1 << 3), requirement.0);
        if status == -67050 {
            return Err(Error::RequirementFailed);
        } // errSecCSReqFailed
        if status != 0 {
            return Err(Error::UnsignedOrInvalidArtifact);
        }
        team(&code)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn sdk_parses_requirements_and_refuses_unsigned_artifacts() {
        let source = "anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"ABCDEFGHIJ\"";
        assert!(requirement(source).is_ok());
        assert!(matches!(requirement(""), Err(Error::InvalidRequirement)));
        assert!(matches!(
            requirement("not a requirement"),
            Err(Error::InvalidRequirement)
        ));
        let nonce: String = crate::random_bytes::<16>()
            .unwrap()
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect();
        let path = std::env::temp_dir().join(format!("arkdeck-unsigned-{nonce}.dmg"));
        std::fs::write(&path, b"not a signed disk image").unwrap();
        let result = validate_update_code(&path, source);
        std::fs::remove_file(path).unwrap();
        assert!(matches!(
            result,
            Err(Error::StaticCodeUnavailable | Error::UnsignedOrInvalidArtifact)
        ));
    }
}
