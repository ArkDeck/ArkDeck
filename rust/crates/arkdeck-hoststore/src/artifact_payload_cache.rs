//! Bounded proofs local to one ArtifactReadStore generation. All owner,
//! receipt, privacy, metadata and root checks remain outside this cache.
use super::*;
use arkdeck_platform::PayloadVerification;
use std::collections::{BTreeMap, VecDeque};

const CAPACITY: usize = 256;

// Import IDs use the validated imp- namespace; Job IDs cannot acquire an
// Import owner through the resource handler. Keep kind explicit as well.
type Key = (bool, String, String);

#[derive(Default)]
pub(super) struct PayloadCache {
    records: BTreeMap<Key, PayloadVerification>,
    order: VecDeque<Key>,
}

impl PayloadCache {
    fn remove(&mut self, key: &Key) {
        self.records.remove(key);
        self.order.retain(|entry| entry != key);
    }

    fn insert(&mut self, key: Key, proof: PayloadVerification) {
        if !self.records.contains_key(&key) {
            if self.records.len() == CAPACITY
                && let Some(oldest) = self.order.pop_front()
            {
                self.records.remove(&oldest);
            }
            self.order.push_back(key.clone());
        }
        self.records.insert(key, proof);
    }
}

impl ArtifactReadStore {
    pub(super) fn with_payload_verification<T>(
        &self,
        owner_id: &str,
        artifact_id: &str,
        access: impl FnOnce(
            Option<&PayloadVerification>,
        ) -> io::Result<(T, Option<PayloadVerification>)>,
    ) -> io::Result<T> {
        let key = (
            owner_id.starts_with("imp-"),
            owner_id.into(),
            artifact_id.into(),
        );
        // Clone only opaque metadata while holding the lock. Hashing and file
        // I/O never hold it or serialize unrelated Artifact readers.
        let prior = self
            .payload_verifications
            .lock()
            .map_err(|_| corrupt())?
            .records
            .get(&key)
            .cloned();
        let result = access(prior.as_ref());
        let mut cache = self.payload_verifications.lock().map_err(|_| corrupt())?;
        match result {
            Ok((value, Some(proof))) => {
                // Platform proofs independently bind the held parent dev/ino,
                // name, expected digest/size and complete payload fingerprint.
                // A concurrent stale insertion therefore becomes a safe miss.
                cache.insert(key, proof);
                Ok(value)
            }
            Ok((value, None)) => {
                cache.remove(&key);
                Ok(value)
            }
            Err(error) => {
                cache.remove(&key);
                Err(error)
            }
        }
    }

    pub(super) fn verify_cached_artifact(
        &self,
        directory: &HostDirectory,
        owner_id: &str,
        artifact_id: &str,
        length: u64,
        digest: &str,
    ) -> io::Result<()> {
        self.with_payload_verification(owner_id, artifact_id, |cached| {
            directory
                .verify_cached_payload(artifact_id, length, digest, cached)
                .map(|proof| ((), proof))
        })
    }
}

// Unix fixtures (mode bits, symbolic links); the Windows owners are proved
// by `tests/windows_artifact_owners.rs`.
#[cfg(all(test, target_os = "macos"))]
mod tests {
    use super::*;
    use std::{
        fs,
        os::unix::fs::{DirBuilderExt, PermissionsExt},
        sync::{Arc, mpsc},
        time::Duration,
    };

    struct Fixture {
        path: PathBuf,
        store: Arc<ArtifactReadStore>,
    }
    impl Fixture {
        fn new() -> Self {
            let nonce = u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap());
            let path = std::env::temp_dir()
                .canonicalize()
                .unwrap()
                .join(format!("artifact-proof-cache-{nonce:x}"));
            fs::DirBuilder::new().mode(0o700).create(&path).unwrap();
            Self {
                store: Arc::new(ArtifactReadStore::open(&path).unwrap()),
                path,
            }
        }
        fn proof(&self) -> PayloadVerification {
            fs::write(self.path.join("payload"), b"abc").unwrap();
            fs::set_permissions(self.path.join("payload"), fs::Permissions::from_mode(0o400))
                .unwrap();
            self.store
                .root
                .verify_cached_payload("payload", 3, &arkdeck_contract::sha256_hex(b"abc"), None)
                .unwrap()
                .unwrap()
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            fs::remove_dir_all(&self.path).unwrap();
        }
    }

    #[test]
    fn proof_cache_is_bounded_instance_local_and_forgets_failures() {
        let f = Fixture::new();
        let proof = f.proof();
        for i in 0..=CAPACITY {
            f.store
                .with_payload_verification("JOB-1", &format!("ART-{i}"), |prior| {
                    assert!(prior.is_none());
                    Ok(((), Some(proof.clone())))
                })
                .unwrap();
        }
        let cache = f.store.payload_verifications.lock().unwrap();
        assert_eq!(cache.records.len(), CAPACITY);
        assert_eq!(cache.order.len(), CAPACITY);
        assert!(
            !cache
                .records
                .contains_key(&(false, "JOB-1".into(), "ART-0".into()))
        );
        drop(cache);
        f.store
            .with_payload_verification("JOB-1", "ART-1", |prior| {
                assert!(prior.is_some());
                Err::<((), Option<PayloadVerification>), _>(corrupt())
            })
            .unwrap_err();
        f.store
            .with_payload_verification("JOB-1", "ART-1", |prior| {
                assert!(prior.is_none());
                Ok(((), None))
            })
            .unwrap();
        for owner in ["JOB-2", "imp-00000000-0000-0000-0000-000000000000"] {
            f.store
                .with_payload_verification(owner, "ART-2", |prior| {
                    assert!(prior.is_none());
                    Ok(((), None))
                })
                .unwrap();
        }
        let reopened = ArtifactReadStore::open(&f.path).unwrap();
        reopened
            .with_payload_verification("JOB-1", "ART-2", |prior| {
                assert!(prior.is_none());
                Ok(((), None))
            })
            .unwrap();
        assert_eq!(
            fs::read_dir(&f.path).unwrap().count(),
            1,
            "no persisted cache"
        );
    }

    #[test]
    fn payload_io_does_not_hold_the_metadata_cache_lock() {
        let f = Fixture::new();
        let (started, observed) = mpsc::channel();
        let mut threads = Vec::new();
        let mut releases = Vec::new();
        for id in ["A", "B"] {
            let (release, wait) = mpsc::channel();
            releases.push(release);
            let store = Arc::clone(&f.store);
            let started = started.clone();
            threads.push(std::thread::spawn(move || {
                store
                    .with_payload_verification("JOB-1", id, |_| {
                        started.send(()).unwrap();
                        wait.recv_timeout(Duration::from_secs(5)).unwrap();
                        Ok(((), None))
                    })
                    .unwrap();
            }));
        }
        let first = observed.recv_timeout(Duration::from_secs(2));
        let second = observed.recv_timeout(Duration::from_secs(2));
        for release in releases {
            let _ = release.send(());
        }
        for thread in threads {
            thread.join().unwrap();
        }
        assert!(
            first.is_ok() && second.is_ok(),
            "both file accesses must enter concurrently"
        );
    }

    #[test]
    fn poisoned_metadata_cache_refuses_without_accessing_payload() {
        let f = Fixture::new();
        let store = Arc::clone(&f.store);
        assert!(
            std::thread::spawn(move || {
                let _guard = store.payload_verifications.lock().unwrap();
                panic!("fixture poison");
            })
            .join()
            .is_err()
        );
        assert!(
            f.store
                .with_payload_verification::<()>("JOB-1", "A", |_| {
                    panic!("poisoned cache must not run payload access")
                })
                .is_err()
        );
    }
}
