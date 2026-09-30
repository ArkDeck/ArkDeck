//! Reuse a complete hash only while a private sealed payload keeps the exact
//! fingerprint it was hashed with, on NTFS (the Unix
//! `host_payload_verification.rs`). The fingerprint is what `fstat` reports
//! there, read from the held handle: the volume serial and file id, size,
//! link count, attributes, owner and DACL grants, and the write, change and
//! creation times. No persisted proof, permission change, or payload buffer
//! is cached.
use super::super::host_fs::{Access, Stat, fail};
use super::{HostDirectory, Ownership, hash_to_end, owned, read_exact_at};
use sha2::{Digest, Sha256};
use std::io;

#[derive(Clone, Debug, PartialEq, Eq)]
struct Fingerprint {
    stat: Stat,
    access: Access,
}

impl Fingerprint {
    fn of(stat: Stat, access: Access) -> Self {
        Self { stat, access }
    }

    // The owner is checked by owned(..., Ownership::Private) on every access,
    // including a hit, before and after reading the handle.
    fn sealed(&self) -> bool {
        self.stat.regular() && self.stat.links == 1 && self.access.sealed()
    }
}

/// Opaque evidence produced only by a successful complete payload verification.
/// Callers may retain it in a bounded, instance-local cache. A proof never
/// authorizes an owner, metadata, lease, or access to sensitive bytes.
#[derive(Clone, Debug)]
pub struct PayloadVerification {
    parent: (u64, [u8; 16]),
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
        let parent_stat = Stat::of(&self.0)?;
        let parent = (parent_stat.volume, parent_stat.id);
        let file = self.open_at(name)?;
        owned(&file, false, Ownership::Private)?;
        let before = Fingerprint::of(Stat::of(&file)?, Access::of(&file)?);
        let (linked, linked_access) = self.inspect_at(name)?;
        if before.stat.size != length || before != Fingerprint::of(linked, linked_access) {
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
            read_exact_at(&file, &mut bytes, offset).map_err(|_| fail())?;
        } else {
            let mut hash = Sha256::new();
            let hashed = hash_to_end(&file, |chunk, next| {
                if next > length {
                    return Err(fail());
                }
                let hashed = next - chunk.len() as u64;
                let start = offset.max(hashed);
                let stop = end.min(next);
                if start < stop {
                    bytes.extend_from_slice(
                        &chunk[(start - hashed) as usize..(stop - hashed) as usize],
                    );
                }
                hash.update(chunk);
                Ok(())
            })?;
            if hashed != length || format!("{:x}", hash.finalize()) != digest {
                return Err(fail());
            }
        }
        after_access(hit);
        owned(&file, false, Ownership::Private)?;
        let (linked, linked_access) = self.inspect_at(name)?;
        if before != Fingerprint::of(Stat::of(&file)?, Access::of(&file)?)
            || before != Fingerprint::of(linked, linked_access)
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
    use super::super::super::host_fs::{self, Descriptor, WRITE};
    use super::*;
    use windows_sys::Win32::Storage::FileSystem::WRITE_DAC;

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
            let directory = HostDirectory::open_or_create_private(&path).unwrap();
            let path = path.canonicalize().unwrap();
            directory.create_document("payload", b"abcdefgh").unwrap();
            directory.seal_document("payload").unwrap();
            Self {
                directory,
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
        /// The payload's DACL made owner read-write again (Unix `chmod 0600`).
        fn unseal(&self) {
            let file = self
                .directory
                .open_at_access("payload", host_fs::INSPECT | WRITE_DAC)
                .unwrap();
            host_fs::set_dacl(&file, &Descriptor::private(false).unwrap()).unwrap();
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.path);
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
    fn proofs_are_bound_to_parent_and_name_and_writable_payloads_are_never_cached() {
        let f = Fixture::new();
        let proof = f.access(None, false);
        let other = Fixture::new();
        other.access(Some(&proof), false);
        f.unseal();
        for prior in [Some(&proof), None] {
            let (bytes, next) = f
                .directory
                .access_payload("payload", (8, &f.digest), Some((0, 1)), prior, |hit| {
                    assert!(!hit)
                })
                .unwrap();
            assert_eq!(bytes, b"a");
            assert!(next.is_none(), "a writable payload yields no proof");
        }
    }

    #[test]
    fn cold_and_hot_access_refuse_races_before_any_range_is_returned() {
        for hot in [false, true] {
            // A sealed payload cannot gain a hard link (that needs write access
            // to its attributes), so the Unix "hardlink" case is covered by the
            // DACL change it would need first ("unseal").
            for attack in ["write", "same-bytes-replace", "unseal"] {
                let f = Fixture::new();
                let proof = hot.then(|| f.access(None, false));
                let result = f.directory.access_payload(
                    "payload",
                    (8, &f.digest),
                    Some((0, 1)),
                    proof.as_ref(),
                    |hit| {
                        assert_eq!(hit, hot);
                        match attack {
                            "write" => {
                                f.unseal();
                                let file = f.directory.open_at_access("payload", WRITE).unwrap();
                                super::super::write_all_at(&file, b"X", 7).unwrap();
                            }
                            "same-bytes-replace" => {
                                f.unseal();
                                f.directory
                                    .publish_document("payload", b"abcdefgh", 64)
                                    .unwrap();
                                f.directory.seal_document("payload").unwrap();
                            }
                            "unseal" => f.unseal(),
                            _ => unreachable!(),
                        }
                    },
                );
                assert!(result.is_err(), "{hot} {attack}");
            }
        }
    }

    #[test]
    fn a_reparse_point_in_the_payload_s_place_is_never_followed() {
        let f = Fixture::new();
        std::fs::rename(f.path.join("payload"), f.path.join("original")).unwrap();
        if std::os::windows::fs::symlink_file(f.path.join("original"), f.path.join("payload"))
            .is_err()
        {
            // Creating a symbolic link needs Developer Mode or the privilege.
            eprintln!("symbolic links are not creatable here; the case is skipped");
            return;
        }
        assert!(
            f.directory
                .read_cached_payload("payload", 8, &f.digest, (0, 1), None)
                .is_err()
        );
    }
}
