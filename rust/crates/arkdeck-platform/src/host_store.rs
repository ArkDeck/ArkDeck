//! Descriptor-relative host-store access. Snapshot entry points never write;
//! private document owners explicitly acquire locks and publish atomically.
use std::ffi::{CStr, CString};
use std::fs::{File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::Path;

pub struct HostDirectory(File, Ownership);
#[path = "host_import_upload.rs"]
mod import_upload;
pub use import_upload::{
    HostImportSource, HostUploadFile, UploadChunkCheckpoint, UploadWritePoint,
};
#[path = "host_journal.rs"]
mod journal;
pub use journal::HostJournal;
#[path = "host_export.rs"]
mod export;
pub use export::{ExportPublishError, ExportStaging, HostExportCapacity};
#[path = "host_file_export.rs"]
mod file_export;
pub use file_export::FileExportStaging;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HostDirectoryFacts {
    pub device: u64,
    pub inode: u64,
    /// A dev-unverified fallback is only a same-mount grouping key. It cannot
    /// prove a later export claim survived an unmount/remount.
    pub volume_identity: String,
}

#[derive(Clone, Copy)]
enum Ownership {
    Private,
    TraceInventory,
    ExportParent,
    SessionTree { device: u64 },
}
impl Ownership {
    fn mode_mask(self) -> u32 {
        match self {
            Self::Private => 0o077,
            Self::TraceInventory | Self::ExportParent => 0,
            Self::SessionTree { .. } => 0o022,
        }
    }
    fn same_volume(self, device: u64) -> bool {
        match self {
            Self::Private | Self::TraceInventory | Self::ExportParent => true,
            Self::SessionTree { device: root } => root == device,
        }
    }
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

pub struct HostReadLock {
    file: File,
}

impl HostReadLock {
    /// Seal a private catalog's first durable publication without replacing
    /// its permanent lock inode. A missing catalog after this mark is corrupt.
    pub fn mark_catalog_initialized(&self, root: &HostDirectory, name: &str) -> io::Result<()> {
        use std::os::unix::fs::FileExt;
        if !matches!(root.1, Ownership::Private) {
            return Err(fail());
        }
        self.validate_link(root, name)?;
        match self.file.metadata()?.len() {
            0 => {
                self.file.write_all_at(&[0xA5], 0)?;
            }
            1 => {
                let mut marker = [0];
                self.file.read_exact_at(&mut marker, 0)?;
                if marker != [0xA5] {
                    return Err(fail());
                }
            }
            _ => return Err(fail()),
        }
        self.file.sync_all()?;
        root.0.sync_all()?;
        self.validate_link(root, name)
    }

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
    let trace = matches!(ownership, Ownership::TraceInventory);
    if (!trace && stat.uid() != unsafe { libc::geteuid() })
        || stat.mode() & ownership.mode_mask() != 0
        || !ownership.same_volume(stat.dev())
        || (directory && !stat.is_dir())
        || (!directory && (!stat.is_file() || (!trace && stat.nlink() != 1)))
    {
        return Err(fail());
    }
    Ok(())
}

impl HostDirectory {
    /// Observe the held descriptor using the current Swift volume-identity
    /// format. No caller-provided volume fact is accepted.
    pub fn export_facts(&self) -> io::Result<HostDirectoryFacts> {
        owned(&self.0, true, self.1)?;
        let metadata = self.0.metadata()?;
        let device = u64::from(metadata.dev() as u32);
        let mut attributes = libc::attrlist {
            bitmapcount: libc::ATTR_BIT_MAP_COUNT,
            reserved: 0,
            commonattr: 0,
            volattr: libc::ATTR_VOL_UUID,
            dirattr: 0,
            fileattr: 0,
            forkattr: 0,
        };
        let mut buffer = [0_u8; 20];
        // SAFETY: attributes names a single fixed-size volume UUID; buffer
        // has room for the length word plus all 16 UUID bytes.
        let result = unsafe {
            libc::fgetattrlist(
                self.0.as_raw_fd(),
                (&mut attributes as *mut libc::attrlist).cast(),
                buffer.as_mut_ptr().cast(),
                buffer.len(),
                0,
            )
        };
        let volume_identity = if result == 0
            && u32::from_ne_bytes(buffer[..4].try_into().map_err(|_| fail())?) == 20
        {
            let hex: String = buffer[4..].iter().map(|b| format!("{b:02x}")).collect();
            format!(
                "uuid:{}-{}-{}-{}-{}",
                &hex[..8],
                &hex[8..12],
                &hex[12..16],
                &hex[16..20],
                &hex[20..]
            )
        } else {
            format!("dev-unverified:{device}")
        };
        Ok(HostDirectoryFacts {
            device,
            inode: metadata.ino(),
            volume_identity,
        })
    }

    /// An export parent is an existing owned physical directory. Unlike
    /// Runtime records it can be an ordinary user directory with public read
    /// bits; this entry point does not grant document publication or locking.
    pub fn open_export_parent(path: &Path) -> io::Result<Self> {
        if !path.is_absolute() || path.canonicalize()? != path {
            return Err(fail());
        }
        let file = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(path)?;
        owned(&file, true, Ownership::ExportParent)?;
        Ok(Self(file, Ownership::ExportParent))
    }

    /// Metadata of a private regular document, resolved relative to the held
    /// directory. Snapshot retention uses this instead of trusting path stats.
    pub fn document_metadata(&self, name: &str) -> io::Result<std::fs::Metadata> {
        if !matches!(self.1, Ownership::Private) {
            return Err(fail());
        }
        let file = self.open_at(name, 0)?;
        owned(&file, false, self.1)?;
        let metadata = file.metadata()?;
        let linked = self.stat_at(name)?;
        if metadata.dev() != linked.st_dev as u64 || metadata.ino() != linked.st_ino {
            return Err(fail());
        }
        Ok(metadata)
    }

    /// Reclaim exactly the private document inspected by snapshot retention.
    /// The caller holds its snapshot-store lock throughout selection and unlink.
    pub fn remove_document(&self, name: &str, expected: &std::fs::Metadata) -> io::Result<()> {
        let current = self.document_metadata(name)?;
        if current.dev() != expected.dev()
            || current.ino() != expected.ino()
            || current.len() != expected.len()
            || current.mtime() != expected.mtime()
            || current.mtime_nsec() != expected.mtime_nsec()
            || current.ctime() != expected.ctime()
            || current.ctime_nsec() != expected.ctime_nsec()
        {
            return Err(fail());
        }
        let name = segment(name)?;
        if unsafe { libc::unlinkat(self.0.as_raw_fd(), name.as_ptr(), 0) } != 0 {
            return Err(io::Error::last_os_error());
        }
        self.0.sync_all()
    }

    /// Check owner permissions and actual create/remove access (including ACLs)
    /// before a Session root selection is published. No existing entry changes.
    pub fn probe_writable(&self) -> io::Result<()> {
        use std::os::fd::IntoRawFd;
        if !matches!(self.1, Ownership::Private) {
            return Err(fail());
        }
        owned(&self.0, true, self.1)?;
        if self.0.metadata()?.mode() & 0o700 != 0o700 {
            return Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "private root is not owner-writable",
            ));
        }
        let nonce = u128::from_ne_bytes(crate::random_bytes::<16>()?);
        let name = segment(&format!(".arkdeck-runtime-storage-probe-{nonce:032x}"))?;
        // SAFETY: the descriptor and C string remain live, the name is one
        // generated segment, and EXCL prevents replacing any existing entry.
        let fd = unsafe {
            libc::openat(
                self.0.as_raw_fd(),
                name.as_ptr(),
                libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL | libc::O_CLOEXEC | libc::O_NOFOLLOW,
                0o600,
            )
        };
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: openat returned a new owned file descriptor.
        let file = unsafe { File::from_raw_fd(fd) };
        let descriptor = file.into_raw_fd();
        // SAFETY: close is issued exactly once, including on EINTR.
        let closed = unsafe { libc::close(descriptor) };
        let close_error = (closed != 0).then(io::Error::last_os_error);
        // SAFETY: unlink is relative to the retained directory and names only
        // the unique empty probe created by this invocation.
        let removed = unsafe { libc::unlinkat(self.0.as_raw_fd(), name.as_ptr(), 0) };
        if let Some(error) = close_error {
            return Err(error);
        }
        if removed != 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(())
    }

    /// Create or reopen a fixed private child without following a replaced
    /// parent path. Existing directory permissions are never changed.
    pub fn private_child(&self, name: &str) -> io::Result<Self> {
        if !matches!(self.1, Ownership::Private) {
            return Err(fail());
        }
        let name_c = segment(name)?;
        if unsafe { libc::mkdirat(self.0.as_raw_fd(), name_c.as_ptr(), 0o700) } != 0
            && io::Error::last_os_error().kind() != io::ErrorKind::AlreadyExists
        {
            return Err(io::Error::last_os_error());
        }
        let child = self.child(name)?;
        self.0.sync_all()?;
        Ok(child)
    }

    /// A private document owner's lock, shared across processes. Never unlink
    /// the lock: replacing its inode would split the writer population.
    pub fn lock_document(&self, name: &str) -> io::Result<HostReadLock> {
        if !matches!(self.1, Ownership::Private) {
            return Err(fail());
        }
        let name_c = segment(name)?;
        let flags = libc::O_RDWR | libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK;
        let mut fd = unsafe {
            libc::openat(
                self.0.as_raw_fd(),
                name_c.as_ptr(),
                flags | libc::O_CREAT | libc::O_EXCL,
                0o600,
            )
        };
        if fd < 0 && io::Error::last_os_error().kind() == io::ErrorKind::AlreadyExists {
            fd = unsafe { libc::openat(self.0.as_raw_fd(), name_c.as_ptr(), flags) };
        }
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        let file = unsafe { File::from_raw_fd(fd) };
        owned(&file, false, self.1)?;
        loop {
            if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } == 0 {
                break;
            }
            let error = io::Error::last_os_error();
            if error.kind() != io::ErrorKind::Interrupted {
                return Err(error);
            }
        }
        let lock = HostReadLock { file };
        lock.validate_link(self, name)?;
        Ok(lock)
    }

    /// Sync a fresh private file, atomically rename it, then sync the directory.
    /// Errors after rename must be treated as uncertain publication by callers.
    pub fn publish_document(
        &self,
        name: &str,
        bytes: &[u8],
        maximum: usize,
    ) -> Result<(), DocumentPublishError> {
        self.publish_with_checkpoint(name, bytes, maximum, |_| {})
    }

    fn publish_with_checkpoint(
        &self,
        name: &str,
        bytes: &[u8],
        maximum: usize,
        checkpoint: impl Fn(&str),
    ) -> Result<(), DocumentPublishError> {
        if !matches!(self.1, Ownership::Private) || bytes.is_empty() || bytes.len() > maximum {
            return Err(fail().into());
        }
        owned(&self.0, true, self.1)?;
        let target = segment(name)?;
        let nonce: String = crate::random_bytes::<16>()?
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect();
        let temporary = segment(&format!(".{name}.{nonce}.part"))?;
        let fd = unsafe {
            libc::openat(
                self.0.as_raw_fd(),
                temporary.as_ptr(),
                libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL | libc::O_NOFOLLOW | libc::O_CLOEXEC,
                0o600,
            )
        };
        if fd < 0 {
            return Err(io::Error::last_os_error().into());
        }
        struct Remove<'a>(&'a File, CString);
        impl Drop for Remove<'_> {
            fn drop(&mut self) {
                unsafe {
                    libc::unlinkat(self.0.as_raw_fd(), self.1.as_ptr(), 0);
                }
            }
        }
        let temporary = Remove(&self.0, temporary);
        let mut file = unsafe { File::from_raw_fd(fd) };
        file.write_all(bytes)?;
        file.sync_all()?;
        checkpoint("beforeRename");
        if unsafe {
            libc::renameat(
                self.0.as_raw_fd(),
                temporary.1.as_ptr(),
                self.0.as_raw_fd(),
                target.as_ptr(),
            )
        } != 0
        {
            return Err(DocumentPublishError::OutcomeUnknown(
                io::Error::last_os_error(),
            ));
        }
        checkpoint("afterRename");
        self.0
            .sync_all()
            .map_err(DocumentPublishError::OutcomeUnknown)
    }

    pub fn open(path: &Path) -> io::Result<Self> {
        Self::open_root(path, false)
    }

    /// ArkTrace inventory measures readable entries without imposing the
    /// private writer's permission or single-link rules. Its root must still be
    /// owned by this user, as Swift's root chmod requires. No chmod is performed.
    pub fn open_trace_inventory(path: &Path) -> io::Result<Self> {
        if !path.is_absolute() || path.canonicalize()? != path {
            return Err(fail());
        }
        let file = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(path)?;
        if file.metadata()?.uid() != unsafe { libc::geteuid() } {
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
        self.open_at_access(name, flags, libc::O_RDONLY)
    }

    fn open_at_access(&self, name: &str, flags: i32, access: i32) -> io::Result<File> {
        let name = segment(name)?;
        let fd = unsafe {
            libc::openat(
                self.0.as_raw_fd(),
                name.as_ptr(),
                access | libc::O_CLOEXEC | libc::O_NOFOLLOW | libc::O_NONBLOCK | flags,
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

    /// Name an optional export Journal using bounded memory and a retained
    /// descriptor. Absence is distinct from a failed or unsafe read; the linked
    /// inode and content timestamps must survive the complete read.
    pub fn optional_document_digest(&self, name: &str, maximum: u64) -> io::Result<Option<String>> {
        use sha2::{Digest, Sha256};
        let file = match self.open_at(name, 0) {
            Ok(file) => file,
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
            Err(error) => return Err(error),
        };
        owned(&file, false, self.1)?;
        let before = file.metadata()?;
        if before.len() > maximum {
            return Err(fail());
        }
        let mut reader = &file;
        let mut buffer = [0_u8; 65536];
        let mut count = 0_u64;
        let mut digest = Sha256::new();
        loop {
            let read = match reader.read(&mut buffer) {
                Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                result => result?,
            };
            if read == 0 {
                break;
            }
            count = count.checked_add(read as u64).ok_or_else(fail)?;
            if count > before.len() || count > maximum {
                return Err(fail());
            }
            digest.update(&buffer[..read]);
        }
        let after = file.metadata()?;
        let linked = self.stat_at(name)?;
        if count != before.len()
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
        Ok(Some(format!("{:x}", digest.finalize())))
    }

    /// Verify immutable payload bytes using bounded memory and a retained
    /// descriptor. Both the linked inode and content timestamps must survive.
    pub fn verify_payload(&self, name: &str, length: u64, digest: &str) -> io::Result<()> {
        use sha2::{Digest, Sha256};
        let file = self.open_at(name, 0)?;
        owned(&file, false, self.1)?;
        let before = file.metadata()?;
        if before.len() != length {
            return Err(fail());
        }
        let mut reader = &file;
        let mut buffer = [0_u8; 65536];
        let mut hashed = 0_u64;
        let mut hash = Sha256::new();
        loop {
            let count = match reader.read(&mut buffer) {
                Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
                result => result?,
            };
            if count == 0 {
                break;
            }
            hashed = hashed.checked_add(count as u64).ok_or_else(fail)?;
            if hashed > length {
                return Err(fail());
            }
            hash.update(&buffer[..count]);
        }
        let after = file.metadata()?;
        let linked = self.stat_at(name)?;
        if hashed != length
            || format!("{:x}", hash.finalize()) != digest
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
        Ok(())
    }

    /// Hash the entire immutable payload while retaining only the requested range.
    /// No bytes escape until the held descriptor and named inode are revalidated.
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

    fn verify_payload_range_checked(
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
        let file = self.open_at(name, 0)?;
        owned(&file, false, self.1)?;
        let before = file.metadata()?;
        if before.len() != length {
            return Err(fail());
        }
        let end = offset + (length - offset).min(maximum as u64);
        let mut bytes = Vec::with_capacity((end - offset) as usize);
        let mut reader = &file;
        let mut buffer = [0_u8; 65536];
        let mut hashed = 0_u64;
        let mut hash = Sha256::new();
        loop {
            let count = match reader.read(&mut buffer) {
                Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
                result => result?,
            };
            if count == 0 {
                break;
            }
            let next = hashed.checked_add(count as u64).ok_or_else(fail)?;
            if next > length {
                return Err(fail());
            }
            let start = offset.max(hashed);
            let stop = end.min(next);
            if start < stop {
                bytes.extend_from_slice(
                    &buffer[(start - hashed) as usize..(stop - hashed) as usize],
                );
            }
            hash.update(&buffer[..count]);
            hashed = next;
        }
        after_read();
        owned(&file, false, self.1)?;
        let after = file.metadata()?;
        let linked = self.stat_at(name)?;
        if hashed != length
            || format!("{:x}", hash.finalize()) != digest
            || before.len() != after.len()
            || before.mode() != after.mode()
            || before.uid() != after.uid()
            || before.nlink() != after.nlink()
            || before.mtime() != after.mtime()
            || before.mtime_nsec() != after.mtime_nsec()
            || before.ctime() != after.ctime()
            || before.ctime_nsec() != after.ctime_nsec()
            || before.dev() != linked.st_dev as u64
            || before.ino() != linked.st_ino
            || before.mode() != linked.st_mode as u32
            || before.len() != linked.st_size as u64
            || before.mtime() != linked.st_mtime
            || before.mtime_nsec() != linked.st_mtime_nsec
            || before.ctime() != linked.st_ctime
            || before.ctime_nsec() != linked.st_ctime_nsec
        {
            return Err(fail());
        }
        Ok(bytes)
    }

    /// Match ArkTrace's existing lock probe. O_RDWR is needed to preserve its
    /// refusal of read-only lock files; no creation, truncation or write occurs.
    /// Key locks are bounded to 4096 bytes; entry leases have no size bound.
    pub fn try_trace_lock_existing(
        &self,
        name: &str,
        maximum: Option<u64>,
    ) -> io::Result<Option<HostReadLock>> {
        if !matches!(self.1, Ownership::TraceInventory) {
            return Err(fail());
        }
        let file = match self.open_at_access(name, 0, libc::O_RDWR) {
            Ok(file) => file,
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
            Err(error) => return Err(error),
        };
        owned(&file, false, self.1)?;
        let size = file.metadata()?.len();
        if maximum.is_some_and(|limit| size > limit) {
            return Err(fail());
        }
        if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
            let error = io::Error::last_os_error();
            if error.kind() == io::ErrorKind::WouldBlock {
                return Ok(None);
            }
            return Err(error);
        }
        let lock = HostReadLock { file };
        lock.validate_link(self, name)?;
        Ok(Some(lock))
    }

    pub fn try_lock_existing(&self, name: &str) -> io::Result<Option<HostReadLock>> {
        self.try_lock_existing_impl(name, true, libc::O_RDONLY)
    }

    /// Never creates a lock file. Missing files remain NotFound; only an
    /// existing exclusive lock held by another owner returns None. Bootstrap
    /// opens its lock read/write, matching the existing Swift owner without
    /// changing the file or broadening ordinary snapshot readers.
    pub fn try_lock_existing_strict(&self, name: &str) -> io::Result<Option<HostReadLock>> {
        self.try_lock_existing_impl(name, false, libc::O_RDWR)
    }

    fn try_lock_existing_impl(
        &self,
        name: &str,
        allow_missing: bool,
        access: i32,
    ) -> io::Result<Option<HostReadLock>> {
        let file = match self.open_at_access(name, 0, access) {
            Ok(file) => file,
            Err(error) if allow_missing && error.kind() == io::ErrorKind::NotFound => {
                return Ok(None);
            }
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

#[cfg(test)]
mod publication_tests {
    use super::*;
    use std::{fs, os::unix::fs::DirBuilderExt, process::Command};

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
            let nonce = crate::random_bytes::<16>().unwrap();
            let path = std::env::temp_dir()
                .canonicalize()
                .unwrap()
                .join(format!("publication-{:x}", u128::from_ne_bytes(nonce)));
            fs::DirBuilder::new().mode(0o700).create(&path).unwrap();
            let root = HostDirectory::open(&path).unwrap();
            root.publish_document("document.json", b"old-complete-document\n", 1024)
                .unwrap();
            let result = Command::new(std::env::current_exe().unwrap())
                .args([
                    "--exact",
                    "host_store::publication_tests::abrupt_exit_child",
                ])
                .env("ARKDECK_TEST_PUBLICATION_ROOT", &path)
                .env("ARKDECK_TEST_PUBLICATION_STAGE", stage)
                .output()
                .unwrap();
            assert_eq!(result.status.code(), Some(86), "{result:?}");
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
            fs::remove_dir_all(path).unwrap();
        }
    }
}

#[cfg(test)]
mod artifact_range_tests {
    use super::*;
    use std::{
        fs,
        os::unix::fs::{DirBuilderExt, PermissionsExt},
    };
    #[test]
    fn artifact_range_refuses_mutation_and_replacement_at_read_checkpoint() {
        for replace in [false, true] {
            let nonce = crate::random_bytes::<16>().unwrap();
            let path = std::env::temp_dir()
                .canonicalize()
                .unwrap()
                .join(format!("artifact-range-{:x}", u128::from_ne_bytes(nonce)));
            fs::DirBuilder::new().mode(0o700).create(&path).unwrap();
            let payload = path.join("payload");
            fs::write(&payload, b"abc").unwrap();
            fs::set_permissions(&payload, fs::Permissions::from_mode(0o600)).unwrap();
            let directory = HostDirectory::open(&path).unwrap();
            let digest = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
            let result = directory.verify_payload_range_checked("payload", 3, digest, 0, 1, || {
                if replace {
                    fs::rename(&payload, path.join("retained-original")).unwrap();
                    fs::write(&payload, b"abc").unwrap();
                    fs::set_permissions(&payload, fs::Permissions::from_mode(0o600)).unwrap();
                } else {
                    fs::write(&payload, b"abd").unwrap();
                }
            });
            assert!(
                result.is_err(),
                "changed identity or bytes must never return the captured range"
            );
        }
    }
}
