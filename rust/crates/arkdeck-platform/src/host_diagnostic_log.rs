//! Swift SystemLogger's bounded diagnostic segment store. This is disposable
//! diagnostic data, never a safety-kernel state or replay record.
use super::*;
use std::os::unix::fs::{DirBuilderExt, FileExt};
use std::path::PathBuf;

struct Segment {
    sequence: u64,
    name: String,
    size: u64,
}
pub struct HostDiagnosticWriter {
    root: HostDirectory,
    path: PathBuf,
    _directory_lock: HostReadLock,
    writer_lock: HostReadLock,
    current: File,
    segments: Vec<Segment>,
    quota: u64,
    segment_limit: u64,
    record_limit: usize,
    poisoned: bool,
}
fn name(sequence: u64) -> String {
    format!("diagnostics-{sequence:020}.jsonl")
}
fn sync(file: &File) -> io::Result<()> {
    // SAFETY: held descriptor. Diagnostic writes allow Swift's fsync fallback.
    if unsafe { libc::fcntl(file.as_raw_fd(), libc::F_FULLFSYNC) } == 0
        || unsafe { libc::fsync(file.as_raw_fd()) } == 0
    {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
    }
}
fn open(root: &HostDirectory, name: &str, create: bool) -> io::Result<File> {
    let name = segment(name)?;
    // SAFETY: bounded immediate name under a retained directory. NONBLOCK
    // avoids hanging on a substituted FIFO before checking its type.
    let fd = unsafe {
        libc::openat(
            root.0.as_raw_fd(),
            name.as_ptr(),
            libc::O_RDWR
                | libc::O_APPEND
                | libc::O_CLOEXEC
                | libc::O_NOFOLLOW
                | libc::O_NONBLOCK
                | if create {
                    libc::O_CREAT | libc::O_EXCL
                } else {
                    0
                },
            0o600,
        )
    };
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: successful openat returns a newly owned descriptor.
    let file = unsafe { File::from_raw_fd(fd) };
    owned(&file, false, Ownership::Private)?;
    Ok(file)
}
fn lock(file: File) -> io::Result<HostReadLock> {
    // SAFETY: retained file or directory; fail immediately on another writer.
    if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(HostReadLock { file })
}

fn validate_root(root: &HostDirectory, path: &Path) -> io::Result<()> {
    owned(&root.0, true, Ownership::Private)?;
    let linked = std::fs::symlink_metadata(path)?;
    let held = root.0.metadata()?;
    if !linked.is_dir() || linked.dev() != held.dev() || linked.ino() != held.ino() {
        return Err(fail());
    }
    Ok(())
}

impl HostDiagnosticWriter {
    pub fn open(
        path: &Path,
        quota: u64,
        segment_limit: u64,
        record_limit: usize,
    ) -> io::Result<Self> {
        if !path.is_absolute()
            || record_limit <= 1
            || record_limit > 72 * 1024
            || segment_limit < record_limit as u64
            || quota < segment_limit
            || quota > 16 * 1024 * 1024
        {
            return Err(fail());
        }
        std::fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(path)?;
        let file = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_DIRECTORY | libc::O_CLOEXEC | libc::O_NOFOLLOW)
            .open(path)?;
        owned(&file, true, Ownership::Private)?;
        let root = HostDirectory(file, Ownership::Private);
        let directory_lock = lock(root.0.try_clone()?)?;
        validate_root(&root, path)?;
        let writer_file = match open(&root, ".writer.lock", true) {
            Ok(file) => file,
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {
                open(&root, ".writer.lock", false)?
            }
            Err(error) => return Err(error),
        };
        let writer_lock = lock(writer_file)?;
        writer_lock.validate_link(&root, ".writer.lock")?;
        let mut segments = Vec::new();
        for entry in root.names(65_536)? {
            let Some(value) = entry
                .strip_prefix("diagnostics-")
                .and_then(|v| v.strip_suffix(".jsonl"))
            else {
                continue;
            };
            let sequence: u64 = value.parse().map_err(|_| fail())?;
            if entry != name(sequence) {
                return Err(fail());
            }
            let opened = open(&root, &entry, false)?;
            let meta = opened.metadata()?;
            if meta.len() > segment_limit
                || root.file_identity(&entry)? != HostFileIdentity::of(&meta)
            {
                return Err(fail());
            }
            segments.push(Segment {
                sequence,
                name: entry,
                size: meta.len(),
            });
        }
        segments.sort_by_key(|s| s.sequence);
        let total = segments
            .iter()
            .try_fold(0u64, |total, s| total.checked_add(s.size))
            .ok_or_else(fail)?;
        if total > quota {
            return Err(fail());
        }
        if segments.is_empty() {
            segments.push(Segment {
                sequence: 0,
                name: name(0),
                size: 0,
            });
        }
        let last = segments.last_mut().ok_or_else(fail)?;
        let current = match open(&root, &last.name, false) {
            Ok(file) => file,
            Err(error) if error.kind() == io::ErrorKind::NotFound && last.size == 0 => {
                let file = open(&root, &last.name, true)?;
                sync(&file)?;
                sync(&root.0)?;
                file
            }
            Err(error) => return Err(error),
        };
        if current.metadata()?.len() != last.size {
            return Err(fail());
        }
        // Only the last segment may contain an interrupted append. Read at
        // most one configured segment; never repair any safety-kernel record.
        if last.size > 0 {
            let mut bytes = vec![0; usize::try_from(last.size).map_err(|_| fail())?];
            current.read_exact_at(&mut bytes, 0)?;
            if bytes.last() != Some(&b'\n') {
                last.size = bytes.iter().rposition(|b| *b == b'\n').map_or(0, |p| p + 1) as u64;
                current.set_len(last.size)?;
                sync(&current)?;
                sync(&root.0)?;
            }
        }
        let writer = Self {
            root,
            path: path.into(),
            _directory_lock: directory_lock,
            writer_lock,
            current,
            segments,
            quota,
            segment_limit,
            record_limit,
            poisoned: false,
        };
        writer.validate()?;
        Ok(writer)
    }

    fn validate(&self) -> io::Result<()> {
        validate_root(&self.root, &self.path)?;
        self.writer_lock.validate_link(&self.root, ".writer.lock")?;
        owned(&self.current, false, Ownership::Private)?;
        let current = self.segments.last().ok_or_else(fail)?;
        let meta = self.current.metadata()?;
        if meta.len() != current.size
            || self.root.file_identity(&current.name)? != HostFileIdentity::of(&meta)
        {
            return Err(fail());
        }
        Ok(())
    }

    pub fn append(&mut self, line: &[u8]) -> io::Result<()> {
        if self.poisoned {
            return Err(fail());
        }
        if line.len() < 2
            || line.len() > self.record_limit
            || line.last() != Some(&b'\n')
            || line[..line.len() - 1].contains(&b'\n')
        {
            return Err(fail());
        }
        let result = self.append_inner(line);
        if result.is_err() {
            self.poisoned = true;
        }
        result
    }
    fn append_inner(&mut self, line: &[u8]) -> io::Result<()> {
        self.validate()?;
        let last = self.segments.last().ok_or_else(fail)?;
        if last.size > 0 && last.size + line.len() as u64 > self.segment_limit {
            sync(&self.current)?;
            let sequence = last.sequence.checked_add(1).ok_or_else(fail)?;
            let segment = Segment {
                sequence,
                name: name(sequence),
                size: 0,
            };
            let file = open(&self.root, &segment.name, true)?;
            sync(&file)?;
            sync(&self.root.0)?;
            self.current = file;
            self.segments.push(segment);
        }
        while self.segments.iter().map(|s| s.size).sum::<u64>() + line.len() as u64 > self.quota
            && self.segments.len() > 1
        {
            let oldest = &self.segments[0];
            self.root.unlink_update_entry(&oldest.name)?;
            sync(&self.root.0)?;
            self.segments.remove(0);
        }
        if self.segments.iter().map(|s| s.size).sum::<u64>() + line.len() as u64 > self.quota {
            return Err(fail());
        }
        self.validate()?;
        self.current.write_all(line)?;
        sync(&self.current)?;
        self.segments.last_mut().ok_or_else(fail)?.size += line.len() as u64;
        self.validate()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::{PermissionsExt, symlink};
    struct Root(PathBuf);
    impl Root {
        fn new() -> Self {
            let nonce: String = crate::random_bytes::<16>()
                .unwrap()
                .iter()
                .map(|b| format!("{b:02x}"))
                .collect();
            Self(std::env::temp_dir().join(format!("arkdeck-diagnostic-{nonce}")))
        }
        fn writer(&self) -> io::Result<HostDiagnosticWriter> {
            HostDiagnosticWriter::open(&self.0, 48, 24, 16)
        }
    }
    impl Drop for Root {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
    #[test]
    fn rotates_prunes_and_repairs_only_the_last_torn_segment() {
        let root = Root::new();
        let mut writer = root.writer().unwrap();
        for _ in 0..8 {
            writer.append(b"{\"ok\":true}\n").unwrap();
        }
        assert_eq!(writer.segments.len(), 2);
        assert_eq!(writer.segments.iter().map(|s| s.size).sum::<u64>(), 48);
        let last = writer.segments.last().unwrap().name.clone();
        drop(writer);
        // Keep total under quota before simulating an interrupted trailing write.
        std::fs::remove_file(root.0.join(name(2))).unwrap();
        let file = OpenOptions::new()
            .write(true)
            .open(root.0.join(&last))
            .unwrap();
        file.set_len(15).unwrap();
        drop(file);
        let mut reopened = root.writer().unwrap();
        assert_eq!(reopened.segments.last().unwrap().size, 12);
        reopened.append(b"{\"ok\":true}\n").unwrap();
        assert_eq!(
            std::fs::read(root.0.join(last)).unwrap(),
            b"{\"ok\":true}\n{\"ok\":true}\n"
        );
    }
    #[test]
    fn active_writer_replacement_and_invalid_input_cannot_silently_resume() {
        let root = Root::new();
        let mut writer = root.writer().unwrap();
        assert!(root.writer().is_err());
        for bad in [
            b"".as_slice(),
            b"\n",
            b"x",
            b"x\ny\n",
            b"01234567890123456\n",
        ] {
            assert!(writer.append(bad).is_err());
        }
        writer.append(b"{}\n").unwrap();
        let file = root.0.join(name(0));
        std::fs::rename(&file, root.0.join("replaced")).unwrap();
        std::fs::write(&file, b"{}\n").unwrap();
        assert!(writer.append(b"{}\n").is_err());
        std::fs::remove_file(file).unwrap();
        std::fs::rename(root.0.join("replaced"), root.0.join(name(0))).unwrap();
        assert!(writer.append(b"{}\n").is_err());
        drop(writer);
        assert!(root.writer().is_ok());
    }
    #[test]
    fn unsafe_directory_segment_links_and_names_are_refused_without_repair() {
        for kind in ["directory", "hardlink", "symlink", "badName"] {
            let root = Root::new();
            drop(root.writer().unwrap());
            let file = root.0.join(name(0));
            match kind {
                "directory" => {
                    std::fs::set_permissions(&root.0, std::fs::Permissions::from_mode(0o755))
                        .unwrap()
                }
                "hardlink" => std::fs::hard_link(&file, root.0.join("alias")).unwrap(),
                "symlink" => {
                    std::fs::rename(&file, root.0.join("target")).unwrap();
                    symlink("target", &file).unwrap();
                }
                _ => std::fs::write(root.0.join("diagnostics-1.jsonl"), b"{}\n").unwrap(),
            }
            assert!(root.writer().is_err(), "{kind}");
            if kind == "directory" {
                assert_eq!(std::fs::metadata(&root.0).unwrap().mode() & 0o777, 0o755);
            }
        }
    }
}
