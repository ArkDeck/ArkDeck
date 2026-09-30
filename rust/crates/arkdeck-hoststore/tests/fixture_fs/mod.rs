//! Owner-only fixtures for the host-store tests that run on macOS and
//! Windows: mode bits on macOS; on Windows the store's own owner-only DACL,
//! which a file or directory std creates below such a directory inherits.
#![allow(dead_code)]
use std::path::{Path, PathBuf};

/// The temporary directory in its canonical spelling: `canonicalize` on
/// macOS; on Windows a local drive's plain spelling (`D:\…`), which the
/// owners compare their roots with.
pub fn temporary_root() -> PathBuf {
    let path = std::env::temp_dir().canonicalize().unwrap();
    #[cfg(windows)]
    let path = match path.to_str().and_then(|text| text.strip_prefix(r"\\?\")) {
        Some(plain) => PathBuf::from(plain),
        None => path,
    };
    path
}

/// Creates `path`, whose parent exists, as an owner-only directory.
pub fn private_dir(path: &Path) {
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

/// Makes the file at `path` owner read/write only: mode 0600 on macOS; on
/// Windows it already inherits its owner-only directory's DACL.
pub fn owner_only(path: &Path) {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600)).unwrap();
    }
    #[cfg(windows)]
    let _ = path;
}

/// Replaces the bytes of a sealed (owner read-only) payload, keeping it
/// sealed: 0600, write, 0400 on macOS; on Windows the sealed file is moved
/// aside and a new one created and sealed by the store in its place.
pub fn rewrite_sealed(path: &Path, bytes: &[u8]) {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600)).unwrap();
        std::fs::write(path, bytes).unwrap();
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o400)).unwrap();
    }
    #[cfg(windows)]
    {
        let parent = path.parent().unwrap();
        let name = path.file_name().unwrap().to_str().unwrap();
        let nonce = u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap());
        std::fs::rename(path, temporary_root().join(format!("sealed-{nonce:032x}"))).unwrap();
        let directory = arkdeck_platform::HostDirectory::open(parent).unwrap();
        directory.create_document(name, bytes).unwrap();
        directory.seal_document(name).unwrap();
    }
}

/// Puts a link to `outside` at `path`: a symbolic link on macOS; on Windows,
/// where one needs a privilege, a second hard link, which the store refuses
/// as it refuses any file reached through another name.
pub fn link(outside: &Path, path: &Path) {
    #[cfg(unix)]
    std::os::unix::fs::symlink(outside, path).unwrap();
    #[cfg(windows)]
    std::fs::hard_link(outside, path).unwrap();
}
