//! One explicit Artifact file export. This staging owner never reopens an old
//! staging name, never writes the source, and never removes a published file.
use super::*;
use sha2::{Digest, Sha256};
use std::os::unix::fs::FileExt;
use std::path::PathBuf;

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
fn same_stat(a: &libc::stat, b: &libc::stat) -> bool {
    a.st_dev == b.st_dev
        && a.st_ino == b.st_ino
        && a.st_size == b.st_size
        && a.st_uid == b.st_uid
        && a.st_mode == b.st_mode
        && a.st_nlink == b.st_nlink
        && a.st_mtime == b.st_mtime
        && a.st_mtime_nsec == b.st_mtime_nsec
        && a.st_ctime == b.st_ctime
        && a.st_ctime_nsec == b.st_ctime_nsec
}
fn same_metadata(a: &std::fs::Metadata, b: &std::fs::Metadata) -> bool {
    a.dev() == b.dev()
        && a.ino() == b.ino()
        && a.len() == b.len()
        && a.uid() == b.uid()
        && a.mode() == b.mode()
        && a.nlink() == b.nlink()
        && a.mtime() == b.mtime()
        && a.mtime_nsec() == b.mtime_nsec()
        && a.ctime() == b.ctime()
        && a.ctime_nsec() == b.ctime_nsec()
}
fn linked(metadata: &std::fs::Metadata, name: &libc::stat) -> bool {
    metadata.dev() == name.st_dev as u64
        && metadata.ino() == name.st_ino
        && metadata.len() == name.st_size as u64
        && metadata.uid() == name.st_uid
        && metadata.mode() == u32::from(name.st_mode)
        && metadata.nlink() == u64::from(name.st_nlink)
        && metadata.mtime() == name.st_mtime
        && metadata.mtime_nsec() == name.st_mtime_nsec
        && metadata.ctime() == name.st_ctime
        && metadata.ctime_nsec() == name.st_ctime_nsec
}
fn regular_owned(value: &libc::stat) -> bool {
    value.st_mode & libc::S_IFMT == libc::S_IFREG
        && value.st_uid == unsafe { libc::geteuid() }
        && value.st_nlink == 1
}
fn file_digest(file: &File, length: u64) -> io::Result<String> {
    let mut buffer = [0u8; 64 * 1024];
    let mut offset = 0u64;
    let mut hash = Sha256::new();
    while offset < length {
        let wanted = usize::try_from((length - offset).min(buffer.len() as u64))
            .map_err(|_| invalid_source())?;
        let count = match file.read_at(&mut buffer[..wanted], offset) {
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            result => result?,
        };
        if count == 0 {
            return Err(invalid_source());
        }
        hash.update(&buffer[..count]);
        offset += count as u64;
    }
    if file.metadata()?.len() != length {
        return Err(invalid_source());
    }
    Ok(format!("{:x}", hash.finalize()))
}
struct Source {
    directory: HostDirectory,
    name: String,
    file: File,
    metadata: std::fs::Metadata,
}
impl Source {
    fn validate(&self) -> io::Result<()> {
        owned(&self.file, false, Ownership::Private)?;
        let current = self.file.metadata()?;
        let named = self
            .directory
            .stat_at(&self.name)
            .map_err(|_| invalid_source())?;
        if !same_metadata(&self.metadata, &current) || !linked(&current, &named) {
            return Err(invalid_source());
        }
        Ok(())
    }
}
/// A single owned file, distinct from Session's directory ExportStaging. Its
/// expected destination is captured before copying. Successful overwrite needs
/// that same exact metadata immediately before the atomic rename.
pub struct FileExportStaging {
    parent: HostDirectory,
    parent_path: PathBuf,
    staging_name: String,
    destination_name: String,
    prior: Option<libc::stat>,
    output: File,
    initial: std::fs::Metadata,
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
        let prior = match parent.stat_at(destination_name) {
            Ok(value) if regular_owned(&value) && overwrite => Some(value),
            Ok(_) => return Err(conflict()),
            Err(error) if error.kind() == io::ErrorKind::NotFound => None,
            Err(error) => return Err(error),
        };
        let random = u128::from_ne_bytes(crate::random_bytes::<16>()?);
        let staging_name = format!(".arkdeck-export-{random:032x}.part");
        let name = segment(&staging_name)?;
        // SAFETY: one generated name below the retained directory; EXCL and
        // NOFOLLOW never adopt or replace another actor's file.
        let fd = unsafe {
            libc::openat(
                parent.0.as_raw_fd(),
                name.as_ptr(),
                libc::O_RDWR | libc::O_CREAT | libc::O_EXCL | libc::O_NOFOLLOW | libc::O_CLOEXEC,
                0o600,
            )
        };
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        let output = unsafe { File::from_raw_fd(fd) };
        let initial = output.metadata()?;
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
    fn current_destination(&self) -> io::Result<Option<libc::stat>> {
        match self.parent.stat_at(&self.destination_name) {
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
            (Some(prior), Some(current)) if same_stat(prior, &current) => Ok(()),
            _ => Err(conflict()),
        }
    }
    fn validate_output_binding(&self) -> io::Result<std::fs::Metadata> {
        owned(&self.output, false, Ownership::Private)?;
        let held = self.output.metadata()?;
        let name = if self.published {
            &self.destination_name
        } else {
            &self.staging_name
        };
        let named = self.parent.stat_at(name).map_err(|_| invalid_source())?;
        if held.dev() != self.initial.dev()
            || held.ino() != self.initial.ino()
            || held.mode() & 0o777 != 0o600
            || !linked(&held, &named)
        {
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
        let file = source.open_at(name, 0).map_err(|_| invalid_source())?;
        owned(&file, false, Ownership::Private).map_err(|_| invalid_source())?;
        let metadata = file.metadata()?;
        if metadata.len() != size {
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
            let count = match input.file.read_at(&mut buffer[..wanted], offset) {
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
        self.output.sync_all()?;
        // Match the owner's fullSync boundary, including macOS drive cache.
        if unsafe { libc::fcntl(self.output.as_raw_fd(), libc::F_FULLFSYNC) } != 0 {
            return Err(io::Error::last_os_error());
        }
        let before = self.validate_output_binding()?;
        if before.len() != size || file_digest(&self.output, size)? != digest {
            return Err(invalid_source());
        }
        let after = self.validate_output_binding()?;
        if !same_metadata(&before, &after) {
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
        if ready.len() != self.expected_size
            || file_digest(&self.output, self.expected_size).map_err(BeforePublication)?
                != self.expected_digest
        {
            return Err(BeforePublication(invalid_source()));
        }
        let current = self.validate_output_binding().map_err(BeforePublication)?;
        if !same_metadata(&ready, &current) {
            return Err(BeforePublication(invalid_source()));
        }
        input.validate().map_err(BeforePublication)?;
        validate_owner().map_err(BeforePublication)?;
        self.validate_destination().map_err(BeforePublication)?;
        let source = segment(&self.staging_name).map_err(BeforePublication)?;
        let destination = segment(&self.destination_name).map_err(BeforePublication)?;
        // The existing overwrite contract compares its captured metadata and
        // publishes atomically at the same descriptor-relative destination.
        let flags = if self.prior.is_none() {
            libc::RENAME_EXCL
        } else {
            0
        };
        if unsafe {
            libc::renameatx_np(
                self.parent.0.as_raw_fd(),
                source.as_ptr(),
                self.parent.0.as_raw_fd(),
                destination.as_ptr(),
                flags,
            )
        } != 0
        {
            return Err(BeforePublication(io::Error::last_os_error()));
        }
        self.published = true;
        after().map_err(OutcomeUnknown)?;
        self.parent.0.sync_all().map_err(OutcomeUnknown)?;
        self.parent
            .validate_path(&self.parent_path)
            .map_err(OutcomeUnknown)?;
        let published = self.validate_output_binding().map_err(OutcomeUnknown)?;
        if published.len() != self.expected_size
            || file_digest(&self.output, self.expected_size).map_err(OutcomeUnknown)?
                != self.expected_digest
        {
            return Err(OutcomeUnknown(invalid_source()));
        }
        let current = self.validate_output_binding().map_err(OutcomeUnknown)?;
        if !same_metadata(&published, &current) {
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
        // Remove only the private, exact inode this invocation created. A
        // substituted name or hard link is left untouched for inspection.
        if self.validate_output_binding().is_ok()
            && let Ok(name) = segment(&self.staging_name)
        {
            unsafe { libc::unlinkat(self.parent.0.as_raw_fd(), name.as_ptr(), 0) };
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::{DirBuilderExt, PermissionsExt, symlink};
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
            std::fs::DirBuilder::new()
                .mode(0o700)
                .create(&root)
                .unwrap();
            for name in ["source", "output"] {
                std::fs::DirBuilder::new()
                    .mode(0o700)
                    .create(root.join(name))
                    .unwrap();
            }
            std::fs::write(root.join("source/payload"), bytes).unwrap();
            std::fs::set_permissions(
                root.join("source/payload"),
                std::fs::Permissions::from_mode(0o400),
            )
            .unwrap();
            Self {
                source: HostDirectory::open(&root.join("source")).unwrap(),
                root,
                digest: format!("{:x}", Sha256::digest(bytes)),
            }
        }
        fn stage(&self, overwrite: bool) -> FileExportStaging {
            let mut stage =
                FileExportStaging::create(&self.root.join("output"), "result", overwrite).unwrap();
            let size = std::fs::metadata(self.root.join("source/payload"))
                .unwrap()
                .len();
            stage
                .copy_verified(&self.source, "payload", size, &self.digest)
                .unwrap();
            stage
        }
        fn output(&self) -> PathBuf {
            self.root.join("output/result")
        }
        fn entries(&self) -> Vec<String> {
            std::fs::read_dir(self.root.join("output"))
                .unwrap()
                .map(|v| v.unwrap().file_name().into_string().unwrap())
                .collect()
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            std::fs::remove_dir_all(&self.root).unwrap();
        }
    }
    #[test]
    fn new_and_explicit_overwrite_publish_exact_bytes_without_mutating_source() {
        for bytes in [b"".as_slice(), b"artifact\0bytes", &[255u8; 65539]] {
            let fixture = Fixture::new(bytes);
            let source_before = std::fs::metadata(fixture.root.join("source/payload")).unwrap();
            let (path, overwritten) = fixture.stage(false).publish(|| Ok(())).unwrap();
            assert_eq!(path, fixture.output());
            assert!(!overwritten);
            assert_eq!(std::fs::read(&path).unwrap(), bytes);
            assert_eq!(std::fs::metadata(&path).unwrap().mode() & 0o777, 0o600);
            assert_eq!(fixture.entries(), ["result"]);
            assert!(
                FileExportStaging::create(&fixture.root.join("output"), "result", false).is_err()
            );
            assert!(fixture.stage(true).publish(|| Ok(())).unwrap().1);
            let source_after = std::fs::metadata(fixture.root.join("source/payload")).unwrap();
            assert!(same_metadata(&source_before, &source_after));
            assert_eq!(
                std::fs::read(fixture.root.join("source/payload")).unwrap(),
                bytes
            );
        }
    }
    #[test]
    fn unsafe_destination_links_and_parent_aliases_are_refused_before_staging() {
        let fixture = Fixture::new(b"source");
        symlink(fixture.root.join("source/payload"), fixture.output()).unwrap();
        assert!(
            matches!(FileExportStaging::create(&fixture.root.join("output"),"result",true),Err(e) if e.kind()==io::ErrorKind::AlreadyExists)
        );
        assert!(fixture.output().is_symlink());
        std::fs::remove_file(fixture.output()).unwrap();
        std::fs::hard_link(fixture.root.join("source/payload"), fixture.output()).unwrap();
        assert!(
            matches!(FileExportStaging::create(&fixture.root.join("output"),"result",true),Err(e) if e.kind()==io::ErrorKind::AlreadyExists)
        );
        assert_eq!(std::fs::metadata(fixture.output()).unwrap().nlink(), 2);
        symlink(fixture.root.join("output"), fixture.root.join("alias")).unwrap();
        assert!(
            matches!(FileExportStaging::create(&fixture.root.join("alias"),"new",false),Err(e) if e.kind()==io::ErrorKind::InvalidInput)
        );
        assert_eq!(fixture.entries(), ["result"]);
    }
    #[test]
    fn absent_destination_competitor_and_changed_overwrite_metadata_are_never_replaced() {
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
                matches!(result,Err(ExportPublishError::BeforePublication(e)) if e.kind()==io::ErrorKind::AlreadyExists)
            );
            assert_eq!(
                std::fs::read(fixture.output()).unwrap(),
                b"concurrent-content"
            );
            assert_eq!(fixture.entries(), ["result"]);
        }
        let fixture = Fixture::new(b"artifact");
        std::fs::write(fixture.output(), b"prior").unwrap();
        let stage = fixture.stage(true);
        let result = stage.publish_with_hooks(
            || Ok(()),
            || {
                std::fs::write(fixture.root.join("replacement"), b"other-inode")?;
                std::fs::rename(fixture.root.join("replacement"), fixture.output())
            },
            || Ok(()),
        );
        assert!(matches!(
            result,
            Err(ExportPublishError::BeforePublication(_))
        ));
        assert_eq!(std::fs::read(fixture.output()).unwrap(), b"other-inode");
    }
    #[test]
    fn source_changes_and_staging_tampering_fail_before_any_publication() {
        let fixture = Fixture::new(b"original");
        let stage = fixture.stage(false);
        let result = stage.publish_with_hooks(
            || Ok(()),
            || {
                std::fs::set_permissions(
                    fixture.root.join("source/payload"),
                    std::fs::Permissions::from_mode(0o600),
                )?;
                std::fs::write(fixture.root.join("source/payload"), b"modified")
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
            || std::fs::write(fixture.root.join("output").join(name), b"modified"),
            || Ok(()),
        );
        assert!(matches!(
            result,
            Err(ExportPublishError::BeforePublication(_))
        ));
        assert!(fixture.entries().is_empty());
    }
    #[test]
    fn replaced_parent_and_staging_names_do_not_become_cleanup_targets() {
        let fixture = Fixture::new(b"artifact");
        let stage = fixture.stage(false);
        let result = stage.publish_with_hooks(
            || Ok(()),
            || {
                std::fs::rename(fixture.root.join("output"), fixture.root.join("moved"))?;
                std::fs::DirBuilder::new()
                    .mode(0o700)
                    .create(fixture.root.join("output"))?;
                std::fs::write(fixture.output(), b"unrelated")
            },
            || Ok(()),
        );
        assert!(matches!(
            result,
            Err(ExportPublishError::BeforePublication(_))
        ));
        assert_eq!(std::fs::read(fixture.output()).unwrap(), b"unrelated");
        assert_eq!(
            std::fs::read_dir(fixture.root.join("moved"))
                .unwrap()
                .count(),
            0
        );
        let fixture = Fixture::new(b"artifact");
        let stage = fixture.stage(false);
        let name = stage.staging_name.clone();
        let staged = fixture.root.join("output").join(&name);
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
        let after = fixture.stage(true).publish_with_hooks(
            || Ok(()),
            || Ok(()),
            || Err(io::Error::other("after publication")),
        );
        assert!(matches!(after, Err(ExportPublishError::OutcomeUnknown(_))));
        assert_eq!(std::fs::read(fixture.output()).unwrap(), b"artifact");
        assert_eq!(fixture.entries(), ["result"]);
        assert!(FileExportStaging::create(&fixture.root.join("output"), "result", false).is_err());
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

    #[test]
    #[ignore = "subprocess helper launched by the crash-window test"]
    fn process_fixture() {
        let root = PathBuf::from(
            std::env::var_os("ARKDECK_FILE_EXPORT_PROCESS_ROOT").expect("test fixture root"),
        );
        let phase = std::env::var("ARKDECK_FILE_EXPORT_PROCESS_PHASE").unwrap();
        if phase == "restart" {
            let refused = FileExportStaging::create(&root.join("output"), "result", false);
            assert!(matches!(refused, Err(error) if error.kind() == io::ErrorKind::AlreadyExists));
            return;
        }
        let source = HostDirectory::open(&root.join("source")).unwrap();
        let payload = std::fs::read(root.join("source/payload")).unwrap();
        let mut stage = FileExportStaging::create(&root.join("output"), "result", true).unwrap();
        stage
            .copy_verified(
                &source,
                "payload",
                payload.len() as u64,
                &format!("{:x}", Sha256::digest(&payload)),
            )
            .unwrap();
        let wait = || -> io::Result<()> {
            std::fs::write(root.join("ready"), phase.as_bytes())?;
            loop {
                std::thread::park();
            }
        };
        let result = if phase == "before" {
            stage.publish_with_hooks(|| Ok(()), wait, || Ok(()))
        } else {
            stage.publish_with_hooks(|| Ok(()), || Ok(()), wait)
        };
        result.unwrap();
    }

    #[test]
    fn sigkill_around_publication_preserves_original_or_complete_file_and_restart_never_replays() {
        struct Child(std::process::Child);
        impl Drop for Child {
            fn drop(&mut self) {
                let _ = self.0.kill();
                let _ = self.0.wait();
            }
        }
        let launch = |root: &Path, phase: &str| {
            std::process::Command::new(std::env::current_exe().unwrap())
                .args([
                    "--exact",
                    "host_store::file_export::tests::process_fixture",
                    "--ignored",
                    "--nocapture",
                ])
                .env("ARKDECK_FILE_EXPORT_PROCESS_ROOT", root)
                .env("ARKDECK_FILE_EXPORT_PROCESS_PHASE", phase)
                .stdout(std::process::Stdio::null())
                .stderr(std::process::Stdio::null())
                .spawn()
                .unwrap()
        };
        for phase in ["before", "after"] {
            let bytes = vec![0x5Au8; 512 * 1024 + 7];
            let fixture = Fixture::new(&bytes);
            std::fs::write(fixture.output(), b"original destination").unwrap();
            let mut child = Child(launch(&fixture.root, phase));
            let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
            while !fixture.root.join("ready").exists() {
                assert!(
                    std::time::Instant::now() < deadline,
                    "export child did not reach the publication boundary"
                );
                assert!(
                    child.0.try_wait().unwrap().is_none(),
                    "export child exited before the publication boundary"
                );
                std::thread::sleep(std::time::Duration::from_millis(10));
            }
            child.0.kill().unwrap();
            child.0.wait().unwrap();
            let expected = if phase == "before" {
                b"original destination".as_slice()
            } else {
                &bytes
            };
            assert_eq!(std::fs::read(fixture.output()).unwrap(), expected);
            let mut before = fixture.entries();
            before.sort();
            let mut restarted = Child(launch(&fixture.root, "restart"));
            assert!(restarted.0.wait().unwrap().success());
            let mut after = fixture.entries();
            after.sort();
            assert_eq!(
                before, after,
                "restart adopted or reclaimed an earlier export"
            );
            assert_eq!(std::fs::read(fixture.output()).unwrap(), expected);
            assert_eq!(
                std::fs::read(fixture.root.join("source/payload")).unwrap(),
                bytes
            );
        }
    }
}
