//! Signed-feed watermark. Admission and publication are one flock transaction;
//! refused candidates never lower or rewrite the last accepted record.
use crate::update_feed::semantic_version;
use arkdeck_platform::HostDirectory;
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

const RECORD: &str = "replay-state-v1.json";
const LOCK: &str = ".replay-state-v1.lock";
const MAXIMUM: usize = 4096;
type Error = &'static str;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReplayRecord {
    pub sequence: u64,
    #[serde(rename = "payloadSHA256")]
    pub payload_sha256: String,
    pub version: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReplayDecision {
    Accepted,
    Replay,
    SequenceConflict,
    NonIncreasingRelease,
}

impl ReplayRecord {
    fn valid(&self) -> bool {
        self.sequence > 0
            && semantic_version(&self.version).is_some()
            && self.payload_sha256.len() == 64
            && self
                .payload_sha256
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    }

    fn bytes(&self) -> Result<Vec<u8>, Error> {
        let value = serde_json::to_value(self).map_err(|_| "replayStateWriteFailed")?;
        serde_json::to_vec(&value).map_err(|_| "replayStateWriteFailed")
    }

    pub fn decision(&self, previous: Option<&Self>) -> ReplayDecision {
        let Some(previous) = previous else {
            return ReplayDecision::Accepted;
        };
        if self.sequence < previous.sequence {
            return ReplayDecision::Replay;
        }
        if self.sequence == previous.sequence {
            return if self == previous {
                ReplayDecision::Accepted
            } else {
                ReplayDecision::SequenceConflict
            };
        }
        match (
            semantic_version(&previous.version),
            semantic_version(&self.version),
        ) {
            (Some(previous), Some(candidate)) if previous < candidate => ReplayDecision::Accepted,
            _ => ReplayDecision::NonIncreasingRelease,
        }
    }
}

pub struct ReplayStore {
    directory: PathBuf,
}

impl ReplayStore {
    pub fn new(directory: impl Into<PathBuf>) -> Self {
        Self {
            directory: directory.into(),
        }
    }

    fn validate_root(&self, root: &HostDirectory) -> Result<(), Error> {
        use std::os::unix::fs::MetadataExt;
        let linked =
            std::fs::symlink_metadata(&self.directory).map_err(|_| "replayStateWriteFailed")?;
        if !linked.is_dir()
            || root
                .directory_identity()
                .map_err(|_| "replayStateWriteFailed")?
                != (linked.dev(), linked.ino())
        {
            return Err("replayStateWriteFailed");
        }
        Ok(())
    }

    fn transaction<T>(
        &self,
        body: impl FnOnce(&HostDirectory) -> Result<T, Error>,
    ) -> Result<T, Error> {
        let root = HostDirectory::open_update_store(&self.directory)
            .map_err(|_| "replayStateWriteFailed")?;
        let lock = root
            .lock_update_record(LOCK, true)
            .map_err(|_| "replayStateWriteFailed")?;
        self.validate_root(&root)?;
        let result = body(&root)?;
        lock.validate_link(&root, LOCK)
            .map_err(|_| "replayStateWriteFailed")?;
        self.validate_root(&root)?;
        Ok(result)
    }

    pub fn load(&self) -> Result<Option<ReplayRecord>, Error> {
        self.transaction(read)
    }

    pub fn admit(&self, candidate: &ReplayRecord) -> Result<ReplayDecision, Error> {
        if !candidate.valid() {
            return Err("replayStateWriteFailed");
        }
        self.transaction(|root| {
            let previous = read(root)?;
            let decision = candidate.decision(previous.as_ref());
            if decision == ReplayDecision::Accepted && previous.as_ref() != Some(candidate) {
                root.publish_sealed_record(RECORD, &candidate.bytes()?, MAXIMUM)
                    .map_err(|_| "replayStateWriteFailed")?;
            }
            Ok(decision)
        })
    }
}

fn read(root: &HostDirectory) -> Result<Option<ReplayRecord>, Error> {
    let Some(bytes) = root
        .read_sealed_record(RECORD, MAXIMUM)
        .map_err(|_| "replayStateCorrupt")?
    else {
        return Ok(None);
    };
    let record: ReplayRecord = serde_json::from_slice(&bytes).map_err(|_| "replayStateCorrupt")?;
    if !record.valid() || record.bytes().map_err(|_| "replayStateCorrupt")? != bytes {
        return Err("replayStateCorrupt");
    }
    Ok(Some(record))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::{MetadataExt, PermissionsExt};

    struct Root(PathBuf);
    impl Root {
        fn new() -> Self {
            Self(std::env::temp_dir().join(format!("arkdeck-replay-{}", crate::client_frame_id())))
        }
    }
    impl Drop for Root {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
    fn candidate(digest: char) -> ReplayRecord {
        ReplayRecord {
            sequence: 1,
            version: "1.0.0".into(),
            payload_sha256: digest.to_string().repeat(64),
        }
    }
    fn decode(value: &serde_json::Value) -> Vec<u8> {
        let encoded = value.as_str().unwrap();
        let padding = encoded.bytes().rev().take_while(|b| *b == b'=').count();
        arkdeck_contract::decode_import_chunk(encoded, (encoded.len() / 4 * 3 - padding) as u64)
            .unwrap()
    }

    #[test]
    fn actual_swift_admissions_reopen_the_same_immutable_watermark() {
        let root = Root::new();
        let store = ReplayStore::new(&root.0);
        let oracle: serde_json::Value = serde_json::from_str(include_str!(
            "../../../../tests/fixtures/runtime-update/replay.json"
        ))
        .unwrap();
        for row in oracle["cases"].as_array().unwrap() {
            let record: ReplayRecord =
                serde_json::from_slice(&decode(&row["candidateBase64"])).unwrap();
            let decision = match store.admit(&record) {
                Ok(ReplayDecision::Accepted) => "accepted",
                Ok(ReplayDecision::Replay) => "replay",
                Ok(ReplayDecision::SequenceConflict) => "sequenceConflict",
                Ok(ReplayDecision::NonIncreasingRelease) => "nonIncreasingRelease",
                Err(error) => error,
            };
            assert_eq!(decision, row["decision"], "{}", row["name"]);
            let bytes = std::fs::read(root.0.join(RECORD)).unwrap();
            assert_eq!(bytes, decode(&row["recordBase64"]), "{}", row["name"]);
            assert_eq!(
                std::fs::metadata(root.0.join(RECORD)).unwrap().mode() & 0o777,
                0o400
            );
            assert_eq!(
                ReplayStore::new(&root.0)
                    .load()
                    .unwrap()
                    .unwrap()
                    .bytes()
                    .unwrap(),
                bytes
            );
        }
    }

    #[test]
    fn idempotent_admission_never_republishes_and_bad_state_is_not_repaired() {
        let root = Root::new();
        let store = ReplayStore::new(&root.0);
        assert_eq!(store.load().unwrap(), None);
        let record = candidate('a');
        store.admit(&record).unwrap();
        let path = root.0.join(RECORD);
        let before = std::fs::metadata(&path).unwrap();
        assert_eq!(store.admit(&record), Ok(ReplayDecision::Accepted));
        let after = std::fs::metadata(&path).unwrap();
        assert_eq!(
            (before.ino(), before.ctime(), before.ctime_nsec()),
            (after.ino(), after.ctime(), after.ctime_nsec())
        );
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
        assert_eq!(store.admit(&record), Err("replayStateCorrupt"));
        assert_eq!(std::fs::metadata(&path).unwrap().mode() & 0o777, 0o600);
        std::fs::write(&path, b"{}\n").unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o400)).unwrap();
        assert_eq!(store.load(), Err("replayStateCorrupt"));
        assert_eq!(std::fs::read(&path).unwrap(), b"{}\n");
    }

    #[test]
    fn separate_owners_admit_only_one_digest_for_a_sequence() {
        let root = Root::new();
        let barrier = std::sync::Barrier::new(2);
        let results = std::thread::scope(|scope| {
            let handles: Vec<_> = ['a', 'b']
                .into_iter()
                .map(|digest| {
                    let directory = &root.0;
                    let barrier = &barrier;
                    scope.spawn(move || {
                        barrier.wait();
                        ReplayStore::new(directory).admit(&candidate(digest))
                    })
                })
                .collect();
            handles
                .into_iter()
                .map(|handle| handle.join().unwrap().unwrap())
                .collect::<Vec<_>>()
        });
        assert_eq!(
            results
                .iter()
                .filter(|r| **r == ReplayDecision::Accepted)
                .count(),
            1
        );
        assert_eq!(
            results
                .iter()
                .filter(|r| **r == ReplayDecision::SequenceConflict)
                .count(),
            1
        );
        assert!(ReplayStore::new(&root.0).load().unwrap().is_some());
    }
}
