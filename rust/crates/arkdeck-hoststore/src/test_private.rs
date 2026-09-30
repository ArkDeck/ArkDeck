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
