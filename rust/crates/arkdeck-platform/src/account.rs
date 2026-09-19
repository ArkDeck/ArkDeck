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
