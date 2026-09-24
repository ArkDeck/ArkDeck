//! Foundation's hidden and package facts for one directory entry, the two a
//! `FileManager` enumerator reads for `.skipsHiddenFiles` and
//! `.skipsPackageDescendants` (`NSURLIsHiddenKey`, `NSURLIsPackageKey`).
//!
//! Measured on this host (TASK-XPA-015): an entry the enumerator never
//! yields is exactly one whose hidden key is true — a leading dot, the
//! `UF_HIDDEN` flag, or the Finder's invisible bit — and a directory it
//! yields without descending is exactly one whose package key is true, which
//! LaunchServices answers from its type database (`.app`, `.bundle`, `.rtfd`
//! and `.xcodeproj` are packages; `.framework` and `.xcassets` are not).
//! Reading the keys themselves is the only way to agree with Swift on every
//! entry. Read-only; a link is described, never followed.
use std::{ffi::c_void, io, os::unix::ffi::OsStrExt, path::Path, ptr};

#[link(name = "CoreFoundation", kind = "framework")]
unsafe extern "C" {
    fn CFURLCreateFromFileSystemRepresentation(
        allocator: *const c_void,
        bytes: *const u8,
        length: isize,
        directory: u8,
    ) -> *const c_void;
    fn CFURLCopyResourcePropertyForKey(
        url: *const c_void,
        key: *const c_void,
        value: *mut *const c_void,
        error: *mut *const c_void,
    ) -> u8;
    fn CFRelease(value: *const c_void);
    static kCFURLIsHiddenKey: *const c_void;
    static kCFURLIsPackageKey: *const c_void;
    static kCFBooleanTrue: *const c_void;
}

/// A create- or copy-rule CoreFoundation object, released once.
struct Owned(*const c_void);
impl Drop for Owned {
    fn drop(&mut self) {
        // SAFETY: constructed only for a nonnull create/copy-rule object.
        unsafe { CFRelease(self.0) };
    }
}

/// What Foundation's enumerator makes of one entry.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct EntryPresentation {
    /// Never yielded under `.skipsHiddenFiles`.
    pub hidden: bool,
    /// Yielded but not descended under `.skipsPackageDescendants`.
    pub package: bool,
}

fn unavailable() -> io::Error {
    io::Error::other("Foundation resource properties are unavailable for this entry")
}

/// The hidden and package keys of the entry at `path`, a directory when
/// `directory` says so. An entry whose keys cannot be read is an error, never
/// a guess in either direction.
pub fn host_entry_presentation(path: &Path, directory: bool) -> io::Result<EntryPresentation> {
    let bytes = path.as_os_str().as_bytes();
    let length = isize::try_from(bytes.len()).map_err(|_| unavailable())?;
    // SAFETY: the byte buffer outlives the call; a nonnull result is owned.
    let url = unsafe {
        CFURLCreateFromFileSystemRepresentation(
            ptr::null(),
            bytes.as_ptr(),
            length,
            u8::from(directory),
        )
    };
    if url.is_null() {
        return Err(unavailable());
    }
    let url = Owned(url);
    let key = |key: *const c_void| -> io::Result<bool> {
        let mut value: *const c_void = ptr::null();
        let mut error: *const c_void = ptr::null();
        // SAFETY: the URL is live; both out-slots are valid; a nonnull value
        // or error follows the copy rule and is released by its owner.
        let copied = unsafe { CFURLCopyResourcePropertyForKey(url.0, key, &mut value, &mut error) };
        let _error = (!error.is_null()).then(|| Owned(error));
        let _value = (!value.is_null()).then(|| Owned(value));
        if copied == 0 {
            return Err(unavailable());
        }
        // SAFETY: kCFBooleanTrue is an immortal process-lifetime constant.
        Ok(!value.is_null() && value == unsafe { kCFBooleanTrue })
    };
    // SAFETY: the property keys are immutable process-lifetime constants.
    let (hidden_key, package_key) = unsafe { (kCFURLIsHiddenKey, kCFURLIsPackageKey) };
    Ok(EntryPresentation {
        hidden: key(hidden_key)?,
        package: directory && key(package_key)?,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    /// The measured table: what Swift's enumerator skipped and did not
    /// descend on this host is what the keys report.
    #[test]
    fn hidden_and_package_keys_match_the_enumerators_measured_behaviour() {
        let root = std::env::temp_dir().canonicalize().unwrap().join(format!(
            "arkdeck-url-properties-{:x}",
            u128::from_ne_bytes(crate::random_bytes::<16>().unwrap())
        ));
        fs::create_dir_all(&root).unwrap();
        for (name, directory, hidden, package) in [
            ("plain.txt", false, false, false),
            (".dot", false, true, false),
            ("Foo.app", true, false, true),
            ("Bar.bundle", true, false, true),
            ("Doc.rtfd", true, false, true),
            ("Proj.xcodeproj", true, false, true),
            ("Lib.framework", true, false, false),
            ("Baz.xcassets", true, false, false),
            ("Plain.dir", true, false, false),
        ] {
            let path = root.join(name);
            if directory {
                fs::create_dir(&path).unwrap();
            } else {
                fs::write(&path, b"x").unwrap();
            }
            assert_eq!(
                host_entry_presentation(&path, directory).unwrap(),
                EntryPresentation { hidden, package },
                "{name}"
            );
        }
        fs::remove_dir_all(&root).unwrap();
    }
}
