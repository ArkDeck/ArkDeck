//! Bounded handle-relative quarantine/removal for Runtime-owned Trace data on
//! NTFS (TASK-XPA-021): the Windows spelling of `host_trace_removal.rs`. The
//! caller must hold the existing key/entry/owner leases and identity proof.
//! Every entry is opened relative to its held parent without following a
//! reparse point; the quarantine is a POSIX rename that never replaces an
//! entry, and each removal deletes through a handle whose identity was just
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
    is_directory: bool,
    /// Held while the tree is captured and checked. NTFS refuses to rename
    /// a directory while a handle is open inside it, so the quarantine lets
    /// go of the moved tree's handles and opens them again after the move,
    /// each required to be the directory captured.
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
            let stat = Stat::of(&directory.0)?;
            result.nodes.push(Node {
                parent,
                name: name.clone(),
                stat,
                is_directory: true,
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
                    if result.nodes.len() >= 4096 {
                        return Err(fail());
                    }
                    result.nodes.push(Node {
                        parent: index + 1,
                        name,
                        stat,
                        is_directory: directory.is_some(),
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
    /// Atomically hide exactly the proven directory under its same anchored
    /// parent. Retain the original owner proof if publication fails: recovery
    /// may locate this same directory inside the fixed recovery root, never
    /// adopt a replacement.
    pub fn quarantine(&mut self, path: &Path) -> io::Result<String> {
        self.root.validate_path(path)?;
        self.validate()?;
        for _ in 0..16 {
            let name = format!(
                ".arktrace-cleanup-{:032x}",
                u128::from_ne_bytes(crate::random_bytes::<16>()?)
            );
            let source = self.linked(self.leaf)?;
            for node in &mut self.nodes[self.leaf..] {
                node.directory = None;
            }
            let node = &self.nodes[self.leaf];
            let parent = self.directory(node.parent);
            let moved = host_fs::rename(&source, &parent.0, &segment(&name)?, false);
            drop(source);
            match moved {
                Ok(()) => self.nodes[self.leaf].name = name,
                Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {
                    self.reopen()?;
                    continue;
                }
                Err(error) => {
                    self.reopen()?;
                    return Err(error);
                }
            }
            host_fs::flush_directory(&self.directory(self.nodes[self.leaf].parent).0)?;
            self.reopen()?;
            self.validate()?;
            return Ok(self.nodes[..=self.leaf]
                .iter()
                .map(|n| n.name.as_str())
                .collect::<Vec<_>>()
                .join("/"));
        }
        Err(fail())
    }

    /// The moved tree's directories held again, parents first, each the
    /// directory captured.
    fn reopen(&mut self) -> io::Result<()> {
        for index in self.leaf..self.nodes.len() {
            if !self.nodes[index].is_directory {
                continue;
            }
            let node = &self.nodes[index];
            let directory = self.directory(node.parent).child(&node.name)?;
            if !Stat::of(&directory.0)?.same_file(&node.stat) {
                return Err(fail());
            }
            self.nodes[index].directory = Some(directory);
        }
        Ok(())
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
    /// The entry the node's name links now, opened for deletion without
    /// following a reparse point, and required to be the captured one.
    fn linked(&self, index: usize) -> io::Result<File> {
        let node = &self.nodes[index];
        let parent = self.directory(node.parent);
        let kind = if node.is_directory {
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
        if !linked.same_file(&node.stat) || (!node.is_directory && !linked.same_content(&node.stat))
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
            if index >= self.leaf {
                if let Some(directory) = &node.directory {
                    if directory.names(4096)? != node.names {
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
            if let Some(directory) = &node.directory
                && !directory.names(4096)?.is_empty()
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
        /// A private tree `parent/{target/{a, nested/b}, neighbor}`, every
        /// level created owner-only relative to its held parent.
        fn new() -> Self {
            let temporary = std::env::temp_dir().canonicalize().unwrap();
            let temporary = temporary.to_str().unwrap();
            let root =
                PathBuf::from(temporary.strip_prefix(r"\\?\").unwrap_or(temporary)).join(format!(
                    "trace-removal-{:032x}",
                    u128::from_ne_bytes(crate::random_bytes::<16>().unwrap())
                ));
            let top = HostDirectory::open_or_create_private(&root).unwrap();
            let parent = top.create_private_child("parent").unwrap();
            let target = parent.create_private_child("target").unwrap();
            parent.create_private_child("neighbor").unwrap();
            let nested = target.create_private_child("nested").unwrap();
            target.create_document("a", b"owned").unwrap();
            nested.create_document("b", b"owned").unwrap();
            Self { root }
        }
        fn path(&self, name: &str) -> PathBuf {
            let target = self.root.join("parent").join("target");
            if name.is_empty() {
                target
            } else {
                target.join(name)
            }
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
    fn quarantine_and_removal_preserve_original_name_replacement_and_neighbor() {
        let f = Fixture::new();
        let identity = HostDirectory::open(&f.path(""))
            .unwrap()
            .directory_identity()
            .unwrap();
        let mut prepared = f.prepared().unwrap();
        let location = prepared.quarantine(&f.root).unwrap();
        assert!(
            location.starts_with("parent/.arktrace-cleanup-"),
            "{location}"
        );
        let quarantined = f.root.join(location.replace('/', "\\"));
        assert_eq!(
            HostDirectory::open(&quarantined)
                .unwrap()
                .directory_identity()
                .unwrap(),
            identity
        );
        let parent = HostDirectory::open(&f.root.join("parent")).unwrap();
        let replacement = parent.create_private_child("target").unwrap();
        replacement
            .create_document("replacement", b"do not remove")
            .unwrap();
        prepared.remove(&f.root).unwrap();
        assert!(!quarantined.exists());
        assert_eq!(fs::read(f.path("replacement")).unwrap(), b"do not remove");
        assert!(f.root.join("parent").join("neighbor").is_dir());
    }

    #[test]
    fn unsafe_tree_or_wrong_owner_identity_refuses_before_quarantine() {
        for kind in ["junction", "hardlink", "permissions", "identity"] {
            let f = Fixture::new();
            match kind {
                "junction" => junction(&f.path("link"), &f.root.join("parent").join("neighbor")),
                "hardlink" => fs::hard_link(f.path("a"), f.path("link")).unwrap(),
                // A file anyone may read (Unix `0o644`).
                "permissions" => {
                    let granted = std::process::Command::new("icacls.exe")
                        .arg(f.path("a"))
                        .args(["/grant", "*S-1-1-0:R"])
                        .stdin(std::process::Stdio::null())
                        .stdout(std::process::Stdio::null())
                        .status()
                        .unwrap();
                    assert!(granted.success());
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

    /// Unix lets an ancestor of a prepared tree be renamed and replaced, and
    /// the quarantine then refuses; NTFS refuses the rename itself while the
    /// prepared removal holds handles inside it, so the tree stays where its
    /// evidence says it is.
    #[test]
    fn a_prepared_tree_s_ancestor_cannot_be_moved_away() {
        let f = Fixture::new();
        let prepared = f.prepared().unwrap();
        let moved = fs::rename(f.root.join("parent"), f.root.join("retained")).unwrap_err();
        assert_eq!(moved.kind(), io::ErrorKind::PermissionDenied);
        prepared.validate().unwrap();
        drop(prepared);
    }

    #[test]
    fn changed_content_or_membership_refuses_before_quarantine() {
        for kind in ["bytes", "membership"] {
            let f = Fixture::new();
            let mut prepared = f.prepared().unwrap();
            match kind {
                "bytes" => {
                    let target = HostDirectory::open(&f.path("")).unwrap();
                    target.replace_document("a", b"other", 1024).unwrap();
                }
                _ => {
                    let target = HostDirectory::open(&f.path("")).unwrap();
                    target.create_document("late", b"retain").unwrap();
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
        let quarantined = f.root.join(location.replace('/', "\\"));
        let error = prepared
            .remove_with_checkpoint(&f.root, |_| Err(io::Error::other("after unlink")))
            .unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::Other);
        assert!(!quarantined.join("nested").join("b").exists());
        assert!(quarantined.join("a").exists());
        assert!(f.root.join("parent").join("neighbor").is_dir());
    }
}
