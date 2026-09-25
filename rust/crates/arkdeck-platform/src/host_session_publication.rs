//! The writes a Session publication makes, each as Swift's Session storage
//! makes it: a Session root created once, its identity document created once,
//! locks held by blocking `flock`, the outcome audit appended under the log's
//! writer lock, and the terminal Manifest published write-once.
use super::*;

impl HostDirectory {
    /// Swift `SessionStore.createSession`'s `mkdir(root, 0700)`: a new private
    /// child. An existing entry is refused, never adopted.
    pub fn create_private_child(&self, name: &str) -> io::Result<Self> {
        if !matches!(self.1, Ownership::Private) {
            return Err(fail());
        }
        let name_c = segment(name)?;
        // SAFETY: the held directory descriptor and one checked segment.
        if unsafe { libc::mkdirat(self.0.as_raw_fd(), name_c.as_ptr(), 0o700) } != 0 {
            return Err(io::Error::last_os_error());
        }
        self.child(name)
    }

    /// The directory's namespace barrier.
    pub fn sync(&self) -> io::Result<()> {
        owned(&self.0, true, self.1)?;
        self.0.sync_all()
    }

    /// A private document created once (`O_EXCL`, 0600) and fully
    /// synchronized, as Swift writes a fresh Session identity.
    pub fn create_document(&self, name: &str, bytes: &[u8]) -> io::Result<()> {
        if !matches!(self.1, Ownership::Private) {
            return Err(fail());
        }
        let name_c = segment(name)?;
        // SAFETY: the held directory descriptor and one checked segment.
        let fd = unsafe {
            libc::openat(
                self.0.as_raw_fd(),
                name_c.as_ptr(),
                libc::O_RDWR | libc::O_CREAT | libc::O_EXCL | libc::O_NOFOLLOW | libc::O_CLOEXEC,
                0o600,
            )
        };
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: openat returned a new owned descriptor.
        let mut file = unsafe { File::from_raw_fd(fd) };
        file.write_all(bytes)?;
        file.sync_all()
    }

    /// A lock file held by blocking `flock` and still bound to its name once
    /// held, created 0600 when absent: Swift's terminal publication lock (which
    /// synchronizes a new lock with its directory) and its Artifact
    /// publication shards (which do not).
    pub fn wait_lock(&self, name: &str, synchronize_created: bool) -> io::Result<HostReadLock> {
        if !matches!(self.1, Ownership::Private) {
            return Err(fail());
        }
        let name_c = segment(name)?;
        let flags = libc::O_RDWR | libc::O_NOFOLLOW | libc::O_CLOEXEC;
        // SAFETY: the held directory descriptor and one checked segment.
        let mut fd = unsafe {
            libc::openat(
                self.0.as_raw_fd(),
                name_c.as_ptr(),
                flags | libc::O_CREAT | libc::O_EXCL,
                0o600,
            )
        };
        let created = fd >= 0;
        if fd < 0 && io::Error::last_os_error().kind() == io::ErrorKind::AlreadyExists {
            // SAFETY: as above; the existing entry is checked below.
            fd = unsafe { libc::openat(self.0.as_raw_fd(), name_c.as_ptr(), flags) };
        }
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: openat returned a new owned descriptor.
        let file = unsafe { File::from_raw_fd(fd) };
        owned(&file, false, self.1)?;
        if created && synchronize_created {
            file.sync_all()?;
            self.0.sync_all()?;
        }
        // SAFETY: flock on the retained descriptor.
        while unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX) } != 0 {
            let error = io::Error::last_os_error();
            if error.kind() != io::ErrorKind::Interrupted {
                return Err(error);
            }
        }
        let lock = HostReadLock { file };
        lock.validate_link(self, name)?;
        Ok(lock)
    }

    /// Swift `FileDurableSessionAuditStore.appendAndSynchronize` for one
    /// record: appended under the log's exclusive writer lock, a new log
    /// synchronized with its directory first, then the file and directory.
    pub fn append_record(&self, name: &str, bytes: &[u8]) -> io::Result<()> {
        if !matches!(self.1, Ownership::Private) {
            return Err(fail());
        }
        let name_c = segment(name)?;
        let flags = libc::O_RDWR | libc::O_APPEND | libc::O_NOFOLLOW | libc::O_CLOEXEC;
        // SAFETY: the held directory descriptor and one checked segment.
        let mut fd = unsafe {
            libc::openat(
                self.0.as_raw_fd(),
                name_c.as_ptr(),
                flags | libc::O_CREAT | libc::O_EXCL,
                0o600,
            )
        };
        let created = fd >= 0;
        if fd < 0 && io::Error::last_os_error().kind() == io::ErrorKind::AlreadyExists {
            // SAFETY: as above; the existing entry is checked below.
            fd = unsafe { libc::openat(self.0.as_raw_fd(), name_c.as_ptr(), flags) };
        }
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: openat returned a new owned descriptor.
        let mut file = unsafe { File::from_raw_fd(fd) };
        owned(&file, false, self.1)?;
        // SAFETY: flock on the retained descriptor.
        if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
            return Err(io::Error::last_os_error());
        }
        if created {
            file.sync_all()?;
            self.0.sync_all()?;
        }
        file.write_all(bytes)?;
        file.sync_all()?;
        self.0.sync_all()
    }

    /// Swift `AtomicSessionManifestPublisher.publish`: a fresh private file,
    /// synchronized, renamed onto `name` only while nothing holds that name
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
        let temporary = segment(&format!(".{name}.{nonce}.tmp"))?;
        // SAFETY: the held directory descriptor and one checked segment.
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
                // SAFETY: the held directory and the temporary's own segment.
                unsafe {
                    libc::unlinkat(self.0.as_raw_fd(), self.1.as_ptr(), 0);
                }
            }
        }
        let temporary = Remove(&self.0, temporary);
        // SAFETY: openat returned a new owned descriptor.
        let mut file = unsafe { File::from_raw_fd(fd) };
        file.write_all(bytes)?;
        file.sync_all()?;
        drop(file);
        // SAFETY: both segments name entries of the held directory.
        if unsafe {
            libc::renameatx_np(
                self.0.as_raw_fd(),
                temporary.1.as_ptr(),
                self.0.as_raw_fd(),
                target.as_ptr(),
                libc::RENAME_EXCL,
            )
        } != 0
        {
            return Err(DocumentPublishError::BeforePublication(
                io::Error::last_os_error(),
            ));
        }
        self.0
            .sync_all()
            .map_err(DocumentPublishError::OutcomeUnknown)
    }

    /// This directory's child `name` renamed to `to` in `destination` with
    /// `renameatx_np(RENAME_EXCL)`: `true` once moved, `false` when `to`
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
        let from = segment(name)?;
        let to = segment(to)?;
        // SAFETY: two held directory descriptors and two checked segments.
        let moved = unsafe {
            libc::renameatx_np(
                self.0.as_raw_fd(),
                from.as_ptr(),
                destination.0.as_raw_fd(),
                to.as_ptr(),
                libc::RENAME_EXCL,
            )
        };
        if moved == 0 {
            return Ok(true);
        }
        let error = io::Error::last_os_error();
        if error.raw_os_error() == Some(libc::EEXIST) {
            return Ok(false);
        }
        Err(error)
    }

    /// The tree `name` below this directory, removed through descriptors
    /// only: its directories and regular files, and never a link or any
    /// other kind of entry, which refuses. An absent tree is already removed.
    pub fn remove_tree(&self, name: &str) -> io::Result<()> {
        if !matches!(self.1, Ownership::Private) {
            return Err(fail());
        }
        crate::distribution_tree::remove_tree_snapshot(&self.0, name).map_err(|_| fail())
    }

    /// The directory `name` below this one removed if it is empty: `true`
    /// once removed, `false` when it still holds an entry or is gone.
    pub fn remove_if_empty(&self, name: &str) -> io::Result<bool> {
        if !matches!(self.1, Ownership::Private) {
            return Err(fail());
        }
        let name_c = segment(name)?;
        // SAFETY: the held directory descriptor and one checked segment.
        if unsafe { libc::unlinkat(self.0.as_raw_fd(), name_c.as_ptr(), libc::AT_REMOVEDIR) } == 0 {
            return Ok(true);
        }
        let error = io::Error::last_os_error();
        match error.raw_os_error() {
            Some(libc::ENOTEMPTY | libc::EEXIST | libc::ENOENT) => Ok(false),
            _ => Err(error),
        }
    }
}

#[cfg(test)]
mod staging_tests {
    use super::*;
    use std::os::unix::fs::{DirBuilderExt, symlink};
    use std::path::PathBuf;

    struct Scratch(PathBuf);
    impl Drop for Scratch {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
    fn private(path: &std::path::Path) {
        std::fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(path)
            .unwrap();
    }

    #[test]
    fn a_staged_tree_moves_once_never_over_an_entry_and_is_removed_by_descriptor() {
        let nonce = u128::from_ne_bytes(crate::random_bytes::<16>().unwrap());
        let scratch = Scratch(
            std::env::temp_dir()
                .canonicalize()
                .unwrap()
                .join(format!("staging-{nonce:032x}")),
        );
        for path in [
            "root/.staging/first/nested",
            "root/.staging/second",
            "root/2026/09",
        ] {
            private(&scratch.0.join(path));
        }
        std::fs::write(scratch.0.join("root/.staging/first/nested/file"), b"x").unwrap();
        let root = HostDirectory::open(&scratch.0.join("root")).unwrap();
        let staging = root.child(".staging").unwrap();
        let month = root.child("2026").unwrap().child("09").unwrap();

        assert!(staging.move_exclusive("first", &month, "session").unwrap());
        assert!(scratch.0.join("root/2026/09/session/nested/file").exists());
        assert!(!scratch.0.join("root/.staging/first").exists());
        // Never over an entry: the second stays where it was.
        assert!(!staging.move_exclusive("second", &month, "session").unwrap());
        assert!(scratch.0.join("root/.staging/second").exists());

        assert!(!root.remove_if_empty(".staging").unwrap());
        staging.remove_tree("second").unwrap();
        staging.remove_tree("second").unwrap();
        assert!(root.remove_if_empty(".staging").unwrap());
        assert!(!root.remove_if_empty(".staging").unwrap());

        // A link is never followed or removed.
        private(&scratch.0.join("root/.staging/linked"));
        symlink("/", scratch.0.join("root/.staging/linked/escape")).unwrap();
        let staging = root.child(".staging").unwrap();
        assert!(staging.remove_tree("linked").is_err());
        assert!(scratch.0.join("root/.staging/linked/escape").is_symlink());
    }
}
