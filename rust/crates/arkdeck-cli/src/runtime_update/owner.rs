use super::{Cache, Failure, Snapshot, State, Store, StoreError};

pub struct Owner {
    pub store: Store,
    pub cache: Cache,
}

impl Owner {
    pub fn recover(&self, now: &str) -> Result<(), StoreError> {
        let _lease = match self.store.acquire_operation_lease() {
            Ok(lease) => lease,
            Err(StoreError::OperationInProgress) => return Ok(()),
            Err(error) => return Err(error),
        };
        self.recover_held(now)
    }

    fn recover_held(&self, now: &str) -> Result<(), StoreError> {
        let mut snapshot = self.store.load(now)?;
        if snapshot.active_operation_id.is_some() {
            let recovered = match &snapshot.state {
                State::Verifying { .. } => {
                    self.cache.remove_interrupted(&snapshot.state);
                    State::Cancelled {}
                }
                State::AwaitingConsent { .. } => {
                    self.cache.remove_interrupted(&snapshot.state);
                    State::Failed {
                        code: Failure::Handoff,
                    }
                }
                State::Checking {} | State::Downloading { .. } => State::Cancelled {},
                _ => return Err(StoreError::RecordUnreadable),
            };
            snapshot = self
                .store
                .replace(snapshot.generation, recovered, None, false, now)?;
        }
        self.cache.remove_partials()?;
        self.cache
            .remove_unreferenced(&self.cache.retained(&snapshot.state))?;
        Ok(())
    }

    pub fn status(&self, now: &str) -> Result<Snapshot, StoreError> {
        self.recover(now)?;
        self.store.load(now)
    }

    pub fn cancel(&self, now: &str) -> Result<Snapshot, StoreError> {
        self.recover(now)?;
        self.store.request_cancellation(now)
    }

    pub fn cleanup(&self, now: &str) -> Result<(Snapshot, usize), StoreError> {
        let _lease = self.store.acquire_operation_lease()?;
        self.recover_held(now)?;
        let mut snapshot = self.store.load(now)?;
        if matches!(
            snapshot.state,
            State::AwaitingConsent { .. } | State::HandedOff { .. }
        ) {
            snapshot = self
                .store
                .replace(snapshot.generation, State::Idle {}, None, false, now)?;
        }
        let removed = self
            .cache
            .remove_unreferenced(&self.cache.retained(&snapshot.state))?;
        Ok((snapshot, removed))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;
    const NOW: &str = "2026-09-26T00:00:00Z";
    const NAME: &str = "12345678-1234-1234-1234-123456789abc.dmg";
    struct Root(PathBuf);
    impl Drop for Root {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn setup(name: &str) -> (Root, Owner) {
        let root = Root(
            std::env::temp_dir().join(format!("arkdeck-update-owner-{}", crate::client_frame_id())),
        );
        let cache = root.0.join("cache with space");
        std::fs::create_dir_all(&cache).unwrap();
        let owner = Owner {
            store: Store::new(root.0.join("state")),
            cache: Cache::new(&cache),
        };
        let fixture: serde_json::Value = serde_json::from_str(include_str!(
            "../../../../tests/fixtures/runtime-update/states.json"
        ))
        .unwrap();
        let row = fixture["cases"]
            .as_array()
            .unwrap()
            .iter()
            .find(|row| row["name"] == name)
            .unwrap();
        let encoded = row["snapshotBase64"].as_str().unwrap();
        let padding = encoded
            .bytes()
            .rev()
            .take_while(|byte| *byte == b'=')
            .count();
        let bytes = arkdeck_contract::decode_import_chunk(
            encoded,
            (encoded.len() / 4 * 3 - padding) as u64,
        )
        .unwrap();
        let mut snapshot: Snapshot = serde_json::from_slice(&bytes).unwrap();
        let url = format!(
            "file://{}",
            cache.join(NAME).to_str().unwrap().replace(' ', "%20")
        );
        match &mut snapshot.state {
            State::Verifying { artifact } => artifact.url = url,
            State::AwaitingConsent { artifact, .. } => artifact.downloaded.url = url,
            State::HandedOff { url: current } => *current = url,
            _ => {}
        }
        owner
            .store
            .replace(0, snapshot.state, snapshot.active_operation_id, false, NOW)
            .unwrap();
        std::fs::write(cache.join(NAME), b"fixture").unwrap();
        std::fs::write(cache.join("orphan.part"), b"partial").unwrap();
        std::fs::write(cache.join("leave-me.txt"), b"unmanaged").unwrap();
        (root, owner)
    }

    #[test]
    fn abandoned_active_states_settle_before_status_and_cleanup_cache() {
        for (name, expected) in [
            ("checking", State::Cancelled {}),
            ("downloading", State::Cancelled {}),
            ("verifying", State::Cancelled {}),
            (
                "handoffInProgress",
                State::Failed {
                    code: Failure::Handoff,
                },
            ),
        ] {
            let (root, owner) = setup(name);
            let snapshot = owner.status(NOW).unwrap();
            assert_eq!(snapshot.state, expected, "{name}");
            assert_eq!(snapshot.generation, 2);
            assert!(snapshot.active_operation_id.is_none());
            assert!(!root.0.join("cache with space").join(NAME).exists());
            assert!(!root.0.join("cache with space/orphan.part").exists());
            assert!(root.0.join("cache with space/leave-me.txt").exists());
        }
    }

    #[test]
    fn active_owner_prevents_recovery_but_not_cancellation_and_blocks_cleanup() {
        let (root, owner) = setup("checking");
        let lease = owner.store.acquire_operation_lease().unwrap();
        assert!(matches!(
            owner.status(NOW).unwrap().state,
            State::Checking {}
        ));
        assert!(root.0.join("cache with space/orphan.part").exists());
        let cancelled = owner.cancel(NOW).unwrap();
        assert!(cancelled.cancellation_requested);
        assert_eq!(cancelled.generation, 2);
        assert_eq!(owner.cleanup(NOW), Err(StoreError::OperationInProgress));
        drop(lease);
        assert!(matches!(
            owner.status(NOW).unwrap().state,
            State::Cancelled {}
        ));
    }

    #[test]
    fn recovery_keeps_referenced_artifact_and_cleanup_counts_only_its_final_sweep() {
        for name in ["awaitingConsent", "handedOff"] {
            let (root, owner) = setup(name);
            let cache = root.0.join("cache with space");
            std::fs::write(
                cache.join("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa.dmg"),
                b"orphan",
            )
            .unwrap();
            owner.status(NOW).unwrap();
            assert!(cache.join(NAME).exists());
            assert!(!cache.join("orphan.part").exists());
            assert!(
                !cache
                    .join("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa.dmg")
                    .exists()
            );
            let (snapshot, removed) = owner.cleanup(NOW).unwrap();
            assert!(matches!(snapshot.state, State::Idle {}));
            assert_eq!(removed, 1);
            assert!(!cache.join(NAME).exists());
            assert!(cache.join("leave-me.txt").exists());
        }
    }

    #[test]
    fn cache_cleanup_never_follows_links_or_recurses_into_directories() {
        let (root, owner) = setup("idle");
        let outside = root.0.join("outside");
        std::fs::write(&outside, b"keep").unwrap();
        let cache = root.0.join("cache with space");
        std::os::unix::fs::symlink(&outside, cache.join("link.part")).unwrap();
        owner.status(NOW).unwrap();
        assert_eq!(std::fs::read(&outside).unwrap(), b"keep");
        assert!(std::fs::symlink_metadata(cache.join("link.part")).is_err());
        std::fs::create_dir(cache.join("directory.part")).unwrap();
        std::fs::write(cache.join("directory.part/inside"), b"keep").unwrap();
        assert_eq!(owner.status(NOW), Err(StoreError::CacheUnavailable));
        assert_eq!(
            std::fs::read(cache.join("directory.part/inside")).unwrap(),
            b"keep"
        );
    }
}
