//! The two filesystem steps Swift's `LaunchAgentService.install` replaces the
//! installed helper bundle with: Foundation's `FileManager.copyItem` (a
//! `copyfile` clone of the whole tree, links kept as links, attributes and
//! extended attributes carried) and the atomic exchange `replaceItemAt` makes
//! with `renamex_np(RENAME_SWAP)`, which never leaves the installed path
//! without a bundle.
use std::ffi::CString;
use std::io;
use std::os::unix::ffi::OsStrExt;
use std::path::Path;
use std::ptr;

fn c_path(path: &Path) -> io::Result<CString> {
    CString::new(path.as_os_str().as_bytes())
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "a path holds a NUL byte"))
}

/// Copies the tree at `source` to `destination`, which must not exist, as
/// `FileManager.copyItem(at:to:)` copies it: cloned where the volume can,
/// recursively, without following links.
pub fn clone_tree(source: &Path, destination: &Path) -> io::Result<()> {
    if std::fs::symlink_metadata(destination).is_ok() {
        return Err(io::Error::new(
            io::ErrorKind::AlreadyExists,
            "the copy destination already exists",
        ));
    }
    let (source, destination) = (c_path(source)?, c_path(destination)?);
    // SAFETY: both paths are NUL-terminated and live for the call; no copy
    // state is passed.
    let result = unsafe {
        libc::copyfile(
            source.as_ptr(),
            destination.as_ptr(),
            ptr::null_mut(),
            libc::COPYFILE_CLONE | libc::COPYFILE_RECURSIVE,
        )
    };
    if result != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

/// Exchanges the entries at `first` and `second`, both of which must exist, in
/// one step.
pub fn exchange_paths(first: &Path, second: &Path) -> io::Result<()> {
    let (first, second) = (c_path(first)?, c_path(second)?);
    // SAFETY: both paths are NUL-terminated and live for the call.
    if unsafe { libc::renamex_np(first.as_ptr(), second.as_ptr(), libc::RENAME_SWAP) } != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::os::unix::fs::PermissionsExt;

    #[test]
    fn a_bundle_is_cloned_whole_and_exchanged_in_one_step() {
        let root = std::env::temp_dir().canonicalize().unwrap().join(format!(
            "helper-replace-{:016x}",
            u64::from_ne_bytes(crate::random_bytes::<8>().unwrap())
        ));
        let source = root.join("Source.app");
        fs::create_dir_all(source.join("Contents/MacOS")).unwrap();
        fs::write(source.join("Contents/MacOS/tool"), b"#!/bin/sh\n").unwrap();
        fs::set_permissions(
            source.join("Contents/MacOS/tool"),
            fs::Permissions::from_mode(0o755),
        )
        .unwrap();
        std::os::unix::fs::symlink("MacOS/tool", source.join("Contents/link")).unwrap();
        let copy = root.join("Copy.app");
        clone_tree(&source, &copy).unwrap();
        assert_eq!(
            fs::read(copy.join("Contents/MacOS/tool")).unwrap(),
            b"#!/bin/sh\n"
        );
        assert_eq!(
            fs::metadata(copy.join("Contents/MacOS/tool"))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o755
        );
        assert_eq!(
            fs::read_link(copy.join("Contents/link")).unwrap(),
            Path::new("MacOS/tool")
        );
        // An existing destination is never merged into.
        assert_eq!(
            clone_tree(&source, &copy).unwrap_err().kind(),
            io::ErrorKind::AlreadyExists
        );
        fs::write(copy.join("Contents/marker"), b"copy").unwrap();
        exchange_paths(&source, &copy).unwrap();
        assert_eq!(fs::read(source.join("Contents/marker")).unwrap(), b"copy");
        assert!(!copy.join("Contents/marker").exists());
        assert!(exchange_paths(&source, &root.join("absent")).is_err());
        fs::remove_dir_all(&root).unwrap();
    }
}
