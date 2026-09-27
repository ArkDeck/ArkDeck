//! Reuse a complete hash only while a private sealed payload has the exact
//! macOS stat fingerprint. No persisted proof, permission change, or payload
//! buffer is cached. Other platforms retain their existing full-hash paths.
use super::*;
use sha2::{Digest, Sha256};
use std::os::unix::fs::FileExt;

#[derive(Clone, Debug, PartialEq, Eq)]
struct Fingerprint {
    device: libc::dev_t,
    inode: libc::ino_t,
    size: libc::off_t,
    owner: libc::uid_t,
    mode: libc::mode_t,
    links: libc::nlink_t,
    modified: (libc::time_t, libc::c_long),
    changed: (libc::time_t, libc::c_long),
    created: (libc::time_t, libc::c_long),
}

impl Fingerprint {
    fn of(value: &libc::stat) -> Self {
        Self {
            device: value.st_dev,
            inode: value.st_ino,
            size: value.st_size,
            owner: value.st_uid,
            mode: value.st_mode,
            links: value.st_nlink,
            modified: (value.st_mtime, value.st_mtime_nsec),
            changed: (value.st_ctime, value.st_ctime_nsec),
            created: (value.st_birthtime, value.st_birthtime_nsec),
        }
    }

    // The effective owner is checked by owned(..., Ownership::Private) on
    // every access, including a hit, before and after reading the descriptor.
    fn sealed(&self) -> bool {
        self.mode & libc::S_IFMT == libc::S_IFREG && self.mode & 0o777 == 0o400 && self.links == 1
    }
}

/// Opaque evidence produced only by a successful complete payload verification.
/// Callers may retain it in a bounded, instance-local cache. A proof never
/// authorizes an owner, metadata, lease, or access to sensitive bytes.
#[derive(Clone, Debug)]
pub struct PayloadVerification {
    parent: (libc::dev_t, libc::ino_t),
    name: String,
    digest: String,
    fingerprint: Fingerprint,
}

impl HostDirectory {
    pub fn verify_cached_payload(
        &self,
        name: &str,
        length: u64,
        digest: &str,
        cached: Option<&PayloadVerification>,
    ) -> io::Result<Option<PayloadVerification>> {
        self.access_payload(name, (length, digest), None, cached, |_| {})
            .map(|(_, proof)| proof)
    }

    pub fn read_cached_payload(
        &self,
        name: &str,
        length: u64,
        digest: &str,
        range: (u64, usize),
        cached: Option<&PayloadVerification>,
    ) -> io::Result<(Vec<u8>, Option<PayloadVerification>)> {
        self.access_payload(name, (length, digest), Some(range), cached, |_| {})
    }

    fn access_payload(
        &self,
        name: &str,
        (length, digest): (u64, &str),
        range: Option<(u64, usize)>,
        cached: Option<&PayloadVerification>,
        after_access: impl FnOnce(bool),
    ) -> io::Result<(Vec<u8>, Option<PayloadVerification>)> {
        let (offset, end) = match range {
            Some((offset, maximum)) => {
                if offset > length || maximum == 0 || maximum > 4_194_304 {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidInput,
                        "Invalid Artifact range",
                    ));
                }
                (offset, offset + (length - offset).min(maximum as u64))
            }
            None => (0, 0),
        };
        let parent_stat = file_stat(&self.0)?;
        let parent = (parent_stat.st_dev, parent_stat.st_ino);
        let file = self.open_at(name, 0)?;
        owned(&file, false, Ownership::Private)?;
        let before = Fingerprint::of(&file_stat(&file)?);
        if u64::try_from(before.size).ok() != Some(length)
            || before != Fingerprint::of(&self.stat_at(name)?)
        {
            return Err(fail());
        }
        let hit = before.sealed()
            && cached.is_some_and(|proof| {
                proof.parent == parent
                    && proof.name == name
                    && proof.digest == digest
                    && proof.fingerprint == before
            });
        let mut bytes = Vec::with_capacity((end - offset) as usize);
        if hit {
            bytes.resize((end - offset) as usize, 0);
            let mut consumed = 0;
            while consumed < bytes.len() {
                let count = match file.read_at(&mut bytes[consumed..], offset + consumed as u64) {
                    Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                    result => result?,
                };
                if count == 0 {
                    return Err(fail());
                }
                consumed += count;
            }
        } else {
            let mut reader = &file;
            let mut buffer = [0_u8; 65536];
            let mut hashed = 0_u64;
            let mut hash = Sha256::new();
            loop {
                let count = match reader.read(&mut buffer) {
                    Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                    result => result?,
                };
                if count == 0 {
                    break;
                }
                let next = hashed.checked_add(count as u64).ok_or_else(fail)?;
                if next > length {
                    return Err(fail());
                }
                let start = offset.max(hashed);
                let stop = end.min(next);
                if start < stop {
                    bytes.extend_from_slice(
                        &buffer[(start - hashed) as usize..(stop - hashed) as usize],
                    );
                }
                hash.update(&buffer[..count]);
                hashed = next;
            }
            if hashed != length || format!("{:x}", hash.finalize()) != digest {
                return Err(fail());
            }
        }
        after_access(hit);
        owned(&file, false, Ownership::Private)?;
        if before != Fingerprint::of(&file_stat(&file)?)
            || before != Fingerprint::of(&self.stat_at(name)?)
        {
            return Err(fail());
        }
        let proof = before.sealed().then(|| PayloadVerification {
            parent,
            name: name.into(),
            digest: digest.into(),
            fingerprint: before,
        });
        Ok((bytes, proof))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::os::unix::fs::{DirBuilderExt, PermissionsExt, symlink};

    struct Fixture {
        path: std::path::PathBuf,
        directory: HostDirectory,
        digest: String,
    }
    impl Fixture {
        fn new() -> Self {
            let nonce = u128::from_ne_bytes(crate::random_bytes::<16>().unwrap());
            let path = std::env::temp_dir()
                .canonicalize()
                .unwrap()
                .join(format!("payload-proof-{nonce:x}"));
            fs::DirBuilder::new().mode(0o700).create(&path).unwrap();
            fs::write(path.join("payload"), b"abcdefgh").unwrap();
            fs::set_permissions(path.join("payload"), fs::Permissions::from_mode(0o400)).unwrap();
            Self {
                directory: HostDirectory::open(&path).unwrap(),
                path,
                digest: format!("{:x}", Sha256::digest(b"abcdefgh")),
            }
        }
        fn access(
            &self,
            proof: Option<&PayloadVerification>,
            expected_hit: bool,
        ) -> PayloadVerification {
            let (bytes, proof) = self
                .directory
                .access_payload("payload", (8, &self.digest), Some((2, 3)), proof, |hit| {
                    assert_eq!(hit, expected_hit)
                })
                .unwrap();
            assert_eq!(bytes, b"cde");
            proof.unwrap()
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            fs::remove_dir_all(&self.path).unwrap();
        }
    }

    #[test]
    fn sealed_pages_reuse_one_full_verification_and_eof_is_empty() {
        let f = Fixture::new();
        let mut proof = f.access(None, false);
        for _ in 0..65 {
            proof = f.access(Some(&proof), true);
        }
        let (bytes, _) = f
            .directory
            .access_payload(
                "payload",
                (8, &f.digest),
                Some((8, 1)),
                Some(&proof),
                |hit| assert!(hit),
            )
            .unwrap();
        assert!(bytes.is_empty());
        // Even an opaque proof cannot bless another expected digest or size.
        assert!(
            f.directory
                .read_cached_payload("payload", 8, &"0".repeat(64), (0, 1), Some(&proof))
                .is_err()
        );
        assert!(
            f.directory
                .read_cached_payload("payload", 7, &f.digest, (0, 1), Some(&proof))
                .is_err()
        );
    }

    #[test]
    fn proofs_are_bound_to_parent_and_name_and_replacement_rehashes() {
        let f = Fixture::new();
        let proof = f.access(None, false);
        let other = Fixture::new();
        other.access(Some(&proof), false);
        fs::rename(f.path.join("payload"), f.path.join("renamed")).unwrap();
        f.directory
            .access_payload(
                "renamed",
                (8, &f.digest),
                Some((0, 1)),
                Some(&proof),
                |hit| assert!(!hit),
            )
            .unwrap();
        fs::write(f.path.join("payload"), b"abcdefgh").unwrap();
        fs::set_permissions(f.path.join("payload"), fs::Permissions::from_mode(0o400)).unwrap();
        // Same published bytes between requests are valid after a fresh hash.
        let replacement = f.access(Some(&proof), false);
        f.access(Some(&replacement), true);
    }

    #[test]
    fn writable_payloads_are_never_cached_or_chmodded_by_reads() {
        let f = Fixture::new();
        let proof = f.access(None, false);
        fs::set_permissions(f.path.join("payload"), fs::Permissions::from_mode(0o600)).unwrap();
        for prior in [Some(&proof), None] {
            let (bytes, next) = f
                .directory
                .access_payload("payload", (8, &f.digest), Some((0, 1)), prior, |hit| {
                    assert!(!hit)
                })
                .unwrap();
            assert_eq!(bytes, b"a");
            assert!(next.is_none());
            assert_eq!(
                fs::metadata(f.path.join("payload")).unwrap().mode() & 0o777,
                0o600
            );
        }
    }

    #[test]
    fn retained_writer_and_restored_mtime_cannot_hide_out_of_range_corruption() {
        let f = Fixture::new();
        let path = f.path.join("payload");
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
        let writer = OpenOptions::new().write(true).open(&path).unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o400)).unwrap();
        let proof = f.access(None, false);
        let modified = writer.metadata().unwrap().modified().unwrap();
        writer.write_all_at(b"X", 7).unwrap();
        writer
            .set_times(fs::FileTimes::new().set_modified(modified))
            .unwrap();
        assert!(
            f.directory
                .read_cached_payload("payload", 8, &f.digest, (0, 1), Some(&proof))
                .is_err()
        );
        assert!(
            f.directory
                .read_cached_payload("payload", 8, &f.digest, (0, 1), None)
                .is_err()
        );
    }

    #[test]
    fn cold_and_hot_access_refuse_races_before_any_range_is_returned() {
        for hot in [false, true] {
            for attack in [
                "write",
                "same-bytes-replace",
                "symlink",
                "hardlink",
                "chmod",
                "truncate",
            ] {
                let f = Fixture::new();
                let proof = hot.then(|| f.access(None, false));
                let path = f.path.join("payload");
                let result = f.directory.access_payload(
                    "payload",
                    (8, &f.digest),
                    Some((0, 1)),
                    proof.as_ref(),
                    |hit| {
                        assert_eq!(hit, hot);
                        match attack {
                            "write" => {
                                fs::set_permissions(&path, fs::Permissions::from_mode(0o600))
                                    .unwrap();
                                fs::write(&path, b"abcdefgX").unwrap();
                                fs::set_permissions(&path, fs::Permissions::from_mode(0o400))
                                    .unwrap();
                            }
                            "same-bytes-replace" | "symlink" => {
                                fs::rename(&path, f.path.join("original")).unwrap();
                                if attack == "symlink" {
                                    symlink(f.path.join("original"), &path).unwrap();
                                } else {
                                    fs::write(&path, b"abcdefgh").unwrap();
                                    fs::set_permissions(&path, fs::Permissions::from_mode(0o400))
                                        .unwrap();
                                }
                            }
                            "hardlink" => fs::hard_link(&path, f.path.join("alias")).unwrap(),
                            "chmod" => {
                                fs::set_permissions(&path, fs::Permissions::from_mode(0o600))
                                    .unwrap()
                            }
                            "truncate" => {
                                fs::set_permissions(&path, fs::Permissions::from_mode(0o600))
                                    .unwrap();
                                OpenOptions::new()
                                    .write(true)
                                    .open(&path)
                                    .unwrap()
                                    .set_len(1)
                                    .unwrap();
                            }
                            _ => unreachable!(),
                        }
                    },
                );
                assert!(result.is_err(), "{hot} {attack}");
            }
        }
    }
}
