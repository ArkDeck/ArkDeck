//! The home directory Swift `NSHomeDirectory()` reports for a non-sandboxed
//! process: `CFFIXED_USER_HOME` when it is set, otherwise the account's home
//! from the password database. `HOME` is deliberately not consulted.
use std::ffi::CStr;
use std::path::PathBuf;

pub fn runtime_home() -> Option<String> {
    if let Some(fixed) = std::env::var_os("CFFIXED_USER_HOME").filter(|value| !value.is_empty()) {
        return fixed.into_string().ok();
    }
    let mut buffer = vec![0 as libc::c_char; 16 * 1024];
    // SAFETY: a zeroed passwd is a valid output slot for getpwuid_r.
    let mut entry: libc::passwd = unsafe { std::mem::zeroed() };
    let mut found = std::ptr::null_mut();
    // SAFETY: every pointer is live for the call and the buffer bounds the
    // strings the entry points into.
    let status = unsafe {
        libc::getpwuid_r(
            libc::getuid(),
            &mut entry,
            buffer.as_mut_ptr(),
            buffer.len(),
            &mut found,
        )
    };
    if status != 0 || found.is_null() || entry.pw_dir.is_null() {
        return None;
    }
    // SAFETY: getpwuid_r stored a NUL-terminated string inside `buffer`.
    unsafe { CStr::from_ptr(entry.pw_dir) }
        .to_str()
        .ok()
        .map(str::to_owned)
}

/// Swift `FileManager.urls(for: .applicationSupportDirectory, in:
/// .userDomainMask)[0]` for a non-sandboxed process:
/// `<home>/Library/Application Support`, with the home resolved as
/// [`runtime_home`] resolves it.
pub fn application_support_directory() -> Option<PathBuf> {
    runtime_home().map(|home| PathBuf::from(home).join("Library/Application Support"))
}

/// The product's Application Support root, `…/Library/Application
/// Support/ArkDeck`: the parent of the daemon state directory (Swift
/// `AgentXPCContract.applicationSupportRelativeStateDirectory`, `ArkDeck/Agentd`)
/// and the root of the Rockchip binding and post-flash alias stores.
pub fn arkdeck_application_support_root() -> Option<PathBuf> {
    application_support_directory().map(|directory| directory.join("ArkDeck"))
}

/// The effective user ID of this process, for ownership checks.
pub fn effective_user_id() -> u32 {
    // SAFETY: geteuid has no preconditions and cannot fail.
    unsafe { libc::geteuid() }
}

/// Why a file could not be measured (Swift `RuntimeCLI.measureArtifact`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FileMeasureError {
    /// `open(2)` without following a link failed with this errno.
    Open(i32),
    /// Not a regular file, or empty.
    NotRegularOrEmpty,
    /// A read failed with this errno.
    Read(i32),
    /// Its identity, size or times changed while it was read.
    Changed,
}

/// Swift `RuntimeCLI.measureArtifact`: the byte count and lowercase SHA-256
/// of a non-empty regular file, opened without following a link at its last
/// component and read to its end, refused if it changed while read.
pub fn measure_unchanged_file(path: &std::path::Path) -> Result<(u64, String), FileMeasureError> {
    use sha2::{Digest, Sha256};
    use std::io::Read;
    use std::os::fd::FromRawFd;
    use std::os::unix::ffi::OsStrExt;
    use std::os::unix::fs::MetadataExt;
    let native = std::ffi::CString::new(path.as_os_str().as_bytes())
        .map_err(|_| FileMeasureError::Open(libc::EINVAL))?;
    // SAFETY: `native` is a live NUL-terminated string for the call.
    let descriptor = unsafe {
        libc::open(
            native.as_ptr(),
            libc::O_RDONLY | libc::O_CLOEXEC | libc::O_NOFOLLOW,
        )
    };
    if descriptor < 0 {
        return Err(FileMeasureError::Open(
            std::io::Error::last_os_error().raw_os_error().unwrap_or(0),
        ));
    }
    // SAFETY: a new descriptor nothing else owns.
    let mut file = unsafe { std::fs::File::from_raw_fd(descriptor) };
    let before = file
        .metadata()
        .ok()
        .filter(|metadata| metadata.is_file() && metadata.len() > 0)
        .ok_or(FileMeasureError::NotRegularOrEmpty)?;
    let mut hasher = Sha256::new();
    let mut measured = 0_u64;
    let mut buffer = vec![0_u8; 1024 * 1024];
    loop {
        let count = match file.read(&mut buffer) {
            Ok(count) => count,
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(error) => return Err(FileMeasureError::Read(error.raw_os_error().unwrap_or(0))),
        };
        if count == 0 {
            break;
        }
        hasher.update(&buffer[..count]);
        measured += count as u64;
    }
    let unchanged = file.metadata().is_ok_and(|after| {
        measured == before.len()
            && after.dev() == before.dev()
            && after.ino() == before.ino()
            && after.len() == before.len()
            && after.mtime() == before.mtime()
            && after.mtime_nsec() == before.mtime_nsec()
            && after.ctime() == before.ctime()
            && after.ctime_nsec() == before.ctime_nsec()
    });
    if !unchanged {
        return Err(FileMeasureError::Changed);
    }
    let digest = hasher
        .finalize()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect();
    Ok((measured, digest))
}

/// Whether this process may execute `path` now (`access(2)` with `X_OK`,
/// evaluated with the real user and group IDs as Swift's `access` is).
pub fn executable_by_caller(path: &std::path::Path) -> bool {
    use std::os::unix::ffi::OsStrExt;
    let Ok(path) = std::ffi::CString::new(path.as_os_str().as_bytes()) else {
        return false;
    };
    // SAFETY: `path` is a live NUL-terminated string for the call.
    unsafe { libc::access(path.as_ptr(), libc::X_OK) == 0 }
}
