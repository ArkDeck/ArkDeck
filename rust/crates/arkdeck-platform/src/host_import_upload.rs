//! Mutable upload staging owned by the Import lifetime, never a Raw Artifact.
//! Names are restricted to import stage files; durable checkpoints precede any
//! interpretation of the committed prefix after a restart.
use super::*;
use sha2::{Digest, Sha256};
use std::os::unix::fs::FileExt;

const MAX_CHUNK: usize = 2 * 1024 * 1024;
const MAX_UPLOAD: u64 = 8 * 1024 * 1024 * 1024;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct UploadChunkCheckpoint {
    pub offset: u64,
    pub byte_count: u64,
    pub sha256: String,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum UploadWritePoint {
    AfterPartialChunk,
    AfterChunkSync,
}

fn upload_name(name: &str) -> bool {
    let Some(id) = name
        .strip_prefix("imp-")
        .and_then(|s| s.strip_suffix(".stage"))
    else {
        return false;
    };
    id.len() == 36
        && id.bytes().enumerate().all(|(i, b)| {
            if [8, 13, 18, 23].contains(&i) {
                b == b'-'
            } else {
                b.is_ascii_digit() || (b'a'..=b'f').contains(&b)
            }
        })
}
fn full_sync(file: &File) -> io::Result<()> {
    file.sync_all()?;
    // SAFETY: F_FULLFSYNC takes no trailing argument and the descriptor lives.
    if unsafe { libc::fcntl(file.as_raw_fd(), libc::F_FULLFSYNC) } != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}
fn file_stat(file: &File) -> io::Result<libc::stat> {
    let mut stat = std::mem::MaybeUninit::<libc::stat>::uninit();
    // SAFETY: one valid retained descriptor and a correctly-sized output.
    if unsafe { libc::fstat(file.as_raw_fd(), stat.as_mut_ptr()) } != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(unsafe { stat.assume_init() })
}
fn same(a: &libc::stat, b: &libc::stat) -> bool {
    a.st_dev == b.st_dev
        && a.st_ino == b.st_ino
        && a.st_gen == b.st_gen
        && a.st_size == b.st_size
        && a.st_uid == b.st_uid
        && a.st_mode == b.st_mode
        && a.st_nlink == b.st_nlink
        && a.st_mtime == b.st_mtime
        && a.st_mtime_nsec == b.st_mtime_nsec
        && a.st_ctime == b.st_ctime
        && a.st_ctime_nsec == b.st_ctime_nsec
}
fn private_regular(s: &libc::stat) -> bool {
    s.st_mode & libc::S_IFMT == libc::S_IFREG
        && s.st_mode & 0o077 == 0
        && s.st_uid == unsafe { libc::geteuid() }
        && s.st_nlink == 1
}
fn range_digest(file: &File, offset: u64, count: u64) -> io::Result<String> {
    let mut buffer = [0u8; 64 * 1024];
    let mut hash = Sha256::new();
    let mut done = 0;
    while done < count {
        let want = (count - done).min(buffer.len() as u64) as usize;
        let count = match file.read_at(&mut buffer[..want], offset + done) {
            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
            result => result?,
        };
        if count == 0 {
            return Err(fail());
        }
        hash.update(&buffer[..count]);
        done += count as u64;
    }
    Ok(format!("{:x}", hash.finalize()))
}

pub struct HostUploadFile {
    directory: HostDirectory,
    name: String,
    file: File,
    initial: libc::stat,
}
impl HostUploadFile {
    /// `allow_create` is true only for a durable zero-offset upload checkpoint.
    /// An absent committed prefix must never be replaced by a new empty stage.
    pub fn open(directory: &HostDirectory, name: &str, allow_create: bool) -> io::Result<Self> {
        if !matches!(directory.1, Ownership::Private) || !upload_name(name) {
            return Err(fail());
        }
        owned(&directory.0, true, Ownership::Private)?;
        let cname = segment(name)?;
        let flags = libc::O_RDWR | libc::O_NONBLOCK | libc::O_NOFOLLOW | libc::O_CLOEXEC;
        // SAFETY: a validated component below a retained private directory.
        let mut fd = unsafe { libc::openat(directory.0.as_raw_fd(), cname.as_ptr(), flags) };
        let mut created = false;
        if fd < 0 && io::Error::last_os_error().kind() == io::ErrorKind::NotFound && allow_create {
            fd = unsafe {
                libc::openat(
                    directory.0.as_raw_fd(),
                    cname.as_ptr(),
                    flags | libc::O_CREAT | libc::O_EXCL,
                    0o600,
                )
            };
            created = fd >= 0;
        }
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: ownership of the newly opened fd transfers exactly once.
        let file = unsafe { File::from_raw_fd(fd) };
        let initial = file_stat(&file)?;
        let value = Self {
            directory: HostDirectory(directory.0.try_clone()?, Ownership::Private),
            name: name.into(),
            file,
            initial,
        };
        value.stat()?;
        if created {
            full_sync(&value.file)?;
            value.directory.0.sync_all()?;
            value.stat()?;
        }
        Ok(value)
    }
    fn stat(&self) -> io::Result<libc::stat> {
        owned(&self.directory.0, true, Ownership::Private)?;
        let stat = file_stat(&self.file)?;
        let named = self.directory.stat_at(&self.name)?;
        if !private_regular(&stat)
            || stat.st_dev != self.initial.st_dev
            || stat.st_ino != self.initial.st_ino
            || stat.st_gen != self.initial.st_gen
            || !same(&stat, &named)
        {
            return Err(fail());
        }
        Ok(stat)
    }
    pub fn byte_count(&self) -> io::Result<u64> {
        u64::try_from(self.stat()?.st_size).map_err(|_| fail())
    }
    /// Includes every identity field used by the Swift committed-prefix cache.
    pub fn checkpoint_identity(&self) -> io::Result<String> {
        let s = self.stat()?;
        Ok(format!(
            "{}:{}:{}:{}:{}:{}:{}:{}:{}:{}:{}",
            s.st_dev,
            s.st_ino,
            s.st_gen,
            s.st_size,
            s.st_mtime,
            s.st_mtime_nsec,
            s.st_ctime,
            s.st_ctime_nsec,
            s.st_uid,
            s.st_mode,
            s.st_nlink
        ))
    }
    pub fn recover(&mut self, chunks: &[UploadChunkCheckpoint], committed: u64) -> io::Result<()> {
        if committed > MAX_UPLOAD || chunks.len() > 16384 {
            return Err(fail());
        }
        let mut total = 0u64;
        for chunk in chunks {
            if chunk.offset != total
                || !(1..=MAX_CHUNK as u64).contains(&chunk.byte_count)
                || chunk.byte_count > MAX_UPLOAD - total
                || chunk.sha256.len() != 64
                || !chunk
                    .sha256
                    .bytes()
                    .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
            {
                return Err(fail());
            }
            total += chunk.byte_count;
        }
        if total != committed {
            return Err(fail());
        }
        let size = self.byte_count()?;
        if size < committed {
            return Err(fail());
        }
        if size > committed {
            // Only this import's uncommitted suffix is rolled back. Its durable
            // chunk records were validated before this truncation was allowed.
            self.file.set_len(committed)?;
            full_sync(&self.file)?;
            self.stat()?;
        }
        let before = self.stat()?;
        for chunk in chunks {
            if range_digest(&self.file, chunk.offset, chunk.byte_count)? != chunk.sha256 {
                return Err(fail());
            }
        }
        if !same(&before, &self.stat()?) {
            return Err(fail());
        }
        Ok(())
    }
    pub fn append(&mut self, offset: u64, bytes: &[u8], digest: &str) -> io::Result<()> {
        self.append_with_checkpoint(offset, bytes, digest, |_| Ok(()))
    }
    /// The hooks are in-process failure injection, never wire options.
    pub fn append_with_checkpoint(
        &mut self,
        offset: u64,
        bytes: &[u8],
        digest: &str,
        checkpoint: impl Fn(UploadWritePoint) -> io::Result<()>,
    ) -> io::Result<()> {
        if bytes.is_empty()
            || bytes.len() > MAX_CHUNK
            || offset > MAX_UPLOAD
            || bytes.len() as u64 > MAX_UPLOAD - offset
            || self.byte_count()? != offset
            || format!("{:x}", Sha256::digest(bytes)) != digest
        {
            return Err(fail());
        }
        let first = (bytes.len() / 2).max(1);
        let mut written = 0;
        while written < bytes.len() {
            let end = if written < first { first } else { bytes.len() };
            let count = match self
                .file
                .write_at(&bytes[written..end], offset + written as u64)
            {
                Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
                result => result?,
            };
            if count == 0 {
                return Err(io::Error::from(io::ErrorKind::WriteZero));
            }
            written += count;
            if written == first {
                checkpoint(UploadWritePoint::AfterPartialChunk)?;
            }
        }
        full_sync(&self.file)?;
        checkpoint(UploadWritePoint::AfterChunkSync)?;
        let before = self.stat()?;
        if before.st_size as u64 != offset + bytes.len() as u64
            || range_digest(&self.file, offset, bytes.len() as u64)? != digest
            || !same(&before, &self.stat()?)
        {
            return Err(fail());
        }
        Ok(())
    }
}

struct CheckpointStage<'a> {
    root: &'a HostDirectory,
    name: String,
    file: File,
    published: bool,
}
impl CheckpointStage<'_> {
    fn validate(&self) -> io::Result<()> {
        let held = file_stat(&self.file)?;
        let named = self.root.stat_at(&self.name)?;
        if !private_regular(&held) || !same(&held, &named) {
            return Err(fail());
        }
        Ok(())
    }
}
impl Drop for CheckpointStage<'_> {
    fn drop(&mut self) {
        if !self.published
            && self.validate().is_ok()
            && let Ok(name) = segment(&self.name)
        {
            // SAFETY: cleanup is limited to the exact temporary inode held here.
            unsafe { libc::unlinkat(self.root.0.as_raw_fd(), name.as_ptr(), 0) };
        }
    }
}
impl HostDirectory {
    /// Frozen Import checkpoint publication uses the existing `.tmp` recovery
    /// vocabulary. The caller holds the lifetime lock and supplies the exact
    /// prior document, or None for a new exclusive identity.
    pub fn publish_import_checkpoint(
        &self,
        name: &str,
        prior: Option<&[u8]>,
        bytes: &[u8],
        maximum: usize,
    ) -> Result<(), DocumentPublishError> {
        use DocumentPublishError::{BeforePublication, OutcomeUnknown};
        if !matches!(self.1, Ownership::Private)
            || !name.ends_with(".json")
            || bytes.is_empty()
            || bytes.len() > maximum
        {
            return Err(fail().into());
        }
        let target = segment(name)?;
        let original = match self.stat_at(name) {
            Ok(stat) if private_regular(&stat) && prior.is_some() => {
                if self.read(name, maximum)?.as_slice() != prior.unwrap() {
                    return Err(fail().into());
                }
                Some(stat)
            }
            Ok(_) => return Err(io::Error::from(io::ErrorKind::AlreadyExists).into()),
            Err(error) if error.kind() == io::ErrorKind::NotFound && prior.is_none() => None,
            Err(error) => return Err(error.into()),
        };
        let nonce = u128::from_ne_bytes(crate::random_bytes::<16>()?);
        let staging_name = format!(".{name}.{nonce:032x}.tmp");
        let staging = segment(&staging_name)?;
        // SAFETY: one generated private component; EXCL never adopts an orphan.
        let fd = unsafe {
            libc::openat(
                self.0.as_raw_fd(),
                staging.as_ptr(),
                libc::O_RDWR | libc::O_CREAT | libc::O_EXCL | libc::O_NOFOLLOW | libc::O_CLOEXEC,
                0o600,
            )
        };
        if fd < 0 {
            return Err(io::Error::last_os_error().into());
        }
        let file = unsafe { File::from_raw_fd(fd) };
        let mut stage = CheckpointStage {
            root: self,
            name: staging_name,
            file,
            published: false,
        };
        stage.file.write_all(bytes)?;
        full_sync(&stage.file)?;
        stage.validate()?;
        let ready = file_stat(&stage.file)?;
        if ready.st_size != bytes.len() as i64
            || range_digest(&stage.file, 0, bytes.len() as u64)?
                != format!("{:x}", Sha256::digest(bytes))
        {
            return Err(fail().into());
        }
        stage.validate()?;
        if !same(&ready, &file_stat(&stage.file)?) {
            return Err(fail().into());
        }
        match (&original, self.stat_at(name)) {
            (None, Err(error)) if error.kind() == io::ErrorKind::NotFound => {}
            (Some(expected), Ok(current)) if same(expected, &current) => {
                if self.read(name, maximum)?.as_slice() != prior.unwrap()
                    || !same(expected, &self.stat_at(name)?)
                {
                    return Err(fail().into());
                }
            }
            _ => return Err(io::Error::from(io::ErrorKind::AlreadyExists).into()),
        }
        stage.validate()?;
        if !same(&ready, &file_stat(&stage.file)?) {
            return Err(fail().into());
        }
        // SAFETY: both names are descriptor-relative; new records are exclusive.
        if unsafe {
            libc::renameatx_np(
                self.0.as_raw_fd(),
                staging.as_ptr(),
                self.0.as_raw_fd(),
                target.as_ptr(),
                if original.is_none() {
                    libc::RENAME_EXCL
                } else {
                    0
                },
            )
        } != 0
        {
            let error = io::Error::last_os_error();
            return Err(if error.kind() == io::ErrorKind::AlreadyExists {
                BeforePublication(error)
            } else {
                OutcomeUnknown(error)
            });
        }
        stage.published = true;
        self.0.sync_all().map_err(OutcomeUnknown)?;
        let held = file_stat(&stage.file).map_err(OutcomeUnknown)?;
        let linked = self.stat_at(name).map_err(OutcomeUnknown)?;
        if !same(&held, &linked) || self.read(name, maximum).map_err(OutcomeUnknown)? != bytes {
            return Err(OutcomeUnknown(fail()));
        }
        Ok(())
    }
}

/// Explicit caller-selected source. Its descriptor, pathname binding and content
/// identity are held throughout one bounded upload; no source is ever modified.
pub struct HostImportSource {
    file: File,
    path: std::path::PathBuf,
    initial: libc::stat,
    pub name: String,
    pub byte_count: u64,
    pub sha256: String,
}
impl HostImportSource {
    pub fn open(
        path: &Path,
        maximum: u64,
        mut check: impl FnMut() -> io::Result<()>,
    ) -> io::Result<Self> {
        use std::os::unix::fs::OpenOptionsExt;
        check()?;
        let path = if path.is_absolute() {
            path.to_owned()
        } else {
            std::env::current_dir()?.join(path)
        };
        let name = path
            .file_name()
            .and_then(|s| s.to_str())
            .filter(|s| !s.is_empty())
            .ok_or_else(fail)?
            .to_owned();
        let file = File::options()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC)
            .open(&path)?;
        let initial = file_stat(&file)?;
        if initial.st_mode & libc::S_IFMT != libc::S_IFREG
            || initial.st_size <= 0
            || initial.st_size as u64 > maximum
        {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "Import source exceeds its registered regular-file bound",
            ));
        }
        let mut source = Self {
            file,
            path,
            byte_count: initial.st_size as u64,
            name,
            initial,
            sha256: String::new(),
        };
        let mut hash = Sha256::new();
        let mut offset = 0;
        while offset < source.byte_count {
            check()?;
            let bytes = source.chunk(
                offset,
                (source.byte_count - offset).min(1024 * 1024) as usize,
            )?;
            hash.update(&bytes);
            offset += bytes.len() as u64;
        }
        source.sha256 = format!("{:x}", hash.finalize());
        source.check_identity()?;
        Ok(source)
    }
    pub fn check_identity(&self) -> io::Result<()> {
        let current = file_stat(&self.file)?;
        let metadata = std::fs::symlink_metadata(&self.path)?;
        if !same(&self.initial, &current)
            || !metadata.is_file()
            || metadata.dev() != self.initial.st_dev as u64
            || metadata.ino() != self.initial.st_ino
        {
            return Err(fail());
        }
        Ok(())
    }
    pub fn chunk(&self, offset: u64, count: usize) -> io::Result<Vec<u8>> {
        self.check_identity()?;
        if count == 0
            || count > MAX_CHUNK
            || offset
                .checked_add(count as u64)
                .is_none_or(|n| n > self.byte_count)
        {
            return Err(fail());
        }
        let mut bytes = vec![0; count];
        self.file.read_exact_at(&mut bytes, offset)?;
        self.check_identity()?;
        Ok(bytes)
    }
}
