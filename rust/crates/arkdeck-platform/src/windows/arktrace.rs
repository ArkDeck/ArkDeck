//! Native authority and signer checks for the Windows ArkTrace distribution.
//! The loader copies only a reviewed, closed tree; each launch retains its
//! resources using VerifiedSource and runs in the existing kill-on-close Job.
use super::host_fs::{self, Access, DIRECTORY, Stat};
use super::identity::{authenticode_evidence, lock_namespace};
use super::pinned_file::standard_local_path;
use super::publisher::signer_name;
use crate::process::open_locked_file;
use crate::{denied, invalid};
use std::fs::File;
use std::io;
use std::os::windows::ffi::OsStrExt;
use std::path::{Path, PathBuf};

/// Every physical directory from the volume root through an installation or
/// private runtime directory, held against replacement for the whole operation.
/// Existing ACLs are checked without repairing them.
pub struct WindowsCodeNamespace {
    path: PathBuf,
    directories: Vec<File>,
    private: bool,
}

impl WindowsCodeNamespace {
    pub fn open(path: &Path, private: bool) -> io::Result<Self> {
        if !standard_local_path(path) {
            return Err(invalid("a code namespace needs a canonical local path"));
        }
        let held = lock_namespace(&path.join(".namespace-binding"))?;
        let mut ancestors: Vec<_> = path.ancestors().collect();
        ancestors.reverse();
        let directories = ancestors
            .iter()
            .map(|level| host_fs::open_directory_path(level, DIRECTORY))
            .collect::<io::Result<Vec<_>>>()?;
        let value = Self {
            path: path.to_owned(),
            directories,
            private,
        };
        value.revalidate()?;
        // Retain both the handles carrying security-query rights and the
        // no-delete-sharing namespace barriers.
        let mut value = value;
        value.directories.extend(held);
        Ok(value)
    }

    pub fn revalidate(&self) -> io::Result<()> {
        let count = self.path.ancestors().count();
        if count == 0 || self.directories.len() < count {
            return Err(denied("the code namespace is incomplete"));
        }
        let mut levels: Vec<_> = self.path.ancestors().collect();
        levels.reverse();
        for (index, (level, directory)) in levels.iter().zip(&self.directories).enumerate() {
            host_fs::canonical(level, directory)?;
            if !Stat::of(directory)?.directory() {
                return Err(denied("the code namespace changed"));
            }
            let access = Access::of(directory)?;
            let leaf = index + 1 == count;
            let permitted = if leaf && self.private {
                access.owner_is_user && access.private()
            } else if leaf {
                access.trusted_write_only()
            } else {
                access.trusted_write_only_but_add()
            };
            if !permitted {
                return Err(denied(
                    "the code namespace is changeable by another principal",
                ));
            }
        }
        Ok(())
    }
}

/// A reviewed descriptor is an owner-private regular file below trusted
/// ancestors. Its bytes are subsequently held by VerifiedSource while read.
pub fn validate_windows_private_file(path: &Path) -> io::Result<WindowsCodeNamespace> {
    if !standard_local_path(path) {
        return Err(invalid("the descriptor needs a canonical local path"));
    }
    let parent = path
        .parent()
        .ok_or_else(|| invalid("the descriptor has no parent"))?;
    let namespace = WindowsCodeNamespace::open(parent, false)?;
    let file = open_locked_file(path)?;
    host_fs::canonical(path, &file)?;
    let stat = Stat::of(&file)?;
    let access = Access::of(&file)?;
    if !stat.regular() || stat.links != 1 || !access.owner_is_user || !access.private() {
        return Err(denied("the descriptor is not owner-private"));
    }
    namespace.revalidate()?;
    Ok(namespace)
}

/// Require an actual trusted embedded signature by exactly the reviewed
/// publisher, and a verified timestamp when the manifest promises one.
pub fn verify_windows_publisher(path: &Path, publisher: &str, timestamped: bool) -> io::Result<()> {
    if publisher.is_empty() || publisher.len() > 256 {
        return Err(invalid("the publisher pin is invalid"));
    }
    // The trust provider can terminate the caller on an overlong filename.
    // Refuse before file or native trust access, using the same UTF-16 limit
    // as the Windows CLI's own executable-identity boundary.
    if path.as_os_str().encode_wide().count() >= 260 {
        return Err(invalid(
            "the distribution executable path exceeds native trust limits",
        ));
    }
    let file = open_locked_file(path)?;
    let (chain, has_timestamp) = authenticode_evidence(&file, path)?
        .map_err(|_| denied("the distribution signature is not trusted"))?;
    let leaf = chain
        .first()
        .ok_or_else(|| denied("the distribution signer is absent"))?;
    if signer_name(leaf)? != publisher || (timestamped && !has_timestamp) {
        return Err(denied(
            "the distribution signer or timestamp does not match",
        ));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn overlong_publisher_paths_are_refused_before_native_trust() {
        for filename in ["x".repeat(257), format!("{}x", "\u{1d11e}".repeat(128))] {
            let path = PathBuf::from(format!("C:\\{filename}"));
            let error = verify_windows_publisher(&path, "a reviewed publisher", false)
                .expect_err("an overlong path must not reach native trust");
            assert_eq!(error.kind(), io::ErrorKind::InvalidInput);
            assert_eq!(
                error.to_string(),
                "the distribution executable path exceeds native trust limits"
            );
        }
    }
}
