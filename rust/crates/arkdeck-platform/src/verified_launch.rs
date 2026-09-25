//! What a signed bundle's tool is held to while it runs at its canonical
//! path (Swift `ArkDeckProcess`'s `VerifiedRegularFileDescriptor` and
//! `VerifiedDirectoryDescriptor`): each pinned file opened through its
//! physical path, bound to its digest and held open, and the bundle's
//! owner-only directory held open; both checked again, by descriptor and by
//! path, before and after the child is spawned.
use super::{denied, invalid};
use sha2::{Digest, Sha256};
use std::ffi::CString;
use std::fs::{File, Metadata};
use std::io;
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::fs::MetadataExt;

/// Swift's reading of an absolute path: `/var`, `/tmp` and `/etc` below
/// `/private`, then its non-empty components, none `.` or `..`.
fn components(path: &str) -> io::Result<Vec<String>> {
    if !path.starts_with('/') {
        return Err(invalid("a verified path must be absolute"));
    }
    let mapped = ["/var", "/tmp", "/etc"]
        .into_iter()
        .any(|root| path == root || path.starts_with(&format!("{root}/")));
    let physical = if mapped {
        format!("/private{path}")
    } else {
        path.to_owned()
    };
    let parts: Vec<String> = physical
        .split('/')
        .filter(|part| !part.is_empty())
        .map(str::to_owned)
        .collect();
    if parts.is_empty() || parts.iter().any(|part| part == "." || part == "..") {
        return Err(invalid("a verified path must name physical components"));
    }
    Ok(parts)
}

fn open_at(parent: Option<&File>, name: &str, flags: i32) -> io::Result<File> {
    let name = CString::new(name).map_err(|_| invalid("a path component contains NUL"))?;
    let fd = match parent {
        // SAFETY: a valid C string and flags; the descriptor is owned below.
        None => unsafe { libc::open(name.as_ptr(), flags) },
        // SAFETY: the live parent descriptor and component are valid here.
        Some(parent) => unsafe { libc::openat(parent.as_raw_fd(), name.as_ptr(), flags) },
    };
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: a newly opened descriptor has exactly one owner.
    Ok(unsafe { File::from_raw_fd(fd) })
}

/// Every ancestor opened as a directory without following a link, then the
/// leaf with `flags`, also without following one.
fn open_physical(path: &str, flags: i32, leaf_is_directory: bool) -> io::Result<File> {
    let parts = components(path)?;
    let directory = libc::O_RDONLY | libc::O_DIRECTORY | libc::O_CLOEXEC | libc::O_NOFOLLOW;
    let mut current = open_at(None, "/", directory)?;
    let (leaf, ancestors) = if leaf_is_directory {
        (None, parts.as_slice())
    } else {
        let (leaf, ancestors) = parts.split_last().expect("non-empty components");
        (Some(leaf), ancestors)
    };
    for component in ancestors {
        current = open_at(Some(&current), component, directory)?;
    }
    match leaf {
        None => Ok(current),
        Some(leaf) => open_at(
            Some(&current),
            leaf,
            flags | libc::O_CLOEXEC | libc::O_NOFOLLOW,
        ),
    }
}

fn euid() -> u32 {
    // SAFETY: geteuid has no preconditions.
    unsafe { libc::geteuid() }
}

fn same_identity(left: &Metadata, right: &Metadata) -> bool {
    left.dev() == right.dev()
        && left.ino() == right.ino()
        && left.uid() == right.uid()
        && left.mode() == right.mode()
        && left.size() == right.size()
        && left.mtime() == right.mtime()
        && left.mtime_nsec() == right.mtime_nsec()
        && left.ctime() == right.ctime()
        && left.ctime_nsec() == right.ctime_nsec()
        && left.file_type().is_file()
}

/// Swift `VerifiedRegularFileDescriptor.hash`: exactly `length` bytes by
/// positioned reads, then the end, the file's identity unchanged.
fn hash(file: &File, length: u64, initial: &Metadata) -> io::Result<String> {
    use std::os::unix::fs::FileExt;
    if length == 0 {
        return Err(denied("a verified file is not empty"));
    }
    let mut hasher = Sha256::new();
    let mut buffer = vec![0; length.min(64 * 1024) as usize];
    let mut offset = 0;
    while offset < length {
        let want = buffer.len().min((length - offset) as usize);
        let count = match file.read_at(&mut buffer[..want], offset) {
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            result => result?,
        };
        if count == 0 {
            return Err(denied("a verified file was truncated while it was read"));
        }
        hasher.update(&buffer[..count]);
        offset += count as u64;
    }
    let mut extra = [0u8; 1];
    if file.read_at(&mut extra, offset)? != 0 {
        return Err(denied("a verified file grew while it was read"));
    }
    if !same_identity(initial, &file.metadata()?) {
        return Err(denied("a verified file changed while it was read"));
    }
    Ok(format!("{:x}", hasher.finalize()))
}

/// Swift `VerifiedRegularFileDescriptor`: one pinned regular file held open,
/// bound to its digest.
pub struct VerifiedResource {
    path: String,
    inode_path: String,
    sha256: String,
    byte_count: u64,
    file: File,
    opened: Metadata,
    require_executable: bool,
}

impl VerifiedResource {
    /// Opened through its physical path: a regular, non-empty file of at most
    /// `maximum` bytes, owned by this user or root, writable by no one else,
    /// executable when required, whose bytes have `sha256` and whose inode
    /// alias names it.
    pub fn open(
        path: &str,
        sha256: &str,
        maximum: u64,
        require_executable: bool,
    ) -> io::Result<Self> {
        if sha256.len() != 64
            || !sha256
                .bytes()
                .all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
        {
            return Err(invalid("a verified file needs its lowercase SHA-256"));
        }
        let file = open_physical(path, libc::O_RDONLY | libc::O_NONBLOCK, false)?;
        let opened = file.metadata()?;
        let owner = euid();
        if !opened.file_type().is_file()
            || (opened.uid() != owner && opened.uid() != 0)
            || opened.mode() & 0o022 != 0
            || (require_executable && opened.mode() & 0o111 == 0)
            || opened.size() == 0
            || opened.size() > maximum
        {
            return Err(denied("a verified file is not a safe regular file"));
        }
        if hash(&file, opened.size(), &opened)? != sha256 {
            return Err(denied("a verified file does not have its SHA-256"));
        }
        let inode_path = format!("/.vol/{}/{}", opened.dev() as u32, opened.ino());
        let linked = std::fs::symlink_metadata(&inode_path)
            .map_err(|_| denied("a verified file's inode path is unavailable"))?;
        if linked.dev() != opened.dev() || linked.ino() != opened.ino() || !linked.is_file() {
            return Err(denied("a verified file's inode path is unavailable"));
        }
        Ok(Self {
            path: path.to_owned(),
            inode_path,
            sha256: sha256.to_owned(),
            byte_count: opened.size(),
            file,
            opened,
            require_executable,
        })
    }

    /// The retained file's `/.vol` alias.
    pub fn inode_path(&self) -> &str {
        &self.inode_path
    }

    /// The length the file had when it was opened and hashed.
    pub fn byte_count(&self) -> u64 {
        self.byte_count
    }

    /// Swift `revalidate`: the descriptor, the path and the inode alias all
    /// still name the opened file, unchanged, with its digest.
    pub fn revalidate(&self) -> io::Result<()> {
        let retained = self.file.metadata()?;
        let safe = |metadata: &Metadata| {
            same_identity(&self.opened, metadata)
                && metadata.mode() & 0o022 == 0
                && (!self.require_executable || metadata.mode() & 0o111 != 0)
        };
        if !safe(&retained) {
            return Err(denied("a verified file changed"));
        }
        let current = open_physical(&self.path, libc::O_RDONLY | libc::O_NONBLOCK, false)?;
        if !safe(&current.metadata()?) {
            return Err(denied("a verified file's path names another file"));
        }
        let linked = std::fs::symlink_metadata(&self.inode_path)
            .map_err(|_| denied("a verified file's inode path is unavailable"))?;
        if !same_identity(&self.opened, &linked) {
            return Err(denied("a verified file's inode path is unavailable"));
        }
        if hash(&self.file, self.byte_count, &retained)? != self.sha256 {
            return Err(denied("a verified file does not have its SHA-256"));
        }
        Ok(())
    }
}

/// Swift `VerifiedDirectoryDescriptor`: a signed bundle's owner-only
/// directory held open while its tool runs.
pub struct VerifiedNamespace {
    path: String,
    directory: File,
    opened: Metadata,
}

impl VerifiedNamespace {
    /// Swift `openOwnerOnly`: a directory this user owns, writable by no one
    /// else, opened through its physical path.
    pub fn open_owner_only(path: &str) -> io::Result<Self> {
        let directory = open_physical(path, 0, true)?;
        let opened = directory.metadata()?;
        if !opened.is_dir() || opened.uid() != euid() || opened.mode() & 0o022 != 0 {
            return Err(denied(
                "a verified namespace is not an owner-only directory",
            ));
        }
        Ok(Self {
            path: path.to_owned(),
            directory,
            opened,
        })
    }

    /// Swift `revalidate`: the descriptor and the path still name the opened
    /// directory, unchanged.
    pub fn revalidate(&self) -> io::Result<()> {
        let same = |metadata: &Metadata| {
            metadata.dev() == self.opened.dev()
                && metadata.ino() == self.opened.ino()
                && metadata.uid() == self.opened.uid()
                && metadata.mode() == self.opened.mode()
        };
        let retained = self.directory.metadata()?;
        if !same(&retained) || !retained.is_dir() || retained.mode() & 0o022 != 0 {
            return Err(denied("a verified namespace changed"));
        }
        let current = open_physical(&self.path, 0, true)?;
        if !same(&current.metadata()?) {
            return Err(denied(
                "a verified namespace's path names another directory",
            ));
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::{PermissionsExt, symlink};

    struct Scratch(std::path::PathBuf);
    impl Drop for Scratch {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn scratch() -> Scratch {
        let path = std::path::PathBuf::from(format!(
            "/private/tmp/arkdeck-verified-launch-{:032x}",
            u128::from_ne_bytes(crate::random_bytes::<16>().unwrap())
        ));
        std::fs::create_dir(&path).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o700)).unwrap();
        Scratch(path)
    }

    #[test]
    fn a_resource_is_bound_to_its_digest_and_path() {
        let scratch = scratch();
        let file = scratch.0.join("pinned");
        std::fs::write(&file, b"pinned\n").unwrap();
        std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o644)).unwrap();
        let path = file.to_str().unwrap();
        let digest = format!("{:x}", Sha256::digest(b"pinned\n"));
        let resource = VerifiedResource::open(path, &digest, 1024, false).unwrap();
        resource.revalidate().unwrap();
        assert!(resource.inode_path().starts_with("/.vol/"));
        // The `/tmp` alias is read below `/private`, as Swift reads it.
        let through_tmp = path.strip_prefix("/private").unwrap();
        VerifiedResource::open(through_tmp, &digest, 1024, false).unwrap();
        assert!(VerifiedResource::open(path, &"0".repeat(64), 1024, false).is_err());
        assert!(VerifiedResource::open(path, &digest, 1024, true).is_err());
        assert!(VerifiedResource::open(path, &digest, 6, false).is_err());
        // Replaced at its path: the retained descriptor no longer names it.
        std::fs::rename(&file, scratch.0.join("moved")).unwrap();
        std::fs::write(&file, b"pinned\n").unwrap();
        std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o644)).unwrap();
        assert!(resource.revalidate().is_err());
        symlink(scratch.0.join("moved"), scratch.0.join("link")).unwrap();
        assert!(
            VerifiedResource::open(
                scratch.0.join("link").to_str().unwrap(),
                &digest,
                1024,
                false
            )
            .is_err()
        );
    }

    #[test]
    fn a_namespace_is_an_owner_only_directory_that_stays_itself() {
        let scratch = scratch();
        let bundle = scratch.0.join("App.app");
        std::fs::create_dir(&bundle).unwrap();
        std::fs::set_permissions(&bundle, std::fs::Permissions::from_mode(0o755)).unwrap();
        let namespace = VerifiedNamespace::open_owner_only(bundle.to_str().unwrap()).unwrap();
        namespace.revalidate().unwrap();
        std::fs::set_permissions(&bundle, std::fs::Permissions::from_mode(0o775)).unwrap();
        assert!(namespace.revalidate().is_err());
        assert!(VerifiedNamespace::open_owner_only(bundle.to_str().unwrap()).is_err());
        std::fs::set_permissions(&bundle, std::fs::Permissions::from_mode(0o755)).unwrap();
        std::fs::rename(&bundle, scratch.0.join("held.app")).unwrap();
        std::fs::create_dir(&bundle).unwrap();
        assert!(namespace.revalidate().is_err());
    }
}
