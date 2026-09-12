//! Sealed, descriptor-relative removal of a previously inspected Session tree.
//! Only the selected Session directory and its descendants are unlinked.
use super::*;
use std::fs::Metadata;

struct Node {
    parent: usize,
    name: String,
    metadata: Metadata,
    directory: Option<HostDirectory>,
    names: Vec<String>,
    digest: Option<String>,
}

pub struct PreparedSessionRemoval {
    root: HostDirectory,
    nodes: Vec<Node>,
    bytes: u64,
}

impl HostDirectory {
    /// Capture the exact year/month/Session subtree with safe ownership, file
    /// identities and bytes before the owner writes its applying intent.
    pub fn prepare_session_removal(
        &self,
        location: &[String; 3],
    ) -> io::Result<PreparedSessionRemoval> {
        if !matches!(self.1, Ownership::SessionTree { .. })
            || location[0].len() != 4
            || !location[0].bytes().all(|b| b.is_ascii_digit())
            || location[1].len() != 2
            || !location[1]
                .parse::<u8>()
                .ok()
                .is_some_and(|n| (1..=12).contains(&n))
        {
            return Err(fail());
        }
        let mut result = PreparedSessionRemoval {
            root: HostDirectory(self.0.try_clone()?, self.1),
            nodes: Vec::new(),
            bytes: 0,
        };
        for name in location {
            let parent = result.nodes.len();
            let root = result.directory(parent);
            let directory = root.child(name)?;
            let metadata = directory.0.metadata()?;
            result.nodes.push(Node {
                parent,
                name: name.clone(),
                metadata,
                directory: Some(directory),
                names: Vec::new(),
                digest: None,
            });
        }
        let mut index = 2;
        while index < result.nodes.len() {
            if result.nodes[index].directory.is_some() {
                let names = result.directory(index + 1).names(usize::MAX)?;
                result.nodes[index].names = names.clone();
                for name in names {
                    let parent = result.directory(index + 1);
                    let (kind, _) = parent.owned_kind_and_size(&name)?;
                    let (metadata, directory, digest) = match kind {
                        HostEntryKind::Directory => {
                            let directory = parent.child(&name)?;
                            (directory.0.metadata()?, Some(directory), None)
                        }
                        HostEntryKind::Regular => {
                            let file = parent.open_at(&name, 0)?;
                            owned(&file, false, parent.1)?;
                            let metadata = file.metadata()?;
                            let digest = parent
                                .optional_document_digest(&name, metadata.len())?
                                .ok_or_else(fail)?;
                            (metadata, None, Some(digest))
                        }
                        HostEntryKind::Other => return Err(fail()),
                    };
                    if directory.is_none() {
                        result.bytes = result.bytes.checked_add(metadata.len()).ok_or_else(fail)?;
                    }
                    result.nodes.push(Node {
                        parent: index + 1,
                        name,
                        metadata,
                        directory,
                        names: Vec::new(),
                        digest,
                    });
                }
            }
            index += 1;
        }
        result.validate()?;
        Ok(result)
    }
}

impl PreparedSessionRemoval {
    fn directory(&self, index: usize) -> &HostDirectory {
        if index == 0 {
            &self.root
        } else {
            self.nodes[index - 1]
                .directory
                .as_ref()
                .expect("directory parent")
        }
    }
    pub fn byte_count(&self) -> u64 {
        self.bytes
    }
    fn identity(&self, index: usize) -> io::Result<()> {
        let node = &self.nodes[index];
        let parent = self.directory(node.parent);
        owned(&parent.0, true, parent.1)?;
        let linked = parent.stat_at(&node.name)?;
        if linked.st_dev as u64 != node.metadata.dev() || linked.st_ino != node.metadata.ino() {
            return Err(fail());
        }
        if let Some(directory) = &node.directory {
            owned(&directory.0, true, directory.1)?;
            let held = directory.0.metadata()?;
            if held.dev() != node.metadata.dev() || held.ino() != node.metadata.ino() {
                return Err(fail());
            }
        } else {
            let file = parent.open_at(&node.name, 0)?;
            owned(&file, false, parent.1)?;
            let held = file.metadata()?;
            if held.dev() != node.metadata.dev()
                || held.ino() != node.metadata.ino()
                || held.len() != node.metadata.len()
                || held.mtime() != node.metadata.mtime()
                || held.mtime_nsec() != node.metadata.mtime_nsec()
                || held.ctime() != node.metadata.ctime()
                || held.ctime_nsec() != node.metadata.ctime_nsec()
            {
                return Err(fail());
            }
        }
        Ok(())
    }
    /// A failure here mechanically precedes every unlink in this removal.
    pub fn validate(&self) -> io::Result<()> {
        for (index, node) in self.nodes.iter().enumerate() {
            self.identity(index)?;
            if index >= 2 {
                if let Some(directory) = &node.directory {
                    if directory.names(usize::MAX)? != node.names {
                        return Err(fail());
                    }
                } else {
                    self.directory(node.parent).verify_payload(
                        &node.name,
                        node.metadata.len(),
                        node.digest.as_deref().ok_or_else(fail)?,
                    )?;
                }
            }
        }
        Ok(())
    }
    /// The caller durably publishes applying first. Any error from this method
    /// is uncertain; it never provides a retryable/zero-effect result.
    pub fn remove(self, path: &Path) -> io::Result<()> {
        self.remove_with_checkpoint(path, |_| Ok(()))
    }
    fn remove_with_checkpoint(
        self,
        path: &Path,
        checkpoint: impl Fn(usize) -> io::Result<()>,
    ) -> io::Result<()> {
        self.root.validate_path(path)?;
        self.validate()?;
        for index in (2..self.nodes.len()).rev() {
            self.root.validate_path(path)?;
            let mut ancestor = self.nodes[index].parent;
            while ancestor != 0 {
                self.identity(ancestor - 1)?;
                ancestor = self.nodes[ancestor - 1].parent;
            }
            self.identity(index)?;
            let node = &self.nodes[index];
            let parent = self.directory(node.parent);
            if let Some(directory) = &node.directory
                && !directory.names(usize::MAX)?.is_empty()
            {
                return Err(fail());
            }
            let name = segment(&node.name)?;
            let flags = if node.directory.is_some() {
                libc::AT_REMOVEDIR
            } else {
                0
            };
            // SAFETY: parent is a held descriptor, name is one validated segment;
            // no symlink is followed and each linked identity was just checked.
            if unsafe { libc::unlinkat(parent.0.as_raw_fd(), name.as_ptr(), flags) } != 0 {
                return Err(io::Error::last_os_error());
            }
            parent.0.sync_all()?;
            checkpoint(index)?;
        }
        self.root.validate_path(path)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        fs,
        os::unix::fs::{DirBuilderExt, PermissionsExt, symlink},
        path::PathBuf,
    };
    struct Fixture {
        root: PathBuf,
    }
    impl Fixture {
        fn new() -> Self {
            let root = std::env::temp_dir().canonicalize().unwrap().join(format!(
                "session-removal-{:032x}",
                u128::from_ne_bytes(crate::random_bytes::<16>().unwrap())
            ));
            fs::DirBuilder::new()
                .recursive(true)
                .mode(0o700)
                .create(root.join("2026/09/session-target/nested"))
                .unwrap();
            fs::DirBuilder::new()
                .mode(0o700)
                .create(root.join("2026/09/session-neighbor"))
                .unwrap();
            for (name, bytes) in [("a", b"abc".as_slice()), ("nested/b", b"def".as_slice())] {
                let path = root.join("2026/09/session-target").join(name);
                fs::write(&path, bytes).unwrap();
                fs::set_permissions(path, fs::Permissions::from_mode(0o600)).unwrap();
            }
            Self { root }
        }
        fn path(&self, name: &str) -> PathBuf {
            self.root.join("2026/09/session-target").join(name)
        }
        fn prepared(&self) -> io::Result<PreparedSessionRemoval> {
            HostDirectory::open_session_tree(&self.root)?.prepare_session_removal(&[
                "2026".into(),
                "09".into(),
                "session-target".into(),
            ])
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.root);
        }
    }
    #[test]
    fn removes_only_the_inspected_session_and_preserves_calendar_directories() {
        let fixture = Fixture::new();
        let prepared = fixture.prepared().unwrap();
        assert_eq!(prepared.byte_count(), 6);
        prepared.remove(&fixture.root).unwrap();
        assert!(!fixture.path("").exists());
        assert!(fixture.root.join("2026/09/session-neighbor").exists());
    }
    #[test]
    fn symlink_hardlink_and_public_write_are_rejected_before_removal() {
        for kind in ["symlink", "hardlink", "permissions"] {
            let fixture = Fixture::new();
            match kind {
                "symlink" => symlink(fixture.path("a"), fixture.path("unsafe")).unwrap(),
                "hardlink" => fs::hard_link(fixture.path("a"), fixture.path("unsafe")).unwrap(),
                _ => fs::set_permissions(fixture.path("a"), fs::Permissions::from_mode(0o666))
                    .unwrap(),
            }
            assert!(fixture.prepared().is_err(), "{kind}");
            assert_eq!(fs::read(fixture.path("a")).unwrap(), b"abc");
        }
    }
    #[test]
    fn changing_membership_bytes_or_directory_identity_invalidates_the_prepared_tree() {
        for kind in ["bytes", "newFile", "directory", "ancestor"] {
            let fixture = Fixture::new();
            let prepared = fixture.prepared().unwrap();
            match kind {
                "bytes" => fs::write(fixture.path("a"), b"XYZ").unwrap(),
                "newFile" => fs::write(fixture.path("late"), b"retain").unwrap(),
                "directory" => {
                    fs::rename(fixture.path("nested"), fixture.root.join("saved")).unwrap();
                    fs::DirBuilder::new()
                        .mode(0o700)
                        .create(fixture.path("nested"))
                        .unwrap();
                }
                _ => {
                    fs::rename(fixture.root.join("2026/09"), fixture.root.join("saved")).unwrap();
                    fs::DirBuilder::new()
                        .mode(0o700)
                        .create(fixture.root.join("2026/09"))
                        .unwrap();
                }
            }
            assert!(prepared.validate().is_err(), "{kind}");
            assert!(prepared.remove(&fixture.root).is_err(), "{kind}");
            if kind == "ancestor" {
                assert_eq!(
                    fs::read(fixture.root.join("saved/session-target/a")).unwrap(),
                    b"abc"
                );
            } else {
                assert!(fixture.path("a").exists());
            }
        }
    }
    #[test]
    fn fault_after_first_unlink_returns_uncertainty_without_following_new_content() {
        let fixture = Fixture::new();
        let prepared = fixture.prepared().unwrap();
        let error = prepared
            .remove_with_checkpoint(&fixture.root, |_| {
                Err(io::Error::other("injected post-unlink failure"))
            })
            .unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::Other);
        assert!(!fixture.path("nested/b").exists());
        assert!(fixture.path("a").exists());
        assert!(fixture.root.join("2026/09/session-neighbor").exists());
    }
}
