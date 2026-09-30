//! The durable host store on NTFS (TASK-XPA-005): the same public surface,
//! names and bytes as the Unix `host_store.rs`, each check made with the
//! Windows primitive of `host_fs.rs`. Nothing here decides Runtime meaning;
//! it only answers the questions the Unix owner answers with `openat`,
//! `fstat`, `flock`, `renameat` and mode bits.
use super::host_fs::{
    self, Access, DIRECTORY, DIRECTORY_WRITE, Descriptor, Kind, READ, Stat, WRITE, fail, segment,
};
use std::fs::File;
use std::io::{self, Read, Write};
use std::os::windows::fs::FileExt;
use std::path::Path;
use windows_sys::Wdk::Storage::FileSystem::{FILE_CREATE, FILE_OPEN};
use windows_sys::Win32::Storage::FileSystem::{DELETE, READ_CONTROL, WRITE_DAC};

#[path = "host_journal.rs"]
mod journal;
pub use journal::{HostJournal, HostJournalAppender, JournalAppendError, JournalWritePoint};
#[path = "host_import_upload.rs"]
mod import_upload;
pub use import_upload::{
    HostImportSource, HostUploadFile, HostUploadReader, UploadChunkCheckpoint, UploadWritePoint,
};

pub struct HostDirectory(pub(super) File, pub(super) Ownership);

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HostDirectoryFacts {
    pub device: u64,
    pub inode: u64,
    /// A dev-unverified fallback is only a same-mount grouping key. It cannot
    /// prove a later export claim survived an unmount/remount.
    pub volume_identity: String,
}

/// What identifies a file's bytes without reading them: its volume serial
/// and file id (the device and inode), its size, and its last-write and
/// change times. A write changes the size or both times, and any change of
/// the file's metadata its change time, which no caller sets through the store.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct HostFileIdentity {
    pub device: u64,
    pub inode: u64,
    pub size: u64,
    /// Seconds and nanoseconds since 1970.
    pub modified: (i64, i64),
    /// Seconds and nanoseconds since 1970.
    pub changed: (i64, i64),
}

impl HostFileIdentity {
    pub(crate) fn of(stat: &Stat) -> io::Result<Self> {
        Ok(Self {
            device: stat.volume,
            inode: stat.inode()?,
            size: stat.size,
            modified: host_fs::unix_time(stat.written),
            changed: host_fs::unix_time(stat.changed),
        })
    }
}

#[derive(Clone, Copy)]
pub(super) enum Ownership {
    Private,
    TraceInventory,
    ExportParent,
    SessionTree { volume: u64 },
}
impl Ownership {
    /// The access a directory of this ownership is held with: the store
    /// writes (and flushes) only in private and Session trees.
    fn directory_access(self) -> u32 {
        match self {
            Self::Private | Self::SessionTree { .. } => DIRECTORY_WRITE,
            Self::TraceInventory | Self::ExportParent => DIRECTORY,
        }
    }
    /// The Unix `mode & mode_mask() == 0` rule, read from the DACL.
    fn permits(self, access: &Access) -> bool {
        match self {
            Self::Private => access.private(),
            Self::TraceInventory | Self::ExportParent => true,
            Self::SessionTree { .. } => access.no_public_write(),
        }
    }
    fn same_volume(self, volume: u64) -> bool {
        match self {
            Self::Private | Self::TraceInventory | Self::ExportParent => true,
            Self::SessionTree { volume: root } => root == volume,
        }
    }
}

/// How a stored payload compares with the length and digest it was published
/// with, in the classes Swift `RuntimeArtifactStore.validateStoredPayload`
/// distinguishes.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PayloadCheck {
    /// Opening it without following a link failed with this OS error number
    /// (a Win32 error code on Windows).
    Unopenable(i32),
    /// Not a private single-link regular file of the published length.
    TypeOrSize,
    /// The hashed bytes, or the file's identity while hashing, differ.
    DigestOrIdentity,
    Verified,
}
#[derive(Debug)]
pub enum DocumentPublishError {
    BeforePublication(io::Error),
    OutcomeUnknown(io::Error),
}
impl From<io::Error> for DocumentPublishError {
    fn from(error: io::Error) -> Self {
        Self::BeforePublication(error)
    }
}

/// A held lock: `LockFileEx` on the lock byte of one lock file. Only this
/// handle holds it; child processes never inherit it.
pub struct HostReadLock {
    file: File,
}

impl HostReadLock {
    /// Seal a private catalog's first durable publication without replacing
    /// its permanent lock file. A missing catalog after this mark is corrupt.
    /// The marker is byte 0; the lock covers a byte far beyond it, so the
    /// marker stays readable through every other handle.
    pub fn mark_catalog_initialized(&self, root: &HostDirectory, name: &str) -> io::Result<()> {
        if !matches!(root.1, Ownership::Private) {
            return Err(fail());
        }
        self.validate_link(root, name)?;
        match Stat::of(&self.file)?.size {
            0 => {
                write_all_at(&self.file, &[0xA5], 0)?;
            }
            1 => {
                let mut marker = [0];
                read_exact_at(&self.file, &mut marker, 0)?;
                if marker != [0xA5] {
                    return Err(fail());
                }
            }
            _ => return Err(fail()),
        }
        host_fs::flush(&self.file)?;
        host_fs::flush_directory(&root.0)?;
        self.validate_link(root, name)
    }

    /// The lock only covers this file. A replacement at the same name must
    /// never be mistaken for the lock held by this snapshot.
    pub fn validate_link(&self, root: &HostDirectory, name: &str) -> io::Result<()> {
        owned(&self.file, false, root.1)?;
        let held = Stat::of(&self.file)?;
        let linked = root.stat_at(name)?;
        if !held.same_file(&linked) {
            return Err(fail());
        }
        Ok(())
    }
}

impl Drop for HostReadLock {
    /// Unlock before the handle closes, as the Unix owner does.
    fn drop(&mut self) {
        host_fs::unlock(&self.file);
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum HostEntryKind {
    Directory,
    Regular,
    Other,
}

fn owned(file: &File, directory: bool, ownership: Ownership) -> io::Result<()> {
    let stat = Stat::of(file)?;
    let access = Access::of(file)?;
    let trace = matches!(ownership, Ownership::TraceInventory);
    if (!trace && !access.owner_is_user)
        || !ownership.permits(&access)
        || !ownership.same_volume(stat.volume)
        || (directory && !stat.directory())
        || (!directory && (!stat.regular() || (!trace && stat.links != 1)))
    {
        return Err(fail());
    }
    Ok(())
}

/// What [`HostDirectory::read`] requires once it has read a document to its
/// end: exactly the size the file had when it was opened, within the
/// maximum; the size and the write and change times unchanged since; and
/// the name still linking the file that was read.
fn read_whole(before: &Stat, after: &Stat, linked: &Stat, length: u64, maximum: usize) -> bool {
    length <= maximum as u64
        && length == before.size
        && before.same_content(after)
        && before.same_file(linked)
}

/// Swift `RockchipPostFlashHDCBindingStore.validateFile`: an owned,
/// single-link regular file the owner alone may read and write.
fn owner_only(file: &File, ownership: Ownership) -> io::Result<Stat> {
    owned(file, false, ownership)?;
    if !Access::of(file)?.owner_read_write() {
        return Err(fail());
    }
    Stat::of(file)
}

fn read_exact_at(file: &File, mut buffer: &mut [u8], mut offset: u64) -> io::Result<()> {
    while !buffer.is_empty() {
        match file.seek_read(buffer, offset) {
            Ok(0) => return Err(io::ErrorKind::UnexpectedEof.into()),
            Ok(count) => {
                buffer = &mut buffer[count..];
                offset += count as u64;
            }
            Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
            Err(error) => return Err(error),
        }
    }
    Ok(())
}

fn write_all_at(file: &File, mut bytes: &[u8], mut offset: u64) -> io::Result<()> {
    while !bytes.is_empty() {
        match file.seek_write(bytes, offset) {
            Ok(0) => return Err(io::ErrorKind::WriteZero.into()),
            Ok(count) => {
                bytes = &bytes[count..];
                offset += count as u64;
            }
            Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
            Err(error) => return Err(error),
        }
    }
    Ok(())
}

fn would_block() -> io::Error {
    io::Error::new(
        io::ErrorKind::WouldBlock,
        "the lock is held by another owner",
    )
}

/// Which check of [`HostDirectory::read_owner_only_detailed`] refused a
/// present document.
#[derive(Debug)]
pub enum OwnerOnlyReadFailure {
    /// The name could not be opened: a link, a directory, any other error.
    Open(io::Error),
    /// Not the owner's single-link regular file the owner alone may read
    /// and write.
    Identity,
    /// Empty, or larger than the maximum.
    Size,
    /// The read failed or ended before the size the file reported.
    Truncated,
}

/// What [`HostDirectory::create_exclusive_or_match`] found at the name.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ExclusiveOutcome {
    /// The name was free: the bytes are there now, synced, owner-only.
    Created,
    /// The name already held exactly these bytes; nothing was written.
    Matched,
    /// The name already holds a different owner-only document; nothing was
    /// written and nothing was replaced.
    Different,
}

impl HostDirectory {
    pub fn directory_identity(&self) -> io::Result<(u64, u64)> {
        owned(&self.0, true, self.1)?;
        let stat = Stat::of(&self.0)?;
        Ok((stat.volume, stat.inode()?))
    }

    /// Removing a now-empty cache grouping directory never traverses contents.
    pub fn remove_empty_directory(&self, name: &str, expected: (u64, u64)) -> io::Result<()> {
        if !matches!(self.1, Ownership::Private)
            || self.child(name)?.directory_identity()? != expected
        {
            return Err(fail());
        }
        host_fs::unlink(&self.0, &segment(name)?, Kind::Directory)?;
        host_fs::flush_directory(&self.0)
    }

    /// Observe the held handle: the volume serial and file id, and the
    /// volume's GUID in the Unix `uuid:` spelling (the profile's
    /// VolumeIdentityResolver: never a drive letter or path string). No
    /// caller-provided volume fact is accepted.
    pub fn export_facts(&self) -> io::Result<HostDirectoryFacts> {
        owned(&self.0, true, self.1)?;
        let stat = Stat::of(&self.0)?;
        let volume_identity = host_fs::final_path(&self.0, true)
            .ok()
            .and_then(|path| {
                let text = path.to_str()?.strip_prefix(r"\\?\Volume{")?;
                let guid = text.get(..36)?;
                (text.get(36..37) == Some("}")
                    && guid.bytes().enumerate().all(|(index, byte)| {
                        if matches!(index, 8 | 13 | 18 | 23) {
                            byte == b'-'
                        } else {
                            byte.is_ascii_hexdigit()
                        }
                    }))
                .then(|| format!("uuid:{}", guid.to_ascii_lowercase()))
            })
            .unwrap_or_else(|| format!("dev-unverified:{}", stat.volume));
        Ok(HostDirectoryFacts {
            device: stat.volume,
            inode: stat.inode()?,
            volume_identity,
        })
    }

    /// An export parent is an existing owned physical directory. Unlike
    /// Runtime records it can be an ordinary user directory others may read;
    /// this entry point does not grant document publication or locking.
    pub fn open_export_parent(path: &Path) -> io::Result<Self> {
        let file = host_fs::open_directory_path(path, DIRECTORY)?;
        host_fs::canonical(path, &file)?;
        owned(&file, true, Ownership::ExportParent)?;
        Ok(Self(file, Ownership::ExportParent))
    }

    /// Check owner rights and actual create/remove access before a Session
    /// root selection is published. No existing entry changes.
    pub fn probe_writable(&self) -> io::Result<()> {
        if !matches!(self.1, Ownership::Private) {
            return Err(fail());
        }
        owned(&self.0, true, self.1)?;
        if !Access::of(&self.0)?.owner_full_directory() {
            return Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "private root is not owner-writable",
            ));
        }
        let nonce = u128::from_ne_bytes(crate::random_bytes::<16>()?);
        let name = segment(&format!(".arkdeck-runtime-storage-probe-{nonce:032x}"))?;
        let probe = host_fs::open_relative(
            &self.0,
            &name,
            WRITE,
            FILE_CREATE,
            Kind::NonDirectory,
            Some(&Descriptor::private(false)?),
        )?;
        drop(probe);
        host_fs::unlink(&self.0, &name, Kind::NonDirectory)
    }

    /// Create or reopen a fixed private child without following a replaced
    /// parent path. Existing directory permissions are never changed.
    pub fn private_child(&self, name: &str) -> io::Result<Self> {
        if !matches!(self.1, Ownership::Private) {
            return Err(fail());
        }
        match self.make_directory(name) {
            Ok(()) => {}
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {}
            Err(error) => return Err(error),
        }
        let child = self.child(name)?;
        host_fs::flush_directory(&self.0)?;
        Ok(child)
    }

    fn make_directory(&self, name: &str) -> io::Result<()> {
        host_fs::open_relative(
            &self.0,
            &segment(name)?,
            DIRECTORY,
            FILE_CREATE,
            Kind::Directory,
            Some(&Descriptor::private(true)?),
        )
        .map(drop)
    }

    /// Open or create (owner-only) a lock file for reading and writing.
    fn lock_file(&self, name: &str) -> io::Result<(File, bool)> {
        let name = segment(name)?;
        match host_fs::open_relative(
            &self.0,
            &name,
            WRITE,
            FILE_CREATE,
            Kind::Any,
            Some(&Descriptor::private(false)?),
        ) {
            Ok(file) => Ok((file, true)),
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => Ok((
                host_fs::open_relative(&self.0, &name, WRITE, FILE_OPEN, Kind::Any, None)?,
                false,
            )),
            Err(error) => Err(error),
        }
    }

    /// A private document owner's lock, shared across processes. Never unlink
    /// the lock: replacing its file would split the writer population.
    pub fn lock_document(&self, name: &str) -> io::Result<HostReadLock> {
        if !matches!(self.1, Ownership::Private) {
            return Err(fail());
        }
        let (file, _) = self.lock_file(name)?;
        owned(&file, false, self.1)?;
        if !host_fs::lock(&file, false)? {
            return Err(would_block());
        }
        let lock = HostReadLock { file };
        lock.validate_link(self, name)?;
        Ok(lock)
    }

    /// Swift `RockchipPostFlashHDCBindingStore.archiveSuperseded`: a document
    /// created exactly once at its name, written and synced in place (no
    /// rename, no unlink), and — when the name is already taken — compared
    /// byte for byte against the owner-only file there instead of replaced.
    /// A taken name is evidence: nothing here ever removes one.
    pub fn create_exclusive_or_match(
        &self,
        name: &str,
        bytes: &[u8],
        maximum: usize,
    ) -> io::Result<ExclusiveOutcome> {
        if !matches!(self.1, Ownership::Private) || bytes.is_empty() || bytes.len() > maximum {
            return Err(fail());
        }
        owned(&self.0, true, self.1)?;
        let created = host_fs::open_relative(
            &self.0,
            &segment(name)?,
            WRITE,
            FILE_CREATE,
            Kind::NonDirectory,
            Some(&Descriptor::private(false)?),
        );
        let mut file = match created {
            Ok(file) => file,
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {
                let existing = self.open_at(name)?;
                let stat = owner_only(&existing, self.1)?;
                if stat.size > maximum as u64 {
                    return Err(fail());
                }
                if stat.size != bytes.len() as u64 {
                    return Ok(ExclusiveOutcome::Different);
                }
                let mut held = Vec::with_capacity(bytes.len());
                (&existing)
                    .take(maximum as u64 + 1)
                    .read_to_end(&mut held)?;
                return Ok(if held == bytes {
                    ExclusiveOutcome::Matched
                } else {
                    ExclusiveOutcome::Different
                });
            }
            Err(error) => return Err(error),
        };
        file.write_all(bytes)?;
        host_fs::flush(&file)?;
        host_fs::flush_directory(&self.0)?;
        Ok(ExclusiveOutcome::Created)
    }

    /// Swift `RockchipPostFlashHDCBindingStore.load`: `None` when the name is
    /// absent; otherwise the whole document, which must be the owner's
    /// single-link regular file the owner alone may read and write, opened
    /// through no link, of 1..=`maximum` bytes.
    pub fn read_owner_only(&self, name: &str, maximum: usize) -> io::Result<Option<Vec<u8>>> {
        self.read_owner_only_detailed(name, maximum)
            .map_err(|failure| match failure {
                OwnerOnlyReadFailure::Open(error) => error,
                OwnerOnlyReadFailure::Identity
                | OwnerOnlyReadFailure::Size
                | OwnerOnlyReadFailure::Truncated => fail(),
            })
    }

    /// [`Self::read_owner_only`], naming which of Swift's checks refused,
    /// in the order Swift makes them: the open, the file's identity and
    /// rights, its size, then the read.
    pub fn read_owner_only_detailed(
        &self,
        name: &str,
        maximum: usize,
    ) -> Result<Option<Vec<u8>>, OwnerOnlyReadFailure> {
        let file = match self.open_at(name) {
            Ok(file) => file,
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
            Err(error) => return Err(OwnerOnlyReadFailure::Open(error)),
        };
        let stat = owner_only(&file, self.1).map_err(|_| OwnerOnlyReadFailure::Identity)?;
        if stat.size == 0 || stat.size > maximum as u64 {
            return Err(OwnerOnlyReadFailure::Size);
        }
        let mut bytes = Vec::with_capacity(stat.size as usize);
        (&file)
            .take(maximum as u64 + 1)
            .read_to_end(&mut bytes)
            .map_err(|_| OwnerOnlyReadFailure::Truncated)?;
        if bytes.len() as u64 != stat.size {
            return Err(OwnerOnlyReadFailure::Truncated);
        }
        Ok(Some(bytes))
    }

    /// Flush a fresh private file, atomically rename it, then flush the
    /// directory. Errors after rename must be treated as uncertain
    /// publication by callers.
    pub fn publish_document(
        &self,
        name: &str,
        bytes: &[u8],
        maximum: usize,
    ) -> Result<(), DocumentPublishError> {
        if bytes.is_empty() {
            return Err(fail().into());
        }
        self.publish_with_checkpoint(name, bytes, maximum, |_| {})
    }

    /// Swift `DurableFileWriter.createOrReplaceAtomically`, with which the
    /// capability store writes its checkpoint and empties its ledger: published
    /// as [`Self::publish_document`] publishes, where the document may be empty.
    pub fn replace_document(
        &self,
        name: &str,
        bytes: &[u8],
        maximum: usize,
    ) -> Result<(), DocumentPublishError> {
        self.publish_with_checkpoint(name, bytes, maximum, |_| {})
    }

    /// Swift `RuntimeCapabilityStore.appendEvent`'s write: the bytes appended
    /// to an owner-only document, created owner-only when absent, through no
    /// link, then fully flushed. Swift synchronizes no directory for it, not
    /// even for a new document; the store's lock serializes its writers.
    pub fn append_synchronized(&self, name: &str, bytes: &[u8]) -> io::Result<()> {
        if !matches!(self.1, Ownership::Private) {
            return Err(fail());
        }
        let (file, _) = self.open_or_create(name)?;
        owned(&file, false, self.1)?;
        host_fs::append_all(&file, bytes)?;
        host_fs::flush(&file)
    }

    /// An existing document opened for reading and writing, or a new one
    /// created owner-only: the handle and whether it was created.
    fn open_or_create(&self, name: &str) -> io::Result<(File, bool)> {
        let name = segment(name)?;
        match host_fs::open_relative(
            &self.0,
            &name,
            WRITE,
            FILE_CREATE,
            Kind::NonDirectory,
            Some(&Descriptor::private(false)?),
        ) {
            Ok(file) => Ok((file, true)),
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => Ok((
                host_fs::open_relative(&self.0, &name, WRITE, FILE_OPEN, Kind::Any, None)?,
                false,
            )),
            Err(error) => Err(error),
        }
    }

    pub(super) fn publish_with_checkpoint(
        &self,
        name: &str,
        bytes: &[u8],
        maximum: usize,
        checkpoint: impl Fn(&str),
    ) -> Result<(), DocumentPublishError> {
        if !matches!(self.1, Ownership::Private) || bytes.len() > maximum {
            return Err(fail().into());
        }
        owned(&self.0, true, self.1)?;
        let target = segment(name)?;
        let nonce: String = crate::random_bytes::<16>()?
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect();
        let (_temporary, mut file) = Temporary::create(&self.0, &format!(".{name}.{nonce}.part"))?;
        file.write_all(bytes)?;
        host_fs::flush(&file)?;
        checkpoint("beforeRename");
        host_fs::rename(&file, &self.0, &target, true)
            .map_err(DocumentPublishError::OutcomeUnknown)?;
        checkpoint("afterRename");
        host_fs::flush_directory(&self.0).map_err(DocumentPublishError::OutcomeUnknown)
    }

    /// Swift `RuntimeArtifactStore.validateStoredPayload`'s seal: an owned,
    /// single-link regular payload, opened through no link, becomes owner
    /// read-only (its DACL: the owner may read).
    pub fn seal_document(&self, name: &str) -> io::Result<()> {
        if !matches!(self.1, Ownership::Private) {
            return Err(fail());
        }
        // Write access is taken before the seal removes it: the flush that
        // follows needs a handle opened for writing.
        let file = host_fs::open_relative(
            &self.0,
            &segment(name)?,
            WRITE | WRITE_DAC,
            FILE_OPEN,
            Kind::Any,
            None,
        )?;
        owned(&file, false, self.1)?;
        host_fs::seal(&file)?;
        host_fs::flush(&file)
    }

    /// Swift `RockchipPostFlashHDCBindingStore.prepareRoot`: a private root
    /// that is created when absent — every missing level owner-only — and
    /// made owner-only whether or not it existed, then opened as
    /// [`HostDirectory::open`] opens it, by its canonical path.
    pub fn open_or_create_private(path: &Path) -> io::Result<Self> {
        if !path.is_absolute() {
            return Err(fail());
        }
        host_fs::create_private_directories(path)?;
        let canonical = path.canonicalize()?;
        {
            use std::os::windows::fs::OpenOptionsExt;
            use windows_sys::Win32::Storage::FileSystem::FILE_FLAG_BACKUP_SEMANTICS;
            // As Swift's `chmod(rootURL.path, 0o700)`: the canonical path's
            // directory, whose DACL becomes the private one.
            let root = std::fs::OpenOptions::new()
                .access_mode(READ_CONTROL | WRITE_DAC)
                .share_mode(host_fs::SHARE_ALL)
                .custom_flags(FILE_FLAG_BACKUP_SEMANTICS)
                .open(&canonical)?;
            host_fs::set_dacl(&root, &Descriptor::private(true)?)?;
        }
        Self::open_root(&canonical, false)
    }

    pub fn open(path: &Path) -> io::Result<Self> {
        Self::open_root(path, false)
    }

    /// ArkTrace inventory measures readable entries without imposing the
    /// private writer's rights or single-link rules. Its root must still be
    /// owned by this user. No DACL is changed.
    pub fn open_trace_inventory(path: &Path) -> io::Result<Self> {
        let file = host_fs::open_directory_path(path, DIRECTORY)?;
        host_fs::canonical(path, &file)?;
        if !Access::of(&file)?.owner_is_user {
            return Err(fail());
        }
        owned(&file, true, Ownership::TraceInventory)?;
        Ok(Self(file, Ownership::TraceInventory))
    }

    /// SessionRetentionCatalog's existing owner/same-volume/no-public-write
    /// boundary. This does not change the stricter private-cache entry point.
    pub fn open_session_tree(path: &Path) -> io::Result<Self> {
        Self::open_root(path, true)
    }

    fn open_root(path: &Path, session_tree: bool) -> io::Result<Self> {
        let file = host_fs::open_directory_path(path, DIRECTORY_WRITE)?;
        host_fs::canonical(path, &file)?;
        let ownership = if session_tree {
            Ownership::SessionTree {
                volume: Stat::of(&file)?.volume,
            }
        } else {
            Ownership::Private
        };
        owned(&file, true, ownership)?;
        Ok(Self(file, ownership))
    }

    /// Recheck the caller's root binding after a bounded snapshot. Handle
    /// reads remain anchored after rename, but cannot certify a replacement
    /// namespace at the original path.
    pub fn validate_path(&self, path: &Path) -> io::Result<()> {
        owned(&self.0, true, self.1)?;
        let linked = host_fs::open_directory_path(path, DIRECTORY)?;
        host_fs::canonical(path, &linked)?;
        let linked = Stat::of(&linked)?;
        if !linked.directory() || !Stat::of(&self.0)?.same_file(&linked) {
            return Err(fail());
        }
        Ok(())
    }

    pub fn child(&self, name: &str) -> io::Result<Self> {
        let file = host_fs::open_relative(
            &self.0,
            &segment(name)?,
            self.1.directory_access(),
            FILE_OPEN,
            Kind::Directory,
            None,
        )?;
        owned(&file, true, self.1)?;
        Ok(Self(file, self.1))
    }

    pub(super) fn open_at(&self, name: &str) -> io::Result<File> {
        self.open_at_access(name, READ)
    }

    pub(super) fn open_at_access(&self, name: &str, access: u32) -> io::Result<File> {
        host_fs::open_relative(&self.0, &segment(name)?, access, FILE_OPEN, Kind::Any, None)
    }

    pub fn names(&self, maximum: usize) -> io::Result<Vec<String>> {
        host_fs::names(&self.0, maximum)
    }

    pub fn kind_and_size(&self, name: &str) -> io::Result<(HostEntryKind, i64)> {
        let stat = self.stat_at(name)?;
        let kind = if stat.directory() {
            HostEntryKind::Directory
        } else if stat.regular() {
            HostEntryKind::Regular
        } else {
            HostEntryKind::Other
        };
        Ok((kind, i64::try_from(stat.size).map_err(|_| fail())?))
    }

    /// Measurement metadata validated under this directory's ownership rules.
    pub fn owned_kind_and_size(&self, name: &str) -> io::Result<(HostEntryKind, u64)> {
        let (stat, access) = self.inspect_at(name)?;
        if !access.owner_is_user || !self.1.permits(&access) || !self.1.same_volume(stat.volume) {
            return Err(fail());
        }
        if stat.directory() {
            Ok((HostEntryKind::Directory, 0))
        } else if stat.regular() && stat.links == 1 {
            Ok((HostEntryKind::Regular, stat.size))
        } else {
            Err(fail())
        }
    }

    /// `fstatat(AT_SYMLINK_NOFOLLOW)`: what `name` names in the held
    /// directory, a reparse point itself rather than what it names.
    pub(super) fn stat_at(&self, name: &str) -> io::Result<Stat> {
        Ok(self.inspect_at(name)?.0)
    }

    fn inspect_at(&self, name: &str) -> io::Result<(Stat, Access)> {
        let entry = self.inspect_entry(name)?;
        Ok((Stat::of(&entry)?, Access::of(&entry)?))
    }

    /// An entry opened for its attributes and security only. A reparse point
    /// is opened as itself, so its own attributes are reported.
    fn inspect_entry(&self, name: &str) -> io::Result<File> {
        host_fs::inspect_relative(&self.0, &segment(name)?)
    }

    pub fn read(&self, name: &str, maximum: usize) -> io::Result<Vec<u8>> {
        self.read_identified(name, maximum).map(|(bytes, _)| bytes)
    }

    /// [`Self::read`], and the identity of the file whose bytes these are:
    /// `read` requires it unchanged from before the read to after it, and
    /// still linked at `name`.
    pub fn read_identified(
        &self,
        name: &str,
        maximum: usize,
    ) -> io::Result<(Vec<u8>, HostFileIdentity)> {
        let file = self.open_at(name)?;
        owned(&file, false, self.1)?;
        let before = Stat::of(&file)?;
        if before.size > maximum as u64 {
            return Err(fail());
        }
        let mut bytes = Vec::new();
        (&file).take(maximum as u64 + 1).read_to_end(&mut bytes)?;
        let after = Stat::of(&file)?;
        let linked = self.stat_at(name)?;
        if !read_whole(&before, &after, &linked, bytes.len() as u64, maximum) {
            return Err(fail());
        }
        Ok((bytes, HostFileIdentity::of(&before)?))
    }

    /// The identity of what `name` names in the held directory, a reparse
    /// point itself rather than what it names.
    pub fn file_identity(&self, name: &str) -> io::Result<HostFileIdentity> {
        HostFileIdentity::of(&self.stat_at(name)?)
    }

    /// [`Self::read`] for a reader that parses the document as it streams
    /// instead of holding its bytes: the same open, identity and size checks
    /// before any byte is read, [`HostDocument::pass`] for a read from the
    /// first byte, [`HostDocument::read_range`] for a part read again, and
    /// [`HostDocument::check`] for the checks `read` makes once its read is
    /// complete.
    pub fn open_document(&self, name: &str, maximum: usize) -> io::Result<HostDocument<'_>> {
        let file = self.open_at(name)?;
        owned(&file, false, self.1)?;
        let before = Stat::of(&file)?;
        if before.size > maximum as u64 {
            return Err(fail());
        }
        Ok(HostDocument {
            directory: self,
            name: name.to_owned(),
            file,
            before,
            maximum,
        })
    }

    /// Name an optional export Journal using bounded memory and a retained
    /// handle. Absence is distinct from a failed or unsafe read; the linked
    /// file and its times must survive the complete read.
    pub fn optional_document_digest(&self, name: &str, maximum: u64) -> io::Result<Option<String>> {
        use sha2::{Digest, Sha256};
        let file = match self.open_at(name) {
            Ok(file) => file,
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
            Err(error) => return Err(error),
        };
        owned(&file, false, self.1)?;
        let before = Stat::of(&file)?;
        if before.size > maximum {
            return Err(fail());
        }
        let mut digest = Sha256::new();
        let count = hash_to_end(&file, |bytes, _| {
            digest.update(bytes);
            Ok(())
        })?;
        if count > before.size || count > maximum {
            return Err(fail());
        }
        let after = Stat::of(&file)?;
        let linked = self.stat_at(name)?;
        if count != before.size || !before.same_content(&after) || !before.same_file(&linked) {
            return Err(fail());
        }
        Ok(Some(format!("{:x}", digest.finalize())))
    }

    /// Verify immutable payload bytes using bounded memory and a retained
    /// handle. Both the linked file and its times must survive.
    pub fn verify_payload(&self, name: &str, length: u64, digest: &str) -> io::Result<()> {
        use sha2::{Digest, Sha256};
        let file = self.open_at(name)?;
        owned(&file, false, self.1)?;
        let before = Stat::of(&file)?;
        if before.size != length {
            return Err(fail());
        }
        let mut hash = Sha256::new();
        let hashed = hash_to_end(&file, |bytes, total| {
            if total > length {
                return Err(fail());
            }
            hash.update(bytes);
            Ok(())
        })?;
        let after = Stat::of(&file)?;
        let linked = self.stat_at(name)?;
        if hashed != length
            || format!("{:x}", hash.finalize()) != digest
            || !before.same_content(&after)
            || !before.same_file(&linked)
        {
            return Err(fail());
        }
        Ok(())
    }

    /// Classify an immutable payload as Swift
    /// `RuntimeArtifactStore.validateStoredPayload` classifies its refusals:
    /// it cannot be opened without following a link, it is not a private
    /// single-link regular file of the published length, or its bytes or its
    /// identity changed while they were hashed. Never follows a link.
    pub fn check_payload(&self, name: &str, length: u64, digest: &str) -> io::Result<PayloadCheck> {
        use sha2::{Digest, Sha256};
        let file = match self.open_at(name) {
            Ok(file) => file,
            Err(error) => {
                return error
                    .raw_os_error()
                    .map(PayloadCheck::Unopenable)
                    .ok_or(error);
            }
        };
        let before = Stat::of(&file)?;
        if owned(&file, false, self.1).is_err() || before.size != length {
            return Ok(PayloadCheck::TypeOrSize);
        }
        let mut hash = Sha256::new();
        let mut longer = false;
        let hashed = hash_to_end(&file, |bytes, total| {
            if total > length {
                longer = true;
                return Err(fail());
            }
            hash.update(bytes);
            Ok(())
        });
        let hashed = match hashed {
            Ok(hashed) => hashed,
            Err(_) if longer => return Ok(PayloadCheck::DigestOrIdentity),
            Err(error) => return Err(error),
        };
        let after = Stat::of(&file)?;
        let Ok(linked) = self.stat_at(name) else {
            return Ok(PayloadCheck::DigestOrIdentity);
        };
        Ok(
            if hashed != length
                || format!("{:x}", hash.finalize()) != digest
                || !before.same_content(&after)
                || !before.same_file(&linked)
            {
                PayloadCheck::DigestOrIdentity
            } else {
                PayloadCheck::Verified
            },
        )
    }

    /// Hash the entire immutable payload while retaining only the requested
    /// range. No bytes escape until the held handle and named file are
    /// revalidated.
    pub fn verify_payload_range(
        &self,
        name: &str,
        length: u64,
        digest: &str,
        offset: u64,
        maximum: usize,
    ) -> io::Result<Vec<u8>> {
        self.verify_payload_range_checked(name, length, digest, offset, maximum, || {})
    }

    pub(super) fn verify_payload_range_checked(
        &self,
        name: &str,
        length: u64,
        digest: &str,
        offset: u64,
        maximum: usize,
        after_read: impl FnOnce(),
    ) -> io::Result<Vec<u8>> {
        use sha2::{Digest, Sha256};
        if offset > length || maximum == 0 || maximum > 4_194_304 {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "Invalid Artifact range",
            ));
        }
        let file = self.open_at(name)?;
        owned(&file, false, self.1)?;
        let before = Stat::of(&file)?;
        let before_access = Access::of(&file)?;
        if before.size != length {
            return Err(fail());
        }
        let end = offset + (length - offset).min(maximum as u64);
        let mut bytes = Vec::with_capacity((end - offset) as usize);
        let mut hash = Sha256::new();
        let hashed = hash_to_end(&file, |chunk, next| {
            if next > length {
                return Err(fail());
            }
            let hashed = next - chunk.len() as u64;
            let start = offset.max(hashed);
            let stop = end.min(next);
            if start < stop {
                bytes
                    .extend_from_slice(&chunk[(start - hashed) as usize..(stop - hashed) as usize]);
            }
            hash.update(chunk);
            Ok(())
        })?;
        after_read();
        owned(&file, false, self.1)?;
        let after = Stat::of(&file)?;
        let (linked, linked_access) = self.inspect_at(name)?;
        if hashed != length
            || format!("{:x}", hash.finalize()) != digest
            || before != after
            || before_access != Access::of(&file)?
            || !before.same_file(&linked)
            || before != linked
            || before_access != linked_access
        {
            return Err(fail());
        }
        Ok(bytes)
    }

    /// Match ArkTrace's existing lock probe. Read/write access is needed to
    /// preserve its refusal of read-only lock files; no creation, truncation
    /// or write occurs. Key locks are bounded to 4096 bytes; entry leases have
    /// no size bound.
    pub fn try_trace_lock_existing(
        &self,
        name: &str,
        maximum: Option<u64>,
    ) -> io::Result<Option<HostReadLock>> {
        if !matches!(self.1, Ownership::TraceInventory) {
            return Err(fail());
        }
        let file = match self.open_at_access(name, WRITE) {
            Ok(file) => file,
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
            Err(error) => return Err(error),
        };
        owned(&file, false, self.1)?;
        let size = Stat::of(&file)?.size;
        if maximum.is_some_and(|limit| size > limit) {
            return Err(fail());
        }
        if !host_fs::lock(&file, false)? {
            return Ok(None);
        }
        let lock = HostReadLock { file };
        lock.validate_link(self, name)?;
        Ok(Some(lock))
    }

    pub fn try_lock_existing(&self, name: &str) -> io::Result<Option<HostReadLock>> {
        self.try_lock_existing_impl(name, true, READ)
    }

    /// Never creates a lock file. Missing files remain NotFound; only an
    /// existing exclusive lock held by another owner returns None. Bootstrap
    /// opens its lock read/write, matching the existing Swift owner without
    /// changing the file or broadening ordinary snapshot readers.
    pub fn try_lock_existing_strict(&self, name: &str) -> io::Result<Option<HostReadLock>> {
        self.try_lock_existing_impl(name, false, WRITE)
    }

    fn try_lock_existing_impl(
        &self,
        name: &str,
        allow_missing: bool,
        access: u32,
    ) -> io::Result<Option<HostReadLock>> {
        let file = match self.open_at_access(name, access) {
            Ok(file) => file,
            Err(error) if allow_missing && error.kind() == io::ErrorKind::NotFound => {
                return Ok(None);
            }
            Err(error) => return Err(error),
        };
        owned(&file, false, self.1)?;
        if !host_fs::lock(&file, false)? {
            return Ok(None);
        }
        let lock = HostReadLock { file };
        lock.validate_link(self, name)?;
        Ok(Some(lock))
    }

    // The writes a Session publication makes (Unix `host_session_publication.rs`).

    /// Swift `SessionStore.createSession`'s `mkdir(root, 0700)`: a new private
    /// child. An existing entry is refused, never adopted.
    pub fn create_private_child(&self, name: &str) -> io::Result<Self> {
        if !matches!(self.1, Ownership::Private) {
            return Err(fail());
        }
        self.make_directory(name)?;
        self.child(name)
    }

    /// The directory's namespace barrier.
    pub fn sync(&self) -> io::Result<()> {
        owned(&self.0, true, self.1)?;
        host_fs::flush_directory(&self.0)
    }

    /// A private document created once and fully flushed, as Swift writes a
    /// fresh Session identity.
    pub fn create_document(&self, name: &str, bytes: &[u8]) -> io::Result<()> {
        if !matches!(self.1, Ownership::Private) {
            return Err(fail());
        }
        let mut file = host_fs::open_relative(
            &self.0,
            &segment(name)?,
            WRITE,
            FILE_CREATE,
            Kind::NonDirectory,
            Some(&Descriptor::private(false)?),
        )?;
        file.write_all(bytes)?;
        host_fs::flush(&file)
    }

    /// A lock file held by a blocking lock and still bound to its name once
    /// held, created owner-only when absent: Swift's terminal publication
    /// lock (which synchronizes a new lock with its directory) and its
    /// Artifact publication shards (which do not).
    pub fn wait_lock(&self, name: &str, synchronize_created: bool) -> io::Result<HostReadLock> {
        if !matches!(self.1, Ownership::Private) {
            return Err(fail());
        }
        let (file, created) = self.lock_file(name)?;
        owned(&file, false, self.1)?;
        if created && synchronize_created {
            host_fs::flush(&file)?;
            host_fs::flush_directory(&self.0)?;
        }
        host_fs::lock(&file, true)?;
        let lock = HostReadLock { file };
        lock.validate_link(self, name)?;
        Ok(lock)
    }

    /// Swift `FileDurableSessionAuditStore.appendAndSynchronize` for one
    /// record: appended under the log's exclusive writer lock, a new log
    /// flushed with its directory first, then the file and directory. The
    /// log's own lock byte lies beyond any record, so readers of the log are
    /// never refused by it.
    pub fn append_record(&self, name: &str, bytes: &[u8]) -> io::Result<()> {
        if !matches!(self.1, Ownership::Private) {
            return Err(fail());
        }
        let (file, created) = self.open_or_create(name)?;
        owned(&file, false, self.1)?;
        if !host_fs::lock(&file, false)? {
            return Err(would_block());
        }
        let _unlock = Unlock(&file);
        if created {
            host_fs::flush(&file)?;
            host_fs::flush_directory(&self.0)?;
        }
        host_fs::append_all(&file, bytes)?;
        host_fs::flush(&file)?;
        host_fs::flush_directory(&self.0)
    }

    /// Swift `AtomicSessionManifestPublisher.publish`: a fresh private file,
    /// flushed, renamed onto `name` only while nothing holds that name
    /// (`RENAME_EXCL`), then the directory barrier. An existing `name` refuses
    /// before publication; an error after the rename leaves it uncertain.
    pub fn publish_exclusive(&self, name: &str, bytes: &[u8]) -> Result<(), DocumentPublishError> {
        if !matches!(self.1, Ownership::Private) || bytes.is_empty() {
            return Err(fail().into());
        }
        owned(&self.0, true, self.1)?;
        let target = segment(name)?;
        let nonce: String = crate::random_bytes::<16>()?
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect();
        let (_temporary, mut file) = Temporary::create(&self.0, &format!(".{name}.{nonce}.tmp"))?;
        file.write_all(bytes)?;
        host_fs::flush(&file)?;
        host_fs::rename(&file, &self.0, &target, false)
            .map_err(DocumentPublishError::BeforePublication)?;
        drop(file);
        host_fs::flush_directory(&self.0).map_err(DocumentPublishError::OutcomeUnknown)
    }

    /// This directory's child `name` renamed to `to` in `destination`,
    /// never over an existing entry: `true` once moved, `false` when `to`
    /// already exists. A Session written aside reaches its published name in
    /// one step and never replaces another entry there.
    pub fn move_exclusive(
        &self,
        name: &str,
        destination: &HostDirectory,
        to: &str,
    ) -> io::Result<bool> {
        if !matches!(self.1, Ownership::Private) || !matches!(destination.1, Ownership::Private) {
            return Err(fail());
        }
        let source = host_fs::open_relative(
            &self.0,
            &segment(name)?,
            DELETE | windows_sys::Win32::Storage::FileSystem::FILE_READ_ATTRIBUTES,
            FILE_OPEN,
            Kind::Any,
            None,
        )?;
        match host_fs::rename(&source, &destination.0, &segment(to)?, false) {
            Ok(()) => Ok(true),
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => Ok(false),
            Err(error) => Err(error),
        }
    }

    /// The tree `name` below this directory, removed through handles only:
    /// its directories and regular files, and never a reparse point or any
    /// other kind of entry, which refuses. An absent tree is already removed.
    pub fn remove_tree(&self, name: &str) -> io::Result<()> {
        if !matches!(self.1, Ownership::Private) {
            return Err(fail());
        }
        remove_tree(&self.0, name, 0).map_err(|_| fail())
    }

    /// The directory `name` below this one removed if it is empty: `true`
    /// once removed, `false` when it still holds an entry or is gone.
    pub fn remove_if_empty(&self, name: &str) -> io::Result<bool> {
        if !matches!(self.1, Ownership::Private) {
            return Err(fail());
        }
        match host_fs::unlink(&self.0, &segment(name)?, Kind::Directory) {
            Ok(()) => Ok(true),
            Err(error)
                if matches!(
                    error.kind(),
                    io::ErrorKind::DirectoryNotEmpty | io::ErrorKind::NotFound
                ) =>
            {
                Ok(false)
            }
            Err(error) => Err(error),
        }
    }
}

/// Hash a file from its first byte to its end through one handle, calling
/// `each` with every chunk and the running total after it.
fn hash_to_end(file: &File, mut each: impl FnMut(&[u8], u64) -> io::Result<()>) -> io::Result<u64> {
    let mut buffer = [0_u8; 65536];
    let mut total = 0_u64;
    loop {
        let count = match file.seek_read(&mut buffer, total) {
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            result => result?,
        };
        if count == 0 {
            return Ok(total);
        }
        total = total.checked_add(count as u64).ok_or_else(fail)?;
        each(&buffer[..count], total)?;
    }
}

/// A temporary document of one publication, removed when the publication
/// ends however it ends (nothing to remove once it was renamed away).
struct Temporary<'a> {
    directory: &'a File,
    name: Vec<u16>,
}
impl<'a> Temporary<'a> {
    fn create(directory: &'a File, name: &str) -> io::Result<(Self, File)> {
        let name = segment(name)?;
        let file = host_fs::open_relative(
            directory,
            &name,
            WRITE,
            FILE_CREATE,
            Kind::NonDirectory,
            Some(&Descriptor::private(false)?),
        )?;
        Ok((Self { directory, name }, file))
    }
}
impl Drop for Temporary<'_> {
    fn drop(&mut self) {
        let _ = host_fs::unlink(self.directory, &self.name, Kind::NonDirectory);
    }
}

struct Unlock<'a>(&'a File);
impl Drop for Unlock<'_> {
    fn drop(&mut self) {
        host_fs::unlock(self.0);
    }
}

/// Remove the directory or regular file `name` below `parent`, its
/// directories' contents first, through handles only.
fn remove_tree(parent: &File, name: &str, depth: usize) -> io::Result<()> {
    if depth > 256 {
        return Err(fail());
    }
    let segment = segment(name)?;
    let entry = match host_fs::open_relative(
        parent,
        &segment,
        DIRECTORY | DELETE,
        FILE_OPEN,
        Kind::Any,
        None,
    ) {
        Ok(entry) => entry,
        Err(error) if error.kind() == io::ErrorKind::NotFound && depth == 0 => return Ok(()),
        Err(error) => return Err(error),
    };
    let stat = Stat::of(&entry)?;
    if stat.directory() {
        for child in host_fs::names(&entry, usize::MAX)? {
            remove_tree(&entry, &child, depth + 1)?;
        }
    } else if !stat.regular() {
        return Err(fail());
    }
    host_fs::delete(&entry)
}

/// [`HostDirectory::open_document`]: a document opened as
/// [`HostDirectory::read`] opens one, for a reader that parses it as it
/// streams. The handle is retained, so every pass reads the file that was
/// opened and checked.
pub struct HostDocument<'a> {
    directory: &'a HostDirectory,
    name: String,
    file: File,
    before: Stat,
    maximum: usize,
}

impl HostDocument<'_> {
    /// The document from its first byte, read as [`HostDirectory::read`]
    /// reads it: at most one byte beyond the maximum, so that a document
    /// grown past it is seen to have grown. Each pass reads by offset, so
    /// passes never share a position.
    pub fn pass(&self) -> HostDocumentPass<'_> {
        HostDocumentPass {
            file: &self.file,
            offset: 0,
            limit: self.maximum as u64 + 1,
        }
    }

    /// The bytes at `range` of the document, read by offset from the file
    /// that was opened, within the size it had then. A reader makes
    /// [`Self::check`] after it, as after a pass.
    pub fn read_range(&self, range: std::ops::Range<u64>) -> io::Result<Vec<u8>> {
        if range.start > range.end || range.end > self.before.size {
            return Err(fail());
        }
        let mut bytes = vec![0; usize::try_from(range.end - range.start).map_err(|_| fail())?];
        read_exact_at(&self.file, &mut bytes, range.start)?;
        Ok(bytes)
    }

    /// The checks [`HostDirectory::read`] makes once its read is complete,
    /// for a pass that read `length` bytes to its end. A reader makes them
    /// after its last read, before it trusts anything it parsed.
    pub fn check(&self, length: u64) -> io::Result<()> {
        let after = Stat::of(&self.file)?;
        let linked = self.directory.stat_at(&self.name)?;
        if !read_whole(&self.before, &after, &linked, length, self.maximum) {
            return Err(fail());
        }
        Ok(())
    }
}

/// [`HostDocument::pass`].
pub struct HostDocumentPass<'a> {
    file: &'a File,
    offset: u64,
    limit: u64,
}

impl HostDocumentPass<'_> {
    /// The bytes this pass has read.
    pub fn position(&self) -> u64 {
        self.offset
    }
}

impl Read for HostDocumentPass<'_> {
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        let room = usize::try_from(self.limit - self.offset).unwrap_or(usize::MAX);
        let wanted = buffer.len().min(room);
        if wanted == 0 {
            return Ok(0);
        }
        let count = self.file.seek_read(&mut buffer[..wanted], self.offset)?;
        self.offset += count as u64;
        Ok(count)
    }
}

#[cfg(test)]
mod publication_tests {
    use super::*;
    use std::process::Command;

    fn scratch(label: &str) -> std::path::PathBuf {
        let nonce = u128::from_ne_bytes(crate::random_bytes::<16>().unwrap());
        std::env::temp_dir()
            .canonicalize()
            .unwrap()
            .join(format!("{label}-{nonce:032x}"))
    }

    // This checkpoint hook is only reachable in the test executable. Production
    // publication never reads failure-injection environment or caller inputs.
    #[test]
    fn abrupt_exit_child() {
        let Some(path) = std::env::var_os("ARKDECK_TEST_PUBLICATION_ROOT") else {
            return;
        };
        let stage = std::env::var("ARKDECK_TEST_PUBLICATION_STAGE").unwrap();
        let root = HostDirectory::open(Path::new(&path)).unwrap();
        let _lock = root.lock_document("document.lock").unwrap();
        root.publish_with_checkpoint(
            "document.json",
            b"new-complete-document\n",
            1024,
            |checkpoint| {
                if checkpoint == stage {
                    std::process::exit(86);
                }
            },
        )
        .unwrap();
        panic!("requested publication checkpoint was not reached");
    }

    #[test]
    fn process_death_preserves_a_complete_old_or_new_document() {
        for stage in ["beforeRename", "afterRename"] {
            let path = scratch("publication");
            let root = HostDirectory::open_or_create_private(&path).unwrap();
            let path = path.canonicalize().unwrap();
            root.publish_document("document.json", b"old-complete-document\n", 1024)
                .unwrap();
            // A reader holding the published document open never stops the
            // replace (SPK-5) and keeps the bytes it opened.
            let reader = root.open_document("document.json", 1024).unwrap();
            let result = Command::new(std::env::current_exe().unwrap())
                .args([
                    "--exact",
                    "windows::host_store::publication_tests::abrupt_exit_child",
                ])
                .env("ARKDECK_TEST_PUBLICATION_ROOT", &path)
                .env("ARKDECK_TEST_PUBLICATION_STAGE", stage)
                .output()
                .unwrap();
            assert_eq!(result.status.code(), Some(86), "{result:?}");
            let mut held = Vec::new();
            reader.pass().read_to_end(&mut held).unwrap();
            assert_eq!(held, b"old-complete-document\n");
            assert_eq!(
                reader.check(held.len() as u64).is_ok(),
                stage == "beforeRename",
                "a replaced name no longer links the file the reader holds"
            );
            drop(reader);
            let reopened = HostDirectory::open(&path).unwrap();
            let _lock = reopened.lock_document("document.lock").unwrap();
            let expected = if stage == "beforeRename" {
                b"old-complete-document\n"
            } else {
                b"new-complete-document\n"
            };
            assert_eq!(reopened.read("document.json", 1024).unwrap(), expected);
            // The real lock was released by process death and a subsequent
            // transaction remains possible, irrespective of an orphan .part.
            reopened
                .publish_document("document.json", b"recovered\n", 1024)
                .unwrap();
            assert_eq!(
                reopened.read("document.json", 1024).unwrap(),
                b"recovered\n"
            );
            drop((root, reopened, _lock));
            std::fs::remove_dir_all(path).unwrap();
        }
    }

    #[test]
    fn artifact_range_refuses_mutation_and_replacement_at_read_checkpoint() {
        for replace in [false, true] {
            let path = scratch("artifact-range");
            let directory = HostDirectory::open_or_create_private(&path).unwrap();
            let path = path.canonicalize().unwrap();
            directory.create_document("payload", b"abc").unwrap();
            let digest = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
            assert_eq!(
                directory
                    .verify_payload_range("payload", 3, digest, 0, 1)
                    .unwrap(),
                b"a"
            );
            let result = directory.verify_payload_range_checked("payload", 3, digest, 0, 1, || {
                if replace {
                    directory.publish_document("payload", b"abc", 1024).unwrap();
                } else {
                    let file = directory.open_at_access("payload", WRITE).unwrap();
                    write_all_at(&file, b"d", 2).unwrap();
                }
            });
            assert!(
                result.is_err(),
                "changed identity or bytes must never return the captured range"
            );
            drop(directory);
            std::fs::remove_dir_all(path).unwrap();
        }
    }
}
