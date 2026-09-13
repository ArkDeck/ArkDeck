//! Bounded descriptor-relative quarantine/removal for Runtime-owned Trace data.
//! The caller must hold the existing key/entry/owner leases and inode proof.
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

pub struct PreparedTraceRemoval {
    root: HostDirectory,
    nodes: Vec<Node>,
    leaf: usize,
}

impl HostDirectory {
    /// Capture a bounded, private subtree and compare its observed identity to
    /// the existing durable Trace owner evidence before any rename or unlink.
    pub fn prepare_trace_removal(
        &self,
        location: &[String],
        expected: (u64, u64),
    ) -> io::Result<PreparedTraceRemoval> {
        if !matches!(self.1, Ownership::Private) || location.is_empty() || location.len() > 8 {
            return Err(fail());
        }
        let mut result = PreparedTraceRemoval {
            root: HostDirectory(self.0.try_clone()?, self.1),
            nodes: Vec::new(),
            leaf: location.len() - 1,
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
        if result.directory(location.len()).directory_identity()? != expected {
            return Err(fail());
        }
        let mut index = result.leaf;
        while index < result.nodes.len() {
            if result.nodes[index].directory.is_some() {
                let names = result.directory(index + 1).names(4096)?;
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
                    if result.nodes.len() >= 4096 {
                        return Err(fail());
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

impl PreparedTraceRemoval {
    /// Atomically hide exactly the proven inode under its same anchored parent.
    /// Retain the original owner proof if publication fails: recovery may locate
    /// this same inode inside the fixed recovery root, never adopt a replacement.
    pub fn quarantine(&mut self, path: &Path) -> io::Result<String> {
        self.root.validate_path(path)?;
        self.validate()?;
        for _ in 0..16 {
            let name = format!(
                ".arktrace-cleanup-{:032x}",
                u128::from_ne_bytes(crate::random_bytes::<16>()?)
            );
            let node = &self.nodes[self.leaf];
            let parent = self.directory(node.parent);
            let source = segment(&node.name)?;
            let destination = segment(&name)?;
            // SAFETY: both names are single segments in the held parent; EXCL
            // prevents replacing any pre-existing entry.
            if unsafe {
                libc::renameatx_np(
                    parent.0.as_raw_fd(),
                    source.as_ptr(),
                    parent.0.as_raw_fd(),
                    destination.as_ptr(),
                    libc::RENAME_EXCL,
                )
            } != 0
            {
                let error = io::Error::last_os_error();
                if error.kind() == io::ErrorKind::AlreadyExists {
                    continue;
                }
                return Err(error);
            }
            parent.0.sync_all()?;
            self.nodes[self.leaf].name = name;
            self.validate()?;
            return Ok(self.nodes[..=self.leaf]
                .iter()
                .map(|n| n.name.as_str())
                .collect::<Vec<_>>()
                .join("/"));
        }
        Err(fail())
    }

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
            if index >= self.leaf {
                if let Some(directory) = &node.directory {
                    if directory.names(4096)? != node.names {
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
    /// The caller publishes the existing Trace owner evidence for the quarantine
    /// before removal. Any failure after quarantine remains outcome unknown.
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
        for index in (self.leaf..self.nodes.len()).rev() {
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
                && !directory.names(4096)?.is_empty()
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
            let root = PathBuf::from(format!(
                "/private/tmp/trace-removal-{:032x}",
                u128::from_ne_bytes(crate::random_bytes::<16>().unwrap())
            ));
            fs::DirBuilder::new()
                .recursive(true)
                .mode(0o700)
                .create(root.join("parent/target/nested"))
                .unwrap();
            fs::DirBuilder::new()
                .mode(0o700)
                .create(root.join("parent/neighbor"))
                .unwrap();
            for name in ["a", "nested/b"] {
                let path = root.join("parent/target").join(name);
                fs::write(&path, b"owned").unwrap();
                fs::set_permissions(path, fs::Permissions::from_mode(0o600)).unwrap();
            }
            Self { root }
        }
        fn path(&self, name: &str) -> PathBuf {
            self.root.join("parent/target").join(name)
        }
        fn prepared(&self) -> io::Result<PreparedTraceRemoval> {
            let root = HostDirectory::open(&self.root)?;
            let identity = root
                .child("parent")?
                .child("target")?
                .directory_identity()?;
            root.prepare_trace_removal(&["parent".into(), "target".into()], identity)
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.root);
        }
    }
    #[test]
    fn quarantine_and_removal_preserve_original_name_replacement_and_neighbor() {
        let f = Fixture::new();
        let identity = HostDirectory::open(&f.path(""))
            .unwrap()
            .directory_identity()
            .unwrap();
        let mut prepared = f.prepared().unwrap();
        let location = prepared.quarantine(&f.root).unwrap();
        assert_eq!(
            HostDirectory::open(&f.root.join(&location))
                .unwrap()
                .directory_identity()
                .unwrap(),
            identity
        );
        fs::DirBuilder::new()
            .mode(0o700)
            .create(f.path(""))
            .unwrap();
        fs::write(f.path("replacement"), b"do not remove").unwrap();
        prepared.remove(&f.root).unwrap();
        assert!(!f.root.join(location).exists());
        assert_eq!(fs::read(f.path("replacement")).unwrap(), b"do not remove");
        assert!(f.root.join("parent/neighbor").is_dir());
    }
    #[test]
    fn unsafe_tree_or_wrong_owner_identity_refuses_before_quarantine() {
        for kind in ["symlink", "hardlink", "permissions", "identity"] {
            let f = Fixture::new();
            match kind {
                "symlink" => symlink(f.path("a"), f.path("link")).unwrap(),
                "hardlink" => fs::hard_link(f.path("a"), f.path("link")).unwrap(),
                "permissions" => {
                    fs::set_permissions(f.path("a"), fs::Permissions::from_mode(0o666)).unwrap()
                }
                _ => (),
            }
            let result = if kind == "identity" {
                HostDirectory::open(&f.root)
                    .unwrap()
                    .prepare_trace_removal(&["parent".into(), "target".into()], (0, 0))
            } else {
                f.prepared()
            };
            assert!(result.is_err(), "{kind}");
            assert_eq!(fs::read(f.path("a")).unwrap(), b"owned");
        }
    }
    #[test]
    fn changed_content_or_ancestor_refuses_before_quarantine() {
        for kind in ["bytes", "membership", "ancestor"] {
            let f = Fixture::new();
            let mut prepared = f.prepared().unwrap();
            match kind {
                "bytes" => fs::write(f.path("a"), b"other").unwrap(),
                "membership" => fs::write(f.path("late"), b"retain").unwrap(),
                _ => {
                    fs::rename(f.root.join("parent"), f.root.join("retained")).unwrap();
                    fs::DirBuilder::new()
                        .recursive(true)
                        .mode(0o700)
                        .create(f.root.join("parent/target"))
                        .unwrap();
                }
            }
            assert!(prepared.quarantine(&f.root).is_err(), "{kind}");
            assert!(f.path("").exists());
        }
    }
    #[test]
    fn first_unlink_fault_leaves_owned_residual_and_does_not_touch_replacement() {
        let f = Fixture::new();
        let mut prepared = f.prepared().unwrap();
        let location = prepared.quarantine(&f.root).unwrap();
        let error = prepared
            .remove_with_checkpoint(&f.root, |_| Err(io::Error::other("after unlink")))
            .unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::Other);
        assert!(!f.root.join(&location).join("nested/b").exists());
        assert!(f.root.join(location).join("a").exists());
        assert!(f.root.join("parent/neighbor").is_dir());
    }
}
