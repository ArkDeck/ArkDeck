//! Descriptor-relative, bounded, read-only snapshots for host-store migration.
//! No file, directory or lock is created by this module.
use std::ffi::{CStr, CString};
use std::fs::{File, OpenOptions};
use std::io::{self, Read};
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::Path;

pub struct HostDirectory(File, Ownership);

#[derive(Clone, Copy)]
enum Ownership {
    Private,
    SessionTree { device: u64 },
}
impl Ownership {
    fn mode_mask(self) -> u32 {
        match self {
            Self::Private => 0o077,
            Self::SessionTree { .. } => 0o022,
        }
    }
    fn same_volume(self, device: u64) -> bool {
        match self {
            Self::Private => true,
            Self::SessionTree { device: root } => root == device,
        }
    }
}
pub struct HostReadLock {
    file: File,
}

impl HostReadLock {
    /// The advisory lock only covers this inode. A replacement at the same
    /// name must never be mistaken for the lock held by this snapshot.
    pub fn validate_link(&self, root: &HostDirectory, name: &str) -> io::Result<()> {
        owned(&self.file, false, root.1)?;
        let held = self.file.metadata()?;
        let linked = root.stat_at(name)?;
        if held.dev() != linked.st_dev as u64 || held.ino() != linked.st_ino {
            return Err(fail());
        }
        Ok(())
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum HostEntryKind {
    Directory,
    Regular,
    Other,
}

fn fail() -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, "host snapshot refused")
}
fn segment(name: &str) -> io::Result<CString> {
    if name.is_empty() || name == "." || name == ".." || name.contains('/') {
        return Err(fail());
    }
    CString::new(name).map_err(|_| fail())
}
fn owned(file: &File, directory: bool, ownership: Ownership) -> io::Result<()> {
    let stat = file.metadata()?;
    if stat.uid() != unsafe { libc::geteuid() }
        || stat.mode() & ownership.mode_mask() != 0
        || !ownership.same_volume(stat.dev())
        || (directory && !stat.is_dir())
        || (!directory && (!stat.is_file() || stat.nlink() != 1))
    {
        return Err(fail());
    }
    Ok(())
}

impl HostDirectory {
    pub fn open(path: &Path) -> io::Result<Self> {
        Self::open_root(path, false)
    }

    /// SessionRetentionCatalog's existing owner/same-volume/no-public-write
    /// boundary. This does not change the stricter private-cache entry point.
    pub fn open_session_tree(path: &Path) -> io::Result<Self> {
        Self::open_root(path, true)
    }

    fn open_root(path: &Path, session_tree: bool) -> io::Result<Self> {
        if !path.is_absolute() || path.canonicalize()? != path {
            return Err(fail());
        }
        let file = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(path)?;
        let ownership = if session_tree {
            Ownership::SessionTree {
                device: file.metadata()?.dev(),
            }
        } else {
            Ownership::Private
        };
        owned(&file, true, ownership)?;
        Ok(Self(file, ownership))
    }

    /// Recheck the caller's root binding after a bounded snapshot. Descriptor
    /// reads remain anchored after rename, but cannot certify a replacement
    /// namespace at the original path.
    pub fn validate_path(&self, path: &Path) -> io::Result<()> {
        if !path.is_absolute() || path.canonicalize()? != path {
            return Err(fail());
        }
        owned(&self.0, true, self.1)?;
        let held = self.0.metadata()?;
        let linked = std::fs::symlink_metadata(path)?;
        if !linked.is_dir() || held.dev() != linked.dev() || held.ino() != linked.ino() {
            return Err(fail());
        }
        Ok(())
    }

    pub fn child(&self, name: &str) -> io::Result<Self> {
        let file = self.open_at(name, libc::O_DIRECTORY)?;
        owned(&file, true, self.1)?;
        Ok(Self(file, self.1))
    }

    fn open_at(&self, name: &str, flags: i32) -> io::Result<File> {
        let name = segment(name)?;
        let fd = unsafe {
            libc::openat(
                self.0.as_raw_fd(),
                name.as_ptr(),
                libc::O_RDONLY | libc::O_CLOEXEC | libc::O_NOFOLLOW | libc::O_NONBLOCK | flags,
            )
        };
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(unsafe { File::from_raw_fd(fd) })
    }

    pub fn names(&self, maximum: usize) -> io::Result<Vec<String>> {
        // A separate open description gives each enumeration its own offset.
        let fd = unsafe {
            libc::openat(
                self.0.as_raw_fd(),
                c".".as_ptr(),
                libc::O_RDONLY | libc::O_DIRECTORY | libc::O_CLOEXEC | libc::O_NOFOLLOW,
            )
        };
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        let directory = unsafe { libc::fdopendir(fd) };
        if directory.is_null() {
            let error = io::Error::last_os_error();
            unsafe {
                libc::close(fd);
            }
            return Err(error);
        }
        struct Close(*mut libc::DIR);
        impl Drop for Close {
            fn drop(&mut self) {
                unsafe {
                    libc::closedir(self.0);
                }
            }
        }
        let _close = Close(directory);
        let mut names = Vec::new();
        loop {
            unsafe {
                *libc::__error() = 0;
            }
            let entry = unsafe { libc::readdir(directory) };
            if entry.is_null() {
                if unsafe { *libc::__error() } != 0 {
                    return Err(io::Error::last_os_error());
                }
                break;
            }
            let name = unsafe { CStr::from_ptr((*entry).d_name.as_ptr()) }
                .to_str()
                .map_err(|_| fail())?;
            if name == "." || name == ".." {
                continue;
            }
            if names.len() >= maximum {
                return Err(fail());
            }
            names.push(name.to_owned());
        }
        names.sort();
        Ok(names)
    }

    pub fn kind_and_size(&self, name: &str) -> io::Result<(HostEntryKind, i64)> {
        let stat = self.stat_at(name)?;
        let kind = match stat.st_mode & libc::S_IFMT {
            libc::S_IFDIR => HostEntryKind::Directory,
            libc::S_IFREG => HostEntryKind::Regular,
            _ => HostEntryKind::Other,
        };
        Ok((kind, stat.st_size))
    }

    /// Measurement metadata validated under this directory's ownership rules.
    pub fn owned_kind_and_size(&self, name: &str) -> io::Result<(HostEntryKind, u64)> {
        let stat = self.stat_at(name)?;
        if stat.st_uid != unsafe { libc::geteuid() }
            || u32::from(stat.st_mode) & self.1.mode_mask() != 0
            || !self.1.same_volume(stat.st_dev as u64)
            || stat.st_size < 0
        {
            return Err(fail());
        }
        match stat.st_mode & libc::S_IFMT {
            libc::S_IFDIR => Ok((HostEntryKind::Directory, 0)),
            libc::S_IFREG if stat.st_nlink == 1 => {
                Ok((HostEntryKind::Regular, stat.st_size as u64))
            }
            _ => Err(fail()),
        }
    }

    fn stat_at(&self, name: &str) -> io::Result<libc::stat> {
        let name = segment(name)?;
        let mut stat = std::mem::MaybeUninit::<libc::stat>::uninit();
        if unsafe {
            libc::fstatat(
                self.0.as_raw_fd(),
                name.as_ptr(),
                stat.as_mut_ptr(),
                libc::AT_SYMLINK_NOFOLLOW,
            )
        } != 0
        {
            return Err(io::Error::last_os_error());
        }
        Ok(unsafe { stat.assume_init() })
    }

    pub fn read(&self, name: &str, maximum: usize) -> io::Result<Vec<u8>> {
        let file = self.open_at(name, 0)?;
        owned(&file, false, self.1)?;
        let before = file.metadata()?;
        if before.len() > maximum as u64 {
            return Err(fail());
        }
        let mut bytes = Vec::new();
        (&file).take(maximum as u64 + 1).read_to_end(&mut bytes)?;
        let after = file.metadata()?;
        let linked = self.stat_at(name)?;
        if bytes.len() > maximum
            || bytes.len() as u64 != before.len()
            || before.len() != after.len()
            || before.mtime() != after.mtime()
            || before.mtime_nsec() != after.mtime_nsec()
            || before.ctime() != after.ctime()
            || before.ctime_nsec() != after.ctime_nsec()
            || before.dev() != linked.st_dev as u64
            || before.ino() != linked.st_ino
        {
            return Err(fail());
        }
        Ok(bytes)
    }

    pub fn try_lock_existing(&self, name: &str) -> io::Result<Option<HostReadLock>> {
        let file = match self.open_at(name, 0) {
            Ok(file) => file,
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
            Err(error) => return Err(error),
        };
        owned(&file, false, self.1)?;
        loop {
            if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } == 0 {
                break;
            }
            let error = io::Error::last_os_error();
            if error.kind() == io::ErrorKind::Interrupted {
                continue;
            }
            if error.kind() == io::ErrorKind::WouldBlock {
                return Ok(None);
            }
            return Err(error);
        }
        let lock = HostReadLock { file };
        lock.validate_link(self, name)?;
        Ok(Some(lock))
    }
}
