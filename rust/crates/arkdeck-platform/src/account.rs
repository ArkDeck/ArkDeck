//! The home directory Swift `NSHomeDirectory()` reports for a non-sandboxed
//! process: `CFFIXED_USER_HOME` when it is set, otherwise the account's home
//! from the password database. `HOME` is deliberately not consulted.
use std::ffi::CStr;

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
