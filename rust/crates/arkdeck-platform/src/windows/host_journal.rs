//! Handle-bound Journal access under the current manifest lock, on NTFS:
//! the Unix `host_journal.rs` with the same file names, record discipline
//! and refusals. Reads are bounded; the appender adds one complete durable
//! record at a time and makes no recovery or authority decision of its own.
//! `FlushFileBuffers` stands for `fsync` + `F_FULLFSYNC`; SPK-5 measured that
//! a process killed inside an append leaves a byte prefix of it, so the
//! torn-tail repair the caller decides is the Unix one.
use super::super::host_fs::{self, Descriptor, Kind, READ, Stat, WRITE, fail};
use super::{HostDirectory, HostReadLock, Ownership, owned, read_exact_at};
use sha2::{Digest, Sha256};
use std::fs::File;
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use windows_sys::Wdk::Storage::FileSystem::{FILE_CREATE, FILE_OPEN};

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
    let name = host_fs::segment(MANIFEST_LOCK)?;
    let (file, created) = match host_fs::open_relative(
        &directory.0,
        &name,
        WRITE,
        FILE_CREATE,
        Kind::Any,
        Some(&Descriptor::private(false)?),
    ) {
        Ok(file) => (file, true),
        Err(error) if error.kind() == io::ErrorKind::AlreadyExists => (
            host_fs::open_relative(&directory.0, &name, WRITE, FILE_OPEN, Kind::Any, None)?,
            false,
        ),
        Err(error) => return Err(error),
    };
    owned(&file, false, directory.1)?;
    if created {
        host_fs::flush(&file)?;
        host_fs::flush_directory(&directory.0)?;
    }
    let started = std::time::Instant::now();
    while !host_fs::lock(&file, false)? {
        if started.elapsed() >= std::time::Duration::from_secs(5) {
            return Err(io::Error::new(
                io::ErrorKind::WouldBlock,
                "the Job directory's manifest lock stayed held",
            ));
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
    stat: Stat,
    inode: u64,
}
impl HostJournal {
    pub fn open(path: &Path) -> io::Result<Self> {
        let directory = HostDirectory::open_session_tree(path)?;
        let lock = manifest_lock(&directory)?;
        let file = directory.open_at(JOURNAL)?;
        owned(&file, false, directory.1)?;
        let stat = Stat::of(&file)?;
        let linked = directory.stat_at(JOURNAL)?;
        if !stat.same_file(&linked) {
            return Err(fail());
        }
        Ok(Self {
            inode: stat.inode()?,
            directory,
            path: path.into(),
            lock,
            file,
            stat,
        })
    }
    /// The volume serial, the device of Windows.
    pub fn device(&self) -> i64 {
        self.stat.volume as i64
    }
    pub fn inode(&self) -> u64 {
        self.inode
    }
    /// NTFS has no inode generation: its 64-bit file reference already
    /// carries a sequence number that changes when the record is reused.
    pub fn generation(&self) -> u32 {
        0
    }
    pub fn byte_count(&self) -> u64 {
        self.stat.size
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
        read_exact_at(&self.file, &mut bytes, offset)?;
        Ok(bytes)
    }
    pub fn validate(&self) -> io::Result<()> {
        self.directory.validate_path(&self.path)?;
        self.lock.validate_link(&self.directory, MANIFEST_LOCK)?;
        owned(&self.file, false, self.directory.1)?;
        let current = Stat::of(&self.file)?;
        let linked = self.directory.stat_at(JOURNAL)?;
        if !current.same_content(&self.stat) || !current.same_file(&linked) {
            return Err(fail());
        }
        Ok(())
    }
    /// Only the fixed presentation cursor key may be initialized. It has no
    /// admission meaning. A resume never regenerates a missing key.
    pub fn cursor_key(&self, resuming: bool) -> io::Result<[u8; 32]> {
        let name = "event-cursor-key.v1";
        let file = match self.directory.open_at(name) {
            Ok(file) => file,
            Err(error) if error.kind() == io::ErrorKind::NotFound && !resuming => {
                let key = crate::random_bytes::<32>()?;
                let nonce = u128::from_ne_bytes(crate::random_bytes::<16>()?);
                let temporary = host_fs::segment(&format!(".event-cursor-key-{nonce:032x}.part"))?;
                let mut file = host_fs::open_relative(
                    &self.directory.0,
                    &temporary,
                    WRITE,
                    FILE_CREATE,
                    Kind::NonDirectory,
                    Some(&Descriptor::private(false)?),
                )?;
                let result = (|| {
                    file.write_all(&key)?;
                    host_fs::flush(&file)?;
                    self.lock.validate_link(&self.directory, MANIFEST_LOCK)?;
                    // Never over an existing key, also not a non-cooperating one.
                    host_fs::rename(&file, &self.directory.0, &host_fs::segment(name)?, false)?;
                    host_fs::flush_directory(&self.directory.0)?;
                    self.directory.open_at(name)
                })();
                drop(file);
                let _ = host_fs::unlink(&self.directory.0, &temporary, Kind::NonDirectory);
                result?
            }
            Err(error) => return Err(error),
        };
        owned(&file, false, Ownership::Private)?;
        let stat = Stat::of(&file)?;
        if stat.size != 32 || !host_fs::Access::of(&file)?.owner_read_write() {
            return Err(fail());
        }
        let mut key = [0; 32];
        read_exact_at(&file, &mut key, 0)?;
        let linked = self.directory.stat_at(name)?;
        if !stat.same_file(&linked) {
            return Err(fail());
        }
        self.validate()?;
        Ok(key)
    }
}

/// Where a test may stop the process inside one append.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum JournalWritePoint {
    /// Part of the record has been written; no flush has happened.
    AfterPartialRecord,
    /// The complete record is durable in the file; the directory is not yet flushed.
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
    stat: Stat,
    last: Option<(u64, usize, [u8; 32])>,
}
impl Cursor {
    fn new(bytes: &[u8], stat: &Stat) -> io::Result<Self> {
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
        Ok(Self { stat: *stat, last })
    }
    fn matches(&self, stat: &Stat) -> bool {
        self.stat.same_content(stat)
    }
    fn tail_is_unchanged(&self, file: &File) -> io::Result<bool> {
        let Some((offset, length, digest)) = self.last else {
            return Ok(self.stat.size == 0);
        };
        let mut bytes = vec![0; length];
        read_exact_at(file, &mut bytes, offset)?;
        Ok(<[u8; 32]>::from(Sha256::digest(&bytes)) == digest)
    }
}

/// One Job journal's append-only writer (Swift `FileDurableJournal`). Every
/// append holds the Job directory's `.manifest.lock`, refuses after terminal
/// Manifest publication, stays bound to the journal file it opened, and is
/// durable (flushed, then the directory) before it returns. The caller
/// validates each record against the snapshot this appender presents.
pub struct HostJournalAppender {
    directory: HostDirectory,
    path: PathBuf,
    bound: Stat,
    cursor: Cursor,
    poisoned: bool,
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
fn snapshot(file: &File) -> io::Result<(Vec<u8>, Stat)> {
    let before = Stat::of(file)?;
    if before.size > MAX_JOURNAL_SNAPSHOT_BYTES {
        return Err(fail());
    }
    let mut bytes = vec![0; before.size as usize];
    read_exact_at(file, &mut bytes, 0)?;
    let after = Stat::of(file)?;
    if !after.same_file(&before) || !after.same_content(&before) {
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
        let name = host_fs::segment(JOURNAL)?;
        let mut created = false;
        let file =
            match host_fs::open_relative(&directory.0, &name, WRITE, FILE_OPEN, Kind::Any, None) {
                Ok(file) => file,
                Err(error) if error.kind() == io::ErrorKind::NotFound && create => {
                    if terminal {
                        return Err(refused(
                            "cannot create a journal after terminal Manifest publication",
                        ));
                    }
                    // FILE_CREATE never adopts an entry created meanwhile.
                    let file = host_fs::open_relative(
                        &directory.0,
                        &name,
                        WRITE,
                        FILE_CREATE,
                        Kind::NonDirectory,
                        Some(&Descriptor::private(false)?),
                    )?;
                    created = true;
                    file
                }
                Err(error) => return Err(error),
            };
        owned(&file, false, directory.1)?;
        if created {
            host_fs::flush(&file)?;
            host_fs::flush_directory(&directory.0)?;
        }
        let (mut bytes, mut stat) = snapshot(&file)?;
        let linked = directory.stat_at(JOURNAL)?;
        if !stat.same_file(&linked) {
            return Err(fail());
        }
        if let Some(length) = decide(&bytes, terminal)? {
            if terminal || length >= bytes.len() as u64 {
                return Err(refused(
                    "a torn journal can be repaired only before publication",
                ));
            }
            // Truncation of the bound, locked, owner-checked journal.
            file.set_len(length)?;
            host_fs::flush(&file)?;
            host_fs::flush_directory(&directory.0)?;
            (bytes, stat) = snapshot(&file)?;
            if bytes.len() as u64 != length {
                return Err(fail());
            }
        }
        let cursor = Cursor::new(&bytes, &stat)?;
        stat.inode()?;
        Ok((
            Self {
                directory,
                path: path.into(),
                bound: stat,
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
            .open_at_access(JOURNAL, WRITE | READ)
            .map_err(Refused)?;
        owned(&file, false, self.directory.1).map_err(Refused)?;
        let stat = Stat::of(&file).map_err(Refused)?;
        if !stat.same_file(&self.bound) {
            return Err(Refused(refused(
                "journal path no longer identifies the writer's bound journal",
            )));
        }
        let unchanged =
            self.cursor.matches(&stat) && self.cursor.tail_is_unchanged(&file).map_err(Refused)?;
        let before = if unchanged {
            validate(None).map_err(Refused)?;
            self.cursor.stat.size
        } else {
            let (bytes, current) = snapshot(&file).map_err(Refused)?;
            if !current.same_file(&self.bound) {
                return Err(Refused(fail()));
            }
            // A caller that accepts the snapshot also proves its tail is whole.
            validate(Some(&bytes)).map_err(Refused)?;
            Cursor::new(&bytes, &current).map_err(Refused)?;
            current.size
        };
        let written = (|| -> io::Result<Cursor> {
            let first = (record.len() / 2).max(1);
            host_fs::append_all(&file, &record[..first])?;
            checkpoint(JournalWritePoint::AfterPartialRecord);
            host_fs::append_all(&file, &record[first..])?;
            host_fs::flush(&file)?;
            checkpoint(JournalWritePoint::AfterRecordSync);
            host_fs::flush_directory(&self.directory.0)?;
            let after = Stat::of(&file)?;
            let linked = self.directory.stat_at(JOURNAL)?;
            if !after.same_file(&self.bound)
                || !linked.same_file(&self.bound)
                || after.size != before + record.len() as u64
            {
                return Err(fail());
            }
            Ok(Cursor {
                stat: after,
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
