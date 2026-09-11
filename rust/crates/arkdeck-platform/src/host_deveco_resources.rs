//! Bounded CF reader of DevEco's signed resource envelope. Signature validation
//! of the publisher is separate; this binds only the four current child roles.
use std::{ffi::c_void, io, ptr};
pub const DEVECO_RESOURCE_PATHS: [&str; 4] = [
    "Resources/product-info.json",
    "sdk/default/sdk-pkg.json",
    "tools/node/bin/node",
    "tools/hvigor/bin/hvigorw.js",
];
#[link(name = "CoreFoundation", kind = "framework")]
unsafe extern "C" {
    fn CFRelease(value: *const c_void);
    fn CFGetTypeID(value: *const c_void) -> usize;
    fn CFDataCreate(allocator: *const c_void, bytes: *const u8, length: isize) -> *const c_void;
    fn CFDataGetTypeID() -> usize;
    fn CFDataGetLength(value: *const c_void) -> isize;
    fn CFDataGetBytePtr(value: *const c_void) -> *const u8;
    fn CFPropertyListCreateWithData(
        allocator: *const c_void,
        data: *const c_void,
        options: usize,
        format: *mut isize,
        error: *mut *const c_void,
    ) -> *const c_void;
    fn CFDictionaryGetTypeID() -> usize;
    fn CFDictionaryGetValue(dictionary: *const c_void, key: *const c_void) -> *const c_void;
    fn CFStringCreateWithBytes(
        allocator: *const c_void,
        bytes: *const u8,
        length: isize,
        encoding: u32,
        external: u8,
    ) -> *const c_void;
}
struct Owned(*const c_void);
impl Drop for Owned {
    fn drop(&mut self) {
        unsafe { CFRelease(self.0) };
    }
}
fn denied() -> io::Error {
    io::Error::new(
        io::ErrorKind::PermissionDenied,
        "DevEco child role is not bound by the publisher resource envelope",
    )
}
fn owned(value: *const c_void) -> io::Result<Owned> {
    if value.is_null() {
        Err(denied())
    } else {
        Ok(Owned(value))
    }
}
fn key(value: &str) -> io::Result<Owned> {
    // SAFETY: all keys are short static role literals; buffers live through call.
    owned(unsafe {
        CFStringCreateWithBytes(
            ptr::null(),
            value.as_ptr(),
            value.len() as isize,
            0x08000100,
            0,
        )
    })
}
/// Digests are in DEVECO_RESOURCE_PATHS order, not a caller-expandable role set.
pub fn verify_deveco_resource_envelope(bytes: &[u8], digests: [&str; 4]) -> io::Result<()> {
    if bytes.is_empty() || bytes.len() > 32 * 1024 * 1024 {
        return Err(denied());
    }
    let mut expected = [[0u8; 32]; 4];
    for (index, digest) in digests.iter().enumerate() {
        if digest.len() != 64
            || !digest
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        {
            return Err(denied());
        }
        for (offset, target) in expected[index].iter_mut().enumerate() {
            *target = u8::from_str_radix(&digest[offset * 2..offset * 2 + 2], 16)
                .map_err(|_| denied())?;
        }
    }
    // SAFETY: input is bounded; create-rule values have owners, borrowed fields
    // are type checked, and each data read is exactly 32 bytes. No table walk.
    unsafe {
        let data = owned(CFDataCreate(
            ptr::null(),
            bytes.as_ptr(),
            bytes.len() as isize,
        ))?;
        let plist = owned(CFPropertyListCreateWithData(
            ptr::null(),
            data.0,
            0,
            ptr::null_mut(),
            ptr::null_mut(),
        ))?;
        if CFGetTypeID(plist.0) != CFDictionaryGetTypeID() {
            return Err(denied());
        }
        let files_key = key("files2")?;
        let files = CFDictionaryGetValue(plist.0, files_key.0);
        if files.is_null() || CFGetTypeID(files) != CFDictionaryGetTypeID() {
            return Err(denied());
        }
        let hash_key = key("hash2")?;
        for (index, path) in DEVECO_RESOURCE_PATHS.iter().enumerate() {
            let path_key = key(path)?;
            let mut value = CFDictionaryGetValue(files, path_key.0);
            if value.is_null() {
                return Err(denied());
            }
            if CFGetTypeID(value) == CFDictionaryGetTypeID() {
                value = CFDictionaryGetValue(value, hash_key.0);
            }
            if value.is_null()
                || CFGetTypeID(value) != CFDataGetTypeID()
                || CFDataGetLength(value) != 32
            {
                return Err(denied());
            }
            let pointer = CFDataGetBytePtr(value);
            if pointer.is_null() || std::slice::from_raw_parts(pointer, 32) != expected[index] {
                return Err(denied());
            }
        }
    }
    Ok(())
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn closed_hash2_and_direct_data_entries_require_exact_digest_and_type() {
        let zero = "0".repeat(64);
        let digest = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
        let rows = DEVECO_RESOURCE_PATHS
            .iter()
            .enumerate()
            .map(|(i, p)| {
                format!(
                    "<key>{p}</key>{}",
                    if i % 2 == 0 {
                        format!("<data>{digest}</data>")
                    } else {
                        format!("<dict><key>hash2</key><data>{digest}</data></dict>")
                    }
                )
            })
            .collect::<String>();
        let bytes = format!("<plist><dict><key>files2</key><dict>{rows}</dict></dict></plist>");
        verify_deveco_resource_envelope(bytes.as_bytes(), [&zero; 4]).unwrap();
        assert!(verify_deveco_resource_envelope(bytes.as_bytes(), [&"1".repeat(64); 4]).is_err());
        for wrong in [
            bytes.replace("files2", "files"),
            bytes
                .replace("<data>", "<string>")
                .replace("</data>", "</string>"),
            bytes.replace("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=", "AA=="),
        ] {
            assert!(verify_deveco_resource_envelope(wrong.as_bytes(), [&zero; 4]).is_err());
        }
        assert!(verify_deveco_resource_envelope(b"<plist><array/></plist>", [&zero; 4]).is_err());
    }
}
