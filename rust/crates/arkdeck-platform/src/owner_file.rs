//! One small owner-controlled file, read through a single `openat(O_NOFOLLOW)`
//! component walk, as Swift's `LaunchAgentService` reads the ArkTrace
//! distribution descriptor it pins: resolving a path first and opening it
//! later would let an exchanged ancestor select different bytes.
use std::ffi::CString;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::os::unix::ffi::OsStrExt;

/// Why the walk or the read refused, each as Swift names it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum OwnerFileRefusal {
    /// `/` could not be opened.
    RootUnavailable,
    /// An ancestor is missing, not a directory, or a symbolic link.
    AncestorUnavailable,
    /// An ancestor is not owned by the caller or root, or is group- or
    /// world-writable.
    AncestorNotOwnerControlled,
    /// The file itself is missing or a symbolic link.
    NotPhysicalRegularFile,
    /// The file is not a regular, bounded, non-empty file owned by the caller
    /// or root without group or world write.
    NotBoundedOwnerControlled,
    /// A read failed before the recorded size was read.
    IncompleteRead,
    /// Bytes followed the recorded size.
    ChangedWhileRead,
    /// The file's identity, size, mode or times changed during the read.
    IdentityChanged,
}

fn open_at(directory: Option<&OwnedFd>, name: &[u8], flags: i32) -> Option<OwnedFd> {
    let name = CString::new(name).ok()?;
    // SAFETY: `name` is a live NUL-terminated string; the directory descriptor,
    // when given, is owned and open for the call.
    let raw = unsafe {
        match directory {
            None => libc::open(name.as_ptr(), flags),
            Some(directory) => libc::openat(directory.as_raw_fd(), name.as_ptr(), flags),
        }
    };
    // SAFETY: a nonnegative result is a new descriptor this call owns.
    (raw >= 0).then(|| unsafe { OwnedFd::from_raw_fd(raw) })
}

fn status(descriptor: &OwnedFd) -> Option<libc::stat> {
    // SAFETY: a zeroed stat is a valid output slot; the descriptor is open.
    let mut metadata: libc::stat = unsafe { std::mem::zeroed() };
    // SAFETY: as above.
    (unsafe { libc::fstat(descriptor.as_raw_fd(), &mut metadata) } == 0).then_some(metadata)
}

fn owner_controlled(metadata: &libc::stat, uid: u32) -> bool {
    (metadata.st_uid == uid || metadata.st_uid == 0) && metadata.st_mode & 0o022 == 0
}

/// Reads the file at `components` (a physical absolute path already split,
/// with no empty, `.` or `..` component), each ancestor a directory owned by
/// `uid` or root without group or world write, the file itself a regular file
/// of 1…`maximum` bytes under the same ownership rule, whose identity does not
/// change while it is read.
pub fn read_owner_controlled_file(
    components: &[&str],
    maximum: u64,
    uid: u32,
) -> Result<Vec<u8>, OwnerFileRefusal> {
    let Some((last, ancestors)) = components.split_last() else {
        return Err(OwnerFileRefusal::NotPhysicalRegularFile);
    };
    let directory_flags = libc::O_RDONLY | libc::O_DIRECTORY | libc::O_CLOEXEC | libc::O_NOFOLLOW;
    let mut directory =
        open_at(None, b"/", directory_flags).ok_or(OwnerFileRefusal::RootUnavailable)?;
    for component in ancestors {
        let next = open_at(
            Some(&directory),
            std::ffi::OsStr::new(component).as_bytes(),
            directory_flags,
        )
        .ok_or(OwnerFileRefusal::AncestorUnavailable)?;
        let metadata = status(&next).ok_or(OwnerFileRefusal::AncestorNotOwnerControlled)?;
        if metadata.st_mode & libc::S_IFMT != libc::S_IFDIR || !owner_controlled(&metadata, uid) {
            return Err(OwnerFileRefusal::AncestorNotOwnerControlled);
        }
        directory = next;
    }
    let descriptor = open_at(
        Some(&directory),
        std::ffi::OsStr::new(last).as_bytes(),
        libc::O_RDONLY | libc::O_NONBLOCK | libc::O_CLOEXEC | libc::O_NOFOLLOW,
    )
    .ok_or(OwnerFileRefusal::NotPhysicalRegularFile)?;
    let initial = status(&descriptor).ok_or(OwnerFileRefusal::NotBoundedOwnerControlled)?;
    if initial.st_mode & libc::S_IFMT != libc::S_IFREG
        || !owner_controlled(&initial, uid)
        || initial.st_size <= 0
        || initial.st_size as u64 > maximum
    {
        return Err(OwnerFileRefusal::NotBoundedOwnerControlled);
    }
    let size = initial.st_size as usize;
    let mut bytes = vec![0u8; size];
    let mut offset = 0usize;
    while offset < size {
        // SAFETY: the destination range lies inside `bytes`; the descriptor is
        // open for the call.
        let count = unsafe {
            libc::pread(
                descriptor.as_raw_fd(),
                bytes[offset..].as_mut_ptr().cast(),
                size - offset,
                offset as libc::off_t,
            )
        };
        if count < 0 && std::io::Error::last_os_error().kind() == std::io::ErrorKind::Interrupted {
            continue;
        }
        if count <= 0 {
            return Err(OwnerFileRefusal::IncompleteRead);
        }
        offset += count as usize;
    }
    let mut extra = 0u8;
    // SAFETY: one writable byte; the descriptor is open for the call.
    if unsafe {
        libc::pread(
            descriptor.as_raw_fd(),
            (&mut extra as *mut u8).cast(),
            1,
            size as libc::off_t,
        )
    } != 0
    {
        return Err(OwnerFileRefusal::ChangedWhileRead);
    }
    let last = status(&descriptor).ok_or(OwnerFileRefusal::IdentityChanged)?;
    if last.st_dev != initial.st_dev
        || last.st_ino != initial.st_ino
        || last.st_uid != initial.st_uid
        || last.st_mode != initial.st_mode
        || last.st_size != initial.st_size
        || last.st_mtime != initial.st_mtime
        || last.st_mtime_nsec != initial.st_mtime_nsec
        || last.st_ctime != initial.st_ctime
        || last.st_ctime_nsec != initial.st_ctime_nsec
    {
        return Err(OwnerFileRefusal::IdentityChanged);
    }
    Ok(bytes)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::os::unix::fs::{DirBuilderExt, PermissionsExt};

    fn root() -> std::path::PathBuf {
        let root = fs::canonicalize(std::env::temp_dir())
            .unwrap()
            .join(format!(
                "arkdeck-owner-file-{:032x}",
                u128::from_ne_bytes(crate::random_bytes::<16>().unwrap())
            ));
        fs::DirBuilder::new().mode(0o700).create(&root).unwrap();
        root
    }

    fn components(path: &std::path::Path) -> Vec<String> {
        path.to_str()
            .unwrap()
            .split('/')
            .filter(|component| !component.is_empty())
            .map(str::to_owned)
            .collect()
    }

    fn read(path: &std::path::Path, maximum: u64) -> Result<Vec<u8>, OwnerFileRefusal> {
        let parts = components(path);
        let parts: Vec<&str> = parts.iter().map(String::as_str).collect();
        read_owner_controlled_file(&parts, maximum, crate::effective_user_id())
    }

    #[test]
    fn an_owner_controlled_file_is_read_and_everything_else_is_named() {
        let root = root();
        // The system temporary directory's own ancestors are owner-controlled
        // (`/private/var/folders/...`), unlike world-writable `/private/tmp`.
        let file = root.join("descriptor.json");
        fs::write(&file, b"{}").unwrap();
        fs::set_permissions(&file, fs::Permissions::from_mode(0o600)).unwrap();
        assert_eq!(read(&file, 16), Ok(b"{}".to_vec()));
        assert_eq!(
            read(&file, 1),
            Err(OwnerFileRefusal::NotBoundedOwnerControlled)
        );

        fs::set_permissions(&file, fs::Permissions::from_mode(0o622)).unwrap();
        assert_eq!(
            read(&file, 16),
            Err(OwnerFileRefusal::NotBoundedOwnerControlled)
        );
        fs::set_permissions(&file, fs::Permissions::from_mode(0o600)).unwrap();

        let empty = root.join("empty.json");
        fs::write(&empty, b"").unwrap();
        assert_eq!(
            read(&empty, 16),
            Err(OwnerFileRefusal::NotBoundedOwnerControlled)
        );

        let link = root.join("link.json");
        std::os::unix::fs::symlink(&file, &link).unwrap();
        assert_eq!(
            read(&link, 16),
            Err(OwnerFileRefusal::NotPhysicalRegularFile)
        );
        assert_eq!(
            read(&root.join("missing.json"), 16),
            Err(OwnerFileRefusal::NotPhysicalRegularFile)
        );

        let linked_directory = root.join("linked");
        std::os::unix::fs::symlink(&root, &linked_directory).unwrap();
        assert_eq!(
            read(&linked_directory.join("descriptor.json"), 16),
            Err(OwnerFileRefusal::AncestorUnavailable)
        );

        let open = root.join("open");
        fs::DirBuilder::new().mode(0o777).create(&open).unwrap();
        fs::set_permissions(&open, fs::Permissions::from_mode(0o777)).unwrap();
        fs::write(open.join("descriptor.json"), b"{}").unwrap();
        assert_eq!(
            read(&open.join("descriptor.json"), 16),
            Err(OwnerFileRefusal::AncestorNotOwnerControlled)
        );
        fs::remove_dir_all(&root).unwrap();
    }
}
