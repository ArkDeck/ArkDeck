//! Swift `ArkTraceDistributionTreeHasher`: the bounded digest of one physical
//! directory tree an ArkTrace distribution is, the pinned files it yields,
//! and the private copy of it a daemon runs from.
//!
//! Every entry is opened relative to its parent without following a link;
//! a directory or regular file must be owned by this user or root and
//! writable by no one else, and anything else refuses the tree. A file is
//! read to exactly the size it had when opened (never empty, at most
//! 128 MiB), and a directory's own identity and entry list must not change
//! while it is walked. At most 32 levels, 512 entries, 256 files, 256 MiB and
//! 1,024 bytes of relative path. The digest runs over the files in byte order
//! of their relative paths: `F`, the mode in octal, the path, the byte count
//! and the file's SHA-256, each followed by a NUL.
//!
//! A failure to open the root is the reader's error; every other refusal is
//! Swift's `contractMismatch`.
use crate::profile_file_reader::{ProfilePath, ProfileReadError, open_physical_directory};
use sha2::{Digest, Sha256};
use std::ffi::{CStr, CString};
use std::fs::File;
use std::os::fd::{AsRawFd, FromRawFd};

const MAXIMUM_FILE_BYTES: u64 = 128 * 1024 * 1024;
const MAXIMUM_TREE_BYTES: u64 = 256 * 1024 * 1024;
const MAXIMUM_FILES: usize = 256;
const MAXIMUM_ENTRIES: usize = 512;
const MAXIMUM_DEPTH: usize = 32;
const MAXIMUM_RELATIVE_PATH_BYTES: usize = 1_024;
/// `MAXNAMLEN`.
const MAXIMUM_NAME_BYTES: usize = 255;

/// Why a tree was refused: its root did not open as the reader opens it, or
/// anything else (Swift's `contractMismatch`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TreeError {
    Reader(ProfileReadError),
    Mismatch,
}

/// One file of a tree, by its absolute path below the tree's root path.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TreePin {
    pub path: String,
    pub sha256: String,
    pub byte_count: u64,
    pub require_executable: bool,
}

/// Swift `TreeSnapshot`: the tree's digest and its files.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DistributionTree {
    pub sha256: String,
    pub pinned_files: Vec<TreePin>,
}

struct Record {
    path: Vec<u8>,
    digest: String,
    byte_count: u64,
    mode: u32,
}

/// Swift `DescriptorState`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct State {
    device: i32,
    inode: u64,
    mode: u16,
    owner: u32,
    size: i64,
    modification: (i64, i64),
    change: (i64, i64),
}

fn state_of(metadata: &libc::stat) -> State {
    State {
        device: metadata.st_dev,
        inode: metadata.st_ino,
        mode: metadata.st_mode,
        owner: metadata.st_uid,
        size: metadata.st_size,
        modification: (metadata.st_mtime, metadata.st_mtime_nsec),
        change: (metadata.st_ctime, metadata.st_ctime_nsec),
    }
}

fn state(file: &File) -> Result<State, TreeError> {
    // SAFETY: zero is a valid stat; fstat fills it for a live descriptor.
    let mut metadata: libc::stat = unsafe { std::mem::zeroed() };
    // SAFETY: the live descriptor and an exclusively owned stat.
    if unsafe { libc::fstat(file.as_raw_fd(), &mut metadata) } != 0 {
        return Err(TreeError::Mismatch);
    }
    Ok(state_of(&metadata))
}

fn state_at(directory: &File, name: &CStr) -> Result<State, TreeError> {
    // SAFETY: zero is a valid stat.
    let mut metadata: libc::stat = unsafe { std::mem::zeroed() };
    // SAFETY: the live directory descriptor, a valid name and an owned stat.
    if unsafe {
        libc::fstatat(
            directory.as_raw_fd(),
            name.as_ptr(),
            &mut metadata,
            libc::AT_SYMLINK_NOFOLLOW,
        )
    } != 0
    {
        return Err(TreeError::Mismatch);
    }
    Ok(state_of(&metadata))
}

/// Swift `validateAuthority`.
fn validate_authority(state: &State, kind: u16) -> Result<(), TreeError> {
    // SAFETY: geteuid has no preconditions.
    let euid = unsafe { libc::geteuid() };
    if state.mode & libc::S_IFMT != kind
        || (state.owner != euid && state.owner != 0)
        || state.mode & 0o022 != 0
    {
        return Err(TreeError::Mismatch);
    }
    Ok(())
}

fn open_at(directory: &File, name: &CStr, flags: i32) -> Result<File, TreeError> {
    // SAFETY: the live directory descriptor and a valid name.
    let fd = unsafe { libc::openat(directory.as_raw_fd(), name.as_ptr(), flags) };
    if fd < 0 {
        return Err(TreeError::Mismatch);
    }
    // SAFETY: a newly opened descriptor has exactly one owner.
    Ok(unsafe { File::from_raw_fd(fd) })
}

const CHILD_DIRECTORY: i32 =
    libc::O_RDONLY | libc::O_DIRECTORY | libc::O_CLOEXEC | libc::O_NOFOLLOW | libc::O_NONBLOCK;
const CHILD_FILE: i32 = libc::O_RDONLY | libc::O_CLOEXEC | libc::O_NOFOLLOW | libc::O_NONBLOCK;

/// Swift `directoryEntries`: the names below `directory` through an
/// independent description of it, `.` and `..` left out, each valid UTF-8
/// of 1–255 bytes, fewer than 512 of them, sorted by their bytes, none twice.
fn entries(directory: &File) -> Result<Vec<CString>, TreeError> {
    // `dup` would share the stream offset, so `.` is opened again below the
    // verified descriptor.
    // SAFETY: the live descriptor and a literal name.
    let fd = unsafe {
        libc::openat(
            directory.as_raw_fd(),
            c".".as_ptr(),
            libc::O_RDONLY | libc::O_DIRECTORY | libc::O_CLOEXEC | libc::O_NOFOLLOW,
        )
    };
    if fd < 0 {
        return Err(TreeError::Mismatch);
    }
    // SAFETY: fdopendir takes ownership of the new descriptor on success.
    let stream = unsafe { libc::fdopendir(fd) };
    if stream.is_null() {
        // SAFETY: the descriptor is still ours when fdopendir failed.
        unsafe { libc::close(fd) };
        return Err(TreeError::Mismatch);
    }
    struct Stream(*mut libc::DIR);
    impl Drop for Stream {
        fn drop(&mut self) {
            // SAFETY: the stream fdopendir returned, closed once.
            unsafe { libc::closedir(self.0) };
        }
    }
    let stream = Stream(stream);
    let mut names: Vec<CString> = Vec::new();
    loop {
        // SAFETY: the live stream; the entry is read before the next call.
        let entry = unsafe { libc::readdir(stream.0) };
        if entry.is_null() {
            break;
        }
        // SAFETY: d_name is a NUL-terminated name within the live entry.
        let name = unsafe { CStr::from_ptr((*entry).d_name.as_ptr()) };
        if std::str::from_utf8(name.to_bytes()).is_err() {
            return Err(TreeError::Mismatch);
        }
        if name.to_bytes() == b"." || name.to_bytes() == b".." {
            continue;
        }
        if name.to_bytes().is_empty()
            || name.to_bytes().len() > MAXIMUM_NAME_BYTES
            || names.len() >= MAXIMUM_ENTRIES
        {
            return Err(TreeError::Mismatch);
        }
        names.push(name.to_owned());
    }
    names.sort_by(|left, right| left.to_bytes().cmp(right.to_bytes()));
    if names.windows(2).any(|pair| pair[0] == pair[1]) {
        return Err(TreeError::Mismatch);
    }
    Ok(names)
}

/// Swift `readFile`: a non-empty regular file of at most 128 MiB, read with
/// positioned reads to its initial size, then at its end, its state unchanged.
fn read_file(file: &File) -> Result<(Vec<u8>, u16), TreeError> {
    let initial = state(file)?;
    if initial.mode & libc::S_IFMT != libc::S_IFREG
        || initial.size <= 0
        || initial.size as u64 > MAXIMUM_FILE_BYTES
    {
        return Err(TreeError::Mismatch);
    }
    let expected = initial.size as usize;
    let mut data = Vec::with_capacity(expected);
    let mut buffer = vec![0u8; expected.min(1024 * 1024)];
    while data.len() < expected {
        let want = buffer.len().min(expected - data.len());
        // SAFETY: the live descriptor and a buffer of at least `want` bytes.
        let count = unsafe {
            libc::pread(
                file.as_raw_fd(),
                buffer.as_mut_ptr().cast(),
                want,
                data.len() as libc::off_t,
            )
        };
        if count < 0 && std::io::Error::last_os_error().kind() == std::io::ErrorKind::Interrupted {
            continue;
        }
        if count <= 0 {
            return Err(TreeError::Mismatch);
        }
        data.extend_from_slice(&buffer[..count as usize]);
    }
    let mut extra = 0u8;
    // SAFETY: the live descriptor and one owned byte.
    let end = unsafe {
        libc::pread(
            file.as_raw_fd(),
            (&mut extra as *mut u8).cast(),
            1,
            data.len() as libc::off_t,
        )
    };
    if end != 0 || state(file)? != initial {
        return Err(TreeError::Mismatch);
    }
    Ok((data, initial.mode))
}

fn sha256_hex(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}

struct Budget {
    total_bytes: u64,
    entries: usize,
}

fn walk(
    directory: &File,
    prefix: &[u8],
    depth: usize,
    records: &mut Vec<Record>,
    budget: &mut Budget,
) -> Result<(), TreeError> {
    if depth > MAXIMUM_DEPTH {
        return Err(TreeError::Mismatch);
    }
    let initial = state(directory)?;
    validate_authority(&initial, libc::S_IFDIR)?;
    let names = entries(directory)?;
    if budget.entries + names.len() > MAXIMUM_ENTRIES {
        return Err(TreeError::Mismatch);
    }
    budget.entries += names.len();
    for name in &names {
        let relative = if prefix.is_empty() {
            name.to_bytes().to_vec()
        } else {
            [prefix, b"/", name.to_bytes()].concat()
        };
        if relative.len() > MAXIMUM_RELATIVE_PATH_BYTES {
            return Err(TreeError::Mismatch);
        }
        let entry = state_at(directory, name)?;
        match entry.mode & libc::S_IFMT {
            libc::S_IFDIR => {
                validate_authority(&entry, libc::S_IFDIR)?;
                let child = open_at(directory, name, CHILD_DIRECTORY)?;
                walk(&child, &relative, depth + 1, records, budget)?;
            }
            libc::S_IFREG => {
                validate_authority(&entry, libc::S_IFREG)?;
                let file = open_at(directory, name, CHILD_FILE)?;
                let (data, mode) = read_file(&file)?;
                records.push(Record {
                    path: relative,
                    digest: sha256_hex(&data),
                    byte_count: data.len() as u64,
                    mode: u32::from(mode) & 0o7777,
                });
                budget.total_bytes += data.len() as u64;
                if records.len() > MAXIMUM_FILES || budget.total_bytes > MAXIMUM_TREE_BYTES {
                    return Err(TreeError::Mismatch);
                }
            }
            _ => return Err(TreeError::Mismatch),
        }
    }
    if state(directory)? != initial || entries(directory)? != names {
        return Err(TreeError::Mismatch);
    }
    Ok(())
}

/// Swift `snapshot(directoryDescriptor:rootPath:)`: the tree below an open
/// directory, its files named below `root_path`.
pub fn tree_snapshot_at(directory: &File, root_path: &str) -> Result<DistributionTree, TreeError> {
    let mut records = Vec::new();
    let mut budget = Budget {
        total_bytes: 0,
        entries: 1,
    };
    walk(directory, b"", 0, &mut records, &mut budget)?;
    records.sort_by(|left, right| left.path.cmp(&right.path));
    let mut hasher = Sha256::new();
    for record in &records {
        hasher.update(b"F\0");
        hasher.update(format!("{:o}", record.mode).as_bytes());
        hasher.update([0]);
        hasher.update(&record.path);
        hasher.update([0]);
        hasher.update(record.byte_count.to_string().as_bytes());
        hasher.update([0]);
        hasher.update(record.digest.as_bytes());
        hasher.update([0]);
    }
    let sha256 = format!("{:x}", hasher.finalize());
    let pinned_files = records
        .into_iter()
        .map(|record| TreePin {
            // Every name is valid UTF-8, so the path is exactly its bytes.
            path: format!("{root_path}/{}", String::from_utf8_lossy(&record.path)),
            sha256: record.digest,
            byte_count: record.byte_count,
            require_executable: record.mode & 0o111 != 0,
        })
        .collect();
    Ok(DistributionTree {
        sha256,
        pinned_files,
    })
}

/// Swift `snapshot(rootPath:)`: the tree whose root opens through `root` as
/// the reader opens a directory, its files named below `root_path`.
pub fn tree_snapshot(root: &ProfilePath, root_path: &str) -> Result<DistributionTree, TreeError> {
    let directory = open_physical_directory(root).map_err(TreeError::Reader)?;
    tree_snapshot_at(&directory, root_path)
}

/// Swift `matches(rootPath:expectedSHA256:)`.
pub fn tree_matches(root: &ProfilePath, root_path: &str, expected: &str) -> bool {
    tree_snapshot(root, root_path).is_ok_and(|tree| tree.sha256 == expected)
}

/// Swift `matches(directoryDescriptor:rootPath:expectedSHA256:)`.
pub fn tree_matches_at(directory: &File, root_path: &str, expected: &str) -> bool {
    tree_snapshot_at(directory, root_path).is_ok_and(|tree| tree.sha256 == expected)
}

fn valid_name(name: &str) -> Option<CString> {
    if name.is_empty() || name.contains('/') || name == "." || name == ".." {
        return None;
    }
    CString::new(name).ok()
}

fn copy_walk(
    source: &File,
    destination: &File,
    depth: usize,
    budget: &mut Budget,
) -> Result<(), TreeError> {
    if depth > MAXIMUM_DEPTH {
        return Err(TreeError::Mismatch);
    }
    let initial = state(source)?;
    validate_authority(&initial, libc::S_IFDIR)?;
    let names = entries(source)?;
    if budget.entries + names.len() > MAXIMUM_ENTRIES {
        return Err(TreeError::Mismatch);
    }
    budget.entries += names.len();
    for name in &names {
        let entry = state_at(source, name)?;
        match entry.mode & libc::S_IFMT {
            libc::S_IFDIR => {
                validate_authority(&entry, libc::S_IFDIR)?;
                // SAFETY: the live destination descriptor and a valid name.
                if unsafe { libc::mkdirat(destination.as_raw_fd(), name.as_ptr(), 0o700) } != 0 {
                    return Err(TreeError::Mismatch);
                }
                let source_child = open_at(source, name, CHILD_DIRECTORY)?;
                let destination_child = open_at(destination, name, CHILD_DIRECTORY)?;
                copy_walk(&source_child, &destination_child, depth + 1, budget)?;
                // SAFETY: the live descriptor.
                if unsafe { libc::fsync(destination_child.as_raw_fd()) } != 0 {
                    return Err(TreeError::Mismatch);
                }
            }
            libc::S_IFREG => {
                validate_authority(&entry, libc::S_IFREG)?;
                let file = open_at(source, name, CHILD_FILE)?;
                let (data, mode) = read_file(&file)?;
                budget.total_bytes += data.len() as u64;
                if budget.total_bytes > MAXIMUM_TREE_BYTES {
                    return Err(TreeError::Mismatch);
                }
                // SAFETY: the live destination descriptor and a valid name.
                let fd = unsafe {
                    libc::openat(
                        destination.as_raw_fd(),
                        name.as_ptr(),
                        libc::O_WRONLY
                            | libc::O_CREAT
                            | libc::O_EXCL
                            | libc::O_CLOEXEC
                            | libc::O_NOFOLLOW,
                        0o600 as libc::c_uint,
                    )
                };
                if fd < 0 {
                    return Err(TreeError::Mismatch);
                }
                // SAFETY: a newly created descriptor has exactly one owner.
                let copy = unsafe { File::from_raw_fd(fd) };
                let mut offset = 0;
                while offset < data.len() {
                    // SAFETY: the live descriptor and the remaining bytes.
                    let written = unsafe {
                        libc::write(
                            copy.as_raw_fd(),
                            data[offset..].as_ptr().cast(),
                            data.len() - offset,
                        )
                    };
                    if written < 0
                        && std::io::Error::last_os_error().kind() == std::io::ErrorKind::Interrupted
                    {
                        continue;
                    }
                    if written <= 0 {
                        return Err(TreeError::Mismatch);
                    }
                    offset += written as usize;
                }
                // SAFETY: the live descriptor.
                if unsafe { libc::fchmod(copy.as_raw_fd(), mode & 0o7777) } != 0
                    // SAFETY: the live descriptor.
                    || unsafe { libc::fsync(copy.as_raw_fd()) } != 0
                {
                    return Err(TreeError::Mismatch);
                }
            }
            _ => return Err(TreeError::Mismatch),
        }
    }
    if state(source)? != initial || entries(source)? != names {
        return Err(TreeError::Mismatch);
    }
    Ok(())
}

/// Swift `copySnapshot`: the tree at `source` copied through retained
/// descriptors into a new directory `name` below `parent` (which must not
/// exist), made `0700`, each file written `0600` and then given its mode;
/// the source's digest taken again afterwards must equal the copy's, whose
/// files are named below `display_path`.
pub fn copy_tree_snapshot(
    source: &ProfilePath,
    source_root_path: &str,
    parent: &File,
    name: &str,
    display_path: &str,
) -> Result<DistributionTree, TreeError> {
    let name = valid_name(name).ok_or(TreeError::Mismatch)?;
    if !display_path.starts_with('/') {
        return Err(TreeError::Mismatch);
    }
    let source_directory = open_physical_directory(source).map_err(TreeError::Reader)?;
    // SAFETY: the live parent descriptor and a valid name.
    if unsafe { libc::mkdirat(parent.as_raw_fd(), name.as_ptr(), 0o700) } != 0 {
        return Err(TreeError::Mismatch);
    }
    let destination = open_at(parent, &name, CHILD_DIRECTORY)?;
    let mut budget = Budget {
        total_bytes: 0,
        entries: 1,
    };
    copy_walk(&source_directory, &destination, 0, &mut budget)?;
    // SAFETY: the live descriptor.
    if unsafe { libc::fsync(destination.as_raw_fd()) } != 0 {
        return Err(TreeError::Mismatch);
    }
    let original = tree_snapshot(source, source_root_path)?;
    let copied = tree_snapshot_at(&destination, display_path)?;
    if copied.sha256 != original.sha256 {
        return Err(TreeError::Mismatch);
    }
    Ok(copied)
}

fn remove_contents(directory: &File) -> Result<(), TreeError> {
    for name in entries(directory)? {
        let entry = state_at(directory, &name)?;
        match entry.mode & libc::S_IFMT {
            libc::S_IFDIR => {
                let child = open_at(directory, &name, CHILD_DIRECTORY)?;
                remove_contents(&child)?;
                drop(child);
                // SAFETY: the live descriptor and a valid name.
                if unsafe {
                    libc::unlinkat(directory.as_raw_fd(), name.as_ptr(), libc::AT_REMOVEDIR)
                } != 0
                {
                    return Err(TreeError::Mismatch);
                }
            }
            libc::S_IFREG => {
                // SAFETY: the live descriptor and a valid name.
                if unsafe { libc::unlinkat(directory.as_raw_fd(), name.as_ptr(), 0) } != 0 {
                    return Err(TreeError::Mismatch);
                }
            }
            _ => return Err(TreeError::Mismatch),
        }
    }
    Ok(())
}

/// Swift `removeSnapshot`: the tree `name` below `parent`, removed through
/// descriptors only; an absent one is already removed.
pub fn remove_tree_snapshot(parent: &File, name: &str) -> Result<(), TreeError> {
    let name = valid_name(name).ok_or(TreeError::Mismatch)?;
    // SAFETY: the live parent descriptor and a valid name.
    let fd = unsafe { libc::openat(parent.as_raw_fd(), name.as_ptr(), CHILD_DIRECTORY) };
    if fd < 0 {
        return if std::io::Error::last_os_error().raw_os_error() == Some(libc::ENOENT) {
            Ok(())
        } else {
            Err(TreeError::Mismatch)
        };
    }
    // SAFETY: a newly opened descriptor has exactly one owner.
    let directory = unsafe { File::from_raw_fd(fd) };
    remove_contents(&directory)?;
    // SAFETY: the live parent descriptor and a valid name.
    if unsafe { libc::unlinkat(parent.as_raw_fd(), name.as_ptr(), libc::AT_REMOVEDIR) } != 0 {
        return Err(TreeError::Mismatch);
    }
    Ok(())
}

/// Swift `openRelativeDirectoryIfPresent`: the directory `name` below
/// `parent`, opened without following a link, or `None` when there is none.
/// A name that is empty, `.`, `..` or holds a solidus, and any other failure,
/// is refused.
pub fn open_relative_directory(parent: &File, name: &str) -> Result<Option<File>, TreeError> {
    let name = valid_name(name).ok_or(TreeError::Mismatch)?;
    // SAFETY: the live parent descriptor and a valid name.
    let fd = unsafe { libc::openat(parent.as_raw_fd(), name.as_ptr(), CHILD_DIRECTORY) };
    if fd >= 0 {
        // SAFETY: a newly opened descriptor has exactly one owner.
        return Ok(Some(unsafe { File::from_raw_fd(fd) }));
    }
    if std::io::Error::last_os_error().raw_os_error() == Some(libc::ENOENT) {
        return Ok(None);
    }
    Err(TreeError::Mismatch)
}

/// `renameatx_np(RENAME_EXCL)` of `from` to `to`, both below `parent`:
/// `true` once renamed, `false` when `to` already exists; any other failure
/// is refused.
pub fn rename_exclusive(parent: &File, from: &str, to: &str) -> Result<bool, TreeError> {
    let from = CString::new(from).map_err(|_| TreeError::Mismatch)?;
    let to = CString::new(to).map_err(|_| TreeError::Mismatch)?;
    // SAFETY: the live parent descriptor and two valid names.
    let renamed = unsafe {
        libc::renameatx_np(
            parent.as_raw_fd(),
            from.as_ptr(),
            parent.as_raw_fd(),
            to.as_ptr(),
            libc::RENAME_EXCL,
        )
    };
    if renamed == 0 {
        return Ok(true);
    }
    if std::io::Error::last_os_error().raw_os_error() == Some(libc::EEXIST) {
        return Ok(false);
    }
    Err(TreeError::Mismatch)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::{PermissionsExt, symlink};
    use std::path::Path;

    struct Scratch(std::path::PathBuf);
    impl Drop for Scratch {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn scratch() -> Scratch {
        let path = std::path::PathBuf::from(format!(
            "/private/tmp/arkdeck-distribution-tree-{:032x}",
            u128::from_ne_bytes(crate::random_bytes::<16>().unwrap())
        ));
        std::fs::create_dir(&path).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o700)).unwrap();
        Scratch(path)
    }

    fn components(path: &Path) -> ProfilePath {
        ProfilePath::Components(
            path.to_str()
                .unwrap()
                .split('/')
                .filter(|part| !part.is_empty())
                .map(str::to_owned)
                .collect(),
        )
    }

    fn write(path: &Path, bytes: &[u8], mode: u32) {
        std::fs::write(path, bytes).unwrap();
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(mode)).unwrap();
    }

    fn directory(path: &Path, mode: u32) {
        std::fs::create_dir(path).unwrap();
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(mode)).unwrap();
    }

    /// Two files below a nested directory, `a-b` sorting before `a/b`.
    fn tree(root: &Path) -> std::path::PathBuf {
        let app = root.join("App");
        directory(&app, 0o755);
        directory(&app.join("a"), 0o755);
        write(&app.join("a/b"), b"inner\n", 0o755);
        write(&app.join("a-b"), b"outer\n", 0o644);
        app
    }

    #[test]
    fn the_digest_runs_over_the_files_in_byte_order_of_their_paths() {
        let scratch = scratch();
        let app = tree(&scratch.0);
        let root_path = app.to_str().unwrap();
        let snapshot = tree_snapshot(&components(&app), root_path).unwrap();
        let mut expected = Sha256::new();
        for (path, mode, bytes) in [("a-b", "644", &b"outer\n"[..]), ("a/b", "755", b"inner\n")] {
            expected.update(
                format!(
                    "F\0{mode}\0{path}\0{}\0{}\0",
                    bytes.len(),
                    sha256_hex(bytes)
                )
                .as_bytes(),
            );
        }
        assert_eq!(snapshot.sha256, format!("{:x}", expected.finalize()));
        assert_eq!(
            snapshot
                .pinned_files
                .iter()
                .map(|pin| (pin.path.clone(), pin.byte_count, pin.require_executable))
                .collect::<Vec<_>>(),
            [
                (format!("{root_path}/a-b"), 6, false),
                (format!("{root_path}/a/b"), 6, true),
            ]
        );
        assert!(tree_matches(&components(&app), root_path, &snapshot.sha256));
        assert!(!tree_matches(&components(&app), root_path, &"0".repeat(64)));
    }

    #[test]
    fn an_empty_linked_writable_or_missing_entry_refuses_the_tree() {
        let scratch = scratch();
        let app = tree(&scratch.0);
        let root_path = app.to_str().unwrap().to_owned();
        let refused = |app: &Path| tree_snapshot(&components(app), &root_path).err();
        write(&app.join("empty"), b"", 0o644);
        assert_eq!(refused(&app), Some(TreeError::Mismatch));
        std::fs::remove_file(app.join("empty")).unwrap();
        symlink(app.join("a-b"), app.join("link")).unwrap();
        assert_eq!(refused(&app), Some(TreeError::Mismatch));
        std::fs::remove_file(app.join("link")).unwrap();
        std::fs::set_permissions(app.join("a-b"), std::fs::Permissions::from_mode(0o664)).unwrap();
        assert_eq!(refused(&app), Some(TreeError::Mismatch));
        std::fs::set_permissions(app.join("a-b"), std::fs::Permissions::from_mode(0o644)).unwrap();
        assert!(refused(&app).is_none());
        assert_eq!(
            refused(&scratch.0.join("absent")),
            Some(TreeError::Reader(ProfileReadError::Open))
        );
    }

    #[test]
    fn a_copy_holds_the_same_digest_and_is_removed_through_descriptors() {
        let scratch = scratch();
        let app = tree(&scratch.0);
        let snapshots = scratch.0.join("snapshots");
        directory(&snapshots, 0o700);
        let parent = File::open(&snapshots).unwrap();
        let source = tree_snapshot(&components(&app), app.to_str().unwrap()).unwrap();
        let display = snapshots.join("copy");
        let copied = copy_tree_snapshot(
            &components(&app),
            app.to_str().unwrap(),
            &parent,
            "copy",
            display.to_str().unwrap(),
        )
        .unwrap();
        assert_eq!(copied.sha256, source.sha256);
        assert_eq!(
            copied.pinned_files[0].path,
            format!("{}/a-b", display.display())
        );
        let mode = |path: &Path| std::fs::metadata(path).unwrap().permissions().mode() & 0o7777;
        assert_eq!(mode(&display), 0o700);
        assert_eq!(mode(&display.join("a")), 0o700);
        assert_eq!(mode(&display.join("a/b")), 0o755);
        assert_eq!(mode(&display.join("a-b")), 0o644);
        // A second copy under the same name is refused: the name must not exist.
        assert!(
            copy_tree_snapshot(
                &components(&app),
                app.to_str().unwrap(),
                &parent,
                "copy",
                display.to_str().unwrap(),
            )
            .is_err()
        );
        assert!(open_relative_directory(&parent, "copy").unwrap().is_some());
        assert!(
            open_relative_directory(&parent, "absent")
                .unwrap()
                .is_none()
        );
        assert_eq!(
            open_relative_directory(&parent, "..").err(),
            Some(TreeError::Mismatch)
        );
        directory(&snapshots.join("other"), 0o700);
        assert_eq!(rename_exclusive(&parent, "other", "copy"), Ok(false));
        assert_eq!(rename_exclusive(&parent, "other", "moved"), Ok(true));
        remove_tree_snapshot(&parent, "copy").unwrap();
        assert!(!display.exists());
        // Removing what is not there is already done.
        remove_tree_snapshot(&parent, "copy").unwrap();
    }
}
