//! Mutable upload staging owned by the Import lifetime, never a Raw Artifact,
//! and the caller-selected Import source, on NTFS (TASK-XPA-008): the Unix
//! `host_import_upload.rs` with the same names, bounds, bytes and refusals.
//! Staging names are restricted to import stage files; durable checkpoints
//! precede any interpretation of the committed prefix after a restart.
//!
//! The Windows spellings: `FlushFileBuffers` for `fsync` + `F_FULLFSYNC`;
//! the POSIX-semantics rename without replace for `renameatx_np(RENAME_EXCL)`
//! and with it for `renameat`; `FileIdInfo` plus size, link count, attributes
//! and the last-write and change times for the `stat` identity; an owner-only
//! protected DACL for `0600`, and the owner-read-only one for the sealed
//! `0400` payload. The source is opened without following a final reparse
//! point (`FILE_FLAG_OPEN_REPARSE_POINT`, the `O_NOFOLLOW`) and shared for
//! reading only, so while it is held nobody can write it, rename it or
//! replace or delete its name; its identity is still compared before and
//! after every read, which catches what a share mode cannot refuse (a
//! metadata change, a new hard link, a replaced parent directory).
use super::super::host_fs::{self, Access, Descriptor, Kind, Stat, WRITE, fail, segment};
use super::{DocumentPublishError, HostDirectory, Ownership, owned, read_exact_at};
use sha2::{Digest, Sha256};
use std::fs::File;
use std::io::{self, Read, Write};
use std::os::windows::fs::FileExt;
use std::path::Path;
use windows_sys::Wdk::Storage::FileSystem::{FILE_CREATE, FILE_OPEN};
use windows_sys::Win32::Storage::FileSystem::{
    DELETE, FILE_ATTRIBUTE_REPARSE_POINT, FILE_READ_ATTRIBUTES, FILE_READ_DATA, FILE_SHARE_READ,
    FILE_TYPE_DISK, GetFileType, SYNCHRONIZE, WRITE_DAC,
};

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

/// Unix `private_regular`: the owner's single-link regular file nobody else
/// is granted anything on (mode `& 0o077 == 0`).
fn private_regular(stat: &Stat, access: &Access) -> bool {
    stat.regular() && stat.links == 1 && access.owner_is_user && access.private()
}

/// The held file's identity and its access, as one comparable value: Unix
/// `same` compares the mode too, which the DACL stands for here.
fn held(file: &File) -> io::Result<(Stat, Access)> {
    Ok((Stat::of(file)?, Access::of(file)?))
}

fn range_digest(file: &File, offset: u64, count: u64) -> io::Result<String> {
    let mut buffer = [0u8; 64 * 1024];
    let mut hash = Sha256::new();
    let mut done = 0;
    while done < count {
        let want = (count - done).min(buffer.len() as u64) as usize;
        let count = match file.seek_read(&mut buffer[..want], offset + done) {
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

/// [`HostUploadFile::validator_reader`].
pub struct HostUploadReader<'a> {
    file: &'a File,
    offset: u64,
}
impl Read for HostUploadReader<'_> {
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        let count = self.file.seek_read(buffer, self.offset)?;
        self.offset += count as u64;
        Ok(count)
    }
}

pub struct HostUploadFile {
    directory: HostDirectory,
    name: String,
    file: File,
    initial: Stat,
}
impl HostUploadFile {
    /// `allow_create` is true only for a durable zero-offset upload checkpoint.
    /// An absent committed prefix must never be replaced by a new empty stage.
    pub fn open(directory: &HostDirectory, name: &str, allow_create: bool) -> io::Result<Self> {
        if !matches!(directory.1, Ownership::Private) || !upload_name(name) {
            return Err(fail());
        }
        owned(&directory.0, true, Ownership::Private)?;
        let segment = segment(name)?;
        let mut created = false;
        let file = match host_fs::open_relative(
            &directory.0,
            &segment,
            WRITE,
            FILE_OPEN,
            Kind::NonDirectory,
            None,
        ) {
            Err(error) if error.kind() == io::ErrorKind::NotFound && allow_create => {
                created = true;
                host_fs::open_relative(
                    &directory.0,
                    &segment,
                    WRITE,
                    FILE_CREATE,
                    Kind::NonDirectory,
                    Some(&Descriptor::private(false)?),
                )?
            }
            result => result?,
        };
        let initial = Stat::of(&file)?;
        let value = Self {
            directory: HostDirectory(directory.0.try_clone()?, Ownership::Private),
            name: name.into(),
            file,
            initial,
        };
        value.stat()?;
        if created {
            host_fs::flush(&value.file)?;
            host_fs::flush_directory(&value.directory.0)?;
            value.stat()?;
        }
        Ok(value)
    }
    fn stat(&self) -> io::Result<Stat> {
        owned(&self.directory.0, true, Ownership::Private)?;
        let (stat, access) = held(&self.file)?;
        let named = self.directory.stat_at(&self.name)?;
        if !private_regular(&stat, &access) || !stat.same_file(&self.initial) || stat != named {
            return Err(fail());
        }
        Ok(stat)
    }
    pub fn byte_count(&self) -> io::Result<u64> {
        Ok(self.stat()?.size)
    }
    /// Every identity field the committed-prefix cache compares, in the
    /// Unix field order: device, inode, generation (0: the NTFS file
    /// reference carries its own reuse sequence), size, both times, the
    /// owner's granted rights, the attributes and the link count.
    pub fn checkpoint_identity(&self) -> io::Result<String> {
        let s = self.stat()?;
        let rights = Access::of(&self.file)?.user;
        let (modified, modified_nanos) = host_fs::unix_time(s.written);
        let (changed, changed_nanos) = host_fs::unix_time(s.changed);
        Ok(format!(
            "{}:{}:0:{}:{modified}:{modified_nanos}:{changed}:{changed_nanos}:{rights:x}:{:x}:{}",
            s.volume,
            s.inode()?,
            s.size,
            s.attributes,
            s.links
        ))
    }
    /// Hash the exact currently named staging file without materializing it.
    pub fn complete_digest(&self, expected: u64) -> io::Result<String> {
        let before = self.stat()?;
        if before.size != expected {
            return Err(fail());
        }
        let digest = range_digest(&self.file, 0, expected)?;
        if before != self.stat()? {
            return Err(fail());
        }
        Ok(digest)
    }

    /// Bounded validator input from the retained staging file.
    pub fn validator_bytes(&self, maximum: usize, prefix_only: bool) -> io::Result<Vec<u8>> {
        let before = self.stat()?;
        let length = usize::try_from(before.size).map_err(|_| fail())?;
        if !prefix_only && length > maximum {
            return Err(fail());
        }
        let mut bytes = vec![0; length.min(maximum)];
        read_exact_at(&self.file, &mut bytes, 0)?;
        if before != self.stat()? {
            return Err(fail());
        }
        Ok(bytes)
    }

    /// Sequential validator input from the retained staging file, read by
    /// offset so no file position moves. As for every validator, the caller
    /// compares the file's identity before and after reading.
    pub fn validator_reader(&self) -> HostUploadReader<'_> {
        HostUploadReader {
            file: &self.file,
            offset: 0,
        }
    }

    /// Stream exact validated bytes to an exclusive, sealed Artifact file.
    /// The derived destination is never replaced. Interrupted copies remain
    /// private temporary files; only a fully flushed payload becomes visible.
    pub fn publish_immutable(
        &self,
        root: &HostDirectory,
        name: &str,
        expected: u64,
        digest: &str,
    ) -> io::Result<()> {
        let before = self.stat()?;
        if before.size != expected {
            return Err(fail());
        }
        if !matches!(root.1, Ownership::Private) {
            return Err(fail());
        }
        owned(&root.0, true, Ownership::Private)?;
        let target = segment(name)?;
        // The Import owner serializes this derived destination. Recover only
        // its private, unpublished copy files left by process termination.
        let prefix = format!(".{name}.");
        for entry in root.names(4096)? {
            if let Some(nonce) = entry
                .strip_prefix(&prefix)
                .and_then(|v| v.strip_suffix(".tmp"))
            {
                if nonce.len() != 32
                    || !nonce
                        .bytes()
                        .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
                {
                    return Err(fail());
                }
                remove_orphan(root, &entry)?;
            }
        }
        let nonce = u128::from_ne_bytes(crate::random_bytes::<16>()?);
        let temporary = format!(".{name}.{nonce:032x}.tmp");
        // Write access and the right to seal are taken at creation: a handle
        // cannot gain them after the seal removes them from the DACL.
        let file = host_fs::open_relative(
            &root.0,
            &segment(&temporary)?,
            WRITE | WRITE_DAC,
            FILE_CREATE,
            Kind::NonDirectory,
            Some(&Descriptor::private(false)?),
        )?;
        let mut stage = CheckpointStage {
            root,
            name: temporary,
            file,
            published: false,
        };
        let mut hash = Sha256::new();
        let mut offset = 0;
        let mut buffer = vec![0; 1024 * 1024];
        while offset < expected {
            let count = (expected - offset).min(buffer.len() as u64) as usize;
            read_exact_at(&self.file, &mut buffer[..count], offset)?;
            hash.update(&buffer[..count]);
            stage.file.write_all(&buffer[..count])?;
            offset += count as u64;
        }
        if format!("{:x}", hash.finalize()) != digest || before != self.stat()? {
            return Err(fail());
        }
        stage.validate()?;
        host_fs::seal(&stage.file)?;
        host_fs::flush(&stage.file)?;
        let sealed = Stat::of(&stage.file)?;
        let linked = root.stat_at(&stage.name)?;
        if sealed != linked || before != self.stat()? {
            return Err(fail());
        }
        host_fs::rename(&stage.file, &root.0, &target, false)?;
        stage.published = true;
        host_fs::flush_directory(&root.0)?;
        root.verify_payload(name, expected, digest)
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
            host_fs::flush(&self.file)?;
            self.stat()?;
        }
        let before = self.stat()?;
        for chunk in chunks {
            if range_digest(&self.file, chunk.offset, chunk.byte_count)? != chunk.sha256 {
                return Err(fail());
            }
        }
        if before != self.stat()? {
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
                .seek_write(&bytes[written..end], offset + written as u64)
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
        host_fs::flush(&self.file)?;
        checkpoint(UploadWritePoint::AfterChunkSync)?;
        let before = self.stat()?;
        if before.size != offset + bytes.len() as u64
            || range_digest(&self.file, offset, bytes.len() as u64)? != digest
            || before != self.stat()?
        {
            return Err(fail());
        }
        Ok(())
    }
}

/// Unix `remove_document` of an unpublished copy: the private single-link
/// regular file at `name`, deleted through the handle that was checked, then
/// the directory barrier.
fn remove_orphan(root: &HostDirectory, name: &str) -> io::Result<()> {
    let file = host_fs::open_relative(
        &root.0,
        &segment(name)?,
        DELETE | FILE_READ_ATTRIBUTES | windows_sys::Win32::Storage::FileSystem::READ_CONTROL,
        FILE_OPEN,
        Kind::NonDirectory,
        None,
    )?;
    owned(&file, false, Ownership::Private)?;
    if !Stat::of(&file)?.same_file(&root.stat_at(name)?) {
        return Err(fail());
    }
    host_fs::delete(&file)?;
    drop(file);
    host_fs::flush_directory(&root.0)
}

struct CheckpointStage<'a> {
    root: &'a HostDirectory,
    name: String,
    file: File,
    published: bool,
}
impl CheckpointStage<'_> {
    fn validate(&self) -> io::Result<()> {
        let (stat, access) = held(&self.file)?;
        let named = self.root.stat_at(&self.name)?;
        if !private_regular(&stat, &access) || stat != named {
            return Err(fail());
        }
        Ok(())
    }
}
impl Drop for CheckpointStage<'_> {
    fn drop(&mut self) {
        if !self.published && self.validate().is_ok() {
            // Cleanup is limited to the exact temporary file held here: the
            // delete goes through its handle, never through its name.
            let _ = host_fs::delete(&self.file);
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
        let original = match self.inspect_at(name) {
            Ok((stat, access)) if private_regular(&stat, &access) && prior.is_some() => {
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
        // One generated private name; FILE_CREATE never adopts an orphan.
        let file = host_fs::open_relative(
            &self.0,
            &segment(&staging_name)?,
            WRITE,
            FILE_CREATE,
            Kind::NonDirectory,
            Some(&Descriptor::private(false)?),
        )?;
        let mut stage = CheckpointStage {
            root: self,
            name: staging_name,
            file,
            published: false,
        };
        stage.file.write_all(bytes)?;
        host_fs::flush(&stage.file)?;
        stage.validate()?;
        let ready = Stat::of(&stage.file)?;
        if ready.size != bytes.len() as u64
            || range_digest(&stage.file, 0, bytes.len() as u64)?
                != format!("{:x}", Sha256::digest(bytes))
        {
            return Err(fail().into());
        }
        stage.validate()?;
        if ready != Stat::of(&stage.file)? {
            return Err(fail().into());
        }
        match (&original, self.stat_at(name)) {
            (None, Err(error)) if error.kind() == io::ErrorKind::NotFound => {}
            (Some(expected), Ok(current)) if *expected == current => {
                if self.read(name, maximum)?.as_slice() != prior.unwrap()
                    || *expected != self.stat_at(name)?
                {
                    return Err(fail().into());
                }
            }
            _ => return Err(io::Error::from(io::ErrorKind::AlreadyExists).into()),
        }
        stage.validate()?;
        if ready != Stat::of(&stage.file)? {
            return Err(fail().into());
        }
        // Both names are relative to the held directory; new records are
        // exclusive (no replace), a frozen successor replaces its prior and
        // waits out a holder of it as every published document does.
        let renamed = if original.is_some() {
            super::rename_replacing(&stage.file, &self.0, &target)
        } else {
            host_fs::rename(&stage.file, &self.0, &target, false)
        };
        if let Err(error) = renamed {
            // An existing name, or a held one, was not replaced.
            return Err(
                if error.kind() == io::ErrorKind::AlreadyExists || host_fs::held(&error) {
                    BeforePublication(error)
                } else {
                    OutcomeUnknown(error)
                },
            );
        }
        stage.published = true;
        host_fs::flush_directory(&self.0).map_err(OutcomeUnknown)?;
        let held = Stat::of(&stage.file).map_err(OutcomeUnknown)?;
        let linked = self.stat_at(name).map_err(OutcomeUnknown)?;
        if held != linked || self.read(name, maximum).map_err(OutcomeUnknown)? != bytes {
            return Err(OutcomeUnknown(fail()));
        }
        Ok(())
    }
}

/// What the source's name is reopened with to compare its identity: the
/// attributes only, which no share mode refuses, and a reparse point as
/// itself.
fn linked_source(path: &Path) -> io::Result<Stat> {
    use std::os::windows::fs::OpenOptionsExt;
    use windows_sys::Win32::Storage::FileSystem::{
        FILE_FLAG_BACKUP_SEMANTICS, FILE_FLAG_OPEN_REPARSE_POINT,
    };
    let file = std::fs::OpenOptions::new()
        .access_mode(FILE_READ_ATTRIBUTES | SYNCHRONIZE)
        .share_mode(host_fs::SHARE_ALL)
        .custom_flags(FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT)
        .open(path)?;
    Stat::of(&file)
}

/// Explicit caller-selected source. Its handle, pathname binding and content
/// identity are held throughout one bounded upload; no source is ever modified.
pub struct HostImportSource {
    file: File,
    path: std::path::PathBuf,
    initial: Stat,
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
        use std::os::windows::fs::OpenOptionsExt;
        use windows_sys::Win32::Storage::FileSystem::FILE_FLAG_OPEN_REPARSE_POINT;
        check()?;
        let path = if path.is_absolute() {
            path.to_owned()
        } else {
            std::env::current_dir()?.join(path)
        };
        // A `:` in the last component names an alternate data stream of a
        // file, not a file.
        let name = path
            .file_name()
            .and_then(|s| s.to_str())
            .filter(|s| !s.is_empty() && !s.contains(':'))
            .ok_or_else(fail)?
            .to_owned();
        // Shared for reading only: while this handle lives nobody writes the
        // source, renames it, or replaces or deletes its name.
        let file = std::fs::OpenOptions::new()
            .access_mode(FILE_READ_DATA | FILE_READ_ATTRIBUTES | SYNCHRONIZE)
            .share_mode(FILE_SHARE_READ)
            .custom_flags(FILE_FLAG_OPEN_REPARSE_POINT)
            .open(&path)?;
        let initial = Stat::of(&file)?;
        if initial.attributes & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
            // The `ELOOP` of `O_NOFOLLOW`: a link is never read through.
            return Err(io::Error::from_raw_os_error(
                windows_sys::Win32::Foundation::ERROR_STOPPED_ON_SYMLINK as i32,
            ));
        }
        // SAFETY: a live handle.
        let disk = unsafe { GetFileType(std::os::windows::io::AsRawHandle::as_raw_handle(&file)) }
            == FILE_TYPE_DISK;
        if !disk || !initial.regular() || initial.size == 0 || initial.size > maximum {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "Import source exceeds its registered regular-file bound",
            ));
        }
        let mut source = Self {
            file,
            path,
            byte_count: initial.size,
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
        let current = Stat::of(&self.file)?;
        let linked = linked_source(&self.path)?;
        if self.initial != current || !linked.regular() || !linked.same_file(&self.initial) {
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
        read_exact_at(&self.file, &mut bytes, offset)?;
        self.check_identity()?;
        Ok(bytes)
    }
}
