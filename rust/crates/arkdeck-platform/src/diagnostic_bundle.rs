//! Swift `LocalDiagnosticBundle`'s filesystem part: the support bundle's
//! destination check and its anchored, owner-only staging and publication
//! (`AnchoredDiagnosticBundleStaging`). The bundle's content is the caller's;
//! this writes exactly the entries it is handed into the directory the user
//! chose, and reads nothing else.
//!
//! - The destination is an absolute path whose last component is a plain
//!   name. Its parent is opened without following a link and must be a
//!   directory this user owns that no group or other can write, the same
//!   directory by path and by descriptor; the destination must not exist.
//! - Publication stages the entries in `.<name>.diagnostics.<UUID>.tmp` beside
//!   it (0700, files 0600, created exclusively, each synced with
//!   `F_FULLFSYNC`, falling back to `fsync`), checks every file's size and
//!   SHA-256, renames the staging directory exclusively onto the destination
//!   and checks everything again. A failure removes what was staged; a
//!   failure to remove it is an unknown outcome.
use crate::distribution_tree::rename_exclusive;
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::ffi::{CStr, CString};
use std::fs::File;
use std::os::fd::{AsRawFd, FromRawFd};

/// The destination's parent, as the destination check opened it: what the
/// scope digest binds and publication requires again.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct BundleParent {
    pub device: u64,
    pub inode: u64,
}

/// Swift `LocalDiagnosticBundleError`, and the staging's name check
/// (`DiagnosticBundleValidation.InvalidRelativePath`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum BundleFailure {
    InvalidInput(String),
    DestinationAlreadyExists,
    OutcomeUnknown,
    FileOperation { path: String, errno: i32 },
    InvalidRelativePath(String),
}

/// Swift `LocalDiagnosticBundleFaultPoint`, for tests.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BundleFaultPoint {
    AfterStagingOpened,
    BeforePublish,
    AfterRenameBeforeCommit,
}

fn errno() -> i32 {
    std::io::Error::last_os_error().raw_os_error().unwrap_or(0)
}

fn failed(path: &str) -> BundleFailure {
    BundleFailure::FileOperation {
        path: path.to_owned(),
        errno: errno(),
    }
}

fn c_string(text: &str) -> Result<CString, BundleFailure> {
    CString::new(text).map_err(|_| BundleFailure::InvalidInput("invalid path".into()))
}

fn stat_of(descriptor: i32) -> Option<libc::stat> {
    // SAFETY: a zeroed stat is valid output storage for fstat.
    let mut metadata: libc::stat = unsafe { std::mem::zeroed() };
    // SAFETY: a live descriptor and valid output storage.
    (unsafe { libc::fstat(descriptor, &mut metadata) } == 0).then_some(metadata)
}

fn stat_at(directory: i32, name: &CStr) -> Option<libc::stat> {
    // SAFETY: a zeroed stat is valid output storage for fstatat.
    let mut metadata: libc::stat = unsafe { std::mem::zeroed() };
    // SAFETY: a live descriptor, a NUL-terminated name and valid storage.
    (unsafe {
        libc::fstatat(
            directory,
            name.as_ptr(),
            &mut metadata,
            libc::AT_SYMLINK_NOFOLLOW,
        )
    } == 0)
        .then_some(metadata)
}

fn lstat_of(path: &CStr) -> Option<libc::stat> {
    // SAFETY: a zeroed stat is valid output storage for lstat.
    let mut metadata: libc::stat = unsafe { std::mem::zeroed() };
    // SAFETY: a NUL-terminated path and valid output storage.
    (unsafe { libc::lstat(path.as_ptr(), &mut metadata) } == 0).then_some(metadata)
}

fn effective_user() -> u32 {
    // SAFETY: geteuid takes no arguments and has no memory preconditions.
    unsafe { libc::geteuid() }
}

fn kind(metadata: &libc::stat) -> u16 {
    metadata.st_mode & libc::S_IFMT
}

const DIRECTORY_FLAGS: i32 =
    libc::O_RDONLY | libc::O_DIRECTORY | libc::O_CLOEXEC | libc::O_NOFOLLOW;

fn open_directory(path: &str) -> Result<File, BundleFailure> {
    let native = c_string(path)?;
    // SAFETY: a NUL-terminated path; the descriptor is owned by the File.
    let descriptor = unsafe { libc::open(native.as_ptr(), DIRECTORY_FLAGS) };
    if descriptor < 0 {
        return Err(failed(path));
    }
    // SAFETY: a new descriptor nothing else owns.
    Ok(unsafe { File::from_raw_fd(descriptor) })
}

fn open_directory_at(parent: &File, name: &str, display: &str) -> Result<File, BundleFailure> {
    let native = c_string(name)?;
    // SAFETY: a live descriptor, a NUL-terminated name; owned by the File.
    let descriptor = unsafe { libc::openat(parent.as_raw_fd(), native.as_ptr(), DIRECTORY_FLAGS) };
    if descriptor < 0 {
        return Err(failed(display));
    }
    // SAFETY: a new descriptor nothing else owns.
    Ok(unsafe { File::from_raw_fd(descriptor) })
}

/// Swift `fullSync`: `F_FULLFSYNC`, else `fsync` (a maintainer-adjudicated
/// durability downgrade for this writer only).
fn full_sync(file: &File, display: &str) -> Result<(), BundleFailure> {
    // SAFETY: a live descriptor.
    if unsafe { libc::fcntl(file.as_raw_fd(), libc::F_FULLFSYNC) } == 0 {
        return Ok(());
    }
    // SAFETY: a live descriptor.
    if unsafe { libc::fsync(file.as_raw_fd()) } == 0 {
        Ok(())
    } else {
        Err(failed(display))
    }
}

fn sha256_hex(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

/// Swift's split of a path into its parent and last component
/// (`deletingLastPathComponent`, `lastPathComponent`) for a canonical
/// absolute path.
fn split(destination: &str) -> (String, String) {
    let trimmed = destination.trim_end_matches('/');
    match trimmed.rfind('/') {
        Some(0) => ("/".to_owned(), trimmed[1..].to_owned()),
        Some(index) => (trimmed[..index].to_owned(), trimmed[index + 1..].to_owned()),
        None => (String::new(), trimmed.to_owned()),
    }
}

/// Swift `DiagnosticBundleValidation.relativePath`: a plain relative path of
/// plain names.
pub fn valid_relative_path(value: &str) -> bool {
    let drive = value.len() >= 2
        && value.as_bytes()[0].is_ascii_alphabetic()
        && value.as_bytes()[1] == b':';
    !value.is_empty()
        && value.len() <= 1_024
        && !value.starts_with('/')
        && !drive
        && value.split('/').all(|component| {
            !component.is_empty()
                && component != "."
                && component != ".."
                && !component.ends_with('.')
                && !component.ends_with(' ')
                && component.chars().all(|scalar| {
                    scalar as u32 > 0x1F && scalar as u32 != 0x7F && !"<>:\"/\\|?*".contains(scalar)
                })
        })
}

fn parent_is_safe(linked: &libc::stat, opened: &libc::stat) -> bool {
    let user = effective_user();
    let writable = libc::S_IWGRP | libc::S_IWOTH;
    kind(linked) == libc::S_IFDIR
        && kind(opened) == libc::S_IFDIR
        && linked.st_uid == user
        && opened.st_uid == user
        && linked.st_mode & writable == 0
        && opened.st_mode & writable == 0
        && linked.st_dev == opened.st_dev
        && linked.st_ino == opened.st_ino
}

/// Swift `validateDestination`: the parent a bundle may be published into,
/// and that the destination does not exist yet.
pub fn bundle_parent(destination: &str) -> Result<BundleParent, BundleFailure> {
    let (parent, name) = split(destination);
    if !destination.starts_with('/')
        || name.is_empty()
        || name == "."
        || name == ".."
        || name.contains('/')
        || destination == "/"
    {
        return Err(BundleFailure::InvalidInput(
            "destination must be absolute".into(),
        ));
    }
    let directory = open_directory(&parent)?;
    let linked = lstat_of(&c_string(&parent)?);
    let opened = stat_of(directory.as_raw_fd());
    let (Some(linked), Some(opened)) = (linked, opened) else {
        return Err(BundleFailure::InvalidInput(
            "unsafe diagnostic export parent".into(),
        ));
    };
    if !parent_is_safe(&linked, &opened) {
        return Err(BundleFailure::InvalidInput(
            "unsafe diagnostic export parent".into(),
        ));
    }
    if stat_at(directory.as_raw_fd(), &c_string(&name)?).is_some() || errno() != libc::ENOENT {
        return Err(BundleFailure::DestinationAlreadyExists);
    }
    Ok(BundleParent {
        device: opened.st_dev as u64,
        inode: opened.st_ino,
    })
}

/// Swift `AnchoredDiagnosticBundleStaging`.
struct Staging {
    parent_path: String,
    destination_path: String,
    staging_path: String,
    parent: File,
    directory: File,
    parent_device: u64,
    parent_inode: u64,
    staging_device: u64,
    staging_inode: u64,
    destination_name: String,
    staging_name: String,
    expected: BTreeMap<String, (u64, String)>,
    renamed: bool,
    committed: bool,
}

fn owner_only(metadata: &libc::stat) -> bool {
    metadata.st_uid == effective_user() && metadata.st_mode & (libc::S_IRWXG | libc::S_IRWXO) == 0
}

impl Staging {
    fn open(destination: &str, expected: BundleParent, uuid: &str) -> Result<Self, BundleFailure> {
        let (parent_path, destination_name) = split(destination);
        if !valid_relative_path(&destination_name) {
            return Err(BundleFailure::InvalidRelativePath(destination_name));
        }
        let staging_name = format!(".{destination_name}.diagnostics.{uuid}.tmp");
        let staging_path = format!("{}/{staging_name}", parent_path.trim_end_matches('/'));
        let parent = open_directory(&parent_path)?;
        let staging_native = c_string(&staging_name)?;
        let result = (|| -> Result<(File, libc::stat, libc::stat), BundleFailure> {
            let linked = lstat_of(&c_string(&parent_path)?);
            let opened = stat_of(parent.as_raw_fd());
            let safe = match (&linked, &opened) {
                (Some(linked), Some(opened)) => {
                    parent_is_safe(linked, opened)
                        && opened.st_dev as u64 == expected.device
                        && opened.st_ino == expected.inode
                }
                _ => false,
            };
            if !safe {
                return Err(BundleFailure::InvalidInput(
                    "unsafe diagnostic export parent".into(),
                ));
            }
            let opened = opened.expect("a checked parent");
            if stat_at(parent.as_raw_fd(), &c_string(&destination_name)?).is_some()
                || errno() != libc::ENOENT
            {
                return Err(BundleFailure::DestinationAlreadyExists);
            }
            // SAFETY: a live descriptor and a NUL-terminated name.
            if unsafe { libc::mkdirat(parent.as_raw_fd(), staging_native.as_ptr(), 0o700) } != 0 {
                return Err(failed(&staging_path));
            }
            let directory = open_directory_at(&parent, &staging_name, &staging_path)?;
            let staged = stat_of(directory.as_raw_fd());
            let staged_link = stat_at(parent.as_raw_fd(), &staging_native);
            let anchored = match (&staged, &staged_link) {
                (Some(staged), Some(link)) => {
                    kind(staged) == libc::S_IFDIR
                        && kind(link) == libc::S_IFDIR
                        && owner_only(staged)
                        && owner_only(link)
                        && staged.st_dev == opened.st_dev
                        && staged.st_dev == link.st_dev
                        && staged.st_ino == link.st_ino
                }
                _ => false,
            };
            if !anchored {
                return Err(BundleFailure::InvalidInput(
                    "diagnostic export staging directory is not owner-only and anchored".into(),
                ));
            }
            full_sync(&directory, &staging_path)?;
            full_sync(&parent, &parent_path)?;
            Ok((
                directory,
                opened,
                staged.expect("a checked staging directory"),
            ))
        })();
        match result {
            Ok((directory, opened, staged)) => Ok(Self {
                destination_path: format!(
                    "{}/{destination_name}",
                    parent_path.trim_end_matches('/')
                ),
                parent_path,
                staging_path,
                parent,
                directory,
                parent_device: opened.st_dev as u64,
                parent_inode: opened.st_ino,
                staging_device: staged.st_dev as u64,
                staging_inode: staged.st_ino,
                destination_name,
                staging_name,
                expected: BTreeMap::new(),
                renamed: false,
                committed: false,
            }),
            Err(error) => {
                if stat_at(parent.as_raw_fd(), &staging_native)
                    .is_some_and(|metadata| kind(&metadata) == libc::S_IFDIR)
                {
                    // SAFETY: a live descriptor and a NUL-terminated name.
                    unsafe {
                        libc::unlinkat(
                            parent.as_raw_fd(),
                            staging_native.as_ptr(),
                            libc::AT_REMOVEDIR,
                        );
                        libc::fsync(parent.as_raw_fd());
                    }
                }
                Err(error)
            }
        }
    }

    /// Swift `openParentDirectory`: each component below the staging
    /// directory, created owner-only when absent, never followed as a link.
    fn parent_of(&self, components: &[&str]) -> Result<File, BundleFailure> {
        let mut current = self
            .directory
            .try_clone()
            .map_err(|_| failed(&self.staging_path))?;
        let mut traversed = self.staging_path.clone();
        for component in components {
            let shown = format!("{traversed}/{component}");
            let native = c_string(component)?;
            if stat_at(current.as_raw_fd(), &native).is_none() {
                // SAFETY: a live descriptor and a NUL-terminated name.
                if errno() != libc::ENOENT
                    || unsafe { libc::mkdirat(current.as_raw_fd(), native.as_ptr(), 0o700) } != 0
                {
                    return Err(failed(&shown));
                }
                full_sync(&current, &traversed)?;
            }
            let next = open_directory_at(&current, component, &shown)?;
            let opened = stat_of(next.as_raw_fd());
            let linked = stat_at(current.as_raw_fd(), &native);
            let anchored = match (&opened, &linked) {
                (Some(opened), Some(linked)) => {
                    kind(opened) == libc::S_IFDIR
                        && kind(linked) == libc::S_IFDIR
                        && owner_only(opened)
                        && owner_only(linked)
                        && opened.st_dev as u64 == self.staging_device
                        && opened.st_dev == linked.st_dev
                        && opened.st_ino == linked.st_ino
                }
                _ => false,
            };
            if !anchored {
                return Err(BundleFailure::InvalidInput(
                    "diagnostic bundle directory ancestry was substituted".into(),
                ));
            }
            current = next;
            traversed = shown;
        }
        Ok(current)
    }

    /// Swift `write(_:relativePath:)`.
    fn write(&mut self, bytes: &[u8], relative: &str) -> Result<(), BundleFailure> {
        if !valid_relative_path(relative) {
            return Err(BundleFailure::InvalidRelativePath(relative.to_owned()));
        }
        let components: Vec<&str> = relative.split('/').collect();
        let (name, ancestors) = components.split_last().expect("a non-empty path");
        let parent = self.parent_of(ancestors)?;
        let shown = format!("{}/{relative}", self.staging_path);
        let native = c_string(name)?;
        // SAFETY: a live descriptor and a NUL-terminated name; owned by the File.
        let descriptor = unsafe {
            libc::openat(
                parent.as_raw_fd(),
                native.as_ptr(),
                libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL | libc::O_CLOEXEC | libc::O_NOFOLLOW,
                0o600 as libc::c_uint,
            )
        };
        if descriptor < 0 {
            return Err(failed(&shown));
        }
        // SAFETY: a new descriptor nothing else owns.
        let mut output = unsafe { File::from_raw_fd(descriptor) };
        let regular = stat_of(output.as_raw_fd()).is_some_and(|metadata| {
            kind(&metadata) == libc::S_IFREG
                && owner_only(&metadata)
                && metadata.st_nlink == 1
                && metadata.st_dev as u64 == self.staging_device
        });
        if !regular {
            return Err(BundleFailure::InvalidInput(
                "diagnostic bundle entry is not an owner-only regular file".into(),
            ));
        }
        std::io::Write::write_all(&mut output, bytes).map_err(|_| failed(&shown))?;
        full_sync(&output, &shown)?;
        drop(output);
        full_sync(&parent, &shown)?;
        if self
            .expected
            .insert(relative.to_owned(), (bytes.len() as u64, sha256_hex(bytes)))
            .is_some()
        {
            return Err(BundleFailure::InvalidInput(
                "duplicate diagnostic bundle entry".into(),
            ));
        }
        Ok(())
    }

    fn parent_bound(&self) -> Result<(), BundleFailure> {
        let opened = stat_of(self.parent.as_raw_fd());
        let linked = lstat_of(&c_string(&self.parent_path)?);
        let bound = match (&linked, &opened) {
            (Some(linked), Some(opened)) => {
                parent_is_safe(linked, opened)
                    && opened.st_dev as u64 == self.parent_device
                    && opened.st_ino == self.parent_inode
            }
            _ => false,
        };
        if bound {
            Ok(())
        } else {
            Err(BundleFailure::InvalidInput(
                "diagnostic export parent changed after user approval".into(),
            ))
        }
    }

    fn owned_entry(&self, name: &str) -> Result<(), BundleFailure> {
        let opened = stat_of(self.directory.as_raw_fd());
        let linked = stat_at(self.parent.as_raw_fd(), &c_string(name)?);
        let owned = match (&opened, &linked) {
            (Some(opened), Some(linked)) => {
                kind(opened) == libc::S_IFDIR
                    && kind(linked) == libc::S_IFDIR
                    && owner_only(opened)
                    && owner_only(linked)
                    && opened.st_dev as u64 == self.staging_device
                    && opened.st_ino == self.staging_inode
                    && opened.st_dev == linked.st_dev
                    && opened.st_ino == linked.st_ino
            }
            _ => false,
        };
        if owned {
            Ok(())
        } else {
            Err(BundleFailure::InvalidInput(
                "diagnostic export staging identity changed".into(),
            ))
        }
    }

    /// Swift `validateExpectedFiles`: every entry is still the owner-only
    /// regular file of the size and digest it was written with.
    fn expected_files(&self) -> Result<(), BundleFailure> {
        for (relative, (size, digest)) in &self.expected {
            let components: Vec<&str> = relative.split('/').collect();
            let (name, ancestors) = components.split_last().expect("a non-empty path");
            let mut current = self
                .directory
                .try_clone()
                .map_err(|_| failed(&self.staging_path))?;
            for component in ancestors {
                let next = open_directory_at(&current, component, &self.staging_path)?;
                let fine = stat_of(next.as_raw_fd()).is_some_and(|metadata| {
                    kind(&metadata) == libc::S_IFDIR
                        && owner_only(&metadata)
                        && metadata.st_dev as u64 == self.staging_device
                });
                if !fine {
                    return Err(BundleFailure::InvalidInput(
                        "diagnostic bundle directory ancestry changed".into(),
                    ));
                }
                current = next;
            }
            let shown = format!("{}/{relative}", self.staging_path);
            let native = c_string(name)?;
            // SAFETY: a live descriptor and a NUL-terminated name; owned by the File.
            let descriptor = unsafe {
                libc::openat(
                    current.as_raw_fd(),
                    native.as_ptr(),
                    libc::O_RDONLY | libc::O_NONBLOCK | libc::O_CLOEXEC | libc::O_NOFOLLOW,
                )
            };
            if descriptor < 0 {
                return Err(failed(&shown));
            }
            // SAFETY: a new descriptor nothing else owns.
            let mut file = unsafe { File::from_raw_fd(descriptor) };
            let unchanged = stat_of(file.as_raw_fd()).is_some_and(|metadata| {
                kind(&metadata) == libc::S_IFREG
                    && owner_only(&metadata)
                    && metadata.st_nlink == 1
                    && metadata.st_dev as u64 == self.staging_device
                    && metadata.st_size >= 0
                    && metadata.st_size as u64 == *size
            }) && {
                let mut bytes = Vec::new();
                std::io::Read::read_to_end(&mut file, &mut bytes).is_ok()
                    && bytes.len() as u64 == *size
                    && sha256_hex(&bytes) == *digest
            };
            if !unchanged {
                return Err(BundleFailure::InvalidInput(
                    "diagnostic bundle entry changed before publication".into(),
                ));
            }
        }
        Ok(())
    }

    /// Swift `publish(afterRename:)`.
    fn publish(
        &mut self,
        fault: &dyn Fn(BundleFaultPoint) -> Result<(), BundleFailure>,
    ) -> Result<(), BundleFailure> {
        self.parent_bound()?;
        self.owned_entry(&self.staging_name)?;
        self.expected_files()?;
        match rename_exclusive(&self.parent, &self.staging_name, &self.destination_name) {
            Ok(true) => {}
            Ok(false) => return Err(BundleFailure::DestinationAlreadyExists),
            Err(_) => {
                return Err(BundleFailure::FileOperation {
                    path: self.destination_path.clone(),
                    errno: errno(),
                });
            }
        }
        self.renamed = true;
        fault(BundleFaultPoint::AfterRenameBeforeCommit)?;
        self.parent_bound()?;
        self.owned_entry(&self.destination_name)?;
        self.expected_files()?;
        full_sync(&self.parent, &self.parent_path)?;
        self.committed = true;
        Ok(())
    }

    /// Swift `cleanup()`: removes the staged tree under whichever name it has,
    /// only while it is still this staging directory.
    fn cleanup(&self) -> Result<(), BundleFailure> {
        if self.committed {
            return Ok(());
        }
        let current = if self.renamed {
            &self.destination_name
        } else {
            &self.staging_name
        };
        let native = c_string(current)?;
        let Some(linked) = stat_at(self.parent.as_raw_fd(), &native) else {
            if errno() == libc::ENOENT {
                let gone = stat_of(self.directory.as_raw_fd()).is_some_and(|opened| {
                    kind(&opened) == libc::S_IFDIR
                        && opened.st_dev as u64 == self.staging_device
                        && opened.st_ino == self.staging_inode
                        && opened.st_nlink == 0
                });
                return if gone {
                    Ok(())
                } else {
                    Err(BundleFailure::InvalidInput(
                        "diagnostic export name vanished while its directory inode remains linked"
                            .into(),
                    ))
                };
            }
            return Err(failed(&format!("{}/{current}", self.parent_path)));
        };
        if kind(&linked) != libc::S_IFDIR
            || linked.st_dev as u64 != self.staging_device
            || linked.st_ino != self.staging_inode
        {
            return Err(BundleFailure::InvalidInput(
                "refusing to clean a substituted diagnostic staging directory".into(),
            ));
        }
        remove_contents(&self.directory, &self.staging_path)?;
        // SAFETY: a live descriptor and a NUL-terminated name.
        if unsafe { libc::unlinkat(self.parent.as_raw_fd(), native.as_ptr(), libc::AT_REMOVEDIR) }
            != 0
        {
            return Err(failed(&format!("{}/{current}", self.parent_path)));
        }
        full_sync(&self.parent, &self.parent_path)
    }
}

/// Every name in a directory but `.` and `..`.
fn entry_names(directory: &File, shown: &str) -> Result<Vec<String>, BundleFailure> {
    // SAFETY: duplicating a live descriptor; the stream owns the duplicate.
    let duplicate = unsafe { libc::dup(directory.as_raw_fd()) };
    if duplicate < 0 {
        return Err(failed(shown));
    }
    // SAFETY: a descriptor this call owns.
    let stream = unsafe { libc::fdopendir(duplicate) };
    if stream.is_null() {
        let failure = failed(shown);
        // SAFETY: the duplicate was not adopted by a stream.
        unsafe { libc::close(duplicate) };
        return Err(failure);
    }
    // SAFETY: a live stream.
    unsafe { libc::rewinddir(stream) };
    let mut names = Vec::new();
    loop {
        // SAFETY: a live stream; the entry is read before the next call.
        let entry = unsafe { libc::readdir(stream) };
        if entry.is_null() {
            break;
        }
        // SAFETY: readdir's entry holds a NUL-terminated name.
        let name = unsafe { CStr::from_ptr((*entry).d_name.as_ptr()) }
            .to_string_lossy()
            .into_owned();
        if name != "." && name != ".." {
            names.push(name);
        }
    }
    // SAFETY: the stream this call opened.
    unsafe { libc::closedir(stream) };
    Ok(names)
}

/// Swift `removeContents`: depth first, never following a link, refusing a
/// directory substituted while it is removed.
fn remove_contents(directory: &File, shown: &str) -> Result<(), BundleFailure> {
    for name in entry_names(directory, shown)? {
        let path = format!("{shown}/{name}");
        let native = c_string(&name)?;
        let Some(metadata) = stat_at(directory.as_raw_fd(), &native) else {
            return Err(failed(&path));
        };
        let removal = if kind(&metadata) == libc::S_IFDIR {
            let child = open_directory_at(directory, &name, &path)?;
            let same = stat_of(child.as_raw_fd()).is_some_and(|opened| {
                opened.st_dev == metadata.st_dev && opened.st_ino == metadata.st_ino
            });
            if !same {
                return Err(BundleFailure::InvalidInput(
                    "diagnostic cleanup directory was substituted".into(),
                ));
            }
            remove_contents(&child, &path)?;
            libc::AT_REMOVEDIR
        } else {
            0
        };
        // SAFETY: a live descriptor and a NUL-terminated name.
        if unsafe { libc::unlinkat(directory.as_raw_fd(), native.as_ptr(), removal) } != 0 {
            return Err(failed(&path));
        }
    }
    full_sync(directory, shown)
}

/// Swift `LocalDiagnosticBundleExporter.export`'s publication: `entries`
/// staged in order under a staging name carrying `uuid`, checked and renamed
/// onto `destination` beside `parent`. Any failure removes what was staged;
/// a failure to remove it is `OutcomeUnknown`. `fault` is Swift's fault
/// injector (tests); production passes one that never fails.
pub fn publish_bundle(
    destination: &str,
    parent: BundleParent,
    entries: &[(&str, &[u8])],
    uuid: &str,
    fault: &dyn Fn(BundleFaultPoint) -> Result<(), BundleFailure>,
) -> Result<(), BundleFailure> {
    let mut staging = Staging::open(destination, parent, uuid)?;
    let result = (|| {
        fault(BundleFaultPoint::AfterStagingOpened)?;
        for (relative, bytes) in entries {
            staging.write(bytes, relative)?;
        }
        fault(BundleFaultPoint::BeforePublish)?;
        staging.publish(fault)
    })();
    match result {
        Ok(()) => Ok(()),
        Err(error) => match staging.cleanup() {
            Ok(()) => Err(error),
            Err(_) => Err(BundleFailure::OutcomeUnknown),
        },
    }
}

/// Foundation `ProcessInfo.operatingSystemVersion`: the host's product
/// version (`kern.osproductversion`) as major, minor and patch, a missing
/// component read as 0.
pub fn operating_system_version() -> Option<(u64, u64, u64)> {
    let mut buffer = [0_u8; 64];
    let mut size = buffer.len();
    // SAFETY: a NUL-terminated name, a writable buffer and its length.
    let read = unsafe {
        libc::sysctlbyname(
            c"kern.osproductversion".as_ptr(),
            buffer.as_mut_ptr().cast(),
            &mut size,
            std::ptr::null_mut(),
            0,
        )
    };
    if read != 0 {
        return None;
    }
    let text = CStr::from_bytes_until_nul(&buffer[..size.min(buffer.len())])
        .ok()?
        .to_str()
        .ok()?;
    let mut parts = text.split('.').map(|part| part.parse::<u64>().ok());
    let major = parts.next()??;
    let minor = parts.next().unwrap_or(Some(0))?;
    let patch = parts.next().unwrap_or(Some(0))?;
    Some((major, minor, patch))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_path_splits_as_foundation_splits_it() {
        assert_eq!(split("/tmp/x/support"), ("/tmp/x".into(), "support".into()));
        assert_eq!(split("/support"), ("/".into(), "support".into()));
    }

    #[test]
    fn a_relative_path_is_plain_names() {
        for good in ["metadata.json", "hdc/tool-placeholder.json", "a b", "é"] {
            assert!(valid_relative_path(good), "{good}");
        }
        for bad in [
            "", "/a", "a//b", "a/./b", "..", "a.", "a ", "C:x", "a:b", "a\u{7f}", "a\u{1}",
        ] {
            assert!(!valid_relative_path(bad), "{bad:?}");
        }
    }
}
