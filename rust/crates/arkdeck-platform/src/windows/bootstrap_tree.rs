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

fn changed() -> BootstrapBundleCaptureError {
    BootstrapBundleCaptureError::new(
        "fileIdentityChanged",
        "Bootstrap bundle source or staging identity changed",
    )
}
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
fn io_failure(_: io::Error) -> BootstrapBundleCaptureError {
    BootstrapBundleCaptureError::new("ioFailure", "the Bundle could not be staged")
}

/// A Bundle capture on NTFS: the source tree held as inspected, and the
/// private staging copy of it in the store.
pub struct BootstrapBundleCapture {
    source_path: PathBuf,
    source: BootstrapTree,
    store: File,
    staging: File,
    name: String,
    path: PathBuf,
    /// Every entry this capture created below its staging directory, in
    /// creation order, with the identity it was created with.
    created: Vec<(String, bool, Stat)>,
    /// The staging directory's own identity.
    staged: Stat,
    published: bool,
    publication_uncertain: bool,
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
        let store =
            host_fs::open_directory_path(registry_root, DIRECTORY_WRITE).map_err(io_failure)?;
        let nonce: String = crate::random_bytes::<16>()
            .map_err(io_failure)?
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect();
        let name = format!(".staging-{nonce}");
        let private = Descriptor::private(true).map_err(io_failure)?;
        let staging = host_fs::open_relative(
            &store,
            &segment(&name).map_err(io_failure)?,
            DIRECTORY_WRITE | DELETE,
            FILE_CREATE,
            Kind::Directory,
            Some(&private),
        )
        .map_err(io_failure)?;
        let staged = Stat::of(&staging).map_err(io_failure)?;
        let mut capture = Self {
            source_path: source.to_path_buf(),
            source: tree,
            store,
            staging,
            path: registry_root.join(&name),
            name,
            created: Vec::new(),
            staged,
            published: false,
            publication_uncertain: false,
        };
        capture.copy()?;
        Ok(capture)
    }

    fn copy(&mut self) -> Result<(), BootstrapBundleCaptureError> {
        let private = Descriptor::private(true).map_err(io_failure)?;
        let file_descriptor = Descriptor::private(false).map_err(io_failure)?;
        let mut directories: BTreeMap<String, File> = BTreeMap::new();
        for entry in self.source.entries.iter().skip(1) {
            let (parent_path, leaf) = entry.path.rsplit_once('/').unwrap_or(("", &entry.path));
            let parent = if parent_path.is_empty() {
                &self.staging
            } else {
                directories.get(parent_path).ok_or_else(changed)?
            };
            let leaf = segment(leaf).map_err(io_failure)?;
            if entry.directory {
                let created = host_fs::open_relative(
                    parent,
                    &leaf,
                    DIRECTORY_WRITE,
                    FILE_CREATE,
                    Kind::Directory,
                    Some(&private),
                )
                .map_err(io_failure)?;
                self.created.push((
                    entry.path.clone(),
                    true,
                    Stat::of(&created).map_err(io_failure)?,
                ));
                directories.insert(entry.path.clone(), created);
            } else {
                let mut from = self
                    .source
                    .open_relative_file(&self.source_path, &entry.path)
                    .map_err(|_| changed())?;
                let mut to = host_fs::open_relative(
                    parent,
                    &leaf,
                    host_fs::WRITE,
                    FILE_CREATE,
                    Kind::NonDirectory,
                    Some(&file_descriptor),
                )
                .map_err(io_failure)?;
                self.created.push((
                    entry.path.clone(),
                    false,
                    Stat::of(&to).map_err(io_failure)?,
                ));
                let mut hasher = Sha256::new();
                let mut remaining = entry.byte_count;
                let mut buffer = vec![0u8; 256 * 1024];
                while remaining > 0 {
                    let want = usize::try_from(remaining.min(buffer.len() as u64))
                        .map_err(|_| changed())?;
                    let read = from.read(&mut buffer[..want]).map_err(|_| changed())?;
                    if read == 0 {
                        return Err(changed());
                    }
                    hasher.update(&buffer[..read]);
                    to.write_all(&buffer[..read]).map_err(io_failure)?;
                    remaining -= read as u64;
                }
                if entry.sha256.as_deref() != Some(format!("{:x}", hasher.finalize()).as_str()) {
                    return Err(changed());
                }
                host_fs::flush(&to).map_err(io_failure)?;
            }
        }
        for directory in directories.values() {
            host_fs::flush_directory(directory).map_err(io_failure)?;
        }
        host_fs::flush_directory(&self.staging).map_err(io_failure)
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

    /// Remove what this capture created, deepest first, each entry only if
    /// it is still the one created; then the staging directory itself, only
    /// if it is empty. Anything else is left for inspection.
    fn cleanup_owned_stage(&self) -> io::Result<()> {
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

    /// The staging copy's path, for the owner's native checks.
    pub fn path(&self) -> &Path {
        &self.path
    }

    /// The source still exactly as captured, and the staging copy the same
    /// content.
    pub fn revalidate_sources(&self) -> Result<(), BootstrapBundleCaptureError> {
        let source = inspect_bootstrap_tree(&self.source_path).map_err(|_| changed())?;
        if source != self.source {
            return Err(changed());
        }
        let staged = inspect_bootstrap_tree(&self.path).map_err(|_| changed())?;
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
            return Err(changed());
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
        use BootstrapBundlePublishError::{BeforePublication, OutcomeUnknown};
        let target = segment(name).map_err(|error| BeforePublication(io_failure(error)))?;
        let destination = self
            .path
            .parent()
            .map(|parent| parent.join(name))
            .ok_or_else(|| BeforePublication(changed()))?;
        match host_fs::inspect_relative(&self.store, &target) {
            Ok(_) => return Ok(BootstrapBundlePublication::AlreadyExists(destination)),
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(error) => return Err(BeforePublication(io_failure(error))),
        }
        if let Err(error) = host_fs::rename(&self.staging, &self.store, &target, false) {
            if error.kind() == io::ErrorKind::AlreadyExists {
                return Err(BeforePublication(changed()));
            }
            self.publication_uncertain = true;
            return Err(OutcomeUnknown(io_failure(error)));
        }
        self.published = true;
        host_fs::flush_directory(&self.store).map_err(|error| OutcomeUnknown(io_failure(error)))?;
        self.name = name.to_owned();
        self.path = destination.clone();
        Ok(BootstrapBundlePublication::Published(destination))
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
}
