//! A directory a caller names by path and the Runtime pins by identity
//! (TASK-XPA-015): the Windows spelling of `open(path, O_DIRECTORY |
//! O_NOFOLLOW)` followed by `fstat`, which the workspace project owner uses
//! to register a project root as `(path, device, inode)`.
use super::host_fs::{self, INSPECT, Stat};
use std::fs::File;
use std::io;
use std::path::Path;

/// A directory opened at an absolute local path, its last component not
/// followed: a link or junction there is refused, as is anything that is
/// not a directory. The handle reads attributes only and shares read, write
/// and delete, so holding it keeps nobody from renaming or removing the
/// directory; it pins what was opened, not the name.
pub struct InspectedDirectory(File);

impl InspectedDirectory {
    pub fn open(path: &Path) -> io::Result<Self> {
        let file = host_fs::open_directory_path(path, INSPECT)?;
        if !Stat::of(&file)?.directory() {
            return Err(io::Error::from(io::ErrorKind::NotADirectory));
        }
        Ok(Self(file))
    }

    /// Whether the system names the opened directory with exactly `path`:
    /// no component of it is a link, a junction, a short name or another
    /// case of the name on disk, and it is on a local drive (the Unix
    /// `path.canonicalize()? == path`).
    pub fn named_exactly(&self, path: &Path) -> bool {
        host_fs::canonical(path, &self.0).is_ok()
    }

    /// The Unix `(st_dev, st_ino)`: the volume serial and the 64-bit NTFS
    /// file reference. A volume whose file ids use the upper half of the
    /// 128-bit id (ReFS) is refused rather than folded.
    pub fn identity(&self) -> io::Result<(u64, u64)> {
        let stat = Stat::of(&self.0)?;
        Ok((stat.volume, stat.inode()?))
    }
}
