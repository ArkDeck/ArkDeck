//! Swift `ArkTraceProfileFileReader.read`: one bounded regular file, opened
//! through its physical path without following a link, read to exactly the
//! size it had when it was opened, and refused if it grew, changed or was
//! replaced while it was read. Swift reads an analyzer's source this way in
//! the one-shot HiLog mode, and every file of an ArkTrace distribution
//! profile.
//!
//! The path arrives already classified, as Swift's `openPhysicalAbsolutePath`
//! classifies its string over Characters: the components below `/`, each
//! opened relative to its parent with `O_NOFOLLOW`, or a kernel inode alias
//! `/.vol/<device>/<inode>`, opened whole and bound to that device and inode.
//! The classification belongs to the caller, which reads the string as Swift
//! does; this module only opens and reads.
use sha2::Digest;
use std::ffi::CString;
use std::fs::File;
use std::io::{self, Read};
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::fs::MetadataExt;

/// Swift `ArkTraceProfileFileReader.ReaderError`, case for case.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ProfileReadError {
    PhysicalPath,
    Open,
    InitialMetadata,
    ShortRead,
    Growth,
    FinalIdentity,
}

/// Where a physical read opens its file.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ProfilePath {
    /// The non-empty components below `/`, none of them `.` or `..`.
    Components(Vec<String>),
    /// A kernel inode alias: the whole alias path, and the device and inode
    /// it names.
    InodeAlias {
        path: String,
        device: u32,
        inode: u64,
    },
}

/// What was read: the bytes, and the mode the file had when it was opened.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ProfileSnapshot {
    pub bytes: Vec<u8>,
    pub mode: u32,
}

/// Swift's read chunk.
const CHUNK: u64 = 64 * 1024;

fn open_at(parent: Option<&File>, name: &str, flags: i32) -> Result<File, ProfileReadError> {
    let name = CString::new(name).map_err(|_| ProfileReadError::Open)?;
    let fd = match parent {
        // SAFETY: a valid C string and flags; the descriptor is owned below.
        None => unsafe { libc::open(name.as_ptr(), flags) },
        // SAFETY: the live parent descriptor and component are valid here.
        Some(parent) => unsafe { libc::openat(parent.as_raw_fd(), name.as_ptr(), flags) },
    };
    if fd < 0 {
        return Err(ProfileReadError::Open);
    }
    // SAFETY: a newly opened descriptor has exactly one owner.
    Ok(unsafe { File::from_raw_fd(fd) })
}

/// Swift `openPhysicalAbsolutePath`: every ancestor a directory opened
/// without following a link, then the leaf with `flags`; or the inode alias,
/// bound to the regular file it names.
pub fn open_profile_path(path: &ProfilePath, flags: i32) -> Result<File, ProfileReadError> {
    match path {
        ProfilePath::InodeAlias {
            path,
            device,
            inode,
        } => {
            let file = open_at(None, path, flags | libc::O_CLOEXEC | libc::O_NOFOLLOW)?;
            let metadata = file
                .metadata()
                .map_err(|_| ProfileReadError::InitialMetadata)?;
            // `UInt32(bitPattern: st_dev)`: the device's 32 bits as stored.
            if metadata.dev() as u32 != *device
                || metadata.ino() != *inode
                || !metadata.file_type().is_file()
            {
                return Err(ProfileReadError::InitialMetadata);
            }
            Ok(file)
        }
        ProfilePath::Components(components) => {
            let Some((leaf, ancestors)) = components.split_last() else {
                return Err(ProfileReadError::PhysicalPath);
            };
            let directory = libc::O_RDONLY | libc::O_DIRECTORY | libc::O_CLOEXEC | libc::O_NOFOLLOW;
            let mut current = open_at(None, "/", directory)?;
            for component in ancestors {
                current = open_at(Some(&current), component, directory)?;
            }
            open_at(
                Some(&current),
                leaf,
                flags | libc::O_CLOEXEC | libc::O_NOFOLLOW,
            )
        }
    }
}

/// Swift `ArkTraceProfileFileReader.read(path:maximumByteCount:)`.
pub fn read_profile_file(
    path: &ProfilePath,
    maximum: u64,
) -> Result<ProfileSnapshot, ProfileReadError> {
    if maximum == 0 {
        return Err(ProfileReadError::PhysicalPath);
    }
    let file = open_profile_path(path, libc::O_RDONLY | libc::O_NONBLOCK)?;
    let initial = file
        .metadata()
        .map_err(|_| ProfileReadError::InitialMetadata)?;
    if !initial.file_type().is_file() || initial.size() > maximum {
        return Err(ProfileReadError::InitialMetadata);
    }
    let expected = initial.size();
    let mut bytes = Vec::with_capacity(expected as usize);
    let mut buffer = vec![0; CHUNK.min(expected.max(1)) as usize];
    let mut reader = &file;
    while (bytes.len() as u64) < expected {
        let want = (buffer.len() as u64).min(expected - bytes.len() as u64) as usize;
        match reader.read(&mut buffer[..want]) {
            Ok(0) => return Err(ProfileReadError::ShortRead),
            Ok(count) => bytes.extend_from_slice(&buffer[..count]),
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(_) => return Err(ProfileReadError::ShortRead),
        }
    }
    // One more byte must be the end, read once: an interruption is growth too.
    let mut extra = [0u8; 1];
    if !matches!(reader.read(&mut extra), Ok(0)) {
        return Err(ProfileReadError::Growth);
    }
    let last = file
        .metadata()
        .map_err(|_| ProfileReadError::FinalIdentity)?;
    if initial.dev() != last.dev()
        || initial.ino() != last.ino()
        || initial.size() != last.size()
        || initial.mtime() != last.mtime()
        || initial.mtime_nsec() != last.mtime_nsec()
    {
        return Err(ProfileReadError::FinalIdentity);
    }
    let current = open_profile_path(path, libc::O_RDONLY | libc::O_NONBLOCK)?;
    let linked = current
        .metadata()
        .map_err(|_| ProfileReadError::FinalIdentity)?;
    if initial.dev() != linked.dev()
        || initial.ino() != linked.ino()
        || !linked.file_type().is_file()
    {
        return Err(ProfileReadError::FinalIdentity);
    }
    Ok(ProfileSnapshot {
        bytes,
        mode: initial.mode(),
    })
}

/// Swift `ArkTraceProfileFileReader.matches`: the file reads as above, has
/// `byte_count` bytes when one is named, the SHA-256 `sha256` (as Swift's
/// lowercase text compares), and an execute bit when one is required.
pub fn profile_file_matches(
    path: &ProfilePath,
    sha256: &str,
    byte_count: Option<u64>,
    maximum: u64,
    require_executable: bool,
) -> bool {
    let Ok(snapshot) = read_profile_file(path, maximum) else {
        return false;
    };
    byte_count.is_none_or(|count| snapshot.bytes.len() as u64 == count)
        && format!("{:x}", sha2::Sha256::digest(&snapshot.bytes)) == sha256
        && (!require_executable || snapshot.mode & 0o111 != 0)
}

/// Swift `openPhysicalDirectoryDescriptor`: the directory, opened through
/// its physical path.
pub fn open_physical_directory(path: &ProfilePath) -> Result<File, ProfileReadError> {
    open_profile_path(path, libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NONBLOCK)
}

/// Swift `isPhysicalDirectory`: the path opens as a directory through its
/// physical path.
pub fn is_physical_directory(path: &ProfilePath) -> bool {
    open_physical_directory(path)
        .and_then(|directory| {
            directory
                .metadata()
                .map_err(|_| ProfileReadError::InitialMetadata)
        })
        .is_ok_and(|metadata| metadata.file_type().is_dir())
}

/// Swift `hasNoSymlinkComponent`: the path opens, whatever it names, with
/// no link anywhere along it.
pub fn has_no_symlink_component(path: &ProfilePath) -> bool {
    open_profile_path(path, libc::O_RDONLY | libc::O_NONBLOCK).is_ok()
}

fn open_component(parent: &File, name: &str, flags: i32) -> Option<File> {
    let name = CString::new(name).ok()?;
    // SAFETY: the live parent descriptor and component are valid here.
    let fd = unsafe { libc::openat(parent.as_raw_fd(), name.as_ptr(), flags) };
    // SAFETY: a newly opened descriptor has exactly one owner.
    (fd >= 0).then(|| unsafe { File::from_raw_fd(fd) })
}

fn errno() -> i32 {
    std::io::Error::last_os_error().raw_os_error().unwrap_or(0)
}

/// Swift `openOrCreateOwnerPrivateDirectory` over the components of its
/// physical path (`/var`, `/tmp` and `/etc` already read below `/private`):
/// every component opened relative to its parent without following a link,
/// a missing one created `0700`, each owned by this user or root and
/// writable by no one else unless it is a root-owned sticky directory; the
/// leaf this user's and made `0700` through its descriptor. Nothing is
/// changed through a path name before it is bound to a descriptor.
pub fn open_or_create_owner_private_directory(
    components: &[String],
) -> Result<File, ProfileReadError> {
    if components.is_empty()
        || components
            .iter()
            .any(|part| part.is_empty() || part == "." || part == "..")
    {
        return Err(ProfileReadError::PhysicalPath);
    }
    let flags =
        libc::O_RDONLY | libc::O_DIRECTORY | libc::O_CLOEXEC | libc::O_NOFOLLOW | libc::O_NONBLOCK;
    let mut directory = open_at(
        None,
        "/",
        libc::O_RDONLY | libc::O_DIRECTORY | libc::O_CLOEXEC | libc::O_NOFOLLOW,
    )?;
    // SAFETY: geteuid has no preconditions.
    let euid = unsafe { libc::geteuid() };
    for (index, component) in components.iter().enumerate() {
        let leaf = index == components.len() - 1;
        let next = match open_component(&directory, component, flags) {
            Some(next) => next,
            None if errno() == libc::ENOENT => {
                let name = CString::new(component.as_str()).map_err(|_| ProfileReadError::Open)?;
                // SAFETY: the live parent descriptor and component are valid.
                let created = unsafe { libc::mkdirat(directory.as_raw_fd(), name.as_ptr(), 0o700) };
                if created != 0 && errno() != libc::EEXIST {
                    return Err(ProfileReadError::Open);
                }
                open_component(&directory, component, flags).ok_or(ProfileReadError::Open)?
            }
            None => return Err(ProfileReadError::Open),
        };
        let metadata = next
            .metadata()
            .map_err(|_| ProfileReadError::PhysicalPath)?;
        if !metadata.file_type().is_dir() || (metadata.uid() != euid && metadata.uid() != 0) {
            return Err(ProfileReadError::PhysicalPath);
        }
        let root_sticky = metadata.uid() == 0 && metadata.mode() & libc::S_ISVTX as u32 != 0;
        if metadata.mode() & 0o022 != 0 && !root_sticky {
            return Err(ProfileReadError::PhysicalPath);
        }
        if leaf {
            if metadata.uid() != euid {
                return Err(ProfileReadError::PhysicalPath);
            }
            // SAFETY: the live descriptor this component was bound to.
            if unsafe { libc::fchmod(next.as_raw_fd(), 0o700) } != 0 {
                return Err(ProfileReadError::PhysicalPath);
            }
            let changed = next
                .metadata()
                .map_err(|_| ProfileReadError::PhysicalPath)?;
            if changed.uid() != euid || changed.mode() & 0o777 != 0o700 {
                return Err(ProfileReadError::PhysicalPath);
            }
        }
        directory = next;
    }
    Ok(directory)
}

/// Swift `validateOwnerOnlyAuthority` over the components of the physical
/// path (`/var`, `/tmp` and `/etc` already read below `/private`): each one
/// opened relative to its parent without following a link, a directory but
/// for a regular-file leaf when `leaf_is_directory` is false, owned by this
/// user or root, and writable by no one else unless it is a root-owned
/// sticky directory.
pub fn validate_owner_only_authority(
    components: &[String],
    leaf_is_directory: bool,
) -> Result<(), ProfileReadError> {
    if components.is_empty()
        || components
            .iter()
            .any(|part| part.is_empty() || part == "." || part == "..")
    {
        return Err(ProfileReadError::PhysicalPath);
    }
    let mut directory = open_at(
        None,
        "/",
        libc::O_RDONLY | libc::O_DIRECTORY | libc::O_CLOEXEC | libc::O_NOFOLLOW,
    )?;
    // SAFETY: geteuid has no preconditions.
    let euid = unsafe { libc::geteuid() };
    for (index, component) in components.iter().enumerate() {
        let file_leaf = index == components.len() - 1 && !leaf_is_directory;
        let flags = if file_leaf {
            libc::O_RDONLY | libc::O_NONBLOCK | libc::O_CLOEXEC | libc::O_NOFOLLOW
        } else {
            libc::O_RDONLY | libc::O_DIRECTORY | libc::O_CLOEXEC | libc::O_NOFOLLOW
        };
        let next = open_component(&directory, component, flags).ok_or(ProfileReadError::Open)?;
        let metadata = next
            .metadata()
            .map_err(|_| ProfileReadError::InitialMetadata)?;
        let kind_matches = if file_leaf {
            metadata.file_type().is_file()
        } else {
            metadata.file_type().is_dir()
        };
        let root_sticky = metadata.uid() == 0
            && metadata.file_type().is_dir()
            && metadata.mode() & libc::S_ISVTX as u32 != 0;
        if !kind_matches
            || (metadata.uid() != euid && metadata.uid() != 0)
            || (metadata.mode() & 0o022 != 0 && !root_sticky)
        {
            return Err(ProfileReadError::PhysicalPath);
        }
        directory = next;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::{PermissionsExt, symlink};
    use std::path::Path;

    struct Scratch(std::path::PathBuf);
    impl Drop for Scratch {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn scratch() -> Scratch {
        let path = std::path::PathBuf::from(format!(
            "/private/tmp/arkdeck-profile-reader-{:032x}",
            u128::from_ne_bytes(crate::random_bytes::<16>().unwrap())
        ));
        std::fs::create_dir(&path).unwrap();
        Scratch(path)
    }

    fn components(path: &Path) -> ProfilePath {
        ProfilePath::Components(
            path.to_str()
                .unwrap()
                .split('/')
                .filter(|part| !part.is_empty())
                .map(str::to_owned)
                .collect(),
        )
    }

    #[test]
    fn reads_a_regular_file_through_its_components_or_its_inode_alias() {
        let scratch = scratch();
        let file = scratch.0.join("source.txt");
        std::fs::write(&file, b"bytes\n").unwrap();
        std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o640)).unwrap();
        let read = read_profile_file(&components(&file), 6).unwrap();
        assert_eq!(read.bytes, b"bytes\n");
        assert_eq!(read.mode & 0o7777, 0o640);
        let metadata = std::fs::metadata(&file).unwrap();
        let alias = ProfilePath::InodeAlias {
            path: format!("/.vol/{}/{}", metadata.dev() as u32, metadata.ino()),
            device: metadata.dev() as u32,
            inode: metadata.ino(),
        };
        assert_eq!(
            read_profile_file(&alias, 1 << 20).unwrap().bytes,
            b"bytes\n"
        );
        // An alias whose device or inode names another object is refused.
        let ProfilePath::InodeAlias {
            path,
            device,
            inode,
        } = alias
        else {
            unreachable!()
        };
        let moved = ProfilePath::InodeAlias {
            path,
            device,
            inode: inode + 1,
        };
        assert!(read_profile_file(&moved, 1 << 20).is_err());
    }

    #[test]
    fn refuses_links_directories_bounds_and_absences() {
        let scratch = scratch();
        let file = scratch.0.join("source.txt");
        std::fs::write(&file, b"bytes\n").unwrap();
        symlink(&file, scratch.0.join("leaf")).unwrap();
        symlink(&scratch.0, scratch.0.join("ancestor")).unwrap();
        assert_eq!(
            read_profile_file(&components(&scratch.0.join("leaf")), 1 << 20),
            Err(ProfileReadError::Open)
        );
        assert_eq!(
            read_profile_file(&components(&scratch.0.join("ancestor/source.txt")), 1 << 20),
            Err(ProfileReadError::Open)
        );
        // `/tmp` is itself a link to `/private/tmp`.
        let through_tmp = Path::new("/tmp").join(file.strip_prefix("/private/tmp").unwrap());
        assert_eq!(
            read_profile_file(&components(&through_tmp), 1 << 20),
            Err(ProfileReadError::Open)
        );
        assert_eq!(
            read_profile_file(&components(&scratch.0), 1 << 20),
            Err(ProfileReadError::InitialMetadata)
        );
        assert_eq!(
            read_profile_file(&components(&file), 5),
            Err(ProfileReadError::InitialMetadata)
        );
        assert_eq!(
            read_profile_file(&components(&file), 0),
            Err(ProfileReadError::PhysicalPath)
        );
        assert_eq!(
            read_profile_file(&components(&scratch.0.join("absent")), 1 << 20),
            Err(ProfileReadError::Open)
        );
        assert_eq!(
            read_profile_file(&ProfilePath::Components(Vec::new()), 1 << 20),
            Err(ProfileReadError::PhysicalPath)
        );
    }

    #[test]
    fn owner_only_authority_admits_root_sticky_ancestors_and_refuses_writable_ones() {
        let scratch = scratch();
        let file = scratch.0.join("descriptor.json");
        std::fs::write(&file, b"{}").unwrap();
        std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o644)).unwrap();
        std::fs::set_permissions(&scratch.0, std::fs::Permissions::from_mode(0o755)).unwrap();
        let parts = |path: &Path| match components(path) {
            ProfilePath::Components(parts) => parts,
            ProfilePath::InodeAlias { .. } => unreachable!(),
        };
        // `/private/tmp` is root's sticky directory, writable by everyone.
        assert_eq!(validate_owner_only_authority(&parts(&file), false), Ok(()));
        assert_eq!(
            validate_owner_only_authority(&parts(&scratch.0), true),
            Ok(())
        );
        // A leaf of the other kind, or a writable ancestor of this user's.
        assert!(validate_owner_only_authority(&parts(&file), true).is_err());
        std::fs::set_permissions(&scratch.0, std::fs::Permissions::from_mode(0o777)).unwrap();
        assert_eq!(
            validate_owner_only_authority(&parts(&file), false),
            Err(ProfileReadError::PhysicalPath)
        );
        std::fs::set_permissions(&scratch.0, std::fs::Permissions::from_mode(0o755)).unwrap();
        std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o666)).unwrap();
        assert_eq!(
            validate_owner_only_authority(&parts(&file), false),
            Err(ProfileReadError::PhysicalPath)
        );
        assert!(is_physical_directory(&components(&scratch.0)));
        assert!(!is_physical_directory(&components(&file)));
        assert!(has_no_symlink_component(&components(&file)));
        symlink(&scratch.0, scratch.0.join("link")).unwrap();
        assert!(!has_no_symlink_component(&components(
            &scratch.0.join("link/descriptor.json")
        )));
    }

    #[test]
    fn a_private_directory_is_created_owner_only_and_never_through_a_link() {
        let scratch = scratch();
        std::fs::set_permissions(&scratch.0, std::fs::Permissions::from_mode(0o755)).unwrap();
        let parts = |path: &Path| match components(path) {
            ProfilePath::Components(parts) => parts,
            ProfilePath::InodeAlias { .. } => unreachable!(),
        };
        let private = scratch.0.join("state/snapshots");
        let directory = open_or_create_owner_private_directory(&parts(&private)).unwrap();
        assert!(directory.metadata().unwrap().is_dir());
        for path in [scratch.0.join("state"), private.clone()] {
            assert_eq!(
                std::fs::metadata(&path).unwrap().permissions().mode() & 0o777,
                0o700
            );
        }
        // An existing leaf is made owner-only through its descriptor.
        std::fs::set_permissions(&private, std::fs::Permissions::from_mode(0o755)).unwrap();
        open_or_create_owner_private_directory(&parts(&private)).unwrap();
        assert_eq!(
            std::fs::metadata(&private).unwrap().permissions().mode() & 0o777,
            0o700
        );
        let foreign = scratch.0.join("foreign");
        std::fs::create_dir(&foreign).unwrap();
        symlink(&foreign, scratch.0.join("linked")).unwrap();
        assert_eq!(
            open_or_create_owner_private_directory(&parts(&scratch.0.join("linked"))).err(),
            Some(ProfileReadError::Open)
        );
        assert_eq!(
            std::fs::metadata(&foreign).unwrap().permissions().mode() & 0o777,
            0o755
        );
    }
}
