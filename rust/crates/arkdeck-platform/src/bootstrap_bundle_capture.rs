//! A Bundle capture owns only its freshly created, bounded staging tree.
//! The source root stays held through capture, native inspection and publication.
//! No source is executed, and no existing content or Session is ever removed.
use crate::{
    BootstrapTree, bootstrap_bundle_version, inspect_bootstrap_tree, random_bytes,
    validate_production_daemon_bundle,
};
use sha2::{Digest, Sha256};
use std::{
    ffi::CString,
    fmt,
    fs::{File, Metadata},
    io::{self, Read, Write},
    os::{
        fd::{AsRawFd, FromRawFd},
        unix::fs::{FileExt, MetadataExt},
    },
    path::{Path, PathBuf},
};

const MAX_BYTES: u64 = 1_073_741_824;
const MAX_ENTRIES: usize = 4096;
const MAX_DEPTH: usize = 24;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BootstrapBundleCaptureError {
    pub code: &'static str,
    pub message: &'static str,
}
impl BootstrapBundleCaptureError {
    pub fn new(code: &'static str, message: &'static str) -> Self {
        Self { code, message }
    }
}
impl fmt::Display for BootstrapBundleCaptureError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}: {}", self.code, self.message)
    }
}
impl std::error::Error for BootstrapBundleCaptureError {}
type Result<T> = std::result::Result<T, BootstrapBundleCaptureError>;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BootstrapBundlePublication {
    Published(PathBuf),
    /// The existing destination was neither opened for writing nor removed.
    /// The registry owner must independently verify its immutable content.
    AlreadyExists(PathBuf),
}
#[derive(Debug)]
pub enum BootstrapBundlePublishError {
    BeforePublication(BootstrapBundleCaptureError),
    OutcomeUnknown(BootstrapBundleCaptureError),
}
impl fmt::Display for BootstrapBundlePublishError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::BeforePublication(e) => write!(f, "{e}"),
            Self::OutcomeUnknown(e) => write!(f, "outcomeUnknown: {e}"),
        }
    }
}
impl std::error::Error for BootstrapBundlePublishError {}

fn changed() -> BootstrapBundleCaptureError {
    BootstrapBundleCaptureError::new(
        "fileIdentityChanged",
        "Bootstrap bundle source or staging identity changed",
    )
}
fn invalid() -> BootstrapBundleCaptureError {
    BootstrapBundleCaptureError::new(
        "invalidInput",
        "Bundle capture requires a bounded app tree and local paths",
    )
}
fn io_failure(_: io::Error) -> BootstrapBundleCaptureError {
    BootstrapBundleCaptureError::new(
        "ioFailure",
        "Bootstrap bundle capture could not complete its local I/O",
    )
}
fn write_failure(error: io::Error) -> BootstrapBundleCaptureError {
    if error.raw_os_error() == Some(libc::ENOSPC) {
        BootstrapBundleCaptureError::new(
            "quotaExceeded",
            "Bootstrap bundle capture exhausted local storage",
        )
    } else {
        io_failure(error)
    }
}
fn bounded() -> BootstrapBundleCaptureError {
    BootstrapBundleCaptureError::new(
        "inputTooLarge",
        "Bundle capture exceeds its tree or byte bounds",
    )
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct Identity {
    device: u64,
    inode: u64,
    mode: u32,
    uid: u32,
    links: u64,
    size: u64,
    modified: (i64, i64),
    changed: (i64, i64),
}
impl From<Metadata> for Identity {
    fn from(m: Metadata) -> Self {
        Self {
            device: m.dev(),
            inode: m.ino(),
            mode: m.mode(),
            uid: m.uid(),
            links: m.nlink(),
            size: m.len(),
            modified: (m.mtime(), m.mtime_nsec()),
            changed: (m.ctime(), m.ctime_nsec()),
        }
    }
}
fn metadata(file: &File) -> Result<Metadata> {
    file.metadata().map_err(io_failure)
}
fn identity(file: &File) -> Result<Identity> {
    Ok(metadata(file)?.into())
}
fn same_object(a: &Metadata, b: &Metadata) -> bool {
    a.dev() == b.dev() && a.ino() == b.ino()
}
fn component(name: &str) -> Result<CString> {
    if name.is_empty() || name == "." || name == ".." || name.contains('/') {
        return Err(invalid());
    }
    CString::new(name).map_err(|_| invalid())
}
fn open_at(parent: &File, name: &str, flags: i32) -> io::Result<File> {
    let name = CString::new(name).map_err(|_| io::Error::from(io::ErrorKind::InvalidInput))?;
    // SAFETY: the live parent descriptor and component are valid for this call.
    let fd = unsafe {
        libc::openat(
            parent.as_raw_fd(),
            name.as_ptr(),
            flags | libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK,
        )
    };
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: a newly opened descriptor has exactly one owner.
    Ok(unsafe { File::from_raw_fd(fd) })
}
fn physical_path(path: &Path) -> Result<PathBuf> {
    let text = path.to_str().ok_or_else(invalid)?;
    if !text.starts_with('/')
        || text.as_bytes().contains(&0)
        || text.split('/').any(|v| matches!(v, "." | ".."))
    {
        return Err(invalid());
    }
    for prefix in ["/tmp", "/var", "/etc"] {
        if text == prefix || text.starts_with(&format!("{prefix}/")) {
            return Ok(PathBuf::from(format!("/private{text}")));
        }
    }
    Ok(path.to_owned())
}
fn open_directory(path: &Path, private_leaf: bool) -> Result<File> {
    let text = path.to_str().ok_or_else(invalid)?;
    // SAFETY: constant root path; returned fd is transferred once.
    let fd = unsafe {
        libc::open(
            c"/".as_ptr(),
            libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
        )
    };
    if fd < 0 {
        return Err(io_failure(io::Error::last_os_error()));
    }
    let mut current = unsafe { File::from_raw_fd(fd) };
    for name in text.split('/').filter(|v| !v.is_empty()) {
        current = match open_at(&current, name, libc::O_RDONLY | libc::O_DIRECTORY) {
            Ok(file) => file,
            Err(error) => {
                let name = component(name)?;
                let mut entry = std::mem::MaybeUninit::<libc::stat>::uninit();
                // SAFETY: this reads only the immediate failed ancestry entry,
                // without following a link; initialization is checked first.
                if unsafe {
                    libc::fstatat(
                        current.as_raw_fd(),
                        name.as_ptr(),
                        entry.as_mut_ptr(),
                        libc::AT_SYMLINK_NOFOLLOW,
                    )
                } == 0
                {
                    let entry = unsafe { entry.assume_init() };
                    if entry.st_mode & libc::S_IFMT == libc::S_IFLNK {
                        return Err(changed());
                    }
                    if entry.st_mode & libc::S_IFMT != libc::S_IFDIR {
                        return Err(invalid());
                    }
                }
                return Err(io_failure(error));
            }
        };
        let m = metadata(&current)?;
        let shared = m.uid() == 0 && m.mode() & u32::from(libc::S_ISVTX) != 0;
        if (m.uid() != unsafe { libc::geteuid() } && m.uid() != 0)
            || (m.mode() & 0o022 != 0 && !shared)
        {
            return Err(changed());
        }
    }
    let m = metadata(&current)?;
    if !m.is_dir()
        || (private_leaf && (m.uid() != unsafe { libc::geteuid() } || m.mode() & 0o077 != 0))
    {
        return Err(changed());
    }
    Ok(current)
}
fn quarantine(file: &File) -> Result<Option<Vec<u8>>> {
    crate::host_bootstrap_tree::quarantine(file).map_err(|_| changed())
}
fn names(file: &File) -> Result<Vec<String>> {
    crate::host_bootstrap_tree::names(file).map_err(|_| changed())
}
fn set_quarantine(file: &File, value: &Option<Vec<u8>>) -> Result<()> {
    if let Some(value) = value {
        // SAFETY: only a newly created, owned output file is modified.
        if unsafe {
            libc::fsetxattr(
                file.as_raw_fd(),
                c"com.apple.quarantine".as_ptr(),
                value.as_ptr().cast(),
                value.len(),
                0,
                0,
            )
        } != 0
        {
            return Err(changed());
        }
    }
    Ok(())
}
fn hash_copy(source: &File, size: u64, mut output: Option<&mut File>) -> Result<String> {
    let mut hasher = Sha256::new();
    let mut offset = 0;
    let mut buffer = [0_u8; 64 * 1024];
    loop {
        let count = match source.read_at(&mut buffer, offset) {
            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
            other => other.map_err(io_failure)?,
        };
        if count == 0 {
            break;
        }
        offset = offset
            .checked_add(count as u64)
            .filter(|v| *v <= size)
            .ok_or_else(changed)?;
        hasher.update(&buffer[..count]);
        if let Some(out) = output.as_mut() {
            out.write_all(&buffer[..count]).map_err(write_failure)?;
        }
    }
    if offset != size {
        return Err(changed());
    }
    Ok(format!("{:x}", hasher.finalize()))
}

struct Created {
    parent: Option<usize>,
    name: String,
    inode: Metadata,
}

/// Sealed ownership of one fresh `.staging-<uuid>.app`. There is no constructor
/// for an existing stage and no caller-supplied cleanup path or native verifier.
pub struct BootstrapBundleCapture {
    registry: File,
    registry_path: PathBuf,
    registry_inode: Metadata,
    stage: File,
    stage_name: String,
    path: PathBuf,
    source: File,
    source_path: PathBuf,
    source_tree: BootstrapTree,
    copied_tree: Option<BootstrapTree>,
    created: Vec<Created>,
    byte_count: u64,
    published: bool,
    publication_uncertain: bool,
}
impl BootstrapBundleCapture {
    /// Copy a bounded Bundle tree into a fresh private stage, preserving raw
    /// quarantine on directories and files. Native production Bundle validation
    /// is mandatory and never executes the captured source or helper.
    pub fn capture(registry_root: &Path, source: &Path) -> Result<Self> {
        Self::capture_with_checkpoint(registry_root, source, |_, _| Ok(()))
    }
    fn capture_with_checkpoint(
        registry_root: &Path,
        source: &Path,
        checkpoint: impl Fn(&str, &Path) -> Result<()>,
    ) -> Result<Self> {
        let registry_path = physical_path(registry_root)?;
        let source_path = physical_path(source)?;
        if source_path.extension().and_then(|v| v.to_str()) != Some("app")
            || registry_path.starts_with(&source_path)
        {
            return Err(invalid());
        }
        let registry = open_directory(&registry_path, true)?;
        let registry_inode = metadata(&registry)?;
        let source = open_directory(&source_path, false)?;
        let source_tree = inspect_bootstrap_tree(&source_path).map_err(|_| changed())?;
        if identity(&source)?
            != Identity::from(std::fs::symlink_metadata(&source_path).map_err(io_failure)?)
        {
            return Err(changed());
        }
        let nonce = random_bytes::<16>().map_err(io_failure)?;
        let text: String = nonce.iter().map(|byte| format!("{byte:02x}")).collect();
        let stage_name = format!(
            ".staging-{}-{}-{}-{}-{}.app",
            &text[..8],
            &text[8..12],
            &text[12..16],
            &text[16..20],
            &text[20..]
        );
        let name = component(&stage_name)?;
        // SAFETY: create a single fresh component below the held private root.
        if unsafe { libc::mkdirat(registry.as_raw_fd(), name.as_ptr(), 0o700) } != 0 {
            return Err(write_failure(io::Error::last_os_error()));
        }
        let stage = open_at(&registry, &stage_name, libc::O_RDONLY | libc::O_DIRECTORY)
            .map_err(io_failure)?;
        let created = vec![Created {
            parent: None,
            name: stage_name.clone(),
            inode: metadata(&stage)?,
        }];
        let mut capture = Self {
            path: registry_path.join(&stage_name),
            registry,
            registry_path,
            registry_inode,
            stage,
            stage_name,
            source,
            source_path,
            source_tree,
            copied_tree: None,
            created,
            byte_count: 0,
            published: false,
            publication_uncertain: false,
        };
        capture.validate_binding()?;
        let source = capture.source.try_clone().map_err(io_failure)?;
        let mut destination = capture.stage.try_clone().map_err(io_failure)?;
        capture.copy_tree(&source, &mut destination, 0, 0)?;
        capture.registry.sync_all().map_err(io_failure)?;
        let copied = inspect_bootstrap_tree(&capture.path).map_err(|_| changed())?;
        if copied.entries != capture.source_tree.entries
            || copied.byte_count != capture.source_tree.byte_count
        {
            return Err(changed());
        }
        capture.copied_tree = Some(copied);
        capture.revalidate_sources()?;
        checkpoint("copied", &capture.path)?;
        capture.revalidate_sources()?;
        capture.verify_native()?;
        capture.revalidate_sources()?;
        Ok(capture)
    }
    pub fn path(&self) -> &Path {
        &self.path
    }

    fn copy_tree(
        &mut self,
        source: &File,
        output: &mut File,
        position: usize,
        depth: usize,
    ) -> Result<()> {
        if depth > MAX_DEPTH || self.created.len() > MAX_ENTRIES {
            return Err(bounded());
        }
        let before = metadata(source)?;
        if (before.uid() != unsafe { libc::geteuid() } && before.uid() != 0)
            || before.mode() & 0o6022 != 0
            || !(before.is_dir() || (before.is_file() && before.nlink() == 1))
        {
            return Err(changed());
        }
        let source_identity = Identity::from(before.clone());
        let attribute = quarantine(source)?;
        set_quarantine(output, &attribute)?;
        if before.is_dir() {
            let children = names(source)?;
            for name in &children {
                if self.created.len() >= MAX_ENTRIES || depth >= MAX_DEPTH {
                    return Err(bounded());
                }
                let child = open_at(source, name, libc::O_RDONLY).map_err(|_| changed())?;
                let child_identity = identity(&child)?;
                let status = metadata(&child)?;
                if !(status.is_dir() || (status.is_file() && status.nlink() == 1)) {
                    return Err(invalid());
                }
                let component = component(name)?;
                let mut copied = if status.is_dir() {
                    // SAFETY: only this newly created parent gets a new child.
                    if unsafe { libc::mkdirat(output.as_raw_fd(), component.as_ptr(), 0o700) } != 0
                    {
                        return Err(write_failure(io::Error::last_os_error()));
                    }
                    open_at(output, name, libc::O_RDONLY | libc::O_DIRECTORY).map_err(io_failure)?
                } else {
                    let mode = if status.mode() & 0o111 == 0 {
                        0o600
                    } else {
                        0o700
                    };
                    // SAFETY: exclusive creation never opens an existing file for writing.
                    let fd = unsafe {
                        libc::openat(
                            output.as_raw_fd(),
                            component.as_ptr(),
                            libc::O_RDWR
                                | libc::O_CREAT
                                | libc::O_EXCL
                                | libc::O_CLOEXEC
                                | libc::O_NOFOLLOW,
                            mode,
                        )
                    };
                    if fd < 0 {
                        return Err(write_failure(io::Error::last_os_error()));
                    }
                    // SAFETY: newly allocated descriptor transfers to exactly one owner.
                    unsafe { File::from_raw_fd(fd) }
                };
                let next = self.created.len();
                self.created.push(Created {
                    parent: Some(position),
                    name: name.clone(),
                    inode: metadata(&copied)?,
                });
                self.copy_tree(&child, &mut copied, next, depth + 1)?;
                let linked = open_at(source, name, libc::O_RDONLY).map_err(|_| changed())?;
                if identity(&linked)? != child_identity {
                    return Err(changed());
                }
            }
            if names(source)? != children {
                return Err(changed());
            }
            output.sync_all().map_err(io_failure)?;
        } else {
            if before.len() > MAX_BYTES - self.byte_count {
                return Err(bounded());
            }
            hash_copy(source, before.len(), Some(output))?;
            self.byte_count += before.len();
            // SAFETY: only the newly created output is durably flushed. Match
            // BootstrapBundleFiles.sync's macOS file durability operation.
            if unsafe { libc::fcntl(output.as_raw_fd(), libc::F_FULLFSYNC) } != 0 {
                return Err(io_failure(io::Error::last_os_error()));
            }
        }
        if identity(source)? != source_identity
            || quarantine(source)? != attribute
            || quarantine(output)? != attribute
        {
            return Err(changed());
        }
        Ok(())
    }
    fn verify_native(&self) -> Result<()> {
        // Match Swift's version-before-signature error precedence. This held
        // file belongs to the already measured stage; no source trust is assumed.
        let tree = self.copied_tree.as_ref().ok_or_else(changed)?;
        let file = tree
            .open_relative_file(&self.path, "Contents/Info.plist")
            .map_err(|_| invalid())?;
        if metadata(&file)?.len() > 64 * 1024 {
            return Err(bounded());
        }
        let mut bytes = Vec::new();
        file.take(64 * 1024 + 1)
            .read_to_end(&mut bytes)
            .map_err(io_failure)?;
        if bytes.len() > 64 * 1024 {
            return Err(bounded());
        }
        bootstrap_bundle_version(&bytes).map_err(|_| invalid())?;
        let validated = validate_production_daemon_bundle(&self.path).map_err(|error| {
            if error.kind() == io::ErrorKind::PermissionDenied {
                BootstrapBundleCaptureError::new(
                    "admissionDenied",
                    "captured Bundle failed the native production helper trust policy",
                )
            } else {
                changed()
            }
        })?;
        if validated != self.path {
            return Err(changed());
        }
        Ok(())
    }
    fn validate_binding(&self) -> Result<()> {
        let registry = open_directory(&self.registry_path, true)?;
        if !same_object(&metadata(&registry)?, &self.registry_inode)
            || !same_object(&metadata(&self.registry)?, &self.registry_inode)
        {
            return Err(changed());
        }
        let name = self
            .path
            .file_name()
            .and_then(|v| v.to_str())
            .ok_or_else(changed)?;
        let linked = open_at(&self.registry, name, libc::O_RDONLY | libc::O_DIRECTORY)
            .map_err(|_| changed())?;
        self.check_created(0, &linked)?;
        self.check_created(0, &self.stage)
    }
    fn check_created(&self, position: usize, file: &File) -> Result<()> {
        let expected = &self.created[position].inode;
        let current = metadata(file)?;
        let mode = if expected.is_dir() || expected.mode() & 0o111 != 0 {
            0o700
        } else {
            0o600
        };
        if !same_object(&current, expected)
            || current.is_dir() != expected.is_dir()
            || current.uid() != unsafe { libc::geteuid() }
            || current.mode() & 0o7777 != mode
            || (!current.is_dir() && (!current.is_file() || current.nlink() != 1))
        {
            return Err(changed());
        }
        Ok(())
    }
    fn open_created(&self, position: usize) -> Result<File> {
        let record = &self.created[position];
        let file = if let Some(parent) = record.parent {
            let parent = self.open_created(parent)?;
            open_at(&parent, &record.name, libc::O_RDONLY).map_err(|_| changed())?
        } else {
            self.stage.try_clone().map_err(io_failure)?
        };
        self.check_created(position, &file)?;
        Ok(file)
    }
    fn validate_created_tree(&self) -> Result<()> {
        self.validate_binding()?;
        for (position, record) in self.created.iter().enumerate() {
            let file = self.open_created(position)?;
            if record.inode.is_dir() {
                let mut expected: Vec<_> = self
                    .created
                    .iter()
                    .filter(|entry| entry.parent == Some(position))
                    .map(|entry| entry.name.clone())
                    .collect();
                expected.sort();
                if names(&file)? != expected {
                    return Err(changed());
                }
            }
        }
        self.validate_binding()
    }
    /// Recheck source identity, bytes, members and raw-quarantine identity,
    /// plus the complete captured tree and every recorded output inode.
    pub fn revalidate_sources(&self) -> Result<()> {
        self.validate_created_tree()?;
        let source = open_directory(&self.source_path, false)?;
        if identity(&source)? != identity(&self.source)?
            || inspect_bootstrap_tree(&self.source_path).map_err(|_| changed())? != self.source_tree
        {
            return Err(changed());
        }
        if self.copied_tree.as_ref().is_none_or(|expected| {
            inspect_bootstrap_tree(&self.path).ok().as_ref() != Some(expected)
        }) {
            return Err(changed());
        }
        self.validate_created_tree()
    }
    /// `digest` is the hoststore's already measured frozen content address.
    /// This primitive checks its syntax, not its derivation; it must never be
    /// wired directly to an arbitrary Runtime caller-supplied digest.
    pub fn publish(
        &mut self,
        digest: &str,
    ) -> std::result::Result<BootstrapBundlePublication, BootstrapBundlePublishError> {
        self.publish_with_checkpoint(digest, |_| Ok(()))
    }
    fn publish_with_checkpoint(
        &mut self,
        digest: &str,
        checkpoint: impl Fn(&str) -> Result<()>,
    ) -> std::result::Result<BootstrapBundlePublication, BootstrapBundlePublishError> {
        self.publish_with_operation(digest, checkpoint, |registry, source, destination| {
            // SAFETY: both exact components are below the held private root;
            // exclusive rename cannot overwrite a directory, file, or symlink.
            if unsafe {
                libc::renameatx_np(
                    registry.as_raw_fd(),
                    source.as_ptr(),
                    registry.as_raw_fd(),
                    destination.as_ptr(),
                    libc::RENAME_EXCL,
                )
            } == 0
            {
                Ok(())
            } else {
                Err(io::Error::last_os_error())
            }
        })
    }
    fn publish_with_operation(
        &mut self,
        digest: &str,
        checkpoint: impl Fn(&str) -> Result<()>,
        rename: impl Fn(&File, &CString, &CString) -> io::Result<()>,
    ) -> std::result::Result<BootstrapBundlePublication, BootstrapBundlePublishError> {
        use BootstrapBundlePublishError::{BeforePublication, OutcomeUnknown};
        if self.published
            || self.publication_uncertain
            || digest.len() != 64
            || !digest
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        {
            return Err(BeforePublication(invalid()));
        }
        self.revalidate_sources().map_err(BeforePublication)?;
        self.verify_native().map_err(BeforePublication)?;
        self.revalidate_sources().map_err(BeforePublication)?;
        let destination_name = format!("bundle-{digest}.app");
        let destination = component(&destination_name).map_err(BeforePublication)?;
        let stage = component(&self.stage_name).map_err(BeforePublication)?;
        let final_path = self.registry_path.join(&destination_name);
        checkpoint("beforeRename").map_err(BeforePublication)?;
        self.validate_created_tree().map_err(BeforePublication)?;
        if let Err(error) = rename(&self.registry, &stage, &destination) {
            if error.kind() == io::ErrorKind::AlreadyExists {
                self.revalidate_sources().map_err(BeforePublication)?;
                return Ok(BootstrapBundlePublication::AlreadyExists(final_path));
            }
            // A failed syscall is not proof that publication had no effect.
            // Retain either namespace and refuse replay by this capture.
            self.publication_uncertain = true;
            return Err(OutcomeUnknown(io_failure(error)));
        }
        // Set before any fallible step. Drop can never reclaim published bytes,
        // even if durability, source, native state or result delivery changes.
        self.published = true;
        self.path = final_path.clone();
        checkpoint("afterRename").map_err(OutcomeUnknown)?;
        self.registry
            .sync_all()
            .map_err(|e| OutcomeUnknown(io_failure(e)))?;
        self.validate_created_tree().map_err(OutcomeUnknown)?;
        let after = inspect_bootstrap_tree(&self.path).map_err(|_| OutcomeUnknown(changed()))?;
        if self.copied_tree.as_ref().is_none_or(|before| {
            before.entries != after.entries || before.byte_count != after.byte_count
        }) {
            return Err(OutcomeUnknown(changed()));
        }
        self.copied_tree = Some(after);
        self.revalidate_sources().map_err(OutcomeUnknown)?;
        Ok(BootstrapBundlePublication::Published(final_path))
    }
    fn cleanup_owned_stage(&self) -> Result<()> {
        if self.published || self.publication_uncertain {
            return Ok(());
        }
        // A complete preflight precedes the first unlink. It includes every
        // directory's membership, not just the files planned for deletion.
        self.validate_created_tree()?;
        for position in (1..self.created.len()).rev() {
            self.validate_binding()?;
            let record = &self.created[position];
            let file = self.open_created(position)?;
            if record.inode.is_dir() && !names(&file)?.is_empty() {
                return Err(changed());
            }
            let parent = self.open_created(record.parent.ok_or_else(changed)?)?;
            let name = component(&record.name)?;
            // SAFETY: this exact object created and recorded this inode; its
            // linked identity and parent were just revalidated. No external
            // directory can be adopted as a cleanup root.
            if unsafe {
                libc::unlinkat(
                    parent.as_raw_fd(),
                    name.as_ptr(),
                    if record.inode.is_dir() {
                        libc::AT_REMOVEDIR
                    } else {
                        0
                    },
                )
            } != 0
            {
                return Err(io_failure(io::Error::last_os_error()));
            }
        }
        self.validate_binding()?;
        if !names(&self.stage)?.is_empty() {
            return Err(changed());
        }
        let name = component(&self.stage_name)?;
        // SAFETY: only this now-empty newly created staging directory is unlinked.
        if unsafe { libc::unlinkat(self.registry.as_raw_fd(), name.as_ptr(), libc::AT_REMOVEDIR) }
            != 0
        {
            return Err(io_failure(io::Error::last_os_error()));
        }
        self.registry.sync_all().map_err(io_failure)
    }
}
impl Drop for BootstrapBundleCapture {
    fn drop(&mut self) {
        let _ = self.cleanup_owned_stage();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        cell::RefCell,
        fs,
        os::unix::fs::{DirBuilderExt, PermissionsExt},
    };
    struct Fixture {
        root: PathBuf,
        source: PathBuf,
        registry: PathBuf,
    }
    impl Fixture {
        fn new() -> Self {
            let nonce = u128::from_ne_bytes(random_bytes::<16>().unwrap());
            let root = PathBuf::from(format!("/private/tmp/bundle-capture-unit-{nonce:032x}"));
            let source = root.join("Source.app");
            let registry = root.join("registry");
            for path in [
                &root,
                &source,
                &source.join("Contents"),
                &source.join("Contents/Nested"),
                &registry,
            ] {
                fs::DirBuilder::new().mode(0o700).create(path).unwrap();
            }
            fs::write(
                source.join("Contents/Nested/payload"),
                b"retained fixture bytes",
            )
            .unwrap();
            fs::write(source.join("Contents/exec"), b"unsigned test executable").unwrap();
            fs::set_permissions(
                source.join("Contents/exec"),
                fs::Permissions::from_mode(0o755),
            )
            .unwrap();
            fs::write(source.join("Contents/Info.plist"), b"<plist><dict><key>CFBundleShortVersionString</key><string>1.0</string></dict></plist>").unwrap();
            Self {
                root,
                source,
                registry,
            }
        }
        fn stages(&self) -> Vec<PathBuf> {
            fs::read_dir(&self.registry)
                .unwrap()
                .map(|e| e.unwrap().path())
                .collect()
        }
    }
    // All roots and source fixtures remain retained. Only the capture's own
    // failure cleanup runs; no test installs a trusted callback or deletes roots.
    #[test]
    fn raw_quarantine_modes_and_tree_are_preserved_before_native_validation() {
        let fixture = Fixture::new();
        for relative in ["", "Contents/Nested", "Contents/exec"] {
            let file = File::open(fixture.source.join(relative)).unwrap();
            set_quarantine(&file, &Some(vec![0x30, 0, 0xff, 0x3b, 0x41])).unwrap();
        }
        let source_tree = inspect_bootstrap_tree(&fixture.source).unwrap();
        let seen = RefCell::new(false);
        let result = BootstrapBundleCapture::capture_with_checkpoint(
            &fixture.registry,
            &fixture.source,
            |phase, stage| {
                assert_eq!(phase, "copied");
                *seen.borrow_mut() = true;
                let tree = inspect_bootstrap_tree(stage).unwrap();
                assert_eq!(tree.entries, source_tree.entries);
                for entry in &tree.entries {
                    let from = File::open(fixture.source.join(&entry.path)).unwrap();
                    let to = File::open(stage.join(&entry.path)).unwrap();
                    assert_eq!(quarantine(&from).unwrap(), quarantine(&to).unwrap());
                    assert_eq!(
                        to.metadata().unwrap().mode() & 0o7777,
                        if entry.directory || entry.executable {
                            0o700
                        } else {
                            0o600
                        }
                    );
                }
                Err(BootstrapBundleCaptureError::new(
                    "testStoppedBeforeTrust",
                    "copy-only negative fixture",
                ))
            },
        );
        assert_eq!(result.err().unwrap().code, "testStoppedBeforeTrust");
        assert!(*seen.borrow());
        assert!(fixture.stages().is_empty());
        assert_eq!(
            inspect_bootstrap_tree(&fixture.source).unwrap(),
            source_tree
        );
    }
    #[test]
    fn unknown_or_replaced_tree_members_leave_the_entire_stage_untouched() {
        for scenario in [
            "unknown",
            "replacedFile",
            "replacedDirectory",
            "hardLinkedFile",
            "lostRegistry",
        ] {
            let fixture = Fixture::new();
            let retained = RefCell::new(PathBuf::new());
            let result = BootstrapBundleCapture::capture_with_checkpoint(
                &fixture.registry,
                &fixture.source,
                |_, stage| {
                    *retained.borrow_mut() = stage.to_owned();
                    match scenario {
                        "unknown" => {
                            fs::write(stage.join("Contents/Nested/unknown"), b"foreign").unwrap();
                        }
                        "replacedFile" => {
                            fs::rename(
                                stage.join("Contents/Nested/payload"),
                                fixture.root.join("retained-original-file"),
                            )
                            .unwrap();
                            fs::write(stage.join("Contents/Nested/payload"), b"replacement")
                                .unwrap();
                            fs::set_permissions(
                                stage.join("Contents/Nested/payload"),
                                fs::Permissions::from_mode(0o600),
                            )
                            .unwrap();
                        }
                        "replacedDirectory" => {
                            fs::rename(
                                stage.join("Contents/Nested"),
                                fixture.root.join("retained-original-directory"),
                            )
                            .unwrap();
                            fs::DirBuilder::new()
                                .mode(0o700)
                                .create(stage.join("Contents/Nested"))
                                .unwrap();
                        }
                        "hardLinkedFile" => {
                            fs::hard_link(
                                stage.join("Contents/Nested/payload"),
                                fixture.root.join("retained-link"),
                            )
                            .unwrap();
                        }
                        "lostRegistry" => {
                            let moved = fixture.root.join("retained-registry");
                            fs::rename(&fixture.registry, &moved).unwrap();
                            *retained.borrow_mut() = moved.join(stage.file_name().unwrap());
                            fs::DirBuilder::new()
                                .mode(0o700)
                                .create(&fixture.registry)
                                .unwrap();
                        }
                        _ => unreachable!(),
                    }
                    Err(changed())
                },
            );
            assert!(result.is_err());
            let stage = retained.borrow();
            assert_eq!(
                fs::read(stage.join("Contents/exec")).unwrap(),
                b"unsigned test executable"
            );
            assert!(stage.join("Contents/Info.plist").is_file());
        }
    }
    #[test]
    fn changed_source_is_rejected_and_only_its_new_stage_is_cleaned() {
        let fixture = Fixture::new();
        let foreign = fixture.registry.join(".staging-existing.app");
        fs::DirBuilder::new().mode(0o700).create(&foreign).unwrap();
        fs::write(foreign.join("keep"), b"untouched").unwrap();
        let result = BootstrapBundleCapture::capture_with_checkpoint(
            &fixture.registry,
            &fixture.source,
            |_, _| {
                fs::write(
                    fixture.source.join("Contents/Nested/payload"),
                    b"changed source",
                )
                .unwrap();
                Ok(())
            },
        );
        assert_eq!(result.err().unwrap().code, "fileIdentityChanged");
        assert_eq!(fixture.stages(), vec![foreign.clone()]);
        assert_eq!(fs::read(foreign.join("keep")).unwrap(), b"untouched");
    }
    #[test]
    fn invalid_version_wins_over_the_same_bundles_invalid_signature() {
        for plist in [
            "<plist><array/></plist>",
            "<plist><dict><key>CFBundleShortVersionString</key><integer>1</integer></dict></plist>",
            "<plist><dict><key>CFBundleShortVersionString</key><string></string></dict></plist>",
        ] {
            let fixture = Fixture::new();
            fs::write(fixture.source.join("Contents/Info.plist"), plist).unwrap();
            assert_eq!(
                BootstrapBundleCapture::capture(&fixture.registry, &fixture.source)
                    .err()
                    .unwrap()
                    .code,
                "invalidInput"
            );
            assert!(fixture.stages().is_empty());
        }
    }
    #[test]
    #[ignore = "requires the explicitly authorized real native Bundle source"]
    fn native_publication_faults_retain_all_uncertain_namespaces() {
        let source = PathBuf::from(
            std::env::var_os("ARKDECK_BUNDLE_CAPTURE_NATIVE_SOURCE").expect("real native source"),
        );
        let before = inspect_bootstrap_tree(&source).unwrap();
        let digest = "a5c9e37fa11f07cdfcdbfa5c8620683102597e3c96c1812bd1bc917b79e0fde5";
        for scenario in [
            "beforeRename",
            "afterRename",
            "renameErrorBeforeEffect",
            "renameErrorAfterEffect",
        ] {
            let fixture = Fixture::new();
            let mut capture = BootstrapBundleCapture::capture(&fixture.registry, &source).unwrap();
            let stage = capture.path().to_owned();
            let destination = fixture.registry.join(format!("bundle-{digest}.app"));
            let result = if scenario.starts_with("renameError") {
                capture.publish_with_operation(
                    digest,
                    |_| Ok(()),
                    |parent, from, to| {
                        if scenario == "renameErrorAfterEffect" {
                            // Test-only ambiguous syscall boundary, after a real
                            // no-replace publication of this fresh native capture.
                            assert_eq!(
                                unsafe {
                                    libc::renameatx_np(
                                        parent.as_raw_fd(),
                                        from.as_ptr(),
                                        parent.as_raw_fd(),
                                        to.as_ptr(),
                                        libc::RENAME_EXCL,
                                    )
                                },
                                0
                            );
                        }
                        Err(io::Error::from_raw_os_error(libc::EIO))
                    },
                )
            } else {
                capture.publish_with_checkpoint(digest, |phase| {
                    if phase == scenario {
                        Err(changed())
                    } else {
                        Ok(())
                    }
                })
            };
            if scenario == "beforeRename" {
                assert!(matches!(
                    result,
                    Err(BootstrapBundlePublishError::BeforePublication(_))
                ));
                drop(capture);
                assert!(!stage.exists());
                assert!(!destination.exists());
            } else {
                assert!(matches!(
                    result,
                    Err(BootstrapBundlePublishError::OutcomeUnknown(_))
                ));
                assert!(capture.publish(digest).is_err());
                drop(capture);
                let retained = if scenario == "renameErrorBeforeEffect" {
                    &stage
                } else {
                    &destination
                };
                assert_eq!(
                    inspect_bootstrap_tree(retained).unwrap().entries,
                    before.entries
                );
                println!(
                    "nativePublicationFault={scenario} retained={}",
                    retained.display()
                );
            }
        }
        assert_eq!(inspect_bootstrap_tree(&source).unwrap(), before);
    }
}
