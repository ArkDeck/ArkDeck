//! Descriptor-bound Journal access under the current manifest lock. Reads are
//! bounded; the appender adds one complete durable record at a time and makes
//! no recovery or authority decision of its own.
use super::{HostDirectory, HostReadLock, Ownership, fail, owned, segment};
use sha2::{Digest, Sha256};
use std::fs::{File, Metadata};
use std::io::{self, Write};
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::fs::{FileExt, MetadataExt};
use std::path::{Path, PathBuf};

const MANIFEST_LOCK: &str = ".manifest.lock";
const MANIFEST: &str = "manifest.json";
const JOURNAL: &str = "journal.jsonl";
/// The appender reads and validates a whole journal snapshot; larger journals
/// are refused rather than partially validated.
pub const MAX_JOURNAL_SNAPSHOT_BYTES: u64 = 256 * 1024 * 1024;
/// One record, including its LF, stays within the readers' record bound.
const MAX_JOURNAL_RECORD_BYTES: usize = 16 * 1024 * 1024 + 1;

/// Swift `SessionTerminalPublicationLock`: every journal read, append, repair
/// and terminal Manifest publication in one Job directory holds this lock.
fn manifest_lock(directory: &HostDirectory) -> io::Result<HostReadLock> {
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
        // SAFETY: as above; the existing entry is checked below.
        fd = unsafe { libc::openat(directory.0.as_raw_fd(), name.as_ptr(), flags) };
    }
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: openat returned a new owned descriptor.
    let file = unsafe { File::from_raw_fd(fd) };
    owned(&file, false, directory.1)?;
    if created {
        file.sync_all()?;
        directory.0.sync_all()?;
    }
    let started = std::time::Instant::now();
    loop {
        // SAFETY: flock on the retained descriptor.
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
    lock.validate_link(directory, MANIFEST_LOCK)?;
    Ok(lock)
}

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
        let lock = manifest_lock(&directory)?;
        let file = directory.open_at(JOURNAL, 0)?;
        owned(&file, false, directory.1)?;
        let metadata = file.metadata()?;
        let linked = directory.stat_at(JOURNAL)?;
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
        self.lock.validate_link(&self.directory, MANIFEST_LOCK)?;
        owned(&self.file, false, self.directory.1)?;
        let current = self.file.metadata()?;
        let linked = self.directory.stat_at(JOURNAL)?;
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
                    self.lock.validate_link(&self.directory, MANIFEST_LOCK)?;
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

/// Where a test may stop the process inside one append.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum JournalWritePoint {
    /// Part of the record has been written; no sync has happened.
    AfterPartialRecord,
    /// The complete record is durable in the file; the directory is not yet synced.
    AfterRecordSync,
}

#[derive(Debug)]
pub enum JournalAppendError {
    /// Nothing was written: the lock, identity, terminal Manifest, snapshot or
    /// the caller's validation refused the record.
    Refused(io::Error),
    /// A write began and its durable result is not proven. The appender is
    /// poisoned; only a new open, which replays and repairs, may continue.
    OutcomeUnknown(io::Error),
}

/// The validated tail of one open appender (Swift `JournalAppendCursor`): an
/// unchanged file needs only its last record rechecked before the next append.
#[derive(Clone)]
struct Cursor {
    size: u64,
    modified: (i64, i64),
    changed: (i64, i64),
    last: Option<(u64, usize, [u8; 32])>,
}
impl Cursor {
    fn new(bytes: &[u8], metadata: &Metadata) -> io::Result<Self> {
        let last = match bytes.split_last() {
            None => None,
            Some((b'\n', body)) => {
                let start = body.iter().rposition(|b| *b == b'\n').map_or(0, |p| p + 1);
                Some((
                    start as u64,
                    bytes.len() - start,
                    Sha256::digest(&bytes[start..]).into(),
                ))
            }
            Some(_) => return Err(fail()),
        };
        Ok(Self {
            size: metadata.len(),
            modified: (metadata.mtime(), metadata.mtime_nsec()),
            changed: (metadata.ctime(), metadata.ctime_nsec()),
            last,
        })
    }
    fn matches(&self, metadata: &Metadata) -> bool {
        metadata.len() == self.size
            && (metadata.mtime(), metadata.mtime_nsec()) == self.modified
            && (metadata.ctime(), metadata.ctime_nsec()) == self.changed
    }
    fn tail_is_unchanged(&self, file: &File) -> io::Result<bool> {
        let Some((offset, length, digest)) = self.last else {
            return Ok(self.size == 0);
        };
        let mut bytes = vec![0; length];
        file.read_exact_at(&mut bytes, offset)?;
        Ok(<[u8; 32]>::from(Sha256::digest(&bytes)) == digest)
    }
}

/// One Job journal's append-only writer (Swift `FileDurableJournal`). Every
/// append holds the Job directory's `.manifest.lock`, refuses after terminal
/// Manifest publication, stays bound to the journal inode it opened, and is
/// durable (fsync + F_FULLFSYNC, then the directory) before it returns. The
/// caller validates each record against the snapshot this appender presents.
pub struct HostJournalAppender {
    directory: HostDirectory,
    path: PathBuf,
    device: u64,
    inode: u64,
    cursor: Cursor,
    poisoned: bool,
}

fn full_sync(file: &File) -> io::Result<()> {
    // SAFETY: fsync and F_FULLFSYNC on one retained descriptor.
    if unsafe { libc::fsync(file.as_raw_fd()) } != 0
        || unsafe { libc::fcntl(file.as_raw_fd(), libc::F_FULLFSYNC) } != 0
    {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}
/// A directory fsync is the namespace durability barrier; F_FULLFSYNC is kept
/// for file contents, as in Swift `DurableFilePrimitives.syncDirectory`.
fn sync_directory(directory: &HostDirectory) -> io::Result<()> {
    // SAFETY: fsync on the retained directory descriptor.
    if unsafe { libc::fsync(directory.0.as_raw_fd()) } != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}
fn exists(directory: &HostDirectory, name: &str) -> io::Result<bool> {
    match directory.stat_at(name) {
        Ok(_) => Ok(true),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(false),
        Err(error) => Err(error),
    }
}
fn refused(message: &'static str) -> io::Error {
    io::Error::new(io::ErrorKind::PermissionDenied, message)
}
fn snapshot(file: &File) -> io::Result<(Vec<u8>, Metadata)> {
    let before = file.metadata()?;
    if before.len() > MAX_JOURNAL_SNAPSHOT_BYTES {
        return Err(fail());
    }
    let mut bytes = vec![0; before.len() as usize];
    file.read_exact_at(&mut bytes, 0)?;
    let after = file.metadata()?;
    if (after.len(), after.dev(), after.ino()) != (before.len(), before.dev(), before.ino())
        || (after.mtime(), after.mtime_nsec()) != (before.mtime(), before.mtime_nsec())
        || (after.ctime(), after.ctime_nsec()) != (before.ctime(), before.ctime_nsec())
    {
        return Err(fail());
    }
    Ok((bytes, after))
}

impl HostJournalAppender {
    /// Opens `journal.jsonl` in an existing Job directory, creating it only
    /// when `create` is set and no terminal Manifest exists. Under the lock,
    /// `decide` sees the complete snapshot and whether a terminal Manifest
    /// exists, and may return the durable length to keep when the tail is
    /// torn. Returns the appender and the final snapshot it is bound to.
    pub fn open(
        path: &Path,
        create: bool,
        decide: impl FnOnce(&[u8], bool) -> io::Result<Option<u64>>,
    ) -> io::Result<(Self, Vec<u8>)> {
        let directory = HostDirectory::open_session_tree(path)?;
        let _lock = manifest_lock(&directory)?;
        let terminal = exists(&directory, MANIFEST)?;
        let name = segment(JOURNAL)?;
        let flags = libc::O_RDWR | libc::O_APPEND | libc::O_NOFOLLOW | libc::O_CLOEXEC;
        // SAFETY: the retained directory descriptor and one fixed segment.
        let mut fd = unsafe { libc::openat(directory.0.as_raw_fd(), name.as_ptr(), flags) };
        let mut created = false;
        if fd < 0 && io::Error::last_os_error().kind() == io::ErrorKind::NotFound && create {
            if terminal {
                return Err(refused(
                    "cannot create a journal after terminal Manifest publication",
                ));
            }
            // SAFETY: as above; EXCL never adopts an entry created meanwhile.
            fd = unsafe {
                libc::openat(
                    directory.0.as_raw_fd(),
                    name.as_ptr(),
                    flags | libc::O_CREAT | libc::O_EXCL,
                    0o600,
                )
            };
            created = fd >= 0;
        }
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: openat returned a new owned descriptor.
        let file = unsafe { File::from_raw_fd(fd) };
        owned(&file, false, directory.1)?;
        if created {
            full_sync(&file)?;
            sync_directory(&directory)?;
        }
        let (mut bytes, mut metadata) = snapshot(&file)?;
        let linked = directory.stat_at(JOURNAL)?;
        if metadata.dev() != linked.st_dev as u64 || metadata.ino() != linked.st_ino {
            return Err(fail());
        }
        if let Some(length) = decide(&bytes, terminal)? {
            if terminal || length >= bytes.len() as u64 {
                return Err(refused(
                    "a torn journal can be repaired only before publication",
                ));
            }
            // SAFETY: truncation of the bound, locked, owner-checked journal.
            if unsafe { libc::ftruncate(file.as_raw_fd(), length as libc::off_t) } != 0 {
                return Err(io::Error::last_os_error());
            }
            full_sync(&file)?;
            sync_directory(&directory)?;
            (bytes, metadata) = snapshot(&file)?;
            if bytes.len() as u64 != length {
                return Err(fail());
            }
        }
        let cursor = Cursor::new(&bytes, &metadata)?;
        Ok((
            Self {
                directory,
                path: path.into(),
                device: metadata.dev(),
                inode: metadata.ino(),
                cursor,
                poisoned: false,
            },
            bytes,
        ))
    }

    /// Appends one complete LF-terminated record. `validate` runs under the
    /// lock with `None` when the file is exactly as this appender left it, or
    /// with the complete current snapshot when anything changed.
    pub fn append(
        &mut self,
        record: &[u8],
        validate: impl FnOnce(Option<&[u8]>) -> io::Result<()>,
    ) -> Result<(), JournalAppendError> {
        self.append_with_checkpoint(record, validate, |_| {})
    }

    pub fn append_with_checkpoint(
        &mut self,
        record: &[u8],
        validate: impl FnOnce(Option<&[u8]>) -> io::Result<()>,
        checkpoint: impl Fn(JournalWritePoint),
    ) -> Result<(), JournalAppendError> {
        use JournalAppendError::{OutcomeUnknown, Refused};
        if self.poisoned {
            return Err(Refused(refused(
                "journal appender is poisoned after an unproven write",
            )));
        }
        match record.split_last() {
            Some((b'\n', body))
                if !body.is_empty()
                    && record.len() <= MAX_JOURNAL_RECORD_BYTES
                    && !body.contains(&b'\n') => {}
            _ => return Err(Refused(fail())),
        }
        let _lock = manifest_lock(&self.directory).map_err(Refused)?;
        self.directory.validate_path(&self.path).map_err(Refused)?;
        if exists(&self.directory, MANIFEST).map_err(Refused)? {
            return Err(Refused(refused(
                "journal append follows terminal Manifest publication",
            )));
        }
        let file = self
            .directory
            .open_at_access(JOURNAL, libc::O_APPEND, libc::O_RDWR)
            .map_err(Refused)?;
        owned(&file, false, self.directory.1).map_err(Refused)?;
        let metadata = file.metadata().map_err(Refused)?;
        if (metadata.dev(), metadata.ino()) != (self.device, self.inode) {
            return Err(Refused(refused(
                "journal path no longer identifies the writer's bound journal",
            )));
        }
        let unchanged = self.cursor.matches(&metadata)
            && self.cursor.tail_is_unchanged(&file).map_err(Refused)?;
        let before = if unchanged {
            validate(None).map_err(Refused)?;
            self.cursor.size
        } else {
            let (bytes, current) = snapshot(&file).map_err(Refused)?;
            if (current.dev(), current.ino()) != (self.device, self.inode) {
                return Err(Refused(fail()));
            }
            // A caller that accepts the snapshot also proves its tail is whole.
            validate(Some(&bytes)).map_err(Refused)?;
            Cursor::new(&bytes, &current).map_err(Refused)?;
            current.len()
        };
        let written = (|| -> io::Result<Cursor> {
            let first = (record.len() / 2).max(1);
            (&file).write_all(&record[..first])?;
            checkpoint(JournalWritePoint::AfterPartialRecord);
            (&file).write_all(&record[first..])?;
            full_sync(&file)?;
            checkpoint(JournalWritePoint::AfterRecordSync);
            sync_directory(&self.directory)?;
            let after = file.metadata()?;
            let linked = self.directory.stat_at(JOURNAL)?;
            if (after.dev(), after.ino()) != (self.device, self.inode)
                || (linked.st_dev as u64, linked.st_ino) != (self.device, self.inode)
                || after.len() != before + record.len() as u64
            {
                return Err(fail());
            }
            Ok(Cursor {
                size: after.len(),
                modified: (after.mtime(), after.mtime_nsec()),
                changed: (after.ctime(), after.ctime_nsec()),
                last: Some((before, record.len(), Sha256::digest(record).into())),
            })
        })();
        match written {
            Ok(cursor) => {
                self.cursor = cursor;
                Ok(())
            }
            Err(error) => {
                self.poisoned = true;
                Err(OutcomeUnknown(error))
            }
        }
    }
}
