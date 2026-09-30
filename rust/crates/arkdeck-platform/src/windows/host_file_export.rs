//! One explicit Artifact file export on NTFS (the Unix `host_file_export.rs`).
//! This staging owner never reopens an old staging name, never writes the
//! source, and never removes a published file. Every open is relative to a
//! held directory handle and never follows a reparse point; the staging file
//! is created owner-only (protected DACL for the token user) with
//! `FILE_CREATE`, flushed, and published by a POSIX-semantics rename that
//! replaces nothing unless the caller asked to overwrite the exact file it
//! saw before copying.
use super::super::host_fs::{self, Access, Descriptor, Kind, Stat, WRITE, segment};
use super::{ExportPublishError, HostDirectory, Ownership, owned};
use sha2::{Digest, Sha256};
use std::fs::File;
use std::io::{self, Write};
use std::os::windows::fs::FileExt;
use std::path::{Path, PathBuf};
use windows_sys::Wdk::Storage::FileSystem::FILE_CREATE;

fn conflict() -> io::Error {
    io::Error::new(
        io::ErrorKind::AlreadyExists,
        "export destination identity changed",
    )
}
fn invalid_source() -> io::Error {
    io::Error::new(
        io::ErrorKind::InvalidData,
        "export source or staging identity changed",
    )
}
/// What `fstat` reports of one entry: its `Stat` and its owner and DACL
/// grants (the Unix owner and mode).
type Entry = (Stat, Access);

fn entry(file: &File) -> io::Result<Entry> {
    Ok((Stat::of(file)?, Access::of(file)?))
}
/// Unix `S_ISREG && st_uid == euid && st_nlink == 1`.
fn regular_owned((stat, access): &Entry) -> bool {
    stat.regular() && access.owner_is_user && stat.links == 1
}
fn file_digest(file: &File, length: u64) -> io::Result<String> {
    let mut buffer = [0u8; 64 * 1024];
    let mut offset = 0u64;
    let mut hash = Sha256::new();
    while offset < length {
        let wanted = usize::try_from((length - offset).min(buffer.len() as u64))
            .map_err(|_| invalid_source())?;
        let count = match file.seek_read(&mut buffer[..wanted], offset) {
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            result => result?,
        };
        if count == 0 {
            return Err(invalid_source());
        }
        hash.update(&buffer[..count]);
        offset += count as u64;
    }
    if Stat::of(file)?.size != length {
        return Err(invalid_source());
    }
    Ok(format!("{:x}", hash.finalize()))
}
struct Source {
    directory: HostDirectory,
    name: String,
    file: File,
    metadata: Entry,
}
impl Source {
    fn validate(&self) -> io::Result<()> {
        owned(&self.file, false, Ownership::Private)?;
        let current = entry(&self.file)?;
        let named = self
            .directory
            .inspect_at(&self.name)
            .map_err(|_| invalid_source())?;
        if self.metadata != current || current != named {
            return Err(invalid_source());
        }
        Ok(())
    }
}
/// A single owned file, distinct from Session's directory ExportStaging. Its
/// expected destination is captured before copying. Successful overwrite needs
/// that same exact identity immediately before the atomic rename.
pub struct FileExportStaging {
    parent: HostDirectory,
    parent_path: PathBuf,
    staging_name: String,
    destination_name: String,
    prior: Option<Entry>,
    output: File,
    initial: Stat,
    source: Option<Source>,
    expected_size: u64,
    expected_digest: String,
    ready: bool,
    published: bool,
}
impl FileExportStaging {
    pub fn create(parent_path: &Path, destination_name: &str, overwrite: bool) -> io::Result<Self> {
        if destination_name.len() > 255 {
            return Err(io::Error::from(io::ErrorKind::InvalidInput));
        }
        segment(destination_name).map_err(|_| io::Error::from(io::ErrorKind::InvalidInput))?;
        let parent = HostDirectory::open_export_parent(parent_path)
            .map_err(|_| io::Error::from(io::ErrorKind::InvalidInput))?;
        parent.validate_path(parent_path).map_err(|_| conflict())?;
        let prior = match parent.inspect_at(destination_name) {
            Ok(value) if regular_owned(&value) && overwrite => Some(value),
            Ok(_) => return Err(conflict()),
            Err(error) if error.kind() == io::ErrorKind::NotFound => None,
            Err(error) => return Err(error),
        };
        let random = u128::from_ne_bytes(crate::random_bytes::<16>()?);
        let staging_name = format!(".arkdeck-export-{random:032x}.part");
        // FILE_CREATE never adopts or replaces another actor's entry.
        let output = host_fs::open_relative(
            &parent.0,
            &segment(&staging_name)?,
            WRITE,
            FILE_CREATE,
            Kind::NonDirectory,
            Some(&Descriptor::private(false)?),
        )?;
        let initial = Stat::of(&output)?;
        let value = Self {
            parent,
            parent_path: parent_path.to_owned(),
            staging_name,
            destination_name: destination_name.to_owned(),
            prior,
            output,
            initial,
            source: None,
            expected_size: 0,
            expected_digest: String::new(),
            ready: false,
            published: false,
        };
        value.validate_output_binding()?;
        Ok(value)
    }
    fn current_destination(&self) -> io::Result<Option<Entry>> {
        match self.parent.inspect_at(&self.destination_name) {
            Ok(value) if regular_owned(&value) => Ok(Some(value)),
            Ok(_) => Err(conflict()),
            Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(None),
            Err(_) => Err(conflict()),
        }
    }
    fn validate_destination(&self) -> io::Result<()> {
        self.parent
            .validate_path(&self.parent_path)
            .map_err(|_| conflict())?;
        match (&self.prior, self.current_destination()?) {
            (None, None) => Ok(()),
            (Some(prior), Some(current)) if *prior == current => Ok(()),
            _ => Err(conflict()),
        }
    }
    fn validate_output_binding(&self) -> io::Result<Entry> {
        owned(&self.output, false, Ownership::Private)?;
        let held = entry(&self.output)?;
        let name = if self.published {
            &self.destination_name
        } else {
            &self.staging_name
        };
        let named = self.parent.inspect_at(name).map_err(|_| invalid_source())?;
        // Unix mode 0600: the owner alone, and it may read and write.
        if !held.0.same_file(&self.initial) || !held.1.owner_read_write() || held != named {
            return Err(invalid_source());
        }
        Ok(held)
    }
    /// Fixed-memory copy from a retained private Artifact directory. All bytes
    /// and identity checks complete before the stage becomes publishable.
    pub fn copy_verified(
        &mut self,
        source: &HostDirectory,
        name: &str,
        size: u64,
        digest: &str,
    ) -> io::Result<()> {
        if self.ready
            || self.source.is_some()
            || self.published
            || !matches!(source.1, Ownership::Private)
            || digest.len() != 64
            || !digest
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        {
            return Err(invalid_source());
        }
        self.validate_destination()?;
        let file = source.open_at(name).map_err(|_| invalid_source())?;
        owned(&file, false, Ownership::Private).map_err(|_| invalid_source())?;
        let metadata = entry(&file)?;
        if metadata.0.size != size {
            return Err(invalid_source());
        }
        self.source = Some(Source {
            directory: HostDirectory(source.0.try_clone()?, Ownership::Private),
            name: name.into(),
            file,
            metadata,
        });
        let input = self.source.as_ref().expect("retained source");
        input.validate()?;
        let mut buffer = [0u8; 64 * 1024];
        let mut offset = 0u64;
        let mut hash = Sha256::new();
        while offset < size {
            let wanted = usize::try_from((size - offset).min(buffer.len() as u64))
                .map_err(|_| invalid_source())?;
            let count = match input.file.seek_read(&mut buffer[..wanted], offset) {
                Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                result => result?,
            };
            if count == 0 {
                return Err(invalid_source());
            }
            self.output.write_all(&buffer[..count])?;
            hash.update(&buffer[..count]);
            offset += count as u64;
        }
        input.validate()?;
        if format!("{:x}", hash.finalize()) != digest {
            return Err(invalid_source());
        }
        // The owner's fullSync boundary: data and metadata through the
        // device cache.
        host_fs::flush(&self.output)?;
        let before = self.validate_output_binding()?;
        if before.0.size != size || file_digest(&self.output, size)? != digest {
            return Err(invalid_source());
        }
        let after = self.validate_output_binding()?;
        if before != after {
            return Err(invalid_source());
        }
        self.expected_size = size;
        self.expected_digest = digest.into();
        self.ready = true;
        Ok(())
    }
    /// The caller revalidates its captured index inside the publication
    /// boundary. An error after the rename never grants replay or cleanup.
    pub fn publish(
        self,
        validate_owner: impl FnOnce() -> io::Result<()>,
    ) -> Result<(PathBuf, bool), ExportPublishError> {
        self.publish_with_hooks(validate_owner, || Ok(()), || Ok(()))
    }
    fn publish_with_hooks(
        mut self,
        validate_owner: impl FnOnce() -> io::Result<()>,
        before: impl FnOnce() -> io::Result<()>,
        after: impl FnOnce() -> io::Result<()>,
    ) -> Result<(PathBuf, bool), ExportPublishError> {
        use ExportPublishError::{BeforePublication, OutcomeUnknown};
        if !self.ready {
            return Err(BeforePublication(invalid_source()));
        }
        before().map_err(BeforePublication)?;
        let input = self
            .source
            .as_ref()
            .ok_or_else(|| BeforePublication(invalid_source()))?;
        input.validate().map_err(BeforePublication)?;
        self.validate_destination().map_err(BeforePublication)?;
        let ready = self.validate_output_binding().map_err(BeforePublication)?;
        if ready.0.size != self.expected_size
            || file_digest(&self.output, self.expected_size).map_err(BeforePublication)?
                != self.expected_digest
        {
            return Err(BeforePublication(invalid_source()));
        }
        let current = self.validate_output_binding().map_err(BeforePublication)?;
        if ready != current {
            return Err(BeforePublication(invalid_source()));
        }
        input.validate().map_err(BeforePublication)?;
        validate_owner().map_err(BeforePublication)?;
        self.validate_destination().map_err(BeforePublication)?;
        let destination = segment(&self.destination_name).map_err(BeforePublication)?;
        // Without an overwrite the rename refuses an existing destination
        // (RENAME_EXCL); with one it replaces, POSIX-style, only the name
        // whose captured identity was compared just above.
        host_fs::rename(
            &self.output,
            &self.parent.0,
            &destination,
            self.prior.is_some(),
        )
        .map_err(BeforePublication)?;
        self.published = true;
        after().map_err(OutcomeUnknown)?;
        host_fs::flush_directory(&self.parent.0).map_err(OutcomeUnknown)?;
        self.parent
            .validate_path(&self.parent_path)
            .map_err(OutcomeUnknown)?;
        let published = self.validate_output_binding().map_err(OutcomeUnknown)?;
        if published.0.size != self.expected_size
            || file_digest(&self.output, self.expected_size).map_err(OutcomeUnknown)?
                != self.expected_digest
        {
            return Err(OutcomeUnknown(invalid_source()));
        }
        let current = self.validate_output_binding().map_err(OutcomeUnknown)?;
        if published != current {
            return Err(OutcomeUnknown(invalid_source()));
        }
        self.parent
            .validate_path(&self.parent_path)
            .map_err(OutcomeUnknown)?;
        Ok((
            self.parent_path.join(&self.destination_name),
            self.prior.is_some(),
        ))
    }
}
impl Drop for FileExportStaging {
    fn drop(&mut self) {
        if self.published {
            return;
        }
        // Remove only the private, exact file this invocation created, while
        // its staging name still links it. A substituted name or hard link is
        // left untouched for inspection.
        if self.validate_output_binding().is_ok() {
            let _ = host_fs::delete(&self.output);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::process::{Command, Stdio};
    use windows_sys::Win32::Storage::FileSystem::WRITE_DAC;

    struct Fixture {
        root: PathBuf,
        source: HostDirectory,
        digest: String,
    }
    impl Fixture {
        fn new(bytes: &[u8]) -> Self {
            let id = u128::from_ne_bytes(crate::random_bytes::<16>().unwrap());
            let root = std::env::temp_dir()
                .canonicalize()
                .unwrap()
                .join(format!("artifact-file-export-{id:x}"));
            let created = HostDirectory::open_or_create_private(&root).unwrap();
            let root = root.canonicalize().unwrap();
            let root = PathBuf::from(
                root.to_str()
                    .and_then(|path| path.strip_prefix(r"\\?\"))
                    .unwrap(),
            );
            let source = created.create_private_child("source").unwrap();
            created.create_private_child("output").unwrap();
            source.create_document("payload", bytes).unwrap();
            source.seal_document("payload").unwrap();
            Self {
                source,
                root,
                digest: format!("{:x}", Sha256::digest(bytes)),
            }
        }
        fn output_directory(&self) -> PathBuf {
            self.root.join("output")
        }
        fn stage(&self, overwrite: bool) -> FileExportStaging {
            let mut stage =
                FileExportStaging::create(&self.output_directory(), "result", overwrite).unwrap();
            let size = std::fs::metadata(self.root.join("source/payload"))
                .unwrap()
                .len();
            stage
                .copy_verified(&self.source, "payload", size, &self.digest)
                .unwrap();
            stage
        }
        fn output(&self) -> PathBuf {
            self.root.join("output").join("result")
        }
        fn entries(&self) -> Vec<String> {
            let mut names: Vec<_> = std::fs::read_dir(self.output_directory())
                .unwrap()
                .map(|v| v.unwrap().file_name().into_string().unwrap())
                .collect();
            names.sort();
            names
        }
        fn output_access(&self) -> Access {
            let parent = HostDirectory::open_export_parent(&self.output_directory()).unwrap();
            parent.inspect_at("result").unwrap().1
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.root);
        }
    }

    #[test]
    fn new_and_explicit_overwrite_publish_exact_bytes_without_mutating_source() {
        for bytes in [b"".as_slice(), b"artifact\0bytes", &[255u8; 65539]] {
            let fixture = Fixture::new(bytes);
            let source_before = fixture.source.inspect_at("payload").unwrap();
            let (path, overwritten) = fixture.stage(false).publish(|| Ok(())).unwrap();
            assert_eq!(path, fixture.output());
            assert!(!overwritten);
            assert_eq!(std::fs::read(&path).unwrap(), bytes);
            let access = fixture.output_access();
            assert!(access.owner_is_user && access.private() && access.owner_read_write());
            assert_eq!(fixture.entries(), ["result"]);
            assert!(
                FileExportStaging::create(&fixture.output_directory(), "result", false).is_err()
            );
            assert!(fixture.stage(true).publish(|| Ok(())).unwrap().1);
            assert_eq!(fixture.source.inspect_at("payload").unwrap(), source_before);
            assert_eq!(
                std::fs::read(fixture.root.join("source/payload")).unwrap(),
                bytes
            );
        }
    }

    #[test]
    fn unsafe_destination_links_and_parent_aliases_are_refused_before_staging() {
        let fixture = Fixture::new(b"source");
        // A junction in the destination's place, even with overwrite.
        let junction = Command::new("cmd")
            .args(["/C", "mklink", "/J"])
            .arg(fixture.output())
            .arg(fixture.root.join("source"))
            .stdout(Stdio::null())
            .status()
            .unwrap();
        assert!(junction.success());
        assert!(matches!(
            FileExportStaging::create(&fixture.output_directory(), "result", true),
            Err(e) if e.kind() == io::ErrorKind::AlreadyExists
        ));
        std::fs::remove_dir(fixture.output()).unwrap();
        // A hard link is not the owner's single-link file.
        std::fs::write(fixture.root.join("linked"), b"linked").unwrap();
        std::fs::hard_link(fixture.root.join("linked"), fixture.output()).unwrap();
        assert!(matches!(
            FileExportStaging::create(&fixture.output_directory(), "result", true),
            Err(e) if e.kind() == io::ErrorKind::AlreadyExists
        ));
        // A junction as the destination directory is not its physical path.
        let alias = Command::new("cmd")
            .args(["/C", "mklink", "/J"])
            .arg(fixture.root.join("alias"))
            .arg(fixture.output_directory())
            .stdout(Stdio::null())
            .status()
            .unwrap();
        assert!(alias.success());
        assert!(matches!(
            FileExportStaging::create(&fixture.root.join("alias"), "new", false),
            Err(e) if e.kind() == io::ErrorKind::InvalidInput
        ));
        assert_eq!(fixture.entries(), ["result"]);
        std::fs::remove_dir(fixture.root.join("alias")).unwrap();
        std::fs::remove_file(fixture.output()).unwrap();
    }

    #[test]
    fn absent_destination_competitor_and_changed_overwrite_identity_are_never_replaced() {
        for prior in [false, true] {
            let fixture = Fixture::new(b"artifact");
            if prior {
                std::fs::write(fixture.output(), b"prior").unwrap();
            }
            let stage = fixture.stage(prior);
            let result = stage.publish_with_hooks(
                || Ok(()),
                || {
                    std::fs::write(fixture.output(), b"concurrent-content")?;
                    Ok(())
                },
                || Ok(()),
            );
            assert!(
                matches!(result, Err(ExportPublishError::BeforePublication(e)) if e.kind() == io::ErrorKind::AlreadyExists)
            );
            assert_eq!(
                std::fs::read(fixture.output()).unwrap(),
                b"concurrent-content"
            );
            assert_eq!(fixture.entries(), ["result"]);
        }
    }

    #[test]
    fn source_changes_and_staging_tampering_fail_before_any_publication() {
        let fixture = Fixture::new(b"original");
        let stage = fixture.stage(false);
        let result = stage.publish_with_hooks(
            || Ok(()),
            || {
                // The seal lifted: the source's identity moved.
                let file = fixture
                    .source
                    .open_at_access("payload", host_fs::INSPECT | WRITE_DAC)
                    .unwrap();
                host_fs::set_dacl(&file, &Descriptor::private(false).unwrap()).unwrap();
                Ok(())
            },
            || Ok(()),
        );
        assert!(matches!(
            result,
            Err(ExportPublishError::BeforePublication(_))
        ));
        assert!(fixture.entries().is_empty());
        let fixture = Fixture::new(b"original");
        let stage = fixture.stage(false);
        let name = stage.staging_name.clone();
        let result = stage.publish_with_hooks(
            || Ok(()),
            || std::fs::write(fixture.output_directory().join(name), b"modified"),
            || Ok(()),
        );
        assert!(matches!(
            result,
            Err(ExportPublishError::BeforePublication(_))
        ));
        assert!(fixture.entries().is_empty());
    }

    #[test]
    fn replaced_staging_names_do_not_become_cleanup_targets() {
        let fixture = Fixture::new(b"artifact");
        let stage = fixture.stage(false);
        let name = stage.staging_name.clone();
        let staged = fixture.output_directory().join(&name);
        std::fs::rename(&staged, fixture.root.join("retained-stage")).unwrap();
        std::fs::write(&staged, b"unrelated").unwrap();
        assert!(matches!(
            stage.publish(|| Ok(())),
            Err(ExportPublishError::BeforePublication(_))
        ));
        assert_eq!(std::fs::read(staged).unwrap(), b"unrelated");
        assert_eq!(
            std::fs::read(fixture.root.join("retained-stage")).unwrap(),
            b"artifact"
        );
    }

    #[test]
    fn publication_faults_never_remove_completed_output_or_authorize_automatic_replay() {
        let fixture = Fixture::new(b"artifact");
        std::fs::write(fixture.output(), b"prior").unwrap();
        let before = fixture.stage(true).publish_with_hooks(
            || Ok(()),
            || Err(io::Error::other("before publication")),
            || Ok(()),
        );
        assert!(matches!(
            before,
            Err(ExportPublishError::BeforePublication(_))
        ));
        assert_eq!(std::fs::read(fixture.output()).unwrap(), b"prior");
        assert_eq!(fixture.entries(), ["result"]);
        let after = fixture.stage(true).publish_with_hooks(
            || Ok(()),
            || Ok(()),
            || Err(io::Error::other("after publication")),
        );
        assert!(matches!(after, Err(ExportPublishError::OutcomeUnknown(_))));
        assert_eq!(std::fs::read(fixture.output()).unwrap(), b"artifact");
        assert_eq!(fixture.entries(), ["result"]);
        assert!(FileExportStaging::create(&fixture.output_directory(), "result", false).is_err());
    }

    #[test]
    fn owner_revalidation_and_postpublication_identity_changes_preserve_uncertainty() {
        let fixture = Fixture::new(b"artifact");
        assert!(matches!(
            fixture.stage(false).publish(|| Err(invalid_source())),
            Err(ExportPublishError::BeforePublication(_))
        ));
        assert!(fixture.entries().is_empty());
        let stage = fixture.stage(false);
        let result = stage.publish_with_hooks(
            || Ok(()),
            || Ok(()),
            || std::fs::write(fixture.output(), b"concurrent"),
        );
        assert!(matches!(result, Err(ExportPublishError::OutcomeUnknown(_))));
        assert_eq!(std::fs::read(fixture.output()).unwrap(), b"concurrent");
        assert_eq!(fixture.entries(), ["result"]);
    }
}
