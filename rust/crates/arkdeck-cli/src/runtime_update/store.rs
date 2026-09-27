use super::{Snapshot, State};
use arkdeck_platform::{HostDirectory, HostReadLock};
use std::path::{Path, PathBuf};

const STATE: &str = "state-v1.json";
const STATE_LOCK: &str = ".state-v1.lock";
const OPERATION_LOCK: &str = ".operation-v1.lock";
const MAXIMUM: usize = 512 * 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StoreError {
    CacheUnavailable,
    UnsafeDirectory,
    RecordUnreadable,
    WriteFailed,
    ResourceConflict,
    OperationInProgress,
}

pub struct Store {
    directory: PathBuf,
    clock: Option<std::sync::Arc<dyn Fn() -> String + Send + Sync>>,
}

impl Store {
    pub fn new(directory: impl Into<PathBuf>) -> Self {
        Self {
            directory: directory.into(),
            clock: None,
        }
    }

    /// Production snapshots take their timestamp while the state transaction
    /// is locked. The explicit `now` arguments remain deterministic fallback
    /// inputs for existing record fixtures, not a long operation's wall clock.
    pub fn with_clock(mut self, clock: impl Fn() -> String + Send + Sync + 'static) -> Self {
        self.clock = Some(std::sync::Arc::new(clock));
        self
    }

    fn timestamp(&self, fallback: &str) -> String {
        self.clock
            .as_ref()
            .map_or_else(|| fallback.to_owned(), |clock| clock())
    }

    pub fn directory(&self) -> &Path {
        &self.directory
    }

    fn open(&self) -> Result<HostDirectory, StoreError> {
        HostDirectory::open_update_store(&self.directory).map_err(|_| StoreError::UnsafeDirectory)
    }

    fn validate_root(&self, root: &HostDirectory) -> Result<(), StoreError> {
        use std::os::unix::fs::MetadataExt;
        let linked =
            std::fs::symlink_metadata(&self.directory).map_err(|_| StoreError::UnsafeDirectory)?;
        if !linked.is_dir()
            || root
                .directory_identity()
                .map_err(|_| StoreError::UnsafeDirectory)?
                != (linked.dev(), linked.ino())
        {
            return Err(StoreError::UnsafeDirectory);
        }
        Ok(())
    }

    fn transaction<T>(
        &self,
        body: impl FnOnce(&HostDirectory) -> Result<T, StoreError>,
    ) -> Result<T, StoreError> {
        let root = self.open()?;
        let lock = root
            .lock_update_record(STATE_LOCK, true)
            .map_err(lock_error)?;
        self.validate_root(&root)?;
        let result = body(&root)?;
        lock.validate_link(&root, STATE_LOCK)
            .map_err(|_| StoreError::RecordUnreadable)?;
        self.validate_root(&root)?;
        Ok(result)
    }

    pub fn load(&self, now: &str) -> Result<Snapshot, StoreError> {
        self.transaction(|root| {
            if let Some(snapshot) = read(root)? {
                return Ok(snapshot);
            }
            let snapshot = Snapshot::initial(&self.timestamp(now));
            save(root, &snapshot)?;
            Ok(snapshot)
        })
    }

    pub fn replace(
        &self,
        expected_generation: u64,
        state: State,
        active_operation_id: Option<String>,
        cancellation_requested: bool,
        now: &str,
    ) -> Result<Snapshot, StoreError> {
        self.transaction(|root| {
            let current = read(root)?.unwrap_or_else(|| Snapshot::initial(&self.timestamp(now)));
            if current.generation != expected_generation || current.generation == u64::MAX {
                return Err(StoreError::ResourceConflict);
            }
            let next = Snapshot {
                generation: current.generation + 1,
                state,
                active_operation_id: active_operation_id.map(|id| id.to_ascii_uppercase()),
                cancellation_requested,
                updated_at_utc: self.timestamp(now),
                ..current
            };
            save(root, &next)?;
            Ok(next)
        })
    }

    pub fn request_cancellation(&self, now: &str) -> Result<Snapshot, StoreError> {
        self.transaction(|root| {
            let mut current =
                read(root)?.unwrap_or_else(|| Snapshot::initial(&self.timestamp(now)));
            if current.active_operation_id.is_none() {
                return Ok(current);
            }
            current.generation = current
                .generation
                .checked_add(1)
                .ok_or(StoreError::ResourceConflict)?;
            current.cancellation_requested = true;
            current.updated_at_utc = self.timestamp(now);
            save(root, &current)?;
            Ok(current)
        })
    }

    /// Complete the held operation under the same short lock as cancellation.
    /// In particular, cancellation cannot race a separate read/CAS gap and
    /// turn an already observed Finder reveal into an untrue cancelled state.
    pub(crate) fn complete_operation(
        &self,
        operation_id: &str,
        minimum_generation: Option<u64>,
        result: State,
        now: &str,
    ) -> Result<Option<(Snapshot, bool)>, StoreError> {
        self.transaction(|root| {
            let current = read(root)?.ok_or(StoreError::RecordUnreadable)?;
            if current.active_operation_id.as_deref() != Some(operation_id) {
                return if minimum_generation.is_none() {
                    Ok(None)
                } else {
                    Err(StoreError::ResourceConflict)
                };
            }
            if minimum_generation.is_some_and(|minimum| current.generation < minimum) {
                return Err(StoreError::ResourceConflict);
            }
            let cancelled =
                current.cancellation_requested && !matches!(result, State::HandedOff { .. });
            let next = Snapshot {
                generation: current
                    .generation
                    .checked_add(1)
                    .ok_or(StoreError::ResourceConflict)?,
                state: if cancelled {
                    State::Cancelled {}
                } else {
                    result
                },
                active_operation_id: None,
                cancellation_requested: false,
                updated_at_utc: self.timestamp(now),
                ..current
            };
            save(root, &next)?;
            Ok(Some((next, cancelled)))
        })
    }

    pub fn acquire_operation_lease(&self) -> Result<HostReadLock, StoreError> {
        let root = self.open()?;
        let lock = root
            .lock_update_record(OPERATION_LOCK, false)
            .map_err(|error| {
                if error.kind() == std::io::ErrorKind::WouldBlock {
                    StoreError::OperationInProgress
                } else {
                    lock_error(error)
                }
            })?;
        self.validate_root(&root)?;
        Ok(lock)
    }
}

fn lock_error(error: std::io::Error) -> StoreError {
    if error.kind() == std::io::ErrorKind::InvalidData {
        StoreError::RecordUnreadable
    } else {
        StoreError::WriteFailed
    }
}

fn canonical(snapshot: &Snapshot) -> Result<Vec<u8>, StoreError> {
    let value = serde_json::to_value(snapshot).map_err(|_| StoreError::WriteFailed)?;
    serde_json::to_vec(&value).map_err(|_| StoreError::WriteFailed)
}

fn read(root: &HostDirectory) -> Result<Option<Snapshot>, StoreError> {
    let Some(bytes) = root
        .read_sealed_record(STATE, MAXIMUM)
        .map_err(|_| StoreError::RecordUnreadable)?
    else {
        return Ok(None);
    };
    let snapshot: Snapshot =
        serde_json::from_slice(&bytes).map_err(|_| StoreError::RecordUnreadable)?;
    if !snapshot.is_valid()
        || canonical(&snapshot).map_err(|_| StoreError::RecordUnreadable)? != bytes
    {
        return Err(StoreError::RecordUnreadable);
    }
    Ok(Some(snapshot))
}

fn save(root: &HostDirectory, snapshot: &Snapshot) -> Result<(), StoreError> {
    if !snapshot.is_valid() {
        return Err(StoreError::WriteFailed);
    }
    root.publish_sealed_record(STATE, &canonical(snapshot)?, MAXIMUM)
        .map_err(|_| StoreError::WriteFailed)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;
    const NOW: &str = "2026-09-26T00:00:00Z";
    const ID: &str = "ABCDEF01-2345-6789-ABCD-EF0123456789";

    struct Root(PathBuf);
    impl Root {
        fn new() -> Self {
            Self(
                std::env::temp_dir()
                    .join(format!("arkdeck-update-store-{}", crate::client_frame_id())),
            )
        }
    }
    impl Drop for Root {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn every_persisted_timestamp_uses_the_clock_while_holding_the_state_lock() {
        use std::sync::{
            Arc,
            atomic::{AtomicU64, Ordering},
        };
        let root = Root::new();
        let tick = Arc::new(AtomicU64::new(1));
        let tick_read = tick.clone();
        let path = root.0.clone();
        let store = Store::new(&root.0).with_clock(move || {
            let directory = HostDirectory::open_update_store(&path).unwrap();
            assert!(matches!(directory.lock_update_record(STATE_LOCK, false), Err(error) if error.kind() == std::io::ErrorKind::WouldBlock));
            format!("2026-09-26T00:00:{:02}Z", tick_read.load(Ordering::SeqCst))
        });
        assert_eq!(
            store.load(NOW).unwrap().updated_at_utc,
            "2026-09-26T00:00:01Z"
        );
        tick.store(2, Ordering::SeqCst);
        assert_eq!(
            store
                .replace(0, State::Checking {}, Some(ID.into()), false, NOW)
                .unwrap()
                .updated_at_utc,
            "2026-09-26T00:00:02Z"
        );
        tick.store(3, Ordering::SeqCst);
        assert_eq!(
            store.request_cancellation(NOW).unwrap().updated_at_utc,
            "2026-09-26T00:00:03Z"
        );
        tick.store(4, Ordering::SeqCst);
        let (finished, cancelled) = store
            .complete_operation(
                ID,
                Some(1),
                State::HandedOff {
                    url: "file:///private/tmp/fixture.dmg".into(),
                },
                NOW,
            )
            .unwrap()
            .unwrap();
        assert!(!cancelled);
        assert_eq!(finished.updated_at_utc, "2026-09-26T00:00:04Z");
        assert_eq!(store.load(NOW).unwrap(), finished);
        tick.store(5, Ordering::SeqCst);
        let started = store
            .replace(
                finished.generation,
                State::Checking {},
                Some(ID.into()),
                false,
                NOW,
            )
            .unwrap();
        assert_eq!(started.updated_at_utc, "2026-09-26T00:00:05Z");
        tick.store(6, Ordering::SeqCst);
        let (settled, _) = store
            .complete_operation(
                ID,
                None,
                State::Failed {
                    code: super::super::Failure::Feed,
                },
                NOW,
            )
            .unwrap()
            .unwrap();
        assert_eq!(settled.updated_at_utc, "2026-09-26T00:00:06Z");
    }

    #[test]
    fn two_owners_share_generation_cancellation_and_sealed_bytes() {
        let root = Root::new();
        let first = Store::new(&root.0);
        let second = Store::new(&root.0);
        assert_eq!(first.load(NOW).unwrap(), Snapshot::initial(NOW));
        let checking = first
            .replace(0, State::Checking {}, Some(ID.to_lowercase()), false, NOW)
            .unwrap();
        assert_eq!(checking.generation, 1);
        assert_eq!(checking.active_operation_id.as_deref(), Some(ID));
        assert_eq!(second.load("2026-09-27T00:00:00Z").unwrap(), checking);
        assert_eq!(
            second.replace(0, State::Idle {}, None, false, NOW),
            Err(StoreError::ResourceConflict)
        );
        let cancelled = second.request_cancellation(NOW).unwrap();
        assert_eq!(cancelled.generation, 2);
        assert!(cancelled.cancellation_requested);
        assert_eq!(first.load(NOW).unwrap(), cancelled);
        assert_eq!(
            std::fs::metadata(root.0.join(STATE))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o400
        );
        assert_eq!(
            std::fs::metadata(&root.0).unwrap().permissions().mode() & 0o777,
            0o700
        );
    }

    #[test]
    fn operation_lease_does_not_block_state_read_or_cancel() {
        let root = Root::new();
        let first = Store::new(&root.0);
        let second = Store::new(&root.0);
        let lease = first.acquire_operation_lease().unwrap();
        first
            .replace(0, State::Checking {}, Some(ID.into()), false, NOW)
            .unwrap();
        assert!(matches!(
            second.acquire_operation_lease(),
            Err(StoreError::OperationInProgress)
        ));
        assert_eq!(second.load(NOW).unwrap().generation, 1);
        assert!(
            second
                .request_cancellation(NOW)
                .unwrap()
                .cancellation_requested
        );
        drop(lease);
        let _new_owner = second.acquire_operation_lease().unwrap();
    }

    #[test]
    fn corrupt_writable_and_linked_records_are_refused_without_repair() {
        let root = Root::new();
        let store = Store::new(&root.0);
        let initial = store.load(NOW).unwrap();
        let path = root.0.join(STATE);
        let bytes = std::fs::read(&path).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
        assert_eq!(store.load(NOW), Err(StoreError::RecordUnreadable));
        let mut newline = bytes.clone();
        newline.push(b'\n');
        std::fs::write(&path, &newline).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o400)).unwrap();
        assert_eq!(store.load(NOW), Err(StoreError::RecordUnreadable));
        assert_eq!(std::fs::read(&path).unwrap(), newline);
        std::fs::remove_file(&path).unwrap();
        let other = root.0.join("outside.json");
        std::fs::write(&other, &bytes).unwrap();
        std::fs::set_permissions(&other, std::fs::Permissions::from_mode(0o400)).unwrap();
        std::os::unix::fs::symlink(&other, &path).unwrap();
        assert_eq!(store.load(NOW), Err(StoreError::RecordUnreadable));
        assert_eq!(std::fs::read(&other).unwrap(), canonical(&initial).unwrap());
    }

    #[test]
    fn overflow_and_invalid_active_states_do_not_change_the_record() {
        let root = Root::new();
        let store = Store::new(&root.0);
        let initial = store.load(NOW).unwrap();
        assert_eq!(
            store.replace(0, State::Checking {}, None, false, NOW),
            Err(StoreError::WriteFailed)
        );
        assert_eq!(
            store.replace(0, State::Idle {}, None, true, NOW),
            Err(StoreError::WriteFailed)
        );
        assert_eq!(store.load(NOW).unwrap(), initial);
        let full = Snapshot {
            generation: u64::MAX,
            ..initial
        };
        save(&store.open().unwrap(), &full).unwrap();
        assert_eq!(
            store.replace(u64::MAX, State::Idle {}, None, false, NOW),
            Err(StoreError::ResourceConflict)
        );
        assert_eq!(store.load(NOW).unwrap(), full);
    }

    #[test]
    fn actual_swift_states_reopen_and_project_without_private_paths() {
        let fixture: serde_json::Value = serde_json::from_str(include_str!(
            "../../../../tests/fixtures/runtime-update/states.json"
        ))
        .unwrap();
        let cases = fixture["cases"].as_array().unwrap();
        assert_eq!(cases.len(), 12);
        for case in cases {
            let encoded = case["snapshotBase64"].as_str().unwrap();
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
            let root = Root::new();
            let store = Store::new(&root.0);
            store
                .open()
                .unwrap()
                .publish_sealed_record(STATE, &bytes, MAXIMUM)
                .unwrap();
            let snapshot = store.load(NOW).unwrap();
            assert_eq!(canonical(&snapshot).unwrap(), bytes, "{}", case["name"]);
            assert_eq!(
                snapshot.projection(),
                case["projection"],
                "{}",
                case["name"]
            );
            assert!(
                !snapshot
                    .projection()
                    .to_string()
                    .contains("arkdeck-update-fixture")
            );
            assert!(!snapshot.projection().to_string().contains("FIXTURE123"));
        }
        let cases = fixture["urlCases"].as_array().unwrap();
        assert_eq!(cases.len(), 10);
        for case in cases {
            let encoded = case["snapshotBase64"].as_str().unwrap();
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
            let root = Root::new();
            let store = Store::new(&root.0);
            store
                .open()
                .unwrap()
                .publish_sealed_record(STATE, &bytes, MAXIMUM)
                .unwrap();
            assert_eq!(
                store.load(NOW).is_ok(),
                case["recordAccepted"].as_bool().unwrap(),
                "{}",
                case["url"]
            );
        }
    }
}
