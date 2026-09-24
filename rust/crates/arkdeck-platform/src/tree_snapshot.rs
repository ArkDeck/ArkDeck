//! A content snapshot of one directory tree: every entry below it, in byte
//! order of its relative path, each regular file with its byte count and
//! SHA-256, each other entry by its kind. No link is followed, nothing is
//! written, and a file that changes while it is measured refuses the
//! snapshot. The M5 cutover records one of the old state directory, taken
//! while no Runtime holds it, for rollback and audit (design §G.4).
use sha2::{Digest, Sha256};
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read};
use std::os::unix::fs::{FileTypeExt, MetadataExt, OpenOptionsExt};
use std::path::Path;

const MAX_DEPTH: usize = 64;
const MAX_ENTRIES: usize = 1_000_000;

/// What one entry is.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum TreeEntryKind {
    Directory,
    File { byte_count: u64, sha256: String },
    Symlink { target: String },
    Socket,
    Other,
}

/// One entry, by its `/`-separated path relative to the root.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TreeEntry {
    pub path: String,
    pub kind: TreeEntryKind,
}

fn changed(path: &Path) -> io::Error {
    io::Error::new(
        io::ErrorKind::InvalidData,
        format!("{} changed while it was measured", path.display()),
    )
}

fn measure(path: &Path, linked: &fs::Metadata) -> io::Result<TreeEntryKind> {
    let file: File = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC)
        .open(path)?;
    let before = file.metadata()?;
    if before.dev() != linked.dev() || before.ino() != linked.ino() || !before.is_file() {
        return Err(changed(path));
    }
    let mut hash = Sha256::new();
    let mut buffer = vec![0u8; 1 << 16];
    let mut count = 0u64;
    let mut reader = &file;
    loop {
        let read = match reader.read(&mut buffer) {
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            result => result?,
        };
        if read == 0 {
            break;
        }
        count += read as u64;
        hash.update(&buffer[..read]);
    }
    let after = file.metadata()?;
    if count != before.len()
        || after.len() != before.len()
        || after.mtime() != before.mtime()
        || after.mtime_nsec() != before.mtime_nsec()
        || after.ctime() != before.ctime()
        || after.ctime_nsec() != before.ctime_nsec()
    {
        return Err(changed(path));
    }
    Ok(TreeEntryKind::File {
        byte_count: count,
        sha256: format!("{:x}", hash.finalize()),
    })
}

fn visit(
    root: &Path,
    relative: &str,
    depth: usize,
    entries: &mut Vec<TreeEntry>,
) -> io::Result<()> {
    if depth > MAX_DEPTH {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "the tree exceeds its depth bound",
        ));
    }
    let directory = if relative.is_empty() {
        root.to_path_buf()
    } else {
        root.join(relative)
    };
    let mut names: Vec<String> = fs::read_dir(&directory)?
        .map(|entry| entry.map(|entry| entry.file_name().to_string_lossy().into_owned()))
        .collect::<io::Result<_>>()?;
    names.sort();
    for name in names {
        if entries.len() >= MAX_ENTRIES {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "the tree exceeds its entry bound",
            ));
        }
        let path = if relative.is_empty() {
            name.clone()
        } else {
            format!("{relative}/{name}")
        };
        let absolute = root.join(&path);
        let linked = fs::symlink_metadata(&absolute)?;
        let kind = linked.file_type();
        if kind.is_dir() {
            entries.push(TreeEntry {
                path: path.clone(),
                kind: TreeEntryKind::Directory,
            });
            visit(root, &path, depth + 1, entries)?;
        } else if kind.is_file() {
            let measured = measure(&absolute, &linked)?;
            entries.push(TreeEntry {
                path,
                kind: measured,
            });
        } else if kind.is_symlink() {
            entries.push(TreeEntry {
                path,
                kind: TreeEntryKind::Symlink {
                    target: fs::read_link(&absolute)?.to_string_lossy().into_owned(),
                },
            });
        } else if kind.is_socket() {
            entries.push(TreeEntry {
                path,
                kind: TreeEntryKind::Socket,
            });
        } else {
            entries.push(TreeEntry {
                path,
                kind: TreeEntryKind::Other,
            });
        }
    }
    Ok(())
}

/// Every entry below `root`, in byte order of its relative path. `root` must
/// be a directory, not a link to one.
pub fn snapshot_tree(root: &Path) -> io::Result<Vec<TreeEntry>> {
    let metadata = fs::symlink_metadata(root)?;
    if !metadata.is_dir() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "a snapshot root must be a directory",
        ));
    }
    let mut entries = Vec::new();
    visit(root, "", 0, &mut entries)?;
    entries.sort_by(|left, right| left.path.as_bytes().cmp(right.path.as_bytes()));
    Ok(entries)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::DirBuilderExt;

    #[test]
    fn a_tree_is_measured_without_following_a_link_or_writing() {
        // Short enough for the socket's `sun_path`.
        let root = Path::new("/private/tmp").join(format!(
            "ats-{:016x}",
            u64::from_ne_bytes(crate::random_bytes::<8>().unwrap())
        ));
        fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(root.join("jobs/job-a"))
            .unwrap();
        fs::write(root.join("jobs/job-a/journal.jsonl"), b"{}\n").unwrap();
        fs::write(root.join("instance.lock"), b"").unwrap();
        std::os::unix::fs::symlink("/etc/hosts", root.join("link")).unwrap();
        let socket = std::os::unix::net::UnixListener::bind(root.join("s.sock")).unwrap();
        let entries = snapshot_tree(&root).unwrap();
        let paths: Vec<&str> = entries.iter().map(|entry| entry.path.as_str()).collect();
        assert_eq!(
            paths,
            [
                "instance.lock",
                "jobs",
                "jobs/job-a",
                "jobs/job-a/journal.jsonl",
                "link",
                "s.sock"
            ]
        );
        assert_eq!(
            entries[3].kind,
            TreeEntryKind::File {
                byte_count: 3,
                sha256: "ca3d163bab055381827226140568f3bef7eaac187cebd76878e0b63e9e442356".into()
            }
        );
        assert_eq!(
            entries[0].kind,
            TreeEntryKind::File {
                byte_count: 0,
                sha256: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855".into()
            }
        );
        assert_eq!(
            entries[4].kind,
            TreeEntryKind::Symlink {
                target: "/etc/hosts".into()
            }
        );
        assert_eq!(entries[5].kind, TreeEntryKind::Socket);
        // The same tree measures the same.
        assert_eq!(snapshot_tree(&root).unwrap(), entries);
        drop(socket);
        assert!(snapshot_tree(&root.join("link")).is_err());
        fs::remove_dir_all(&root).unwrap();
    }
}
