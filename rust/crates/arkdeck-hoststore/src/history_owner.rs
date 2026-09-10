//! The Rust writer for the current, rebuildable History filter document.
//! Its caller supplies a dedicated physical directory; no legacy root is selected.
use crate::decode_history;
use arkdeck_contract::WireError;
use arkdeck_platform::{DocumentPublishError, HostDirectory};
use serde_json::{Map, Value, json};
use std::{
    io,
    path::{Path, PathBuf},
};

const DOCUMENT: &str = "history-filter.json";
const LOCK: &str = ".history-filter.lock";
const MAXIMUM: usize = 64 * 1024;
const EMPTY: &[u8] = b"{\"generation\":1,\"schemaVersion\":\"arkdeck.history-filter-store/1\"}\n";

pub struct HistoryStore {
    path: PathBuf,
    root: HostDirectory,
}
fn failure(code: &str, message: &str) -> WireError {
    WireError {
        code: code.into(),
        message: message.into(),
        details: Some(Map::from_iter([
            ("phase".into(), json!("historyFilterOwner")),
            ("newDispatchCount".into(), json!(0)),
        ])),
    }
}
fn unreadable(_: impl std::fmt::Debug) -> WireError {
    failure(
        "recordUnreadable",
        "History filter storage is unreadable or unsafe",
    )
}
impl HistoryStore {
    pub fn open(path: &Path) -> io::Result<Self> {
        Ok(Self {
            path: path.to_owned(),
            root: HostDirectory::open(path)?,
        })
    }

    pub fn handle(
        &self,
        method: &str,
        params: &Map<String, Value>,
        now: &str,
    ) -> Result<Value, WireError> {
        let list = method == "history.filter.list";
        let delete = method == "history.filter.delete";
        if !list && !delete && method != "history.filter.save" {
            return Err(failure("unknownMethod", "not a History filter method"));
        }
        let keys: &[&str] = if list {
            &[]
        } else if delete {
            &["expectedGeneration"]
        } else {
            &[
                "expectedGeneration",
                "search",
                "status",
                "mode",
                "sessionId",
                "targetId",
                "timeRange",
                "activity",
            ]
        };
        if params.len() != keys.len() || keys.iter().any(|key| !params.contains_key(*key)) {
            return Err(failure(
                "invalidParams",
                "History filter requires its complete typed parameters",
            ));
        }
        let expected = if list {
            0
        } else {
            let text = params["expectedGeneration"].as_str().unwrap_or("");
            text.parse::<u64>()
                .ok()
                .filter(|n| *n > 0 && *n <= i64::MAX as u64 && n.to_string() == text)
                .ok_or_else(|| {
                    failure(
                        "invalidParams",
                        "expectedGeneration must be a canonical positive integer",
                    )
                })?
        };
        let mut query = Map::new();
        if !list && !delete {
            for key in ["search", "status", "mode", "timeRange", "activity"] {
                if !params[key].is_string() {
                    return Err(failure(
                        "invalidParams",
                        "History filter query fields must be strings",
                    ));
                }
                query.insert(key.into(), params[key].clone());
            }
            for (wire, stored) in [("sessionId", "sessionID"), ("targetId", "targetID")] {
                match &params[wire] {
                    Value::Null => {}
                    Value::String(_) => {
                        query.insert(stored.into(), params[wire].clone());
                    }
                    _ => {
                        return Err(failure(
                            "invalidParams",
                            "History filter identities must be strings or null",
                        ));
                    }
                }
            }
            // Validate the query before opening the transaction or reporting CAS.
            let sample = json!({"schemaVersion":"arkdeck.history-filter-store/1", "generation":2,
                "updatedAtUTC":"2026-09-10T00:00:00.000Z", "query":query});
            decode_history(&serde_json::to_vec(&sample).map_err(unreadable)?).map_err(|_| {
                failure(
                    "invalidInput",
                    "History filter query contains an unsupported value",
                )
            })?;
        }
        self.root.validate_path(&self.path).map_err(unreadable)?;
        let lock = self.root.lock_document(LOCK).map_err(|error| {
            if error.kind() == io::ErrorKind::WouldBlock {
                failure("resourceConflict", "History filter is being updated")
            } else {
                unreadable(error)
            }
        })?;
        let bytes = match self.root.read(DOCUMENT, MAXIMUM) {
            Ok(bytes) => bytes,
            Err(error) if error.kind() == io::ErrorKind::NotFound => EMPTY.to_vec(),
            Err(error) => return Err(unreadable(error)),
        };
        let loaded = decode_history(&bytes).map_err(unreadable)?;
        lock.validate_link(&self.root, LOCK).map_err(unreadable)?;
        self.root.validate_path(&self.path).map_err(unreadable)?;
        if list {
            return Ok(loaded.projection);
        }
        if delete
            && loaded.projection["filters"]
                .as_array()
                .is_some_and(Vec::is_empty)
        {
            return Err(failure(
                "resourceNotFound",
                "no saved History filter exists",
            ));
        }
        let generation = loaded.projection["generation"]
            .as_str()
            .and_then(|s| s.parse::<u64>().ok())
            .ok_or_else(|| unreadable(()))?;
        if expected != generation || generation == i64::MAX as u64 {
            return Err(failure(
                "resourceConflict",
                "History filter generation changed or is exhausted",
            ));
        }
        let mut document = json!({"schemaVersion":"arkdeck.history-filter-store/1", "generation":generation + 1, "updatedAtUTC":now});
        if !delete {
            document["query"] = Value::Object(query);
        }
        let next = decode_history(&serde_json::to_vec(&document).map_err(unreadable)?)
            .map_err(unreadable)?;
        self.root.publish_document(DOCUMENT, &next.document, MAXIMUM)
            .map_err(|error| match error {
                DocumentPublishError::BeforePublication(_) => failure("ioFailure", "History filter transaction could not be written"),
                DocumentPublishError::OutcomeUnknown(_) => failure("outcomeUnknown", "History filter publication interrupted; read current generation before another update"),
            })?;
        lock.validate_link(&self.root, LOCK).map_err(|_| failure("outcomeUnknown", "History filter namespace changed during publication; read current state before another update"))?;
        self.root.validate_path(&self.path).map_err(|_| failure("outcomeUnknown", "History filter namespace changed during publication; read current state before another update"))?;
        if delete {
            Ok(
                json!({"schemaVersion":"arkdeck.history-filter/1", "generation":(generation + 1).to_string(), "query":null, "updatedAtUtc":now}),
            )
        } else {
            Ok(next.projection["filters"][0].clone())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        fs,
        os::unix::fs::{DirBuilderExt, symlink},
        sync::{Arc, Barrier},
    };
    const NOW: &str = "2026-09-10T00:00:00.000Z";
    struct Root(PathBuf);
    impl Root {
        fn new() -> Self {
            let nonce = arkdeck_platform::random_bytes::<16>().unwrap();
            let path = std::env::temp_dir()
                .canonicalize()
                .unwrap()
                .join(format!("history-owner-{:x}", u128::from_ne_bytes(nonce)));
            fs::DirBuilder::new().mode(0o700).create(&path).unwrap();
            Self(path)
        }
        fn open(&self) -> HistoryStore {
            HistoryStore::open(&self.0).unwrap()
        }
    }
    impl Drop for Root {
        fn drop(&mut self) {
            fs::remove_dir_all(&self.0).unwrap();
        }
    }
    fn save(generation: &str) -> Map<String, Value> {
        json!({"expectedGeneration":generation, "search":"build", "status":"failed", "mode":"all", "timeRange":"lastDay", "activity":"all", "sessionId":null, "targetId":null}).as_object().unwrap().clone()
    }
    #[test]
    fn restart_reads_save_and_delete_without_resetting_generation() {
        let root = Root::new();
        assert_eq!(
            root.open()
                .handle("history.filter.list", &Map::new(), NOW)
                .unwrap()["generation"],
            "1"
        );
        assert_eq!(
            root.open()
                .handle("history.filter.save", &save("1"), NOW)
                .unwrap()["generation"],
            "2"
        );
        let read = root
            .open()
            .handle("history.filter.list", &Map::new(), NOW)
            .unwrap();
        assert_eq!(read["filters"][0]["query"]["search"], "build");
        assert_eq!(
            root.open()
                .handle("history.filter.save", &save("1"), NOW)
                .unwrap_err()
                .code,
            "resourceConflict"
        );
        let delete = json!({"expectedGeneration":"2"})
            .as_object()
            .unwrap()
            .clone();
        root.open()
            .handle("history.filter.delete", &delete, NOW)
            .unwrap();
        let read = root
            .open()
            .handle("history.filter.list", &Map::new(), NOW)
            .unwrap();
        assert_eq!(read["generation"], "3");
        assert_eq!(read["filters"], json!([]));
        assert!(
            !fs::read_dir(&root.0).unwrap().any(|e| e
                .unwrap()
                .file_name()
                .to_string_lossy()
                .ends_with(".part"))
        );
    }
    #[test]
    fn separate_owners_cannot_both_win_the_same_generation() {
        let root = Root::new();
        let barrier = Arc::new(Barrier::new(2));
        let workers: Vec<_> = (0..2)
            .map(|_| {
                let owner = root.open();
                let barrier = barrier.clone();
                std::thread::spawn(move || {
                    barrier.wait();
                    owner.handle("history.filter.save", &save("1"), NOW)
                })
            })
            .collect();
        let results: Vec<_> = workers
            .into_iter()
            .map(|worker| worker.join().unwrap())
            .collect();
        assert_eq!(results.iter().filter(|r| r.is_ok()).count(), 1);
        assert_eq!(
            results.iter().find_map(|r| r.as_ref().err()).unwrap().code,
            "resourceConflict"
        );
        assert_eq!(
            root.open()
                .handle("history.filter.list", &Map::new(), NOW)
                .unwrap()["generation"],
            "2"
        );
    }
    #[test]
    fn corrupt_document_and_link_are_never_replaced() {
        let root = Root::new();
        let owner = root.open();
        fs::write(root.0.join(DOCUMENT), b"corrupt").unwrap();
        assert_eq!(
            owner
                .handle("history.filter.save", &save("1"), NOW)
                .unwrap_err()
                .code,
            "recordUnreadable"
        );
        assert_eq!(fs::read(root.0.join(DOCUMENT)).unwrap(), b"corrupt");
        fs::remove_file(root.0.join(DOCUMENT)).unwrap();
        symlink("missing", root.0.join(DOCUMENT)).unwrap();
        assert_eq!(
            owner
                .handle("history.filter.save", &save("1"), NOW)
                .unwrap_err()
                .code,
            "recordUnreadable"
        );
        assert!(
            fs::symlink_metadata(root.0.join(DOCUMENT))
                .unwrap()
                .is_symlink()
        );
    }
}
