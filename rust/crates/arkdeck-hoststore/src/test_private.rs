//! Owner-only scratch directories for the unit tests the durable host store
//! runs on macOS and Windows: mode 0700 on macOS; on Windows the store's own
//! protected owner-only DACL, since a directory std creates there inherits
//! the temporary directory's DACL, which the store refuses.
use std::path::Path;

/// Creates `path`, which must not exist, as an owner-only directory.
pub(crate) fn create_private_directory(path: &Path) {
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;
        std::fs::DirBuilder::new().mode(0o700).create(path).unwrap();
    }
    #[cfg(windows)]
    {
        assert!(
            std::fs::symlink_metadata(path).is_err(),
            "{}",
            path.display()
        );
        arkdeck_platform::HostDirectory::open_or_create_private(path).unwrap();
    }
}

/// Writes `bytes` to `path` (replacing what is there) as an owner-only file
/// of its owner-only directory: mode 0600 on macOS; on Windows created by the
/// store itself, relative to the directory, with its owner-only descriptor.
pub(crate) fn plant_owner_only(path: &Path, bytes: &[u8]) {
    let _ = std::fs::remove_file(path);
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::write(path, bytes).unwrap();
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600)).unwrap();
    }
    #[cfg(windows)]
    {
        let name = path.file_name().unwrap().to_str().unwrap();
        arkdeck_platform::HostDirectory::open(path.parent().unwrap())
            .unwrap()
            .create_document(name, bytes)
            .unwrap();
    }
}

/// Makes the file at `path` one others may read, keeping its bytes: mode
/// 0644 on macOS; on Windows the file is written again in the temporary
/// directory, whose DACL it inherits, and moved into place.
pub(crate) fn widen(path: &Path) {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o644)).unwrap();
    }
    #[cfg(windows)]
    {
        let bytes = std::fs::read(path).unwrap();
        let nonce = u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap());
        let staged = std::env::temp_dir().join(format!("widened-{nonce:032x}"));
        std::fs::write(&staged, bytes).unwrap();
        std::fs::remove_file(path).unwrap();
        std::fs::rename(&staged, path).unwrap();
    }
}

/// Puts a link to `outside` at `path`: a symbolic link on macOS; on Windows,
/// where one needs a privilege, a second hard link to the file, which the
/// store refuses as it refuses any file reached through another name.
pub(crate) fn link(outside: &Path, path: &Path) {
    #[cfg(unix)]
    std::os::unix::fs::symlink(outside, path).unwrap();
    #[cfg(windows)]
    std::fs::hard_link(outside, path).unwrap();
}

/// The temporary directory in its canonical spelling: `canonicalize` on
/// macOS; on Windows a local drive's plain spelling (`D:\…`), which the
/// Session owner compares its roots with.
pub(crate) fn temporary_root() -> std::path::PathBuf {
    let path = std::env::temp_dir().canonicalize().unwrap();
    #[cfg(windows)]
    let path = match path.to_str().and_then(|text| text.strip_prefix(r"\\?\")) {
        Some(plain) => std::path::PathBuf::from(plain),
        None => path,
    };
    path
}

/// Creates `path` and every missing ancestor as owner-only directories: mode
/// 0700 on macOS; on Windows each with the store's owner-only DACL, which a
/// file or directory std creates below it then inherits.
pub(crate) fn create_private_directories(path: &Path) {
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;
        std::fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(path)
            .unwrap();
    }
    #[cfg(windows)]
    {
        let missing: Vec<&Path> = path
            .ancestors()
            .take_while(|level| std::fs::symlink_metadata(level).is_err())
            .collect();
        for level in missing.into_iter().rev() {
            arkdeck_platform::HostDirectory::open_or_create_private(level).unwrap();
        }
    }
}

/// Makes the file at `path` owner read/write only: mode 0600 on macOS. On
/// Windows a file std writes in an owner-only directory already inherits its
/// owner-only DACL, so nothing changes.
pub(crate) fn owner_only_file(path: &Path) {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600)).unwrap();
    }
    #[cfg(windows)]
    let _ = path;
}

/// The file identity of the entry at `path`: its device and inode on macOS;
/// its volume serial and NTFS file id on Windows.
pub(crate) fn file_id(path: &Path) -> (u64, u64) {
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        let metadata = std::fs::symlink_metadata(path).unwrap();
        (metadata.dev(), metadata.ino())
    }
    #[cfg(windows)]
    {
        let identity = arkdeck_platform::HostDirectory::open_export_parent(path.parent().unwrap())
            .unwrap()
            .file_identity(path.file_name().unwrap().to_str().unwrap())
            .unwrap();
        (identity.device, identity.inode)
    }
}
