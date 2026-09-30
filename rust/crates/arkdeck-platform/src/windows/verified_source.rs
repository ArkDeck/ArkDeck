//! The Windows `VerifiedSource` and private entries of the signing layer
//! (TASK-XPA-011).
//!
//! macOS hands a child a verified file by the `/.vol/<dev>/<ino>` alias of a
//! retained descriptor, so no later lookup can select other bytes. Windows
//! has no inode alias; the same guarantee comes from the namespace: the file
//! is held without `FILE_SHARE_WRITE` or `FILE_SHARE_DELETE` (nobody may
//! write, rename or delete it) and every ancestor directory is held without
//! `FILE_SHARE_DELETE`, as `VerifiedTool` holds its executable's, after each
//! was refused if it is a reparse point. (NTFS itself already refuses to
//! rename a directory while a file below it is open; the held levels do not
//! rely on that.) No level can then be swapped for another directory or a
//! junction: while the source is held, its canonical path names exactly the
//! retained, hashed file, and that path is what a child is given.
//!
//! [`create_private_directory`] and [`create_private_file`] are the Unix
//! `DirBuilder::mode(0o700)` and `OpenOptions::mode(0o600).create_new(true)`:
//! the new entry carries the store's private descriptor (owner the token
//! user, a protected DACL granting that user alone), whatever its parent
//! grants.
use super::host_fs::{self, Descriptor};
use super::pinned_file::standard_local_path;
use super::{bool_result, file_identity, lock_namespace, wide};
use crate::process::{hash_file, open_locked_file};
use crate::{denied, invalid};
use std::fs::File;
use std::io;
use std::os::windows::io::FromRawHandle;
use std::path::{Path, PathBuf};
use windows_sys::Win32::Foundation::{GENERIC_READ, GENERIC_WRITE, INVALID_HANDLE_VALUE};
use windows_sys::Win32::Security::SECURITY_ATTRIBUTES;
use windows_sys::Win32::Storage::FileSystem::{
    CREATE_NEW, CreateDirectoryW, CreateFileW, FILE_ATTRIBUTE_NORMAL, FILE_FLAG_OPEN_REPARSE_POINT,
};

/// A regular file bound, through one retained handle and its held
/// namespace, to its expected length and SHA-256.
pub struct VerifiedSource {
    _file: File,
    _namespace: Vec<File>,
    path: String,
}

impl VerifiedSource {
    /// `path` must be the file's canonical local spelling (`X:\…`, the
    /// spelling on disk, no link or junction in any component).
    pub fn open(path: &Path, sha256: &str, byte_count: u64) -> io::Result<Self> {
        if byte_count == 0 || sha256.len() != 64 {
            return Err(invalid("a verified source needs its length and SHA-256"));
        }
        let text = path
            .to_str()
            .filter(|text| !text.starts_with(r"\\") && standard_local_path(path))
            .ok_or_else(|| invalid("a verified source needs a plain local path"))?;
        let namespace = lock_namespace(path)?;
        let file = open_locked_file(path)?;
        host_fs::canonical(path, &file)
            .map_err(|_| denied("source path is not the file's canonical spelling"))?;
        let identity = file_identity(&file)?;
        let metadata = file.metadata()?;
        if !metadata.is_file() || metadata.len() != byte_count {
            return Err(denied(
                "source is not a regular file of its expected length",
            ));
        }
        if hash_file(&file, byte_count)? != sha256 {
            return Err(denied("source bytes do not match their SHA-256"));
        }
        if identity != file_identity(&file)? || file.metadata()?.len() != byte_count {
            return Err(denied("source changed while hashing"));
        }
        Ok(Self {
            _file: file,
            _namespace: namespace,
            path: text.to_owned(),
        })
    }

    /// The path a child reads the retained file by: on macOS the `/.vol`
    /// alias of its inode, here its canonical path, which the held
    /// namespace keeps naming the retained file.
    pub fn inode_path(&self) -> String {
        self.path.clone()
    }

    pub fn path(&self) -> PathBuf {
        PathBuf::from(&self.path)
    }
}

fn private_attributes(descriptor: &Descriptor) -> SECURITY_ATTRIBUTES {
    SECURITY_ATTRIBUTES {
        nLength: size_of::<SECURITY_ATTRIBUTES>() as u32,
        lpSecurityDescriptor: descriptor.raw(),
        bInheritHandle: 0,
    }
}

/// One new private directory (Unix `DirBuilder::new().mode(0o700)`); an
/// existing entry is `AlreadyExists`, never adopted. Its DACL is inherited by
/// what is later created in it.
pub fn create_private_directory(path: &Path) -> io::Result<()> {
    let descriptor = Descriptor::private(true)?;
    let attributes = private_attributes(&descriptor);
    let name = wide(path.as_os_str())?;
    // SAFETY: a NUL-terminated path and live security attributes.
    bool_result(unsafe { CreateDirectoryW(name.as_ptr(), &attributes) })
}

/// One new private file opened for reading and writing (Unix
/// `OpenOptions::new().write(true).create_new(true).mode(0o600)`); an
/// existing entry, a link included, is `AlreadyExists`.
pub fn create_private_file(path: &Path) -> io::Result<File> {
    let descriptor = Descriptor::private(false)?;
    let attributes = private_attributes(&descriptor);
    let name = wide(path.as_os_str())?;
    // SAFETY: a NUL-terminated path and live security attributes; a valid
    // result is a new handle owned by the File below.
    let handle = unsafe {
        CreateFileW(
            name.as_ptr(),
            GENERIC_READ | GENERIC_WRITE,
            0,
            &attributes,
            CREATE_NEW,
            FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT,
            std::ptr::null_mut(),
        )
    };
    if handle == INVALID_HANDLE_VALUE || handle.is_null() {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: CreateFileW succeeded, so `handle` is a new owned handle.
    Ok(unsafe { File::from_raw_handle(handle) })
}
