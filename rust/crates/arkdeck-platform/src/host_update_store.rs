//! The updater's durable 0400 records. Publication seals and fully syncs the
//! staging inode before rename; readers cannot observe a writable final record.
use super::*;

#[cfg(test)]
thread_local! { static PUBLISH_FAILURE: std::cell::Cell<u8> = const { std::cell::Cell::new(0) }; }

fn checkpoint(point: u8) -> io::Result<()> {
    #[cfg(test)]
    if PUBLISH_FAILURE.with(|failure| {
        if failure.get() == point {
            failure.set(0);
            true
        } else {
            false
        }
    }) {
        return Err(io::Error::other(
            "injected sealed-record publication failure",
        ));
    }
    let _ = point;
    Ok(())
}

fn strict_sync(file: &File) -> io::Result<()> {
    // SAFETY: both operations use the retained descriptor; F_FULLFSYNC takes
    // no trailing argument. Failure is never downgraded to ordinary fsync.
    if unsafe { libc::fsync(file.as_raw_fd()) } != 0
        || unsafe { libc::fcntl(file.as_raw_fd(), libc::F_FULLFSYNC) } != 0
    {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

impl HostDirectory {
    /// Cache cleanup unlinks one immediate entry and never follows a link or
    /// removes a directory. The lifecycle owner selects only its cache names.
    pub fn unlink_update_entry(&self, name: &str) -> io::Result<bool> {
        if !matches!(self.1, Ownership::Private) {
            return Err(fail());
        }
        let name = segment(name)?;
        // SAFETY: validated single component under the held cache root; flags
        // zero means symlinks themselves are removed and directories refused.
        if unsafe { libc::unlinkat(self.0.as_raw_fd(), name.as_ptr(), 0) } == 0 {
            return Ok(true);
        }
        let error = io::Error::last_os_error();
        if error.kind() == io::ErrorKind::NotFound {
            Ok(false)
        } else {
            Err(error)
        }
    }

    /// Shared updater lock names must keep their inode. `wait=false` is the
    /// process-lifetime operation lease; state transactions use `wait=true`.
    pub fn lock_update_record(&self, name: &str, wait: bool) -> io::Result<HostReadLock> {
        if !matches!(self.1, Ownership::Private) {
            return Err(fail());
        }
        let name_c = segment(name)?;
        // SAFETY: immediate name under a retained root. NONBLOCK also prevents
        // a malicious FIFO lock entry from blocking before its type check.
        let fd = unsafe {
            libc::openat(
                self.0.as_raw_fd(),
                name_c.as_ptr(),
                libc::O_RDWR
                    | libc::O_CREAT
                    | libc::O_NOFOLLOW
                    | libc::O_CLOEXEC
                    | libc::O_NONBLOCK,
                0o600,
            )
        };
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: openat returned a new owned descriptor.
        let file = unsafe { File::from_raw_fd(fd) };
        let metadata = file.metadata()?;
        if !metadata.is_file()
            || metadata.uid() != crate::effective_user_id()
            || metadata.nlink() != 1
        {
            return Err(fail());
        }
        // SAFETY: owned single-link regular lock file, not a caller path.
        if unsafe { libc::fchmod(file.as_raw_fd(), 0o600) } != 0 {
            return Err(fail());
        }
        owned(&file, false, self.1)?;
        let flags = libc::LOCK_EX | if wait { 0 } else { libc::LOCK_NB };
        loop {
            // SAFETY: flock operates on the retained lock inode.
            if unsafe { libc::flock(file.as_raw_fd(), flags) } == 0 {
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

    /// The updater creates missing parents but never follows a final root
    /// symlink. It changes mode only on the opened, owned directory inode.
    pub fn open_update_store(path: &Path) -> io::Result<Self> {
        use std::os::unix::{ffi::OsStrExt, fs::DirBuilderExt};
        if !path.is_absolute() {
            return Err(fail());
        }
        std::fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(path)?;
        let name = CString::new(path.as_os_str().as_bytes()).map_err(|_| fail())?;
        // SAFETY: NUL-terminated root; final symlinks are refused by open.
        let fd = unsafe {
            libc::open(
                name.as_ptr(),
                libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
            )
        };
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: successful open transfers one descriptor to File.
        let file = unsafe { File::from_raw_fd(fd) };
        let opened = file.metadata()?;
        if !opened.is_dir() || opened.uid() != crate::effective_user_id() {
            return Err(fail());
        }
        // SAFETY: ownership/type were checked on this retained inode.
        if unsafe { libc::fchmod(file.as_raw_fd(), 0o700) } != 0 {
            return Err(io::Error::last_os_error());
        }
        let linked = std::fs::symlink_metadata(path)?;
        if !linked.is_dir() || linked.dev() != opened.dev() || linked.ino() != opened.ino() {
            return Err(fail());
        }
        let directory = Self(file, Ownership::Private);
        owned(&directory.0, true, Ownership::Private)?;
        Ok(directory)
    }

    /// Reads exactly the updater's immutable record shape: private, single
    /// link, regular, 0400, nonempty and bounded. Missing is distinct from bad.
    pub fn read_sealed_record(&self, name: &str, maximum: usize) -> io::Result<Option<Vec<u8>>> {
        if !matches!(self.1, Ownership::Private) {
            return Err(fail());
        }
        let file = match self.open_at(name, 0) {
            Ok(file) => file,
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
            Err(error) => return Err(error),
        };
        owned(&file, false, self.1)?;
        let before = file.metadata()?;
        if before.mode() & 0o777 != 0o400 || before.len() == 0 || before.len() > maximum as u64 {
            return Err(fail());
        }
        let mut bytes = Vec::with_capacity(before.len() as usize);
        (&file).take(maximum as u64 + 1).read_to_end(&mut bytes)?;
        if !read_whole(
            &before,
            &file.metadata()?,
            &self.stat_at(name)?,
            bytes.len() as u64,
            maximum,
        ) {
            return Err(fail());
        }
        Ok(Some(bytes))
    }

    /// Swift RuntimeUpdateStateStore/FileUpdateReplayStore durability:
    /// fsync + F_FULLFSYNC, chmod 0400, both syncs again, rename, directory fsync.
    pub fn publish_sealed_record(
        &self,
        name: &str,
        bytes: &[u8],
        maximum: usize,
    ) -> Result<(), DocumentPublishError> {
        if !matches!(self.1, Ownership::Private) || bytes.is_empty() || bytes.len() > maximum {
            return Err(fail().into());
        }
        owned(&self.0, true, self.1)?;
        let target = segment(name)?;
        let nonce: String = crate::random_bytes::<16>()?
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect();
        let stage = segment(&format!(".{name}.{nonce}.part"))?;
        // SAFETY: one validated name relative to the retained private directory.
        let fd = unsafe {
            libc::openat(
                self.0.as_raw_fd(),
                stage.as_ptr(),
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
                // SAFETY: staging name under its retained directory, no traversal.
                unsafe {
                    libc::unlinkat(self.0.as_raw_fd(), self.1.as_ptr(), 0);
                }
            }
        }
        let stage = Remove(&self.0, stage);
        // SAFETY: openat returned a new owned descriptor.
        let mut file = unsafe { File::from_raw_fd(fd) };
        file.write_all(bytes)?;
        checkpoint(1)?;
        strict_sync(&file)?;
        // SAFETY: this is the staging inode we exclusively created.
        if unsafe { libc::fchmod(file.as_raw_fd(), 0o400) } != 0 {
            return Err(io::Error::last_os_error().into());
        }
        strict_sync(&file)?;
        // SAFETY: both names are immediate entries of the retained directory.
        checkpoint(2).map_err(DocumentPublishError::OutcomeUnknown)?;
        if unsafe {
            libc::renameat(
                self.0.as_raw_fd(),
                stage.1.as_ptr(),
                self.0.as_raw_fd(),
                target.as_ptr(),
            )
        } != 0
        {
            return Err(DocumentPublishError::OutcomeUnknown(
                io::Error::last_os_error(),
            ));
        }
        checkpoint(3).map_err(DocumentPublishError::OutcomeUnknown)?;
        self.0
            .sync_all()
            .map_err(DocumentPublishError::OutcomeUnknown)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    struct Root(std::path::PathBuf);
    impl Drop for Root {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn sealed_record_publication_distinguishes_prepublication_and_unknown_outcomes() {
        let nonce = u64::from_ne_bytes(crate::random_bytes::<8>().unwrap());
        let root = Root(std::env::temp_dir().join(format!("arkdeck-sealed-{nonce:016x}")));
        let directory = HostDirectory::open_update_store(&root.0).unwrap();
        for failure in [1, 2, 3] {
            directory
                .publish_sealed_record("state-v1.json", b"old", 32)
                .unwrap();
            PUBLISH_FAILURE.with(|slot| slot.set(failure));
            let error = directory
                .publish_sealed_record("state-v1.json", b"new", 32)
                .unwrap_err();
            if failure == 1 {
                assert!(matches!(error, DocumentPublishError::BeforePublication(_)));
            } else {
                assert!(matches!(error, DocumentPublishError::OutcomeUnknown(_)));
            }
            let expected = if failure == 3 { b"new" } else { b"old" };
            assert_eq!(
                directory
                    .read_sealed_record("state-v1.json", 32)
                    .unwrap()
                    .unwrap(),
                expected
            );
            let reopened = HostDirectory::open_update_store(&root.0).unwrap();
            assert_eq!(
                reopened
                    .read_sealed_record("state-v1.json", 32)
                    .unwrap()
                    .unwrap(),
                expected
            );
            assert_eq!(directory.names(10).unwrap(), vec!["state-v1.json"]);
        }
    }
}
