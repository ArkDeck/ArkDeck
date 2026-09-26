//! Descriptor-relative updater artifacts. Unlike lifecycle records, disposable
//! downloads allow the published Swift cache's F_FULLFSYNC → fsync fallback.
use super::*;
use sha2::{Digest, Sha256};

#[derive(Debug)]
pub enum UpdateDownloadError {
    Io(io::Error),
    UnsafeDirectory,
    UnsafeArtifact,
    ResponseOverflow,
    Truncated,
    DigestMismatch,
    /// The final name may exist: callers must not replay publication.
    PublicationUnknown(io::Error),
}

impl From<io::Error> for UpdateDownloadError {
    fn from(value: io::Error) -> Self {
        Self::Io(value)
    }
}

pub struct HostUpdateDownload {
    root: HostDirectory,
    file: File,
    partial: String,
    final_name: String,
    partial_present: bool,
    expected: u64,
    received: u64,
    hash: Sha256,
}

fn cache_sync(file: &File) -> io::Result<()> {
    // SAFETY: retained descriptor, neither command needs a trailing argument.
    if unsafe { libc::fcntl(file.as_raw_fd(), libc::F_FULLFSYNC) } == 0
        || unsafe { libc::fsync(file.as_raw_fd()) } == 0
    {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
    }
}

fn artifact_identity(file: &File) -> Result<HostFileIdentity, UpdateDownloadError> {
    let metadata = file.metadata()?;
    if !metadata.is_file()
        || metadata.uid() != crate::effective_user_id()
        || metadata.nlink() != 1
        || metadata.mode() & 0o7777 != 0o400
    {
        return Err(UpdateDownloadError::UnsafeArtifact);
    }
    Ok(HostFileIdentity::of(&metadata))
}

impl HostDirectory {
    /// The caller owns this root for the entire stream. Names are immediate
    /// UUID-derived components; final publication refuses any existing entry.
    pub fn begin_update_download(
        self,
        expected: u64,
    ) -> Result<HostUpdateDownload, UpdateDownloadError> {
        if !matches!(self.1, Ownership::Private) {
            return Err(UpdateDownloadError::UnsafeArtifact);
        }
        if expected == 0 {
            return Err(UpdateDownloadError::Truncated);
        }
        owned(&self.0, true, self.1)?;
        let mut bytes = crate::random_bytes::<16>()?;
        bytes[6] = (bytes[6] & 0x0f) | 0x40;
        bytes[8] = (bytes[8] & 0x3f) | 0x80;
        let hex: String = bytes.iter().map(|byte| format!("{byte:02x}")).collect();
        let stem = format!(
            "{}-{}-{}-{}-{}",
            &hex[..8],
            &hex[8..12],
            &hex[12..16],
            &hex[16..20],
            &hex[20..]
        );
        let partial = format!("{stem}.part");
        let name = segment(&partial)?;
        // SAFETY: exclusive immediate entry under the retained private root.
        let fd = unsafe {
            libc::openat(
                self.0.as_raw_fd(),
                name.as_ptr(),
                libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL | libc::O_CLOEXEC | libc::O_NOFOLLOW,
                0o600,
            )
        };
        if fd < 0 {
            return Err(io::Error::last_os_error().into());
        }
        // SAFETY: newly owned descriptor from successful openat.
        let file = unsafe { File::from_raw_fd(fd) };
        Ok(HostUpdateDownload {
            root: self,
            file,
            partial,
            final_name: format!("{stem}.dmg"),
            partial_present: true,
            expected,
            received: 0,
            hash: Sha256::new(),
        })
    }

    /// Rehash a sealed artifact with bounded memory and compare the descriptor
    /// and immediate name before/after reading. No symlink or hardlink follows.
    pub fn verify_update_download(
        &self,
        name: &str,
        expected: u64,
        digest: &str,
    ) -> Result<HostFileIdentity, UpdateDownloadError> {
        if !matches!(self.1, Ownership::Private) {
            return Err(UpdateDownloadError::UnsafeArtifact);
        }
        owned(&self.0, true, self.1)?;
        let name_c = segment(name)?;
        // SAFETY: NONBLOCK refuses FIFO blocking before the type check.
        let fd = unsafe {
            libc::openat(
                self.0.as_raw_fd(),
                name_c.as_ptr(),
                libc::O_RDONLY | libc::O_CLOEXEC | libc::O_NOFOLLOW | libc::O_NONBLOCK,
            )
        };
        if fd < 0 {
            return Err(io::Error::last_os_error().into());
        }
        // SAFETY: successful openat transfers a new descriptor.
        let mut file = unsafe { File::from_raw_fd(fd) };
        let before = artifact_identity(&file)?;
        if before.size != expected {
            return Err(UpdateDownloadError::Truncated);
        }
        let mut hash = Sha256::new();
        let mut count = 0u64;
        let mut buffer = [0u8; 65_536];
        loop {
            let n = file.read(&mut buffer)?;
            if n == 0 {
                break;
            }
            count = count
                .checked_add(n as u64)
                .ok_or(UpdateDownloadError::ResponseOverflow)?;
            if count > expected {
                return Err(UpdateDownloadError::ResponseOverflow);
            }
            hash.update(&buffer[..n]);
        }
        if count != expected {
            return Err(UpdateDownloadError::Truncated);
        }
        if format!("{:x}", hash.finalize()) != digest {
            return Err(UpdateDownloadError::DigestMismatch);
        }
        if artifact_identity(&file)? != before || self.file_identity(name)? != before {
            return Err(UpdateDownloadError::UnsafeArtifact);
        }
        Ok(before)
    }
}

impl HostUpdateDownload {
    pub fn write_chunk(&mut self, bytes: &[u8]) -> Result<(), UpdateDownloadError> {
        if bytes.len() as u64 > self.expected - self.received {
            return Err(UpdateDownloadError::ResponseOverflow);
        }
        self.file.write_all(bytes)?;
        self.hash.update(bytes);
        self.received += bytes.len() as u64;
        Ok(())
    }

    pub fn received(&self) -> u64 {
        self.received
    }

    /// Consumes the writer, so an uncertain rename or directory sync cannot be
    /// retried. Drop removes only the staging entry still linked to our inode.
    pub fn seal(mut self, digest: &str) -> Result<(String, HostFileIdentity), UpdateDownloadError> {
        if self.received != self.expected {
            return Err(UpdateDownloadError::Truncated);
        }
        if format!("{:x}", self.hash.clone().finalize()) != digest {
            return Err(UpdateDownloadError::DigestMismatch);
        }
        cache_sync(&self.file)?;
        // SAFETY: private exclusive artifact descriptor, never a caller path.
        if unsafe { libc::fchmod(self.file.as_raw_fd(), 0o400) } != 0 {
            return Err(io::Error::last_os_error().into());
        }
        cache_sync(&self.file)?;
        let before = artifact_identity(&self.file)?;
        if self.root.file_identity(&self.partial)? != before {
            return Err(UpdateDownloadError::UnsafeArtifact);
        }
        let part = segment(&self.partial)?;
        let final_name = segment(&self.final_name)?;
        // SAFETY: both immediate names under one held directory. RENAME_EXCL
        // refuses collisions instead of overwriting any existing artifact.
        if unsafe {
            libc::renameatx_np(
                self.root.0.as_raw_fd(),
                part.as_ptr(),
                self.root.0.as_raw_fd(),
                final_name.as_ptr(),
                libc::RENAME_EXCL,
            )
        } != 0
        {
            return Err(UpdateDownloadError::PublicationUnknown(
                io::Error::last_os_error(),
            ));
        }
        self.partial_present = false;
        cache_sync(&self.root.0).map_err(UpdateDownloadError::PublicationUnknown)?;
        let after = artifact_identity(&self.file)?;
        if self.root.file_identity(&self.final_name)? != after {
            return Err(UpdateDownloadError::UnsafeArtifact);
        }
        Ok((self.final_name.clone(), after))
    }
}

impl Drop for HostUpdateDownload {
    fn drop(&mut self) {
        if self.partial_present {
            // Never unlink a replacement installed at our old staging name.
            if let (Ok(opened), Ok(linked)) =
                (self.file.metadata(), self.root.stat_at(&self.partial))
                && opened.dev() == linked.st_dev as u64
                && opened.ino() == linked.st_ino
            {
                let _ = self.root.unlink_update_entry(&self.partial);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::{PermissionsExt, symlink};

    struct Temp(std::path::PathBuf);
    impl Temp {
        fn new() -> Self {
            let nonce: String = crate::random_bytes::<16>()
                .unwrap()
                .iter()
                .map(|b| format!("{b:02x}"))
                .collect();
            Self(std::env::temp_dir().join(format!("arkdeck-download-{nonce}")))
        }
        fn root(&self) -> HostDirectory {
            HostDirectory::open_update_store(&self.0).unwrap()
        }
    }
    impl Drop for Temp {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
    fn digest(bytes: &[u8]) -> String {
        format!("{:x}", Sha256::digest(bytes))
    }

    #[test]
    fn seals_stream_and_rehashes_only_the_same_immutable_single_link_inode() {
        let temp = Temp::new();
        let data = vec![0x42; 200_001];
        let mut writer = temp
            .root()
            .begin_update_download(data.len() as u64)
            .unwrap();
        for chunk in data.chunks(65_536) {
            writer.write_chunk(chunk).unwrap();
        }
        assert_eq!(writer.received(), data.len() as u64);
        let (name, identity) = writer.seal(&digest(&data)).unwrap();
        assert_eq!(std::fs::read_dir(&temp.0).unwrap().count(), 1);
        assert_eq!(
            std::fs::metadata(temp.0.join(&name)).unwrap().mode() & 0o7777,
            0o400
        );
        assert_eq!(
            temp.root()
                .verify_update_download(&name, data.len() as u64, &digest(&data))
                .unwrap(),
            identity
        );
        assert!(matches!(
            temp.root().verify_update_download(&name, 2, &digest(&data)),
            Err(UpdateDownloadError::Truncated)
        ));
        assert!(matches!(
            temp.root()
                .verify_update_download(&name, data.len() as u64, &digest(b"bad")),
            Err(UpdateDownloadError::DigestMismatch)
        ));
        std::fs::hard_link(temp.0.join(&name), temp.0.join("hardlink")).unwrap();
        assert!(matches!(
            temp.root()
                .verify_update_download(&name, data.len() as u64, &digest(&data)),
            Err(UpdateDownloadError::UnsafeArtifact)
        ));
        std::fs::remove_file(temp.0.join("hardlink")).unwrap();
        std::fs::set_permissions(temp.0.join(&name), std::fs::Permissions::from_mode(0o600))
            .unwrap();
        assert!(matches!(
            temp.root()
                .verify_update_download(&name, data.len() as u64, &digest(&data)),
            Err(UpdateDownloadError::UnsafeArtifact)
        ));
    }

    #[test]
    fn refuses_overflow_truncation_digest_and_nonregular_input_without_leaking_parts() {
        let temp = Temp::new();
        assert!(matches!(
            temp.root().begin_update_download(0),
            Err(UpdateDownloadError::Truncated)
        ));
        let mut writer = temp.root().begin_update_download(3).unwrap();
        assert!(matches!(
            writer.write_chunk(b"four"),
            Err(UpdateDownloadError::ResponseOverflow)
        ));
        assert_eq!(writer.received(), 0);
        drop(writer);
        let mut writer = temp.root().begin_update_download(3).unwrap();
        writer.write_chunk(b"ab").unwrap();
        assert!(matches!(
            writer.seal(&digest(b"ab")),
            Err(UpdateDownloadError::Truncated)
        ));
        let mut writer = temp.root().begin_update_download(3).unwrap();
        writer.write_chunk(b"abc").unwrap();
        assert!(matches!(
            writer.seal(&digest(b"xyz")),
            Err(UpdateDownloadError::DigestMismatch)
        ));
        assert_eq!(std::fs::read_dir(&temp.0).unwrap().count(), 0);
        std::fs::write(temp.0.join("target"), b"abc").unwrap();
        symlink("target", temp.0.join("link")).unwrap();
        assert!(
            temp.root()
                .verify_update_download("link", 3, &digest(b"abc"))
                .is_err()
        );
        std::fs::create_dir(temp.0.join("directory")).unwrap();
        assert!(matches!(
            temp.root()
                .verify_update_download("directory", 3, &digest(b"abc")),
            Err(UpdateDownloadError::UnsafeArtifact)
        ));
    }

    #[test]
    fn refuses_replaced_staging_name_and_preserves_existing_final_artifact() {
        let temp = Temp::new();
        let mut writer = temp.root().begin_update_download(3).unwrap();
        writer.write_chunk(b"abc").unwrap();
        std::fs::rename(temp.0.join(&writer.partial), temp.0.join("moved")).unwrap();
        std::fs::write(temp.0.join(&writer.partial), b"replacement").unwrap();
        let partial = writer.partial.clone();
        assert!(matches!(
            writer.seal(&digest(b"abc")),
            Err(UpdateDownloadError::UnsafeArtifact)
        ));
        assert_eq!(std::fs::read(temp.0.join(partial)).unwrap(), b"replacement");
        let mut writer = temp.root().begin_update_download(3).unwrap();
        writer.write_chunk(b"abc").unwrap();
        let final_name = writer.final_name.clone();
        let partial = writer.partial.clone();
        std::fs::write(temp.0.join(&final_name), b"existing").unwrap();
        assert!(matches!(
            writer.seal(&digest(b"abc")),
            Err(UpdateDownloadError::PublicationUnknown(_))
        ));
        assert_eq!(std::fs::read(temp.0.join(final_name)).unwrap(), b"existing");
        assert!(!temp.0.join(partial).exists());
    }
}
