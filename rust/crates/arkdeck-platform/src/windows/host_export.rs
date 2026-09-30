//! Writes exclusively into a newly created export staging directory, on NTFS
//! (the Unix `host_export.rs`). Cleanup is limited to entries this instance
//! created and whose file id still matches, and removes each through a
//! handle whose identity was checked. It cannot open an existing Session as
//! a deletion target.
use super::super::host_fs::{
    self, DIRECTORY, Descriptor, INSPECT, Kind, Stat, WRITE, fail, segment,
};
use super::{HostDirectory, HostDirectoryFacts, Ownership, hash_to_end, owned};
use std::collections::{BTreeMap, BTreeSet};
use std::fs::File;
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use windows_sys::Wdk::Storage::FileSystem::{FILE_CREATE, FILE_OPEN};
use windows_sys::Win32::Storage::FileSystem::DELETE;

#[derive(Debug)]
pub struct HostExportCapacity {
    pub facts: HostDirectoryFacts,
    pub total_bytes: u64,
    pub available_bytes: u64,
    pub read_only: bool,
}
impl HostDirectory {
    pub fn export_capacity(&self) -> io::Result<HostExportCapacity> {
        owned(&self.0, true, self.1)?;
        let (total_bytes, available_bytes, read_only) = host_fs::volume_capacity(&self.0)?;
        Ok(HostExportCapacity {
            facts: self.export_facts()?,
            total_bytes,
            available_bytes,
            read_only,
        })
    }
}
#[derive(Debug)]
pub enum ExportPublishError {
    BeforePublication(io::Error),
    OutcomeUnknown(io::Error),
}
struct StagedFile {
    metadata: Stat,
    size: u64,
    digest: String,
}
/// A process-local bounded host export claim and staging directory. It has no
/// path-based reopen constructor and cannot adopt an existing directory.
pub struct ExportStaging {
    parent: HostDirectory,
    parent_path: PathBuf,
    facts: HostDirectoryFacts,
    root: HostDirectory,
    root_metadata: Stat,
    staging_name: String,
    destination_name: String,
    remaining: u64,
    files: BTreeMap<String, StagedFile>,
    directories: BTreeMap<String, Stat>,
    published: bool,
    committed: bool,
    poisoned: bool,
}
fn capacity_budget(snapshot: &HostExportCapacity, maximum: u64) -> io::Result<()> {
    let required = maximum.checked_add(128 * 1024).ok_or_else(fail)?;
    if snapshot.read_only || required > snapshot.available_bytes {
        return Err(io::Error::new(
            io::ErrorKind::StorageFull,
            "export destination lacks bounded headroom",
        ));
    }
    Ok(())
}
fn parts(path: &str) -> io::Result<Vec<&str>> {
    let parts: Vec<_> = path.split('/').collect();
    if parts.is_empty() || path.len() > 1024 {
        return Err(fail());
    }
    for part in &parts {
        segment(part)?;
    }
    Ok(parts)
}
fn same(metadata: &Stat, link: &Stat) -> bool {
    metadata.same_file(link)
}
impl ExportStaging {
    pub fn create(
        parent_path: &Path,
        destination_name: &str,
        expected: &HostDirectoryFacts,
        maximum_growth: u64,
    ) -> io::Result<Self> {
        segment(destination_name)?;
        let parent = HostDirectory::open_export_parent(parent_path)?;
        parent.validate_path(parent_path)?;
        let capacity = parent.export_capacity()?;
        if &capacity.facts != expected {
            return Err(fail());
        }
        capacity_budget(&capacity, maximum_growth)?;
        match parent.stat_at(destination_name) {
            Err(e) if e.kind() == io::ErrorKind::NotFound => (),
            Err(e) => return Err(e),
            Ok(_) => return Err(io::Error::from(io::ErrorKind::AlreadyExists)),
        }
        let random = u128::from_ne_bytes(crate::random_bytes::<16>()?);
        let staging_name = format!(".arkdeck-export-{random:032x}.tmp");
        make_private_directory(&parent.0, &staging_name)?;
        let file = open_directory(&parent.0, &staging_name)?;
        owned(&file, true, Ownership::Private)?;
        let metadata = Stat::of(&file)?;
        if !same(&metadata, &parent.stat_at(&staging_name)?) || metadata.volume != expected.device {
            return Err(fail());
        }
        let stage = Self {
            parent,
            parent_path: parent_path.to_owned(),
            facts: capacity.facts,
            root: HostDirectory(file, Ownership::Private),
            root_metadata: metadata,
            staging_name,
            destination_name: destination_name.to_owned(),
            remaining: maximum_growth,
            files: BTreeMap::new(),
            directories: BTreeMap::new(),
            published: false,
            committed: false,
            poisoned: false,
        };
        host_fs::flush_directory(&stage.root.0)?;
        host_fs::flush_directory(&stage.parent.0)?;
        stage.validate_binding()?;
        Ok(stage)
    }
    pub fn remaining_growth(&self) -> u64 {
        self.remaining
    }
    fn validate_binding(&self) -> io::Result<()> {
        self.parent.validate_path(&self.parent_path)?;
        if self.parent.export_facts()? != self.facts
            || self.root.export_facts()?.volume_identity != self.facts.volume_identity
        {
            return Err(fail());
        }
        owned(&self.root.0, true, Ownership::Private)?;
        let name = if self.published {
            &self.destination_name
        } else {
            &self.staging_name
        };
        if !same(&self.root_metadata, &self.parent.stat_at(name)?) {
            return Err(fail());
        }
        Ok(())
    }
    fn root_clone(&self) -> io::Result<HostDirectory> {
        Ok(HostDirectory(self.root.0.try_clone()?, Ownership::Private))
    }
    fn open_directory(&self, path: &[&str]) -> io::Result<HostDirectory> {
        let mut directory = self.root_clone()?;
        let mut prefix = String::new();
        for component in path {
            if !prefix.is_empty() {
                prefix.push('/');
            }
            prefix.push_str(component);
            let expected = self.directories.get(&prefix).ok_or_else(fail)?;
            let next = directory.child(component)?;
            let opened = Stat::of(&next.0)?;
            if !opened.same_file(expected) || !same(expected, &directory.stat_at(component)?) {
                return Err(fail());
            }
            directory = next;
        }
        if directory.export_facts()?.volume_identity != self.facts.volume_identity {
            return Err(fail());
        }
        Ok(directory)
    }
    fn ensure_parent(&mut self, path: &[&str]) -> io::Result<HostDirectory> {
        let mut directory = self.root_clone()?;
        let mut prefix = String::new();
        for component in path {
            if !prefix.is_empty() {
                prefix.push('/');
            }
            prefix.push_str(component);
            if let Some(expected) = self.directories.get(&prefix) {
                if !same(expected, &directory.stat_at(component)?) {
                    return Err(fail());
                }
            } else {
                // This instance only accepts newly created ancestry. An entry
                // injected by another actor is never adopted or cleaned up.
                make_private_directory(&directory.0, component)?;
                let child = directory.child(component)?;
                self.directories.insert(prefix.clone(), Stat::of(&child.0)?);
                host_fs::flush_directory(&directory.0)?;
            }
            let next = directory.child(component)?;
            let expected = &self.directories[&prefix];
            if !Stat::of(&next.0)?.same_file(expected) {
                return Err(fail());
            }
            directory = next;
        }
        if directory.export_facts()?.volume_identity != self.facts.volume_identity {
            return Err(fail());
        }
        Ok(directory)
    }
    fn begin_file(
        &mut self,
        path: &str,
        size: u64,
        digest: String,
    ) -> io::Result<(File, HostDirectory)> {
        if self.published || self.poisoned || self.files.contains_key(path) || size > self.remaining
        {
            return Err(fail());
        }
        self.validate_binding()?;
        let components = parts(path)?;
        let parent = self.ensure_parent(&components[..components.len() - 1])?;
        let file = host_fs::open_relative(
            &parent.0,
            &segment(components[components.len() - 1])?,
            WRITE,
            FILE_CREATE,
            Kind::NonDirectory,
            Some(&Descriptor::private(false)?),
        )?;
        owned(&file, false, Ownership::Private)?;
        let metadata = Stat::of(&file)?;
        if metadata.volume != self.root_metadata.volume {
            return Err(fail());
        }
        self.files.insert(
            path.to_owned(),
            StagedFile {
                metadata,
                size,
                digest,
            },
        );
        self.remaining -= size;
        // A failed write/copy must never be made publishable by another call.
        self.poisoned = true;
        Ok((file, parent))
    }
    fn finish_file(&mut self, file: &File, parent: &HostDirectory) -> io::Result<()> {
        host_fs::flush(file)?;
        host_fs::flush_directory(&parent.0)?;
        self.validate_binding()?;
        self.poisoned = false;
        Ok(())
    }
    pub fn write_bytes(&mut self, path: &str, bytes: &[u8]) -> io::Result<()> {
        use sha2::{Digest, Sha256};
        let (mut file, parent) = self.begin_file(
            path,
            bytes.len() as u64,
            format!("{:x}", Sha256::digest(bytes)),
        )?;
        file.write_all(bytes)?;
        self.finish_file(&file, &parent)
    }
    /// Stream an identity-free Artifact with fixed memory from a retained,
    /// owned Session directory. Before success, check complete size/digest,
    /// source file id/link/times, and output durability. No source writes.
    pub fn copy_verified(
        &mut self,
        source: &HostDirectory,
        source_name: &str,
        output_path: &str,
        expected_size: u64,
        expected_digest: &str,
    ) -> io::Result<()> {
        use sha2::{Digest, Sha256};
        if !matches!(source.1, Ownership::SessionTree { .. })
            || expected_digest.len() != 64
            || !expected_digest
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        {
            return Err(fail());
        }
        let input = source.open_at(source_name)?;
        owned(&input, false, source.1)?;
        let before = Stat::of(&input)?;
        if before.size != expected_size || !same(&before, &source.stat_at(source_name)?) {
            return Err(fail());
        }
        let (mut output, parent) =
            self.begin_file(output_path, expected_size, expected_digest.to_owned())?;
        let mut digest = Sha256::new();
        let total = hash_to_end(&input, |chunk, total| {
            if total > expected_size {
                return Err(fail());
            }
            output.write_all(chunk)?;
            digest.update(chunk);
            Ok(())
        })?;
        let after = Stat::of(&input)?;
        if total != expected_size
            || format!("{:x}", digest.finalize()) != expected_digest
            || !before.same_content(&after)
            || !same(&before, &source.stat_at(source_name)?)
        {
            return Err(fail());
        }
        self.finish_file(&output, &parent)
    }
    fn validate_files(&self) -> io::Result<()> {
        let mut expected = BTreeSet::new();
        for (path, file) in &self.files {
            let components = parts(path)?;
            let parent = self.open_directory(&components[..components.len() - 1])?;
            let name = components[components.len() - 1];
            if !same(&file.metadata, &parent.stat_at(name)?) {
                return Err(fail());
            }
            parent.verify_payload(name, file.size, &file.digest)?;
            expected.insert(path.clone());
        }
        // Verify all created ancestry as well, including empty directories.
        for (path, metadata) in &self.directories {
            let components = parts(path)?;
            let parent = self.open_directory(&components[..components.len() - 1])?;
            if !same(metadata, &parent.stat_at(components[components.len() - 1])?) {
                return Err(fail());
            }
        }
        let mut pending = vec![(String::new(), self.root_clone()?)];
        while let Some((prefix, directory)) = pending.pop() {
            for name in directory.names(self.files.len() + self.directories.len() + 1)? {
                let path = if prefix.is_empty() {
                    name.clone()
                } else {
                    format!("{prefix}/{name}")
                };
                if self.directories.contains_key(&path) {
                    pending.push((path, directory.child(&name)?));
                } else if !expected.remove(&path) {
                    return Err(fail());
                }
            }
        }
        if !expected.is_empty() {
            return Err(fail());
        }
        Ok(())
    }
    pub fn publish(mut self) -> Result<PathBuf, ExportPublishError> {
        if self.poisoned {
            return Err(ExportPublishError::BeforePublication(fail()));
        }
        self.validate_binding()
            .and_then(|_| self.validate_files())
            .map_err(ExportPublishError::BeforePublication)?;
        let (source, dest) = segment(&self.staging_name)
            .and_then(|source| Ok((source, segment(&self.destination_name)?)))
            .map_err(ExportPublishError::BeforePublication)?;
        // The rename needs a handle with delete access to the very directory
        // that was staged; it is checked to be the staged one.
        let staged = host_fs::open_relative(
            &self.parent.0,
            &source,
            INSPECT | DELETE,
            FILE_OPEN,
            Kind::Directory,
            None,
        )
        .and_then(|staged| {
            if Stat::of(&staged)?.same_file(&self.root_metadata) {
                Ok(staged)
            } else {
                Err(fail())
            }
        })
        .map_err(ExportPublishError::BeforePublication)?;
        // Never replace an existing destination. The caller must durably mark
        // applying before invoking this method; errors from the rename onward
        // cannot authorize replay of the export tuple.
        host_fs::rename(&staged, &self.parent.0, &dest, false)
            .map_err(ExportPublishError::OutcomeUnknown)?;
        drop(staged);
        self.published = true;
        self.validate_binding()
            .and_then(|_| self.validate_files())
            .and_then(|_| host_fs::flush_directory(&self.parent.0))
            .and_then(|_| self.validate_binding())
            .map_err(ExportPublishError::OutcomeUnknown)?;
        self.committed = true;
        Ok(self.parent_path.join(&self.destination_name))
    }
    /// Only remove exact files recorded by this newly created staging
    /// instance. Unknown/replaced content causes refusal, never tree deletion.
    pub fn cleanup(&mut self) -> io::Result<()> {
        if self.committed {
            return Err(fail());
        }
        self.validate_binding()?;
        for (path, file) in &self.files {
            let components = parts(path)?;
            let parent = self.open_directory(&components[..components.len() - 1])?;
            remove_exact(
                &parent.0,
                components[components.len() - 1],
                &file.metadata,
                Kind::NonDirectory,
            )?;
            host_fs::flush_directory(&parent.0)?;
        }
        self.files.clear();
        let mut paths: Vec<_> = self.directories.keys().cloned().collect();
        paths.sort_by_key(|path| std::cmp::Reverse(path.split('/').count()));
        for path in paths {
            let components = parts(&path)?;
            let parent = self.open_directory(&components[..components.len() - 1])?;
            remove_exact(
                &parent.0,
                components[components.len() - 1],
                &self.directories[&path],
                Kind::Directory,
            )?;
            self.directories.remove(&path);
            host_fs::flush_directory(&parent.0)?;
        }
        self.validate_binding()?;
        let name = if self.published {
            &self.destination_name
        } else {
            &self.staging_name
        };
        remove_exact(&self.parent.0, name, &self.root_metadata, Kind::Directory)?;
        host_fs::flush_directory(&self.parent.0)?;
        self.committed = true; // Closed; Drop has nothing left to reclaim.
        Ok(())
    }
}
impl Drop for ExportStaging {
    fn drop(&mut self) {
        if !self.committed {
            let _ = self.cleanup();
        }
    }
}

/// `mkdirat(parent, name, 0700)`: a new owner-only directory; an existing
/// entry is refused, never adopted.
fn make_private_directory(parent: &File, name: &str) -> io::Result<()> {
    host_fs::open_relative(
        parent,
        &segment(name)?,
        DIRECTORY,
        FILE_CREATE,
        Kind::Directory,
        Some(&Descriptor::private(true)?),
    )
    .map(drop)
}

/// A staged directory held with the right to add entries and flush them.
fn open_directory(parent: &File, name: &str) -> io::Result<File> {
    host_fs::open_relative(
        parent,
        &segment(name)?,
        host_fs::DIRECTORY_WRITE,
        FILE_OPEN,
        Kind::Directory,
        None,
    )
}

/// `unlinkat` of `name` only while it is still exactly `expected`: the check
/// and the removal are made on one handle.
fn remove_exact(parent: &File, name: &str, expected: &Stat, kind: Kind) -> io::Result<()> {
    let entry = host_fs::open_relative(
        parent,
        &segment(name)?,
        INSPECT | DELETE,
        FILE_OPEN,
        kind,
        None,
    )?;
    if !Stat::of(&entry)?.same_file(expected) {
        return Err(fail());
    }
    host_fs::delete(&entry)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn capacity_admission_counts_both_headrooms_and_refuses_overflow_or_readonly() {
        let mut snapshot = HostExportCapacity {
            facts: HostDirectoryFacts {
                device: 1,
                inode: 2,
                volume_identity: "fixture".into(),
            },
            total_bytes: 1000000,
            available_bytes: 128 * 1024 + 1,
            read_only: false,
        };
        assert!(capacity_budget(&snapshot, 1).is_ok());
        assert!(capacity_budget(&snapshot, 2).is_err());
        assert!(capacity_budget(&snapshot, u64::MAX).is_err());
        snapshot.read_only = true;
        assert!(capacity_budget(&snapshot, 0).is_err());
    }

    #[test]
    fn a_session_tree_exports_into_a_fresh_directory_and_never_adopts_or_replaces() {
        let nonce = u128::from_ne_bytes(crate::random_bytes::<16>().unwrap());
        let root = std::env::temp_dir()
            .canonicalize()
            .unwrap()
            .join(format!("session-export-{nonce:032x}"));
        let private = HostDirectory::open_or_create_private(&root).unwrap();
        let root = PathBuf::from(
            root.canonicalize()
                .unwrap()
                .to_str()
                .and_then(|path| path.strip_prefix(r"\\?\"))
                .unwrap(),
        );
        let session = private.create_private_child("session").unwrap();
        session
            .create_document("payload", b"session bytes")
            .unwrap();
        let session = HostDirectory::open_session_tree(&root.join("session")).unwrap();
        private.create_private_child("out").unwrap();
        let out = root.join("out");
        let facts = HostDirectory::open_export_parent(&out)
            .unwrap()
            .export_facts()
            .unwrap();
        let capacity = HostDirectory::open_export_parent(&out)
            .unwrap()
            .export_capacity()
            .unwrap();
        assert!(capacity.total_bytes >= capacity.available_bytes && capacity.available_bytes > 0);
        let actual = {
            use sha2::{Digest, Sha256};
            format!("{:x}", Sha256::digest(b"session bytes"))
        };
        let mut stage = ExportStaging::create(&out, "exported", &facts, 1024).unwrap();
        stage.write_bytes("manifest.json", b"{}").unwrap();
        // A wrong digest is refused and poisons the stage's publication.
        let mut refused = ExportStaging::create(&out, "refused", &facts, 1024).unwrap();
        assert!(
            refused
                .copy_verified(&session, "payload", "payload", 13, &"0".repeat(64))
                .is_err()
        );
        assert!(matches!(
            refused.publish(),
            Err(ExportPublishError::BeforePublication(_))
        ));
        stage
            .copy_verified(&session, "payload", "artifacts/payload", 13, &actual)
            .unwrap();
        let published = stage.publish().unwrap();
        assert_eq!(published, out.join("exported"));
        assert_eq!(
            std::fs::read(out.join("exported/artifacts/payload")).unwrap(),
            b"session bytes"
        );
        assert_eq!(
            std::fs::read(out.join("exported/manifest.json")).unwrap(),
            b"{}"
        );
        // An existing destination is refused before anything is staged.
        assert!(ExportStaging::create(&out, "exported", &facts, 1024).is_err());
        // A dropped, unpublished stage removes exactly what it created.
        let mut stage = ExportStaging::create(&out, "other", &facts, 1024).unwrap();
        stage.write_bytes("a/b/c", b"x").unwrap();
        drop(stage);
        let mut names: Vec<_> = std::fs::read_dir(&out)
            .unwrap()
            .map(|entry| entry.unwrap().file_name().into_string().unwrap())
            .collect();
        names.sort();
        assert_eq!(names, ["exported"]);
        drop((private, session));
        std::fs::remove_dir_all(root).unwrap();
    }
}
