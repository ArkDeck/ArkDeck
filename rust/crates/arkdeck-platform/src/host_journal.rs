//! Descriptor-bound, bounded Journal reads under the current manifest lock.
//! This API exposes no journal mutation or recovery primitive.
use super::{HostDirectory, HostReadLock, Ownership, fail, owned, segment};
use std::fs::{File, Metadata};
use std::io::{self, Write};
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::fs::{FileExt, MetadataExt};
use std::path::{Path, PathBuf};

pub struct HostJournal {
    directory: HostDirectory,
    path: PathBuf,
    lock: HostReadLock,
    file: File,
    metadata: Metadata,
    generation: u32,
}
impl HostJournal {
    pub fn open(path: &Path) -> io::Result<Self> {
        let directory = HostDirectory::open_session_tree(path)?;
        let name = c".manifest.lock";
        let flags = libc::O_RDWR | libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK;
        // SAFETY: the live directory and fixed C string anchor this lock.
        let mut fd = unsafe {
            libc::openat(
                directory.0.as_raw_fd(),
                name.as_ptr(),
                flags | libc::O_CREAT | libc::O_EXCL,
                0o600,
            )
        };
        let created = fd >= 0;
        if fd < 0 && io::Error::last_os_error().kind() == io::ErrorKind::AlreadyExists {
            fd = unsafe { libc::openat(directory.0.as_raw_fd(), name.as_ptr(), flags) };
        }
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        let file = unsafe { File::from_raw_fd(fd) };
        owned(&file, false, directory.1)?;
        if created {
            file.sync_all()?;
            directory.0.sync_all()?;
        }
        let started = std::time::Instant::now();
        loop {
            if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } == 0 {
                break;
            }
            let error = io::Error::last_os_error();
            if error.kind() == io::ErrorKind::Interrupted {
                continue;
            }
            if error.kind() != io::ErrorKind::WouldBlock
                || started.elapsed() >= std::time::Duration::from_secs(5)
            {
                return Err(error);
            }
            std::thread::sleep(std::time::Duration::from_millis(5));
        }
        let lock = HostReadLock { file };
        lock.validate_link(&directory, ".manifest.lock")?;
        let file = directory.open_at("journal.jsonl", 0)?;
        owned(&file, false, directory.1)?;
        let metadata = file.metadata()?;
        let linked = directory.stat_at("journal.jsonl")?;
        if metadata.dev() != linked.st_dev as u64 || metadata.ino() != linked.st_ino {
            return Err(fail());
        }
        Ok(Self {
            directory,
            path: path.into(),
            lock,
            file,
            metadata,
            generation: linked.st_gen,
        })
    }
    pub fn device(&self) -> i64 {
        self.metadata.dev() as i32 as i64
    }
    pub fn inode(&self) -> u64 {
        self.metadata.ino()
    }
    pub fn generation(&self) -> u32 {
        self.generation
    }
    pub fn byte_count(&self) -> u64 {
        self.metadata.len()
    }
    pub fn read(&self, offset: u64, count: usize) -> io::Result<Vec<u8>> {
        if count > 16 * 1024 * 1024
            || offset
                .checked_add(count as u64)
                .is_none_or(|n| n > self.byte_count())
        {
            return Err(fail());
        }
        let mut bytes = vec![0; count];
        self.file.read_exact_at(&mut bytes, offset)?;
        Ok(bytes)
    }
    pub fn validate(&self) -> io::Result<()> {
        self.directory.validate_path(&self.path)?;
        self.lock.validate_link(&self.directory, ".manifest.lock")?;
        owned(&self.file, false, self.directory.1)?;
        let current = self.file.metadata()?;
        let linked = self.directory.stat_at("journal.jsonl")?;
        if current.len() != self.metadata.len()
            || current.mtime() != self.metadata.mtime()
            || current.mtime_nsec() != self.metadata.mtime_nsec()
            || current.ctime() != self.metadata.ctime()
            || current.ctime_nsec() != self.metadata.ctime_nsec()
            || current.dev() != linked.st_dev as u64
            || current.ino() != linked.st_ino
            || linked.st_gen != self.generation
        {
            return Err(fail());
        }
        Ok(())
    }
    /// Only the fixed presentation cursor key may be initialized. It has no
    /// admission meaning. A resume never regenerates a missing key.
    pub fn cursor_key(&self, resuming: bool) -> io::Result<[u8; 32]> {
        let name = "event-cursor-key.v1";
        let file = match self.directory.open_at(name, 0) {
            Ok(file) => file,
            Err(error) if error.kind() == io::ErrorKind::NotFound && !resuming => {
                let key = crate::random_bytes::<32>()?;
                let nonce = u128::from_ne_bytes(crate::random_bytes::<16>()?);
                let temporary = segment(&format!(".event-cursor-key-{nonce:032x}.part"))?;
                let fd = unsafe {
                    libc::openat(
                        self.directory.0.as_raw_fd(),
                        temporary.as_ptr(),
                        libc::O_WRONLY
                            | libc::O_CREAT
                            | libc::O_EXCL
                            | libc::O_NOFOLLOW
                            | libc::O_CLOEXEC,
                        0o600,
                    )
                };
                if fd < 0 {
                    return Err(io::Error::last_os_error());
                }
                let mut file = unsafe { File::from_raw_fd(fd) };
                let result = (|| {
                    file.write_all(&key)?;
                    file.sync_all()?;
                    self.lock.validate_link(&self.directory, ".manifest.lock")?;
                    let destination = segment(name)?;
                    // RENAME_EXCL also refuses a non-cooperating replacement.
                    if unsafe {
                        libc::renameatx_np(
                            self.directory.0.as_raw_fd(),
                            temporary.as_ptr(),
                            self.directory.0.as_raw_fd(),
                            destination.as_ptr(),
                            libc::RENAME_EXCL,
                        )
                    } != 0
                    {
                        return Err(io::Error::last_os_error());
                    }
                    self.directory.0.sync_all()?;
                    self.directory.open_at(name, 0)
                })();
                unsafe {
                    libc::unlinkat(self.directory.0.as_raw_fd(), temporary.as_ptr(), 0);
                }
                result?
            }
            Err(error) => return Err(error),
        };
        owned(&file, false, Ownership::Private)?;
        let metadata = file.metadata()?;
        if metadata.len() != 32 || metadata.mode() & 0o777 != 0o600 {
            return Err(fail());
        }
        let mut key = [0; 32];
        file.read_exact_at(&mut key, 0)?;
        let linked = self.directory.stat_at(name)?;
        if metadata.dev() != linked.st_dev as u64 || metadata.ino() != linked.st_ino {
            return Err(fail());
        }
        self.validate()?;
        Ok(key)
    }
}
