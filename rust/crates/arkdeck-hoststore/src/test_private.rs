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
