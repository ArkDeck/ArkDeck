//! The temporary directory Swift `FileManager.default.temporaryDirectory`
//! reports for a non-sandboxed process: the per-user
//! `confstr(_CS_DARWIN_USER_TEMP_DIR)` on macOS, then `TMPDIR`, then `/tmp/`,
//! each spelled as given, symbolic links unresolved. Measured on the pinned
//! macOS toolchain, `TMPDIR` does not override the per-user directory there,
//! which is why `std::env::temp_dir` (`TMPDIR` first) is not this.
use std::ffi::OsString;
use std::path::PathBuf;

pub fn foundation_temporary_directory() -> PathBuf {
    #[cfg(target_os = "macos")]
    let user = darwin_user_temporary_directory();
    #[cfg(not(target_os = "macos"))]
    let user = None;
    resolved(user, std::env::var_os("TMPDIR"))
}

/// Foundation's order: the per-user directory, then `TMPDIR`, then `/tmp/`.
fn resolved(user: Option<PathBuf>, tmpdir: Option<OsString>) -> PathBuf {
    user.or_else(|| tmpdir.map(PathBuf::from))
        .unwrap_or_else(|| PathBuf::from("/tmp/"))
}

/// `confstr(_CS_DARWIN_USER_TEMP_DIR)`, when it answers in full.
#[cfg(target_os = "macos")]
fn darwin_user_temporary_directory() -> Option<PathBuf> {
    use std::ffi::{CStr, OsStr};
    use std::os::unix::ffi::OsStrExt;
    // SAFETY: a null buffer of length zero asks only for the needed length.
    let length = unsafe { libc::confstr(libc::_CS_DARWIN_USER_TEMP_DIR, std::ptr::null_mut(), 0) };
    if length == 0 {
        return None;
    }
    let mut buffer = vec![0 as libc::c_char; length];
    // SAFETY: the buffer holds `length` characters, the length confstr asked
    // for, terminator included.
    let written = unsafe {
        libc::confstr(
            libc::_CS_DARWIN_USER_TEMP_DIR,
            buffer.as_mut_ptr(),
            buffer.len(),
        )
    };
    if written != length {
        return None;
    }
    // SAFETY: confstr wrote a NUL-terminated string within `buffer`.
    let text = unsafe { CStr::from_ptr(buffer.as_ptr()) };
    Some(PathBuf::from(OsStr::from_bytes(text.to_bytes())))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The per-user directory whatever `TMPDIR` says, then `TMPDIR`, then
    /// `/tmp/`, each as given.
    #[test]
    fn the_per_user_directory_comes_before_tmpdir() {
        let (user, tmpdir) = (
            PathBuf::from("/var/folders/x/T/"),
            OsString::from("/elsewhere"),
        );
        assert_eq!(resolved(Some(user.clone()), Some(tmpdir.clone())), user);
        assert_eq!(resolved(None, Some(tmpdir)), PathBuf::from("/elsewhere"));
        assert_eq!(resolved(None, None), PathBuf::from("/tmp/"));
    }

    /// On macOS the answer is confstr's (Foundation's, probed with
    /// `FileManager.default.temporaryDirectory` on this host).
    #[cfg(target_os = "macos")]
    #[test]
    fn macos_answers_the_per_user_directory() {
        let directory = foundation_temporary_directory();
        assert_eq!(Some(directory.clone()), darwin_user_temporary_directory());
        assert!(directory.is_absolute(), "{}", directory.display());
    }
}
