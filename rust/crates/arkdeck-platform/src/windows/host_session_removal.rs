//! Sealed, handle-relative removal of a previously inspected Session tree on
//! NTFS (TASK-XPA-005): the Windows spelling of `host_session_removal.rs`.
//! Only the selected Session directory and its descendants are removed. Every
//! entry is opened relative to its held parent without following a reparse
//! point, and each removal deletes through a handle whose identity was just
//! compared with what was captured, so a replacement is never removed.
use super::host_fs::{self, Kind, Stat, fail, segment};
use super::{HostDirectory, HostEntryKind, Ownership, owned};
use std::fs::File;
use std::io;
use std::path::Path;
use windows_sys::Wdk::Storage::FileSystem::FILE_OPEN;
use windows_sys::Win32::Storage::FileSystem::{DELETE, FILE_READ_ATTRIBUTES};

struct Node {
    parent: usize,
    name: String,
    stat: Stat,
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
            let stat = Stat::of(&directory.0)?;
            result.nodes.push(Node {
                parent,
                name: name.clone(),
                stat,
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
                    let (stat, directory, digest) = match kind {
                        HostEntryKind::Directory => {
                            let directory = parent.child(&name)?;
                            (Stat::of(&directory.0)?, Some(directory), None)
                        }
                        HostEntryKind::Regular => {
                            let file = parent.open_at(&name)?;
                            owned(&file, false, parent.1)?;
                            let stat = Stat::of(&file)?;
                            let digest = parent
                                .optional_document_digest(&name, stat.size)?
                                .ok_or_else(fail)?;
                            (stat, None, Some(digest))
                        }
                        HostEntryKind::Other => return Err(fail()),
                    };
                    if directory.is_none() {
                        result.bytes = result.bytes.checked_add(stat.size).ok_or_else(fail)?;
                    }
                    result.nodes.push(Node {
                        parent: index + 1,
                        name,
                        stat,
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
    /// The entry the node's name links now, opened for deletion without
    /// following a reparse point, and required to be the captured one.
    fn linked(&self, index: usize) -> io::Result<File> {
        let node = &self.nodes[index];
        let parent = self.directory(node.parent);
        let kind = if node.directory.is_some() {
            Kind::Directory
        } else {
            Kind::NonDirectory
        };
        let entry = host_fs::open_relative(
            &parent.0,
            &segment(&node.name)?,
            DELETE | FILE_READ_ATTRIBUTES,
            FILE_OPEN,
            kind,
            None,
        )?;
        let linked = Stat::of(&entry)?;
        if !linked.same_file(&node.stat)
            || (node.directory.is_none() && !linked.same_content(&node.stat))
        {
            return Err(fail());
        }
        Ok(entry)
    }
    fn identity(&self, index: usize) -> io::Result<()> {
        let node = &self.nodes[index];
        let parent = self.directory(node.parent);
        owned(&parent.0, true, parent.1)?;
        if !parent.stat_at(&node.name)?.same_file(&node.stat) {
            return Err(fail());
        }
        if let Some(directory) = &node.directory {
            owned(&directory.0, true, directory.1)?;
            if !Stat::of(&directory.0)?.same_file(&node.stat) {
                return Err(fail());
            }
        } else {
            let file = parent.open_at(&node.name)?;
            owned(&file, false, parent.1)?;
            let held = Stat::of(&file)?;
            if !held.same_file(&node.stat) || !held.same_content(&node.stat) {
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
                        node.stat.size,
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
            if let Some(directory) = &node.directory
                && !directory.names(usize::MAX)?.is_empty()
            {
                return Err(fail());
            }
            // Deleted through the handle whose identity was just compared.
            host_fs::delete(&self.linked(index)?)?;
            host_fs::flush_directory(&self.directory(node.parent).0)?;
            checkpoint(index)?;
        }
        self.root.validate_path(path)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{fs, path::PathBuf};

    struct Fixture {
        root: PathBuf,
    }
    impl Fixture {
        /// A Sessions root `2026/09/{session-target/{a, nested/b},
        /// session-neighbor}`, every level created owner-only relative to its
        /// held parent.
        fn new() -> Self {
            let temporary = std::env::temp_dir().canonicalize().unwrap();
            let temporary = temporary.to_str().unwrap();
            let root =
                PathBuf::from(temporary.strip_prefix(r"\\?\").unwrap_or(temporary)).join(format!(
                    "session-removal-{:032x}",
                    u128::from_ne_bytes(crate::random_bytes::<16>().unwrap())
                ));
            let top = HostDirectory::open_or_create_private(&root).unwrap();
            let month = top
                .create_private_child("2026")
                .unwrap()
                .create_private_child("09")
                .unwrap();
            let target = month.create_private_child("session-target").unwrap();
            month.create_private_child("session-neighbor").unwrap();
            let nested = target.create_private_child("nested").unwrap();
            target.create_document("a", b"abc").unwrap();
            nested.create_document("b", b"def").unwrap();
            Self { root }
        }
        fn path(&self, name: &str) -> PathBuf {
            let target = self.root.join("2026").join("09").join("session-target");
            if name.is_empty() {
                target
            } else {
                target.join(name)
            }
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

    fn junction(link: &Path, target: &Path) {
        let made = std::process::Command::new("cmd.exe")
            .args(["/d", "/c", "mklink", "/J"])
            .arg(link)
            .arg(target)
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .status()
            .unwrap();
        assert!(made.success());
    }

    #[test]
    fn removes_only_the_inspected_session_and_preserves_calendar_directories() {
        let fixture = Fixture::new();
        let prepared = fixture.prepared().unwrap();
        assert_eq!(prepared.byte_count(), 6);
        prepared.remove(&fixture.root).unwrap();
        assert!(!fixture.path("").exists());
        assert!(fixture.root.join("2026/09/session-neighbor").is_dir());
    }

    #[test]
    fn junction_hardlink_and_public_write_are_rejected_before_removal() {
        for kind in ["junction", "hardlink", "permissions"] {
            let fixture = Fixture::new();
            match kind {
                "junction" => junction(
                    &fixture.path("unsafe"),
                    &fixture
                        .root
                        .join("2026")
                        .join("09")
                        .join("session-neighbor"),
                ),
                "hardlink" => fs::hard_link(fixture.path("a"), fixture.path("unsafe")).unwrap(),
                // A file anyone may write (Unix `0o666`): a Session tree admits
                // no public write.
                _ => {
                    let granted = std::process::Command::new("icacls.exe")
                        .arg(fixture.path("a"))
                        .args(["/grant", "*S-1-1-0:W"])
                        .stdin(std::process::Stdio::null())
                        .stdout(std::process::Stdio::null())
                        .status()
                        .unwrap();
                    assert!(granted.success());
                }
            }
            assert!(fixture.prepared().is_err(), "{kind}");
            assert_eq!(fs::read(fixture.path("a")).unwrap(), b"abc");
        }
    }

    #[test]
    fn changing_membership_or_bytes_invalidates_the_prepared_tree() {
        for kind in ["bytes", "newFile"] {
            let fixture = Fixture::new();
            let prepared = fixture.prepared().unwrap();
            let target = HostDirectory::open(&fixture.path("")).unwrap();
            match kind {
                "bytes" => target.replace_document("a", b"XYZ", 1024).unwrap(),
                _ => target.create_document("late", b"retain").unwrap(),
            }
            assert!(prepared.validate().is_err(), "{kind}");
            assert!(prepared.remove(&fixture.root).is_err(), "{kind}");
            assert!(fixture.path("a").exists());
        }
    }

    /// Unix lets an ancestor of a prepared tree be renamed and replaced, and
    /// the removal then refuses; NTFS refuses the rename itself while the
    /// prepared removal holds handles inside it.
    #[test]
    fn a_prepared_tree_s_ancestor_cannot_be_moved_away() {
        let fixture = Fixture::new();
        let prepared = fixture.prepared().unwrap();
        let moved = fs::rename(fixture.root.join("2026"), fixture.root.join("saved")).unwrap_err();
        assert_eq!(moved.kind(), io::ErrorKind::PermissionDenied);
        prepared.validate().unwrap();
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
        assert!(fixture.root.join("2026/09/session-neighbor").is_dir());
    }
}
