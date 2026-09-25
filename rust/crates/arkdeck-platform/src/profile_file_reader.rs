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
}
