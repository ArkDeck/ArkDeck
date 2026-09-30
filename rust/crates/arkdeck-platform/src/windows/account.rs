//! The account's state root on Windows (design §D.2): the Known Folder
//! `FOLDERID_LocalAppData` of this process's token, the directory Windows
//! keeps per user and never roams. The `LOCALAPPDATA` environment variable
//! is deliberately not consulted, as the Unix owner ignores `HOME`: the
//! environment is the caller's, the Known Folder is the account's.
use std::ffi::OsString;
use std::os::windows::ffi::OsStringExt;
use std::path::PathBuf;
use std::ptr::null_mut;
use windows_sys::Win32::System::Com::CoTaskMemFree;
use windows_sys::Win32::UI::Shell::{
    FOLDERID_LocalAppData, FOLDERID_Profile, KF_FLAG_DEFAULT, SHGetKnownFolderPath,
};
use windows_sys::core::GUID;

/// The Windows counterpart of Swift's Application Support directory: the
/// account's local application data directory, absolute and existing.
pub fn application_support_directory() -> Option<PathBuf> {
    known_folder(&FOLDERID_LocalAppData)
}

/// The Windows counterpart of the Unix `runtime_home` (Swift
/// `NSHomeDirectory()`, which Artifact redaction replaces): the account's
/// profile directory, the Known Folder `FOLDERID_Profile` of this process's
/// token, never `USERPROFILE`.
pub fn runtime_home() -> Option<String> {
    known_folder(&FOLDERID_Profile)
        .and_then(|directory| directory.into_os_string().into_string().ok())
}

/// A Known Folder of this process's token, absolute.
fn known_folder(folder: &GUID) -> Option<PathBuf> {
    let mut path = null_mut();
    // SAFETY: a documented Known Folder id, the process token (null) and an
    // output pointer; the returned string is freed below whatever the result.
    let status =
        unsafe { SHGetKnownFolderPath(folder, KF_FLAG_DEFAULT as u32, null_mut(), &mut path) };
    struct Free(*mut u16);
    impl Drop for Free {
        fn drop(&mut self) {
            // SAFETY: memory the Shell allocated with CoTaskMemAlloc (or null).
            unsafe { CoTaskMemFree(self.0.cast()) }
        }
    }
    let _free = Free(path);
    if status != 0 || path.is_null() {
        return None;
    }
    let mut length = 0;
    // SAFETY: a successful call returned a NUL-terminated string.
    unsafe {
        while *path.add(length) != 0 {
            length += 1;
        }
    }
    // SAFETY: `length` characters precede the terminator.
    let wide = unsafe { std::slice::from_raw_parts(path, length) };
    let directory = PathBuf::from(OsString::from_wide(wide));
    directory.is_absolute().then_some(directory)
}

/// The product's root, `<LocalAppData>\ArkDeck`: the parent of the daemon
/// state directory `ArkDeck\Agentd` and of the other product stores, under
/// the same relative names as on macOS.
pub fn arkdeck_application_support_root() -> Option<PathBuf> {
    application_support_directory().map(|directory| directory.join("ArkDeck"))
}
