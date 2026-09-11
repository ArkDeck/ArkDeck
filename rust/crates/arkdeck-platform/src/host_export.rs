//! Writes exclusively into a newly created export staging directory. Cleanup
//! is limited to entries this instance created and whose inode still matches.
//! It cannot open an existing Session as a deletion target.
use super::*;
use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;

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
        let mut status = std::mem::MaybeUninit::<libc::statfs>::uninit();
        // SAFETY: a valid held directory descriptor and writable statfs storage.
        if unsafe { libc::fstatfs(self.0.as_raw_fd(), status.as_mut_ptr()) } != 0 {
            return Err(io::Error::last_os_error());
        }
        let status = unsafe { status.assume_init() };
        let block = u64::from(status.f_bsize);
        Ok(HostExportCapacity {
            facts: self.export_facts()?,
            total_bytes: status.f_blocks.checked_mul(block).ok_or_else(fail)?,
            available_bytes: status.f_bavail.checked_mul(block).ok_or_else(fail)?,
            read_only: status.f_flags & libc::MNT_RDONLY as u32 != 0,
        })
    }
}
#[derive(Debug)]
pub enum ExportPublishError {
    BeforePublication(io::Error),
    OutcomeUnknown(io::Error),
}
struct StagedFile {
    metadata: std::fs::Metadata,
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
    root_metadata: std::fs::Metadata,
    staging_name: String,
    destination_name: String,
    remaining: u64,
    files: BTreeMap<String, StagedFile>,
    directories: BTreeMap<String, std::fs::Metadata>,
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
fn same(metadata: &std::fs::Metadata, link: &libc::stat) -> bool {
    metadata.dev() == link.st_dev as u64 && metadata.ino() == link.st_ino
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
        let name = segment(&staging_name)?;
        if unsafe { libc::mkdirat(parent.0.as_raw_fd(), name.as_ptr(), 0o700) } != 0 {
            return Err(io::Error::last_os_error());
        }
        let file = parent.open_at(&staging_name, libc::O_DIRECTORY)?;
        owned(&file, true, Ownership::Private)?;
        let metadata = file.metadata()?;
        if !same(&metadata, &parent.stat_at(&staging_name)?)
            || metadata.dev() as u32 as u64 != expected.device
        {
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
        stage.root.0.sync_all()?;
        stage.parent.0.sync_all()?;
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
    fn open_directory(&self, path: &[&str]) -> io::Result<HostDirectory> {
        let mut directory = HostDirectory(self.root.0.try_clone()?, Ownership::Private);
        let mut prefix = String::new();
        for component in path {
            if !prefix.is_empty() {
                prefix.push('/');
            }
            prefix.push_str(component);
            let expected = self.directories.get(&prefix).ok_or_else(fail)?;
            let next = directory.child(component)?;
            let opened = next.0.metadata()?;
            if opened.dev() != expected.dev()
                || opened.ino() != expected.ino()
                || !same(expected, &directory.stat_at(component)?)
            {
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
        let mut directory = HostDirectory(self.root.0.try_clone()?, Ownership::Private);
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
                let name = segment(component)?;
                // This instance only accepts newly created ancestry. An entry
                // injected by another actor is never adopted or cleaned up.
                if unsafe { libc::mkdirat(directory.0.as_raw_fd(), name.as_ptr(), 0o700) } != 0 {
                    return Err(io::Error::last_os_error());
                }
                let child = directory.child(component)?;
                self.directories.insert(prefix.clone(), child.0.metadata()?);
                directory.0.sync_all()?;
            }
            let next = directory.child(component)?;
            let expected = &self.directories[&prefix];
            let opened = next.0.metadata()?;
            if opened.dev() != expected.dev() || opened.ino() != expected.ino() {
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
        let name = segment(components[components.len() - 1])?;
        let fd = unsafe {
            libc::openat(
                parent.0.as_raw_fd(),
                name.as_ptr(),
                libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL | libc::O_NOFOLLOW | libc::O_CLOEXEC,
                0o600,
            )
        };
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        let file = unsafe { File::from_raw_fd(fd) };
        owned(&file, false, Ownership::Private)?;
        let metadata = file.metadata()?;
        if metadata.dev() != self.root_metadata.dev() {
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
        file.sync_all()?;
        parent.0.sync_all()?;
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
    /// source inode/link/timestamps, and output durability. No source writes.
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
        let mut input = source.open_at(source_name, 0)?;
        owned(&input, false, source.1)?;
        let before = input.metadata()?;
        if before.len() != expected_size || !same(&before, &source.stat_at(source_name)?) {
            return Err(fail());
        }
        let (mut output, parent) =
            self.begin_file(output_path, expected_size, expected_digest.to_owned())?;
        let mut digest = Sha256::new();
        let mut total = 0_u64;
        let mut buffer = [0_u8; 64 * 1024];
        loop {
            let count = match input.read(&mut buffer) {
                Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
                result => result?,
            };
            if count == 0 {
                break;
            }
            total = total
                .checked_add(count as u64)
                .filter(|n| *n <= expected_size)
                .ok_or_else(fail)?;
            output.write_all(&buffer[..count])?;
            digest.update(&buffer[..count]);
        }
        let after = input.metadata()?;
        if total != expected_size
            || format!("{:x}", digest.finalize()) != expected_digest
            || before.len() != after.len()
            || before.mtime() != after.mtime()
            || before.mtime_nsec() != after.mtime_nsec()
            || before.ctime() != after.ctime()
            || before.ctime_nsec() != after.ctime_nsec()
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
        let mut pending = vec![(
            String::new(),
            HostDirectory(self.root.0.try_clone()?, Ownership::Private),
        )];
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
        let source = segment(&self.staging_name).map_err(ExportPublishError::BeforePublication)?;
        let dest =
            segment(&self.destination_name).map_err(ExportPublishError::BeforePublication)?;
        // Never replace an existing destination. The caller must durably mark
        // applying before invoking this method; errors from the rename onward
        // cannot authorize replay of the export tuple.
        if unsafe {
            libc::renameatx_np(
                self.parent.0.as_raw_fd(),
                source.as_ptr(),
                self.parent.0.as_raw_fd(),
                dest.as_ptr(),
                libc::RENAME_EXCL,
            )
        } != 0
        {
            return Err(ExportPublishError::OutcomeUnknown(
                io::Error::last_os_error(),
            ));
        }
        self.published = true;
        self.validate_binding()
            .and_then(|_| self.validate_files())
            .and_then(|_| self.parent.0.sync_all())
            .and_then(|_| self.validate_binding())
            .map_err(ExportPublishError::OutcomeUnknown)?;
        self.committed = true;
        Ok(self.parent_path.join(&self.destination_name))
    }
    /// Only remove exact inodes recorded by this newly created staging
    /// instance. Unknown/replaced content causes refusal, never tree deletion.
    pub fn cleanup(&mut self) -> io::Result<()> {
        if self.committed {
            return Err(fail());
        }
        self.validate_binding()?;
        for (path, file) in &self.files {
            let components = parts(path)?;
            let parent = self.open_directory(&components[..components.len() - 1])?;
            let name = components[components.len() - 1];
            if !same(&file.metadata, &parent.stat_at(name)?) {
                return Err(fail());
            }
            let name = segment(name)?;
            if unsafe { libc::unlinkat(parent.0.as_raw_fd(), name.as_ptr(), 0) } != 0 {
                return Err(io::Error::last_os_error());
            }
            parent.0.sync_all()?;
        }
        self.files.clear();
        let mut paths: Vec<_> = self.directories.keys().cloned().collect();
        paths.sort_by_key(|path| std::cmp::Reverse(path.split('/').count()));
        for path in paths {
            let components = parts(&path)?;
            let parent = self.open_directory(&components[..components.len() - 1])?;
            let name = components[components.len() - 1];
            if !same(&self.directories[&path], &parent.stat_at(name)?) {
                return Err(fail());
            }
            let name = segment(name)?;
            if unsafe { libc::unlinkat(parent.0.as_raw_fd(), name.as_ptr(), libc::AT_REMOVEDIR) }
                != 0
            {
                return Err(io::Error::last_os_error());
            }
            self.directories.remove(&path);
            parent.0.sync_all()?;
        }
        self.validate_binding()?;
        let name = segment(if self.published {
            &self.destination_name
        } else {
            &self.staging_name
        })?;
        if unsafe { libc::unlinkat(self.parent.0.as_raw_fd(), name.as_ptr(), libc::AT_REMOVEDIR) }
            != 0
        {
            return Err(io::Error::last_os_error());
        }
        self.parent.0.sync_all()?;
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
}
