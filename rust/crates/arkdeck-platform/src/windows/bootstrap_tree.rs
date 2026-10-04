//! Bounded, handle-relative inspection and private capture of a Bootstrap
//! content tree on NTFS: the Windows counterparts of `host_bootstrap_tree.rs`
//! and `bootstrap_bundle_capture.rs`.
//!
//! Every entry is opened relative to its held parent, never through a
//! reparse point (a link or junction refuses the tree), and must be owned by
//! the token user or a trusted principal and changeable by nobody else. A
//! file is read to exactly the size it had when opened. The tree's identity
//! is each entry's volume, file id, size, attributes and write and change
//! times; a second inspection must find the same. Mark-of-the-Web is
//! provenance, never identity, so `quarantine_sha256` is always `None`.
//!
//! A capture copies a tree into a fresh private `.staging-<nonce>` directory
//! of the store, checking every byte against the inspected SHA-256, and
//! publishes it under its content name exclusively. Nothing is executed, and
//! no existing content is replaced or removed.
use super::host_fs::{
    self, Access, DIRECTORY, DIRECTORY_WRITE, Descriptor, Kind, READ, Stat, segment,
};
use super::pinned_file::{may_execute, standard_local_path};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::fmt;
use std::fs::File;
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};
use windows_sys::Wdk::Storage::FileSystem::{FILE_CREATE, FILE_OPEN};
use windows_sys::Win32::Storage::FileSystem::DELETE;

const MAX_ENTRIES: usize = 4096;
const MAX_BYTES: u64 = 1_073_741_824;
const MAX_DEPTH: usize = 24;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BootstrapEntry {
    /// The path below the root, `/`-separated; the root itself is `""`.
    pub path: String,
    pub directory: bool,
    pub executable: bool,
    pub quarantine_sha256: Option<String>,
    pub byte_count: u64,
    pub sha256: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Identity {
    volume: u64,
    id: [u8; 16],
    size: u64,
    attributes: u32,
    written: i64,
    changed: i64,
}
impl From<Stat> for Identity {
    fn from(stat: Stat) -> Self {
        Self {
            volume: stat.volume,
            id: stat.id,
            size: stat.size,
            attributes: stat.attributes,
            written: stat.written,
            changed: stat.changed,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BootstrapTree {
    /// The root first, then every entry in byte order of its path.
    pub entries: Vec<BootstrapEntry>,
    pub byte_count: u64,
    identities: BTreeMap<String, Identity>,
}

fn refusal() -> io::Error {
    io::Error::new(
        io::ErrorKind::InvalidData,
        "bootstrap content tree is unsafe, changed or out of bounds",
    )
}

/// The entry is owned by the token user or a trusted principal, and nobody
/// else may change it.
fn guarded(file: &File) -> io::Result<()> {
    if !Access::of(file)?.trusted_write_only() {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "bootstrap content is changeable by another principal",
        ));
    }
    Ok(())
}

fn child(parent: &File, name: &str, kind: Kind) -> io::Result<File> {
    let access = if kind == Kind::Directory {
        DIRECTORY
    } else {
        READ
    };
    host_fs::open_relative(parent, &segment(name)?, access, FILE_OPEN, kind, None)
}

fn hash_exactly(file: &mut File, size: u64) -> io::Result<String> {
    let mut hasher = Sha256::new();
    let mut remaining = size;
    let mut buffer = vec![0u8; 256 * 1024];
    while remaining > 0 {
        let want = usize::try_from(remaining.min(buffer.len() as u64)).map_err(|_| refusal())?;
        let read = file.read(&mut buffer[..want])?;
        if read == 0 {
            return Err(refusal());
        }
        hasher.update(&buffer[..read]);
        remaining -= read as u64;
    }
    if file.read(&mut [0u8; 1])? != 0 {
        return Err(refusal());
    }
    Ok(format!("{:x}", hasher.finalize()))
}

struct Walk {
    entries: Vec<BootstrapEntry>,
    identities: BTreeMap<String, Identity>,
    byte_count: u64,
}

impl Walk {
    fn directory(&mut self, held: &File, prefix: &str, depth: usize) -> io::Result<()> {
        if depth > MAX_DEPTH {
            return Err(refusal());
        }
        let before = Stat::of(held)?;
        let mut names = host_fs::names(held, MAX_ENTRIES + 1)?;
        names.sort();
        for name in names {
            if self.entries.len() >= MAX_ENTRIES {
                return Err(refusal());
            }
            let path = if prefix.is_empty() {
                name.clone()
            } else {
                format!("{prefix}/{name}")
            };
            let inspected = host_fs::inspect_relative(held, &segment(&name)?)?;
            let stat = Stat::of(&inspected)?;
            if stat.directory() {
                let directory = child(held, &name, Kind::Directory)?;
                let opened = Stat::of(&directory)?;
                if !opened.same_file(&stat) {
                    return Err(refusal());
                }
                guarded(&directory)?;
                self.identities.insert(path.clone(), opened.into());
                self.entries.push(BootstrapEntry {
                    path: path.clone(),
                    directory: true,
                    executable: false,
                    quarantine_sha256: None,
                    byte_count: 0,
                    sha256: None,
                });
                self.directory(&directory, &path, depth + 1)?;
                if Identity::from(Stat::of(&directory)?) != Identity::from(opened) {
                    return Err(refusal());
                }
            } else if stat.regular() {
                let mut file = child(held, &name, Kind::NonDirectory)?;
                let opened = Stat::of(&file)?;
                if !opened.same_file(&stat) || opened.links != 1 {
                    return Err(refusal());
                }
                guarded(&file)?;
                self.byte_count = self
                    .byte_count
                    .checked_add(opened.size)
                    .filter(|total| *total <= MAX_BYTES)
                    .ok_or_else(refusal)?;
                let sha256 = hash_exactly(&mut file, opened.size)?;
                if Identity::from(Stat::of(&file)?) != Identity::from(opened) {
                    return Err(refusal());
                }
                self.identities.insert(path.clone(), opened.into());
                self.entries.push(BootstrapEntry {
                    path,
                    directory: false,
                    executable: may_execute(&file, &name),
                    quarantine_sha256: None,
                    byte_count: opened.size,
                    sha256: Some(sha256),
                });
            } else {
                // A reparse point (link, junction, mount point) of any kind.
                return Err(refusal());
            }
        }
        if Identity::from(Stat::of(held)?) != Identity::from(before) {
            return Err(refusal());
        }
        Ok(())
    }
}

fn open_root(path: &Path) -> io::Result<File> {
    if !standard_local_path(path) {
        return Err(refusal());
    }
    let root = host_fs::open_directory_path(path, DIRECTORY)?;
    host_fs::canonical(path, &root)?;
    if !Stat::of(&root)?.directory() {
        return Err(refusal());
    }
    Ok(root)
}

/// Inspect the directory at the local absolute `path`, as the disk spells
/// it: every entry, its SHA-256 and whether it may be run.
pub fn inspect_bootstrap_tree(path: &Path) -> io::Result<BootstrapTree> {
    let root = open_root(path)?;
    guarded(&root)?;
    let stat = Stat::of(&root)?;
    let mut walk = Walk {
        entries: vec![BootstrapEntry {
            path: String::new(),
            directory: true,
            executable: false,
            quarantine_sha256: None,
            byte_count: 0,
            sha256: None,
        }],
        identities: BTreeMap::from([(String::new(), stat.into())]),
        byte_count: 0,
    };
    walk.directory(&root, "", 1)?;
    walk.entries[1..].sort_by(|a, b| a.path.as_bytes().cmp(b.path.as_bytes()));
    Ok(BootstrapTree {
        entries: walk.entries,
        byte_count: walk.byte_count,
        identities: walk.identities,
    })
}

impl BootstrapTree {
    /// Reopen a regular file of this tree by its relative `/`-separated path,
    /// checking each held component against this snapshot.
    pub fn open_relative_file(&self, root: &Path, relative: &str) -> io::Result<File> {
        let components: Vec<&str> = relative.split('/').collect();
        if relative.len() > MAX_DEPTH * 256 || components.len() > MAX_DEPTH {
            return Err(refusal());
        }
        let mut held = open_root(root)?;
        if Some(&Identity::from(Stat::of(&held)?)) != self.identities.get("") {
            return Err(refusal());
        }
        let mut prefix = String::new();
        for (index, component) in components.iter().enumerate() {
            if !prefix.is_empty() {
                prefix.push('/');
            }
            prefix.push_str(component);
            let last = index + 1 == components.len();
            held = child(
                &held,
                component,
                if last {
                    Kind::NonDirectory
                } else {
                    Kind::Directory
                },
            )?;
            if Some(&Identity::from(Stat::of(&held)?)) != self.identities.get(&prefix) {
                return Err(refusal());
            }
        }
        Ok(held)
    }

    /// Reopen one inspected immediate regular child.
    pub fn open_immediate_file(&self, root: &Path, name: &str) -> io::Result<File> {
        if name.contains('/') {
            return Err(refusal());
        }
        self.open_relative_file(root, name)
    }

    /// The tree's entries without their identities: what two copies of the
    /// same content share.
    fn content(&self) -> &[BootstrapEntry] {
        &self.entries
    }
}

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

/// An HDC capture's answers: the shapes of a Bundle capture's, which macOS
/// declares as separate types of the same shape.
pub type BootstrapToolCaptureError = BootstrapBundleCaptureError;
pub type BootstrapToolPublication = BootstrapBundlePublication;
pub type BootstrapToolPublishError = BootstrapBundlePublishError;

/// What a capture kind says when its source or staging changed, and when
/// its local I/O failed.
#[derive(Clone, Copy)]
struct Labels {
    changed: &'static str,
    io: &'static str,
}
impl Labels {
    fn changed(self) -> BootstrapBundleCaptureError {
        BootstrapBundleCaptureError::new("fileIdentityChanged", self.changed)
    }
    fn io(self) -> BootstrapBundleCaptureError {
        BootstrapBundleCaptureError::new("ioFailure", self.io)
    }
}
const BUNDLE: Labels = Labels {
    changed: "Bootstrap bundle source or staging identity changed",
    io: "Bootstrap bundle capture could not complete its local I/O",
};
const TOOL: Labels = Labels {
    changed: "Bootstrap tool source or staging identity changed",
    io: "Bootstrap tool capture could not complete its local I/O",
};

fn source_refused(error: io::Error) -> BootstrapBundleCaptureError {
    match error.kind() {
        io::ErrorKind::NotFound => BootstrapBundleCaptureError::new(
            "fileIdentityChanged",
            "the Bundle source is absent or not a local directory",
        ),
        io::ErrorKind::PermissionDenied => BootstrapBundleCaptureError::new(
            "admissionDenied",
            "the Bundle source is changeable by another principal",
        ),
        _ => BootstrapBundleCaptureError::new(
            "invalidInput",
            "the Bundle source is not a bounded tree of directories and regular files",
        ),
    }
}

/// A fresh private staging directory of the store: what one capture created
/// there, removed when the capture is dropped unpublished, and its exclusive
/// publication under a content name.
struct Stage {
    labels: Labels,
    store: File,
    staging: File,
    path: PathBuf,
    /// Every entry created below the staging directory, in creation order,
    /// with the identity it was created with.
    created: Vec<(String, bool, Stat)>,
    /// The staging directory's own identity.
    staged: Stat,
    published: bool,
    publication_uncertain: bool,
}

impl Stage {
    fn new(
        labels: Labels,
        registry_root: &Path,
        prefix: &str,
    ) -> Result<Self, BootstrapBundleCaptureError> {
        let io = |_| labels.io();
        let store = host_fs::open_directory_path(registry_root, DIRECTORY_WRITE).map_err(io)?;
        let nonce: String = crate::random_bytes::<16>()
            .map_err(io)?
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect();
        let name = format!("{prefix}{nonce}");
        let staging = host_fs::open_relative(
            &store,
            &segment(&name).map_err(io)?,
            DIRECTORY_WRITE | DELETE,
            FILE_CREATE,
            Kind::Directory,
            Some(&Descriptor::private(true).map_err(io)?),
        )
        .map_err(io)?;
        let staged = Stat::of(&staging).map_err(io)?;
        Ok(Self {
            labels,
            store,
            staging,
            path: registry_root.join(&name),
            created: Vec::new(),
            staged,
            published: false,
            publication_uncertain: false,
        })
    }

    fn parent<'a>(
        &'a self,
        directories: &'a BTreeMap<String, File>,
        relative: &'a str,
    ) -> Result<(&'a File, &'a str), BootstrapBundleCaptureError> {
        let (parent_path, leaf) = relative.rsplit_once('/').unwrap_or(("", relative));
        let parent = if parent_path.is_empty() {
            &self.staging
        } else {
            directories
                .get(parent_path)
                .ok_or_else(|| self.labels.changed())?
        };
        Ok((parent, leaf))
    }

    /// Create the private directory `relative`, its parent created before.
    fn directory(
        &mut self,
        directories: &mut BTreeMap<String, File>,
        relative: &str,
    ) -> Result<(), BootstrapBundleCaptureError> {
        let labels = self.labels;
        let io = |_| labels.io();
        let (parent, leaf) = self.parent(directories, relative)?;
        let created = host_fs::open_relative(
            parent,
            &segment(leaf).map_err(io)?,
            DIRECTORY_WRITE,
            FILE_CREATE,
            Kind::Directory,
            Some(&Descriptor::private(true).map_err(io)?),
        )
        .map_err(io)?;
        let stat = Stat::of(&created).map_err(io)?;
        self.created.push((relative.to_owned(), true, stat));
        directories.insert(relative.to_owned(), created);
        Ok(())
    }

    /// Create the private file `relative` holding exactly `size` bytes of
    /// `from`, read from its start; the copied bytes' SHA-256.
    fn file(
        &mut self,
        directories: &BTreeMap<String, File>,
        relative: &str,
        from: &mut File,
        size: u64,
    ) -> Result<String, BootstrapBundleCaptureError> {
        use std::io::{Seek, SeekFrom};
        let labels = self.labels;
        let io = |_| labels.io();
        let (parent, leaf) = self.parent(directories, relative)?;
        let mut to = host_fs::open_relative(
            parent,
            &segment(leaf).map_err(io)?,
            host_fs::WRITE,
            FILE_CREATE,
            Kind::NonDirectory,
            Some(&Descriptor::private(false).map_err(io)?),
        )
        .map_err(io)?;
        let stat = Stat::of(&to).map_err(io)?;
        self.created.push((relative.to_owned(), false, stat));
        from.seek(SeekFrom::Start(0))
            .map_err(|_| labels.changed())?;
        let mut hasher = Sha256::new();
        let mut remaining = size;
        let mut buffer = vec![0u8; 256 * 1024];
        while remaining > 0 {
            let want = usize::try_from(remaining.min(buffer.len() as u64))
                .map_err(|_| labels.changed())?;
            let read = from
                .read(&mut buffer[..want])
                .map_err(|_| labels.changed())?;
            if read == 0 {
                return Err(labels.changed());
            }
            hasher.update(&buffer[..read]);
            to.write_all(&buffer[..read]).map_err(io)?;
            remaining -= read as u64;
        }
        host_fs::flush(&to).map_err(io)?;
        Ok(format!("{:x}", hasher.finalize()))
    }

    fn flush(
        &self,
        directories: &BTreeMap<String, File>,
    ) -> Result<(), BootstrapBundleCaptureError> {
        for directory in directories.values() {
            host_fs::flush_directory(directory).map_err(|_| self.labels.io())?;
        }
        host_fs::flush_directory(&self.staging).map_err(|_| self.labels.io())
    }

    /// Open one created entry below the staging directory for its removal,
    /// every component held relative to its parent.
    fn open_created(&self, path: &str, directory: bool) -> io::Result<File> {
        let components: Vec<&str> = path.split('/').collect();
        let mut held: Option<File> = None;
        for (index, component) in components.iter().enumerate() {
            let last = index + 1 == components.len();
            let parent = held.as_ref().unwrap_or(&self.staging);
            let (access, kind) = if !last {
                (DIRECTORY, Kind::Directory)
            } else if directory {
                (DIRECTORY | DELETE, Kind::Directory)
            } else {
                (READ | DELETE, Kind::NonDirectory)
            };
            held = Some(host_fs::open_relative(
                parent,
                &segment(component)?,
                access,
                FILE_OPEN,
                kind,
                None,
            )?);
        }
        held.ok_or_else(refusal)
    }

    /// Remove what this stage created, deepest first, each entry only if it
    /// is still the one created; then the staging directory itself, only if
    /// it is empty. Anything else is left for inspection.
    fn cleanup(&self) -> io::Result<()> {
        if self.published || self.publication_uncertain {
            return Ok(());
        }
        for (path, directory, stat) in self.created.iter().rev() {
            let entry = self.open_created(path, *directory)?;
            if !Stat::of(&entry)?.same_file(stat) {
                return Err(refusal());
            }
            if *directory && !host_fs::names(&entry, 1)?.is_empty() {
                return Err(refusal());
            }
            host_fs::delete(&entry)?;
        }
        if !Stat::of(&self.staging)?.same_file(&self.staged)
            || !host_fs::names(&self.staging, 1)?.is_empty()
        {
            return Err(refusal());
        }
        host_fs::delete(&self.staging)
    }

    /// Publish the staging copy as the store's `<name>` exclusively; an
    /// existing entry of that name is left as it is (and this stage is
    /// removed when it is dropped).
    fn publish_as(
        &mut self,
        name: &str,
    ) -> Result<BootstrapBundlePublication, BootstrapBundlePublishError> {
        use BootstrapBundlePublishError::{BeforePublication, OutcomeUnknown};
        let labels = self.labels;
        let target = segment(name).map_err(|_| BeforePublication(labels.io()))?;
        let destination = self
            .path
            .parent()
            .map(|parent| parent.join(name))
            .ok_or_else(|| BeforePublication(labels.changed()))?;
        match host_fs::inspect_relative(&self.store, &target) {
            Ok(_) => return Ok(BootstrapBundlePublication::AlreadyExists(destination)),
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(_) => return Err(BeforePublication(labels.io())),
        }
        if let Err(error) = host_fs::rename(&self.staging, &self.store, &target, false) {
            if error.kind() == io::ErrorKind::AlreadyExists {
                return Err(BeforePublication(labels.changed()));
            }
            self.publication_uncertain = true;
            return Err(OutcomeUnknown(labels.io()));
        }
        self.published = true;
        host_fs::flush_directory(&self.store).map_err(|_| OutcomeUnknown(labels.io()))?;
        self.path = destination.clone();
        Ok(BootstrapBundlePublication::Published(destination))
    }
}

impl Drop for Stage {
    fn drop(&mut self) {
        let _ = self.cleanup();
    }
}

/// A Bundle capture on NTFS: the source tree held as inspected, and the
/// private staging copy of it in the store.
pub struct BootstrapBundleCapture {
    source_path: PathBuf,
    source: BootstrapTree,
    stage: Stage,
}

impl BootstrapBundleCapture {
    /// Copy the tree at `source` into a fresh private staging directory of
    /// the store at `registry_root`, every file checked against its
    /// inspected SHA-256. A capture that fails, or is dropped before its
    /// publication, removes exactly what it created.
    pub fn capture(
        registry_root: &Path,
        source: &Path,
    ) -> Result<Self, BootstrapBundleCaptureError> {
        let tree = inspect_bootstrap_tree(source).map_err(source_refused)?;
        let mut stage = Stage::new(BUNDLE, registry_root, ".staging-")?;
        let mut directories = BTreeMap::new();
        for entry in tree.entries.iter().skip(1) {
            if entry.directory {
                stage.directory(&mut directories, &entry.path)?;
            } else {
                let mut from = tree
                    .open_relative_file(source, &entry.path)
                    .map_err(|_| BUNDLE.changed())?;
                let copied = stage.file(&directories, &entry.path, &mut from, entry.byte_count)?;
                if entry.sha256.as_deref() != Some(copied.as_str()) {
                    return Err(BUNDLE.changed());
                }
            }
        }
        stage.flush(&directories)?;
        Ok(Self {
            source_path: source.to_path_buf(),
            source: tree,
            stage,
        })
    }

    /// The staging copy's path, for the owner's native checks.
    pub fn path(&self) -> &Path {
        &self.stage.path
    }

    /// The source still exactly as captured, and the staging copy the same
    /// content.
    pub fn revalidate_sources(&self) -> Result<(), BootstrapBundleCaptureError> {
        let source = inspect_bootstrap_tree(&self.source_path).map_err(|_| BUNDLE.changed())?;
        if source != self.source {
            return Err(BUNDLE.changed());
        }
        let staged = inspect_bootstrap_tree(&self.stage.path).map_err(|_| BUNDLE.changed())?;
        let same = staged.content().len() == self.source.content().len()
            && staged
                .content()
                .iter()
                .zip(self.source.content())
                .all(|(a, b)| {
                    a.path == b.path
                        && a.directory == b.directory
                        && a.byte_count == b.byte_count
                        && a.sha256 == b.sha256
                });
        if !same {
            return Err(BUNDLE.changed());
        }
        Ok(())
    }

    /// Publish the staging copy as the store's `bundle-<digest>.rc`, the
    /// Windows counterpart of the macOS `bundle-<digest>.app`.
    pub fn publish(
        &mut self,
        digest: &str,
    ) -> Result<BootstrapBundlePublication, BootstrapBundlePublishError> {
        self.publish_as(&format!("bundle-{digest}.rc"))
    }

    /// Publish the staging copy as the store's `<name>` exclusively; an
    /// existing entry of that name is left as it is (and this capture's
    /// staging copy is removed when it is dropped).
    pub fn publish_as(
        &mut self,
        name: &str,
    ) -> Result<BootstrapBundlePublication, BootstrapBundlePublishError> {
        self.stage.publish_as(name)
    }
}

const HDC: &str = "hdc.exe";
const USB: &str = "libusb_shared.dll";
const MAX_TOOL_BYTES: u64 = 256 * 1024 * 1024;
const MAX_TOOL_LIBRARY_BYTES: u64 = 32 * 1024 * 1024;

fn tool_invalid() -> BootstrapToolCaptureError {
    BootstrapToolCaptureError::new(
        "invalidInput",
        "HDC capture requires bounded regular native files and local paths",
    )
}
fn tool_bounded() -> BootstrapToolCaptureError {
    BootstrapToolCaptureError::new(
        "inputTooLarge",
        "HDC and its fixed sibling exceed the byte bound",
    )
}

/// One source file of an HDC capture as it was copied.
struct ToolSource {
    name: String,
    identity: Identity,
    sha256: String,
}

/// An HDC capture on NTFS, the counterpart of the macOS one: the program at
/// the source path and, when it imports it, the fixed sibling
/// `libusb_shared.dll` of the same directory, each opened relative to the
/// held directory, never through a reparse point, owned by the user or a
/// trusted principal and changeable by nobody else; copied as `hdc.exe` and
/// `libusb_shared.dll` into a private `.tool-staging-<nonce>` and published
/// as `tool-<digest>.hdc`. Nothing is executed.
pub struct BootstrapToolCapture {
    directory_path: PathBuf,
    directory: Identity,
    sources: Vec<ToolSource>,
    byte_count: u64,
    /// The staging copy as captured, once it is complete.
    tree: Option<BootstrapTree>,
    stage: Stage,
}

impl BootstrapToolCapture {
    /// The callback reads held source files only. `library` identifies the
    /// fixed USB sibling; the program's result says whether that sibling is
    /// required. The owner uses its bounded PE parser.
    pub fn capture(
        registry_root: &Path,
        source: &Path,
        inspect_image: impl Fn(&File, bool) -> Result<bool, BootstrapToolCaptureError>,
    ) -> Result<Self, BootstrapToolCaptureError> {
        let name = source
            .file_name()
            .and_then(|name| name.to_str())
            .ok_or_else(tool_invalid)?
            .to_owned();
        segment(&name).map_err(|_| tool_invalid())?;
        let directory_path = source.parent().ok_or_else(tool_invalid)?.to_path_buf();
        let directory = open_root(&directory_path).map_err(|_| tool_invalid())?;
        guarded(&directory).map_err(|_| TOOL.changed())?;
        let mut capture = Self {
            directory: Stat::of(&directory).map_err(|_| TOOL.io())?.into(),
            directory_path,
            sources: Vec::new(),
            byte_count: 0,
            tree: None,
            stage: Stage::new(TOOL, registry_root, ".tool-staging-")?,
        };
        if capture.capture_one(&directory, &name, HDC, false, &inspect_image)? {
            capture.capture_one(&directory, USB, USB, true, &inspect_image)?;
        }
        capture.stage.flush(&BTreeMap::new())?;
        capture.revalidate_source_files()?;
        capture.tree =
            Some(inspect_bootstrap_tree(&capture.stage.path).map_err(|_| TOOL.changed())?);
        capture.revalidate_sources()?;
        Ok(capture)
    }

    fn capture_one(
        &mut self,
        directory: &File,
        name: &str,
        output: &str,
        library: bool,
        inspect: &impl Fn(&File, bool) -> Result<bool, BootstrapToolCaptureError>,
    ) -> Result<bool, BootstrapToolCaptureError> {
        let mut source = child(directory, name, Kind::NonDirectory).map_err(|error| {
            if error.kind() == io::ErrorKind::NotFound {
                TOOL.io()
            } else {
                TOOL.changed()
            }
        })?;
        let before = Stat::of(&source).map_err(|_| TOOL.io())?;
        if !before.regular() || before.links != 1 || before.size == 0 {
            return Err(tool_invalid());
        }
        let maximum = if library {
            MAX_TOOL_LIBRARY_BYTES
        } else {
            MAX_TOOL_BYTES
        };
        if before.size > maximum {
            return Err(tool_bounded());
        }
        let needs_usb = inspect(&source, library)?;
        if before.size > MAX_TOOL_BYTES - self.byte_count {
            return Err(tool_bounded());
        }
        guarded(&source).map_err(|_| TOOL.changed())?;
        let sha256 = self
            .stage
            .file(&BTreeMap::new(), output, &mut source, before.size)?;
        if Identity::from(Stat::of(&source).map_err(|_| TOOL.io())?) != Identity::from(before) {
            return Err(TOOL.changed());
        }
        self.byte_count += before.size;
        self.sources.push(ToolSource {
            name: name.to_owned(),
            identity: before.into(),
            sha256,
        });
        Ok(needs_usb)
    }

    /// The staging copy's path, for the owner's native checks.
    pub fn path(&self) -> &Path {
        &self.stage.path
    }

    /// Each source file, reopened by name, still the one copied, with the
    /// same bytes.
    fn revalidate_source_files(&self) -> Result<(), BootstrapToolCaptureError> {
        let directory = open_root(&self.directory_path).map_err(|_| TOOL.changed())?;
        if Identity::from(Stat::of(&directory).map_err(|_| TOOL.changed())?) != self.directory {
            return Err(TOOL.changed());
        }
        for source in &self.sources {
            let mut file =
                child(&directory, &source.name, Kind::NonDirectory).map_err(|_| TOOL.changed())?;
            let stat = Stat::of(&file).map_err(|_| TOOL.changed())?;
            if Identity::from(stat) != source.identity
                || hash_exactly(&mut file, stat.size).map_err(|_| TOOL.changed())? != source.sha256
            {
                return Err(TOOL.changed());
            }
        }
        Ok(())
    }

    /// Call before and after the native signature check and before
    /// publication: the sources as copied, and the staging copy exactly as
    /// captured.
    pub fn revalidate_sources(&self) -> Result<(), BootstrapToolCaptureError> {
        self.revalidate_source_files()?;
        if let Some(tree) = &self.tree
            && inspect_bootstrap_tree(&self.stage.path).map_err(|_| TOOL.changed())? != *tree
        {
            return Err(TOOL.changed());
        }
        Ok(())
    }

    /// Publish the staging copy as the store's `tool-<digest>.hdc`.
    pub fn publish(
        &mut self,
        digest: &str,
    ) -> Result<BootstrapToolPublication, BootstrapToolPublishError> {
        use BootstrapBundlePublishError::BeforePublication;
        if self.stage.published
            || digest.len() != 64
            || !digest
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        {
            return Err(BeforePublication(tool_invalid()));
        }
        self.revalidate_sources().map_err(BeforePublication)?;
        self.stage.publish_as(&format!("tool-{digest}.hdc"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Scratch(PathBuf);
    impl Scratch {
        fn new(label: &str) -> Self {
            let base = crate::windows::application_support_directory()
                .unwrap()
                .canonicalize()
                .unwrap();
            let base = base.to_str().unwrap();
            let path = PathBuf::from(base.strip_prefix(r"\\?\").unwrap_or(base)).join(format!(
                "arkdeck-test-{label}-{:032x}",
                u128::from_le_bytes(crate::random_bytes().unwrap())
            ));
            crate::create_private_directory(&path).unwrap();
            Self(path)
        }
        fn file(&self, relative: &str, bytes: &[u8]) {
            let path = self.0.join(relative);
            let mut ancestor = self.0.clone();
            for part in Path::new(relative)
                .parent()
                .into_iter()
                .flat_map(Path::iter)
            {
                ancestor.push(part);
                if !ancestor.exists() {
                    crate::create_private_directory(&ancestor).unwrap();
                }
            }
            let _ = std::fs::remove_file(&path);
            crate::create_private_file(&path)
                .unwrap()
                .write_all(bytes)
                .unwrap();
        }
    }
    impl Drop for Scratch {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn sha(bytes: &[u8]) -> String {
        format!("{:x}", Sha256::digest(bytes))
    }

    #[test]
    fn a_tree_is_walked_in_path_order_with_every_file_hashed() {
        let scratch = Scratch::new("bootstrap-tree");
        scratch.file(r"source\b.txt", b"bee");
        scratch.file(r"source\a\z.bin", b"zed");
        scratch.file(r"source\a\y.exe", b"MZ fixture");
        let source = scratch.0.join("source");
        let tree = inspect_bootstrap_tree(&source).unwrap();
        let paths: Vec<&str> = tree.entries.iter().map(|e| e.path.as_str()).collect();
        assert_eq!(paths, ["", "a", "a/y.exe", "a/z.bin", "b.txt"]);
        assert_eq!(tree.byte_count, 3 + 3 + 10);
        assert_eq!(
            tree.entries[3].sha256.as_deref(),
            Some(sha(b"zed").as_str())
        );
        assert!(tree.entries.iter().all(|e| e.quarantine_sha256.is_none()));
        // The same tree inspected again is the same snapshot.
        assert_eq!(inspect_bootstrap_tree(&source).unwrap(), tree);
        let mut file = tree.open_relative_file(&source, "a/z.bin").unwrap();
        let mut bytes = Vec::new();
        file.read_to_end(&mut bytes).unwrap();
        assert_eq!(bytes, b"zed");
        assert!(tree.open_relative_file(&source, "a/../b.txt").is_err());
        // A changed file changes the snapshot.
        drop(file);
        scratch.file(r"source\b.txt", b"bee!");
        assert_ne!(inspect_bootstrap_tree(&source).unwrap(), tree);
    }

    #[test]
    fn a_junction_or_a_relative_path_refuses_the_tree() {
        let scratch = Scratch::new("bootstrap-tree-link");
        scratch.file(r"source\a.txt", b"a");
        scratch.file(r"elsewhere\b.txt", b"b");
        assert!(inspect_bootstrap_tree(Path::new(r"relative\source")).is_err());
        let junction = scratch.0.join(r"source\link");
        let status = std::process::Command::new("cmd")
            .args(["/C", "mklink", "/J"])
            .arg(&junction)
            .arg(scratch.0.join("elsewhere"))
            .output()
            .unwrap();
        assert!(status.status.success(), "{status:?}");
        assert!(inspect_bootstrap_tree(&scratch.0.join("source")).is_err());
    }

    #[test]
    fn a_capture_copies_the_tree_privately_and_publishes_it_once() {
        let scratch = Scratch::new("bootstrap-capture");
        scratch.file(r"source\x\one.txt", b"one");
        scratch.file(r"source\two.txt", b"two");
        crate::create_private_directory(&scratch.0.join("store")).unwrap();
        let source = scratch.0.join("source");
        let store = scratch.0.join("store");
        let mut capture = BootstrapBundleCapture::capture(&store, &source).unwrap();
        assert!(
            capture
                .path()
                .file_name()
                .unwrap()
                .to_str()
                .unwrap()
                .starts_with(".staging-")
        );
        capture.revalidate_sources().unwrap();
        assert_eq!(
            capture.publish_as("bundle-fixture.rc").unwrap(),
            BootstrapBundlePublication::Published(store.join("bundle-fixture.rc"))
        );
        let published = inspect_bootstrap_tree(&store.join("bundle-fixture.rc")).unwrap();
        let original = inspect_bootstrap_tree(&source).unwrap();
        assert_eq!(
            published
                .entries
                .iter()
                .map(|e| (&e.path, &e.sha256))
                .collect::<Vec<_>>(),
            original
                .entries
                .iter()
                .map(|e| (&e.path, &e.sha256))
                .collect::<Vec<_>>()
        );
        // A second capture of the same content meets the published one and
        // leaves it as it is.
        let mut again = BootstrapBundleCapture::capture(&store, &source).unwrap();
        assert_eq!(
            again.publish_as("bundle-fixture.rc").unwrap(),
            BootstrapBundlePublication::AlreadyExists(store.join("bundle-fixture.rc"))
        );
        // A source changed after its capture is refused.
        let capture = BootstrapBundleCapture::capture(&store, &source).unwrap();
        scratch.file(r"source\two.txt", b"TWO");
        assert_eq!(
            capture.revalidate_sources().unwrap_err().code,
            "fileIdentityChanged"
        );
        // Every capture that was not published removed what it created when
        // it was dropped: only the published copy is left.
        drop(capture);
        drop(again);
        let mut names: Vec<String> = std::fs::read_dir(&store)
            .unwrap()
            .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        names.sort();
        assert_eq!(names, ["bundle-fixture.rc"]);
    }

    fn store_names(store: &Path) -> Vec<String> {
        let mut names: Vec<String> = std::fs::read_dir(store)
            .unwrap()
            .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        names.sort();
        names
    }

    #[test]
    fn an_hdc_capture_copies_the_program_and_only_an_imported_sibling() {
        let scratch = Scratch::new("tool-capture");
        scratch.file(r"sdk\toolchains\hdc.exe", b"MZ program");
        scratch.file(r"sdk\toolchains\libusb_shared.dll", b"MZ library");
        scratch.file(r"sdk\toolchains\other.dll", b"MZ other");
        crate::create_private_directory(&scratch.0.join("store")).unwrap();
        let store = scratch.0.join("store");
        let hdc = scratch.0.join(r"sdk\toolchains\hdc.exe");
        let digest = "a".repeat(64);
        let seen = std::cell::RefCell::new(Vec::new());

        // The program imports the sibling: both are copied, nothing else.
        let mut capture = BootstrapToolCapture::capture(&store, &hdc, |file, library| {
            let mut bytes = Vec::new();
            (&*file).read_to_end(&mut bytes).unwrap();
            seen.borrow_mut().push((library, bytes));
            Ok(!library)
        })
        .unwrap();
        assert_eq!(
            *seen.borrow(),
            [
                (false, b"MZ program".to_vec()),
                (true, b"MZ library".to_vec())
            ]
        );
        assert!(
            capture
                .path()
                .file_name()
                .unwrap()
                .to_str()
                .unwrap()
                .starts_with(".tool-staging-")
        );
        let staged = inspect_bootstrap_tree(capture.path()).unwrap();
        let paths: Vec<(&str, Option<&str>)> = staged
            .entries
            .iter()
            .map(|e| (e.path.as_str(), e.sha256.as_deref()))
            .collect();
        assert_eq!(
            paths,
            [
                ("", None),
                ("hdc.exe", Some(sha(b"MZ program").as_str())),
                ("libusb_shared.dll", Some(sha(b"MZ library").as_str())),
            ]
        );
        capture.revalidate_sources().unwrap();
        assert_eq!(
            capture.publish("not-a-digest").unwrap_err().to_string(),
            "invalidInput: HDC capture requires bounded regular native files and local paths"
        );
        let published = store.join(format!("tool-{digest}.hdc"));
        assert_eq!(
            capture.publish(&digest).unwrap(),
            BootstrapToolPublication::Published(published.clone())
        );

        // A program that does not import the sibling is copied alone, and
        // meets the published copy without touching it.
        let mut alone = BootstrapToolCapture::capture(&store, &hdc, |_, _| Ok(false)).unwrap();
        assert_eq!(
            inspect_bootstrap_tree(alone.path()).unwrap().entries.len(),
            2
        );
        assert_eq!(
            alone.publish(&digest).unwrap(),
            BootstrapToolPublication::AlreadyExists(published.clone())
        );
        drop(alone);

        // The inspection's refusal is the capture's, leaving nothing staged.
        let refused = BootstrapToolCapture::capture(&store, &hdc, |_, _| {
            Err(BootstrapToolCaptureError::new("invalidInput", "not x64"))
        });
        assert_eq!(refused.err().unwrap().message, "not x64");

        // A source changed after its capture is refused.
        let capture = BootstrapToolCapture::capture(&store, &hdc, |_, _| Ok(false)).unwrap();
        scratch.file(r"sdk\toolchains\hdc.exe", b"MZ changed");
        assert_eq!(
            capture.revalidate_sources().unwrap_err().code,
            "fileIdentityChanged"
        );
        drop(capture);
        assert_eq!(store_names(&store), [format!("tool-{digest}.hdc")]);
    }

    #[test]
    fn an_hdc_capture_refuses_a_missing_sibling_an_empty_program_or_a_relative_path() {
        let scratch = Scratch::new("tool-capture-refusal");
        scratch.file(r"sdk\hdc.exe", b"MZ program");
        scratch.file(r"empty\hdc.exe", b"");
        crate::create_private_directory(&scratch.0.join("store")).unwrap();
        let store = scratch.0.join("store");
        let needs_sibling = |_: &File, library: bool| Ok(!library);
        assert_eq!(
            BootstrapToolCapture::capture(&store, &scratch.0.join(r"sdk\hdc.exe"), needs_sibling)
                .err()
                .unwrap()
                .code,
            "ioFailure"
        );
        assert_eq!(
            BootstrapToolCapture::capture(&store, &scratch.0.join(r"empty\hdc.exe"), |_, _| {
                Ok(false)
            })
            .err()
            .unwrap()
            .code,
            "invalidInput"
        );
        assert_eq!(
            BootstrapToolCapture::capture(&store, Path::new(r"sdk\hdc.exe"), |_, _| Ok(false))
                .err()
                .unwrap()
                .code,
            "invalidInput"
        );
        assert!(store_names(&store).is_empty());
    }
}
