//! A pinned file by its absolute path (TASK-XPA-011): the Windows
//! counterpart of the Unix `canonicalize`/`symlink_metadata`/`access(X_OK)`
//! reads the signing layer's `measure` makes. One handle, opened without
//! following a reparse point, answers the file's identity (`FileIdInfo`), its
//! owner and DACL, whether the caller may execute it, and its SHA-256; the
//! identity is taken again on that handle and on a second open of the path
//! once the last byte is hashed, so a file replaced or written while it was
//! measured is refused instead of pinned.
use super::host_fs::{self, Access, READ, SHARE_ALL, Stat};
use super::host_store::HostFileIdentity;
use sha2::{Digest, Sha256};
use std::fs::File;
use std::io::{self, Read};
use std::os::windows::fs::OpenOptionsExt;
use std::os::windows::io::{AsRawHandle, FromRawHandle};
use std::path::{Component, Path, PathBuf, Prefix};
use windows_sys::Win32::Foundation::INVALID_HANDLE_VALUE;
use windows_sys::Win32::Storage::FileSystem::{
    FILE_EXECUTE, FILE_FLAG_BACKUP_SEMANTICS, FILE_FLAG_OPEN_REPARSE_POINT, FILE_READ_ATTRIBUTES,
    ReOpenFile, SYNCHRONIZE,
};

/// What one measurement of a pinned file established.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HostFileMeasure {
    /// Volume serial, file id, size and times, as the host store reports
    /// them.
    pub identity: HostFileIdentity,
    pub sha256: [u8; 32],
    pub links: u32,
    /// Owned by the token user.
    pub owner_is_user: bool,
    /// The Unix "no group or other write": owned by the token user or a
    /// trusted principal (`SYSTEM`, `Administrators`, `TrustedInstaller`),
    /// and nobody else is granted a right to change it.
    pub trusted_write_only: bool,
    /// The Unix "owned by this user, `mode & 0o077 == 0`": owned by the
    /// token user, and nobody but the user and the trusted principals is
    /// granted anything.
    pub owner_private: bool,
    /// A PE image (`.exe`) the kernel grants this caller `FILE_EXECUTE` on.
    pub executable: bool,
}

/// Why a pinned file could not be measured.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum HostFileMeasureError {
    /// Not a local canonical path, not openable, a reparse point, a
    /// directory, empty or beyond the bound.
    Unreadable,
    /// Its identity, size or times moved while it was hashed, or the path
    /// names another file afterwards.
    Changed,
}

/// Foundation `resolvingSymlinksInPath` on Windows: the path the system
/// reports for what `path` opens, every link and junction followed, in the
/// spelling on disk (case, long names), without the `\\?\` prefix. `None`
/// when the path does not open or resolves off a local drive.
pub fn host_resolved_path(path: &Path) -> Option<PathBuf> {
    let file = std::fs::OpenOptions::new()
        .access_mode(FILE_READ_ATTRIBUTES | SYNCHRONIZE)
        .share_mode(SHARE_ALL)
        .custom_flags(FILE_FLAG_BACKUP_SEMANTICS)
        .open(path)
        .ok()?;
    let reported = host_fs::final_path(&file, false).ok()?;
    let plain = PathBuf::from(reported.to_str()?.strip_prefix(r"\\?\")?);
    local_disk(&plain).then_some(plain)
}

fn local_disk(path: &Path) -> bool {
    matches!(
        path.components().next(),
        Some(Component::Prefix(prefix))
            if matches!(prefix.kind(), Prefix::Disk(_) | Prefix::VerbatimDisk(_))
    ) && path.is_absolute()
}

/// A local absolute path spelled in its standard form: a drive, then
/// `\`-separated components none of which is empty, `.` or `..` (which
/// `Path::components` would otherwise fold away), and no `/`. The verbatim
/// `\\?\` prefix is accepted.
pub(crate) fn standard_local_path(path: &Path) -> bool {
    let Some(text) = path.to_str() else {
        return false;
    };
    let rest = text.strip_prefix(r"\\?\").unwrap_or(text);
    local_disk(path)
        && text.len() <= 16 * 1024
        && !rest.contains('/')
        && rest
            .split('\\')
            .skip(1)
            .all(|part| !part.is_empty() && part != "." && part != "..")
}

/// Whether the caller may run `file` as a program: its name ends in `.exe`
/// (the loader runs nothing else) and the kernel grants `FILE_EXECUTE` on a
/// reopen of the very handle, the `access(X_OK)` of Windows.
pub(crate) fn may_execute(file: &File, name: &str) -> bool {
    let image = name
        .len()
        .checked_sub(4)
        .and_then(|start| name.get(start..))
        .is_some_and(|extension| extension.eq_ignore_ascii_case(".exe"));
    if !image {
        return false;
    }
    // SAFETY: a live handle; a successful call returns a new handle owned
    // (and closed) by the File below.
    let handle = unsafe {
        ReOpenFile(
            file.as_raw_handle(),
            FILE_EXECUTE | SYNCHRONIZE,
            SHARE_ALL,
            0,
        )
    };
    if handle == INVALID_HANDLE_VALUE || handle.is_null() {
        return false;
    }
    // SAFETY: ReOpenFile succeeded, so `handle` is a new owned handle.
    drop(unsafe { File::from_raw_handle(handle) });
    true
}

fn open_no_follow(path: &Path, access: u32) -> io::Result<File> {
    std::fs::OpenOptions::new()
        .access_mode(access)
        .share_mode(SHARE_ALL)
        .custom_flags(FILE_FLAG_OPEN_REPARSE_POINT)
        .open(path)
}

/// Measure the regular file at the local absolute `path` of at most
/// `maximum` bytes. The path must be canonical (no link or junction in any
/// component, the spelling on disk); the last component is opened without
/// following a reparse point.
pub fn measure_host_file(
    path: &Path,
    maximum: u64,
) -> Result<HostFileMeasure, HostFileMeasureError> {
    use HostFileMeasureError::{Changed, Unreadable};
    if !standard_local_path(path) {
        return Err(Unreadable);
    }
    let name = path
        .file_name()
        .and_then(|name| name.to_str())
        .ok_or(Unreadable)?;
    let file = open_no_follow(path, READ).map_err(|_| Unreadable)?;
    let before = Stat::of(&file).map_err(|_| Unreadable)?;
    if !before.regular() || before.size == 0 || before.size > maximum {
        return Err(Unreadable);
    }
    host_fs::canonical(path, &file).map_err(|_| Unreadable)?;
    let access = Access::of(&file).map_err(|_| Unreadable)?;
    let executable = may_execute(&file, name);
    let mut hasher = Sha256::new();
    let mut buffer = vec![0u8; 64 * 1024];
    let mut total = 0u64;
    let mut reader = (&file).take(maximum + 1);
    loop {
        let count = reader.read(&mut buffer).map_err(|_| Changed)?;
        if count == 0 {
            break;
        }
        total += count as u64;
        hasher.update(&buffer[..count]);
    }
    let after = Stat::of(&file).map_err(|_| Changed)?;
    let linked = open_no_follow(path, FILE_READ_ATTRIBUTES | SYNCHRONIZE)
        .and_then(|linked| Stat::of(&linked))
        .map_err(|_| Changed)?;
    if total != before.size
        || !(before.same_file(&after) && before.same_content(&after))
        || !(before.same_file(&linked) && before.same_content(&linked))
    {
        return Err(Changed);
    }
    Ok(HostFileMeasure {
        identity: HostFileIdentity::of(&before).map_err(|_| Unreadable)?,
        sha256: hasher.finalize().into(),
        links: before.links,
        owner_is_user: access.owner_is_user,
        trusted_write_only: access.trusted_write_only(),
        owner_private: access.owner_private(),
        executable,
    })
}

/// Read the regular file at the local absolute `path` whole, as Swift's
/// bounded physical reader reads an analyzer's input (`read_profile_file`):
/// the path canonical (no link or junction in any component, the spelling
/// on disk), the last component opened without following a reparse point,
/// at most `maximum` bytes, and the file unchanged while it is read.
pub fn read_host_file(path: &Path, maximum: u64) -> Result<Vec<u8>, HostFileMeasureError> {
    use HostFileMeasureError::{Changed, Unreadable};
    if !standard_local_path(path) {
        return Err(Unreadable);
    }
    let file = open_no_follow(path, READ).map_err(|_| Unreadable)?;
    let before = Stat::of(&file).map_err(|_| Unreadable)?;
    if !before.regular() || before.size > maximum {
        return Err(Unreadable);
    }
    host_fs::canonical(path, &file).map_err(|_| Unreadable)?;
    let mut bytes = Vec::with_capacity(before.size as usize);
    (&file)
        .take(maximum + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| Changed)?;
    let after = Stat::of(&file).map_err(|_| Changed)?;
    if bytes.len() as u64 != before.size
        || !(before.same_file(&after) && before.same_content(&after))
    {
        return Err(Changed);
    }
    Ok(bytes)
}
