//! A single Bootstrap HDC capture owns only its freshly created staging directory.
//! Source descriptors remain held through inspection and immutable publication.
//! No source is executed, and no existing content or Session is ever removed.
use crate::{BootstrapTree, inspect_bootstrap_tree, random_bytes};
use sha2::{Digest, Sha256};
use std::{
    ffi::{CStr, CString},
    fmt,
    fs::{File, Metadata},
    io::{self, Write},
    os::{
        fd::{AsRawFd, FromRawFd},
        unix::fs::{FileExt, MetadataExt},
    },
    path::{Path, PathBuf},
};

const MAX_BYTES: u64 = 256 * 1024 * 1024;
const MAX_LIBRARY_BYTES: u64 = 32 * 1024 * 1024;
const MAX_QUARANTINE_BYTES: usize = 16 * 1024;
const USB: &str = "libusb_shared.dylib";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BootstrapToolCaptureError {
    pub code: &'static str,
    pub message: &'static str,
}
impl BootstrapToolCaptureError {
    pub fn new(code: &'static str, message: &'static str) -> Self {
        Self { code, message }
    }
}
impl fmt::Display for BootstrapToolCaptureError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}: {}", self.code, self.message)
    }
}
impl std::error::Error for BootstrapToolCaptureError {}
type Result<T> = std::result::Result<T, BootstrapToolCaptureError>;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BootstrapToolPublication {
    Published(PathBuf),
    /// The existing destination was neither opened for writing nor removed.
    /// The registry owner must independently verify its immutable content.
    AlreadyExists(PathBuf),
}
#[derive(Debug)]
pub enum BootstrapToolPublishError {
    BeforePublication(BootstrapToolCaptureError),
    OutcomeUnknown(BootstrapToolCaptureError),
}
impl fmt::Display for BootstrapToolPublishError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::BeforePublication(e) => write!(f, "{e}"),
            Self::OutcomeUnknown(e) => write!(f, "outcomeUnknown: {e}"),
        }
    }
}
impl std::error::Error for BootstrapToolPublishError {}

fn changed() -> BootstrapToolCaptureError {
    BootstrapToolCaptureError::new(
        "fileIdentityChanged",
        "Bootstrap tool source or staging identity changed",
    )
}
fn invalid() -> BootstrapToolCaptureError {
    BootstrapToolCaptureError::new(
        "invalidInput",
        "HDC capture requires bounded regular native files and local paths",
    )
}
fn io_failure(_: io::Error) -> BootstrapToolCaptureError {
    BootstrapToolCaptureError::new(
        "ioFailure",
        "Bootstrap tool capture could not complete its local I/O",
    )
}
fn write_failure(error: io::Error) -> BootstrapToolCaptureError {
    if error.raw_os_error() == Some(libc::ENOSPC) {
        BootstrapToolCaptureError::new(
            "quotaExceeded",
            "Bootstrap tool capture exhausted local storage",
        )
    } else {
        io_failure(error)
    }
}
fn bounded() -> BootstrapToolCaptureError {
    BootstrapToolCaptureError::new(
        "inputTooLarge",
        "HDC and its fixed sibling exceed the byte bound",
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
    // SAFETY: the first call measures a descriptor-bound xattr without a buffer.
    let size = unsafe {
        libc::fgetxattr(
            file.as_raw_fd(),
            c"com.apple.quarantine".as_ptr(),
            std::ptr::null_mut(),
            0,
            0,
            0,
        )
    };
    if size < 0 && io::Error::last_os_error().raw_os_error() == Some(libc::ENOATTR) {
        return Ok(None);
    }
    if size < 0 || size as usize > MAX_QUARANTINE_BYTES {
        return Err(changed());
    }
    let mut value = vec![0; size as usize];
    // SAFETY: the writable buffer is exactly the measured bounded size.
    let actual = unsafe {
        libc::fgetxattr(
            file.as_raw_fd(),
            c"com.apple.quarantine".as_ptr(),
            value.as_mut_ptr().cast(),
            value.len(),
            0,
            0,
        )
    };
    if actual != size {
        return Err(changed());
    }
    Ok(Some(value))
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
fn entry_names(directory: &File) -> Result<Vec<String>> {
    let fresh = open_at(directory, ".", libc::O_RDONLY | libc::O_DIRECTORY).map_err(io_failure)?;
    use std::os::fd::IntoRawFd;
    let fd = fresh.into_raw_fd();
    // SAFETY: fdopendir takes ownership on success; failure retains ownership.
    let raw = unsafe { libc::fdopendir(fd) };
    if raw.is_null() {
        unsafe {
            libc::close(fd);
        }
        return Err(io_failure(io::Error::last_os_error()));
    }
    struct Close(*mut libc::DIR);
    impl Drop for Close {
        fn drop(&mut self) {
            unsafe {
                libc::closedir(self.0);
            }
        }
    }
    let _close = Close(raw);
    let mut result = Vec::new();
    loop {
        unsafe {
            *libc::__error() = 0;
        }
        let entry = unsafe { libc::readdir(raw) };
        if entry.is_null() {
            if unsafe { *libc::__error() } != 0 {
                return Err(io_failure(io::Error::last_os_error()));
            }
            break;
        }
        let name = unsafe { CStr::from_ptr((*entry).d_name.as_ptr()) }
            .to_str()
            .map_err(|_| changed())?;
        if matches!(name, "." | "..") {
            continue;
        }
        if result.len() >= 2 {
            return Err(changed());
        }
        result.push(name.to_owned());
    }
    result.sort();
    Ok(result)
}

struct Source {
    file: File,
    name: String,
    identity: Identity,
    sha256: String,
    quarantine: Option<Vec<u8>>,
}
struct CreatedEntry {
    file: File,
    name: String,
    inode: Metadata,
}

pub struct BootstrapToolCapture {
    registry: File,
    registry_path: PathBuf,
    registry_identity: Metadata,
    stage: File,
    stage_name: String,
    stage_identity: Metadata,
    path: PathBuf,
    source_parent: File,
    source_parent_path: PathBuf,
    sources: Vec<Source>,
    entries: Vec<CreatedEntry>,
    tree: Option<BootstrapTree>,
    published: bool,
}
impl BootstrapToolCapture {
    /// The callback reads held source descriptors only. `library` identifies the
    /// fixed USB sibling; the main result says whether that sibling is required.
    /// The owner uses its existing bounded Mach-O parser and native type policy.
    pub fn capture(
        registry_root: &Path,
        source: &Path,
        inspect_macho: impl Fn(&File, bool) -> Result<bool>,
    ) -> Result<Self> {
        let registry_path = physical_path(registry_root)?;
        let registry = open_directory(&registry_path, true)?;
        let registry_identity = metadata(&registry)?;
        let source = physical_path(source)?;
        let source_parent_path = source.parent().ok_or_else(invalid)?.to_owned();
        let source_name = source
            .file_name()
            .and_then(|v| v.to_str())
            .ok_or_else(invalid)?
            .to_owned();
        component(&source_name)?;
        let source_parent = open_directory(&source_parent_path, false)?;
        let nonce = u128::from_ne_bytes(random_bytes::<16>().map_err(io_failure)?);
        let stage_name = format!(".tool-staging-{nonce:032x}");
        let name = component(&stage_name)?;
        // SAFETY: a fresh random staging child is created under the held registry.
        if unsafe { libc::mkdirat(registry.as_raw_fd(), name.as_ptr(), 0o700) } != 0 {
            return Err(io_failure(io::Error::last_os_error()));
        }
        let stage = open_at(&registry, &stage_name, libc::O_RDONLY | libc::O_DIRECTORY)
            .map_err(io_failure)?;
        let stage_identity = metadata(&stage)?;
        let mut capture = Self {
            path: registry_path.join(&stage_name),
            registry,
            registry_path,
            registry_identity,
            stage,
            stage_name,
            stage_identity,
            source_parent,
            source_parent_path,
            sources: Vec::new(),
            entries: Vec::new(),
            tree: None,
            published: false,
        };
        capture.validate_binding()?;
        let needs_usb = capture.capture_one(&source_name, "hdc", false, &inspect_macho)?;
        if needs_usb {
            capture.capture_one(USB, USB, true, &inspect_macho)?;
        }
        capture.stage.sync_all().map_err(io_failure)?;
        capture.revalidate_source_files()?;
        capture.tree = Some(inspect_bootstrap_tree(&capture.path).map_err(|_| changed())?);
        capture.revalidate_sources()?;
        Ok(capture)
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    fn capture_one(
        &mut self,
        name: &str,
        output_name: &str,
        library: bool,
        inspect: &impl Fn(&File, bool) -> Result<bool>,
    ) -> Result<bool> {
        let source = open_at(&self.source_parent, name, libc::O_RDONLY).map_err(|e| {
            if e.raw_os_error() == Some(libc::ELOOP) {
                changed()
            } else {
                io_failure(e)
            }
        })?;
        let before = metadata(&source)?;
        if !before.is_file()
            || before.nlink() != 1
            || (!library && before.mode() & 0o111 == 0)
            || before.len() == 0
        {
            return Err(invalid());
        }
        if before.len()
            > if library {
                MAX_LIBRARY_BYTES
            } else {
                MAX_BYTES
            }
        {
            return Err(bounded());
        }
        let needs_usb = inspect(&source, library)?;
        let retained: u64 = self.sources.iter().map(|s| s.identity.size).sum();
        if before.len() > MAX_BYTES - retained {
            return Err(bounded());
        }
        if (before.uid() != unsafe { libc::geteuid() } && before.uid() != 0)
            || before.mode() & 0o6022 != 0
        {
            return Err(changed());
        }
        let source_identity: Identity = before.clone().into();
        let attribute = quarantine(&source)?;
        let copy_name = component(output_name)?;
        let mode = if before.mode() & 0o111 != 0 {
            0o700
        } else {
            0o600
        };
        // SAFETY: only this object's newly created stage receives an exclusive file.
        let fd = unsafe {
            libc::openat(
                self.stage.as_raw_fd(),
                copy_name.as_ptr(),
                libc::O_RDWR | libc::O_CREAT | libc::O_EXCL | libc::O_NOFOLLOW | libc::O_CLOEXEC,
                mode,
            )
        };
        if fd < 0 {
            return Err(io_failure(io::Error::last_os_error()));
        }
        let file = unsafe { File::from_raw_fd(fd) };
        let inode = metadata(&file)?;
        self.entries.push(CreatedEntry {
            file,
            name: output_name.to_owned(),
            inode,
        });
        let output = &mut self.entries.last_mut().expect("created entry").file;
        set_quarantine(output, &attribute)?;
        let sha256 = hash_copy(&source, before.len(), Some(output))?;
        output.sync_all().map_err(io_failure)?;
        if identity(&source)? != source_identity || quarantine(&source)? != attribute {
            return Err(changed());
        }
        self.sources.push(Source {
            file: source,
            name: name.to_owned(),
            identity: source_identity,
            sha256,
            quarantine: attribute,
        });
        Ok(needs_usb)
    }

    fn validate_binding(&self) -> Result<()> {
        let registry = open_directory(&self.registry_path, true)?;
        if !same_object(&metadata(&registry)?, &self.registry_identity)
            || !same_object(&metadata(&self.registry)?, &self.registry_identity)
        {
            return Err(changed());
        }
        let name = self
            .path
            .file_name()
            .and_then(|v| v.to_str())
            .ok_or_else(changed)?;
        let stage = open_at(&self.registry, name, libc::O_RDONLY | libc::O_DIRECTORY)
            .map_err(|_| changed())?;
        let current = metadata(&stage)?;
        if !same_object(&current, &self.stage_identity)
            || !same_object(&metadata(&self.stage)?, &self.stage_identity)
            || current.uid() != unsafe { libc::geteuid() }
            || current.mode() & 0o077 != 0
        {
            return Err(changed());
        }
        Ok(())
    }
    fn revalidate_source_files(&self) -> Result<()> {
        let parent = open_directory(&self.source_parent_path, false)?;
        if !same_object(&metadata(&parent)?, &metadata(&self.source_parent)?) {
            return Err(changed());
        }
        for (source, copy) in self.sources.iter().zip(&self.entries) {
            let linked = open_at(&self.source_parent, &source.name, libc::O_RDONLY)
                .map_err(|_| changed())?;
            if identity(&linked)? != source.identity
                || identity(&source.file)? != source.identity
                || hash_copy(&source.file, source.identity.size, None)? != source.sha256
                || quarantine(&source.file)? != source.quarantine
                || identity(&source.file)? != source.identity
            {
                return Err(changed());
            }
            let output = open_at(&self.stage, &copy.name, libc::O_RDONLY).map_err(|_| changed())?;
            if !same_object(&metadata(&output)?, &copy.inode)
                || hash_copy(&output, source.identity.size, None)? != source.sha256
                || quarantine(&output)? != source.quarantine
            {
                return Err(changed());
            }
        }
        Ok(())
    }
    /// Call before and after native signature inspection and before publication.
    pub fn revalidate_sources(&self) -> Result<()> {
        self.validate_binding()?;
        self.revalidate_source_files()?;
        if let Some(tree) = &self.tree
            && inspect_bootstrap_tree(&self.path).map_err(|_| changed())? != *tree
        {
            return Err(changed());
        }
        self.validate_binding()
    }

    pub fn publish(
        &mut self,
        digest: &str,
    ) -> std::result::Result<BootstrapToolPublication, BootstrapToolPublishError> {
        self.publish_with_checkpoint(digest, |_| Ok(()))
    }

    fn publish_with_checkpoint(
        &mut self,
        digest: &str,
        checkpoint: impl Fn(&str) -> Result<()>,
    ) -> std::result::Result<BootstrapToolPublication, BootstrapToolPublishError> {
        use BootstrapToolPublishError::{BeforePublication, OutcomeUnknown};
        if self.published
            || digest.len() != 64
            || !digest
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        {
            return Err(BeforePublication(invalid()));
        }
        self.revalidate_sources().map_err(BeforePublication)?;
        let name = format!("tool-{digest}.hdc");
        let destination = component(&name).map_err(BeforePublication)?;
        let source = component(&self.stage_name).map_err(BeforePublication)?;
        let final_path = self.registry_path.join(&name);
        checkpoint("beforeRename").map_err(BeforePublication)?;
        // SAFETY: both names are bounded immediate children of the held registry.
        // RENAME_EXCL cannot replace any existing destination, including a link.
        if unsafe {
            libc::renameatx_np(
                self.registry.as_raw_fd(),
                source.as_ptr(),
                self.registry.as_raw_fd(),
                destination.as_ptr(),
                libc::RENAME_EXCL,
            )
        } != 0
        {
            let error = io::Error::last_os_error();
            if error.kind() == io::ErrorKind::AlreadyExists {
                self.revalidate_sources().map_err(BeforePublication)?;
                return Ok(BootstrapToolPublication::AlreadyExists(final_path));
            }
            return Err(BeforePublication(io_failure(error)));
        }
        // From this point onward Drop must never remove the published content.
        self.published = true;
        self.path = final_path.clone();
        checkpoint("afterRename").map_err(OutcomeUnknown)?;
        self.registry
            .sync_all()
            .map_err(|e| OutcomeUnknown(io_failure(e)))?;
        self.validate_binding().map_err(OutcomeUnknown)?;
        self.revalidate_source_files().map_err(OutcomeUnknown)?;
        let tree = inspect_bootstrap_tree(&self.path).map_err(|_| OutcomeUnknown(changed()))?;
        if self.tree.as_ref().is_none_or(|before| {
            before.entries != tree.entries || before.byte_count != tree.byte_count
        }) {
            return Err(OutcomeUnknown(changed()));
        }
        self.tree = Some(tree);
        Ok(BootstrapToolPublication::Published(final_path))
    }

    fn cleanup_owned_staging(&self) -> Result<()> {
        if self.published {
            return Ok(());
        }
        self.validate_binding()?;
        let mut expected: Vec<String> = self
            .entries
            .iter()
            .map(|entry| entry.name.clone())
            .collect();
        expected.sort();
        if entry_names(&self.stage)? != expected {
            return Err(changed());
        }
        // Validate every exact created entry before removing any. Unknown or
        // replaced entries leave the complete stage untouched for inspection.
        for entry in &self.entries {
            let file = open_at(&self.stage, &entry.name, libc::O_RDONLY).map_err(|_| changed())?;
            let m = metadata(&file)?;
            if !m.is_file() || m.nlink() != 1 || !same_object(&m, &entry.inode) {
                return Err(changed());
            }
        }
        for entry in &self.entries {
            let name = component(&entry.name)?;
            // SAFETY: this component was created by this capture and revalidated.
            if unsafe { libc::unlinkat(self.stage.as_raw_fd(), name.as_ptr(), 0) } != 0 {
                return Err(io_failure(io::Error::last_os_error()));
            }
        }
        if !entry_names(&self.stage)?.is_empty() {
            return Err(changed());
        }
        self.validate_binding()?;
        let name = component(&self.stage_name)?;
        // SAFETY: remove only the exact empty directory created by this object.
        if unsafe { libc::unlinkat(self.registry.as_raw_fd(), name.as_ptr(), libc::AT_REMOVEDIR) }
            != 0
        {
            return Err(io_failure(io::Error::last_os_error()));
        }
        self.registry.sync_all().map_err(io_failure)
    }
}
impl Drop for BootstrapToolCapture {
    fn drop(&mut self) {
        let _ = self.cleanup_owned_staging();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{fs, os::unix::fs::DirBuilderExt};

    #[test]
    fn interrupted_publication_retains_content_and_never_cleans_a_published_directory() {
        for point in ["beforeRename", "afterRename"] {
            let root = std::env::temp_dir().canonicalize().unwrap().join(format!(
                "arkdeck-tool-publication-{:032x}",
                u128::from_ne_bytes(random_bytes().unwrap())
            ));
            fs::DirBuilder::new().mode(0o700).create(&root).unwrap();
            // Classification is hoststore's responsibility; this platform test
            // copies only the actual native system file, with no trust injected.
            let mut capture =
                BootstrapToolCapture::capture(&root, Path::new("/usr/bin/true"), |_, _| Ok(false))
                    .unwrap();
            let original_stage = capture.path().to_owned();
            let digest = "e".repeat(64);
            let destination = root.join(format!("tool-{digest}.hdc"));
            let result = capture.publish_with_checkpoint(&digest, |at| {
                if at == point {
                    Err(io_failure(io::Error::other(
                        "injected publication interruption",
                    )))
                } else {
                    Ok(())
                }
            });
            if point == "beforeRename" {
                assert!(matches!(
                    result,
                    Err(BootstrapToolPublishError::BeforePublication(_))
                ));
                drop(capture);
                assert!(!original_stage.exists());
                assert!(!destination.exists());
            } else {
                assert!(matches!(
                    result,
                    Err(BootstrapToolPublishError::OutcomeUnknown(_))
                ));
                drop(capture);
                assert!(!original_stage.exists());
                assert_eq!(
                    fs::read(destination.join("hdc")).unwrap(),
                    fs::read("/usr/bin/true").unwrap()
                );
            }
        }
    }
}
