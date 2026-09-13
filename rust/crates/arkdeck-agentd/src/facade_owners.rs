//! Host-only stores the macOS facade serves itself (TASK-XPA-012 installed
//! composition). The paired Swift authority is composed without them, so no
//! lock below ever has two processes behind it. Every other method is still
//! forwarded unchanged.
use arkdeck_contract::{ContractError, DeviceObservationsResult, WireError};
use arkdeck_control::{Control, HdcStatus, HostServices};
use serde_json::{Map, Value, json};
use std::{
    path::PathBuf,
    sync::{Mutex, PoisonError},
};

/// Keep in step with Swift `AgentFacadeHostOwnership.methods`, which composes
/// the paired authority without these owners.
pub const LOCAL_METHODS: [&str; 3] = [
    "history.filter.delete",
    "history.filter.list",
    "history.filter.save",
];

pub struct FacadeOwners(Control<StateOwners>);

impl FacadeOwners {
    /// `state` is the paired authority's state directory: the same path the
    /// facade hands to Swift as `--state-dir`, or its installed default.
    pub fn new(state: PathBuf) -> Result<Self, ContractError> {
        Ok(Self(Control::new(StateOwners {
            state,
            history: Mutex::new(()),
        })?))
    }

    /// The reply for a locally owned method; `None` belongs to the paired
    /// authority. The frame is the complete current request without its LF.
    pub fn handle(&self, method: &str, frame: &[u8]) -> Option<Vec<u8>> {
        LOCAL_METHODS
            .contains(&method)
            .then(|| self.0.handle_frame(frame))
    }
}

struct StateOwners {
    state: PathBuf,
    history: Mutex<()>,
}

impl HostServices for StateOwners {
    fn history_filter(
        &self,
        method: &str,
        params: &Map<String, Value>,
    ) -> Result<Value, WireError> {
        // The Swift owner this replaces waited for its lock, so concurrent App
        // and CLI requests to this process queue instead of refusing each
        // other as a foreign owner. Another process holding the lock is still
        // refused. The guard protects no data, so a poisoned one is reusable.
        let _serial = self.history.lock().unwrap_or_else(PoisonError::into_inner);
        // Reopen per request: a replaced or unsafe directory fails that
        // request only, and a repaired one needs no facade restart.
        arkdeck_hoststore::HistoryStore::open(&self.state)
            .map_err(|_| unreadable())?
            .handle(method, params, &crate::host::utc_now())
    }

    fn observed_at(&self) -> String {
        crate::host::utc_now()
    }

    fn hdc_status(&self, deep: bool) -> HdcStatus {
        HdcStatus::unavailable(deep, "hdc.notConfigured")
    }

    fn observations(&self) -> Result<DeviceObservationsResult, WireError> {
        Err(WireError {
            code: "rejected".into(),
            message: "device observations belong to the paired Runtime authority".into(),
            details: None,
        })
    }
}

fn unreadable() -> WireError {
    WireError {
        code: "recordUnreadable".into(),
        message: "History filter storage is unreadable or unsafe".into(),
        details: Some(Map::from_iter([
            ("phase".into(), json!("historyFilterOwner")),
            ("newDispatchCount".into(), json!(0)),
        ])),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use arkdeck_contract::{CONTRACT_IDENTITY, PROTOCOL_VERSION};
    use std::{fs, os::unix::fs::DirBuilderExt, path::Path, sync::Arc};

    struct Root(PathBuf);
    impl Root {
        fn new() -> Self {
            let path = std::env::temp_dir().canonicalize().unwrap().join(format!(
                "facade-owners-{}",
                crate::host::fresh_id().unwrap()
            ));
            fs::DirBuilder::new().mode(0o700).create(&path).unwrap();
            Self(path)
        }
    }
    impl Drop for Root {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    fn frame(method: &str, params: Value) -> Vec<u8> {
        serde_json::to_vec(&json!({"protocolVersion":PROTOCOL_VERSION,
            "contractIdentity":CONTRACT_IDENTITY,"id":"facade-owner-test",
            "method":method,"params":params}))
        .unwrap()
    }

    fn reply(owners: &FacadeOwners, method: &str, params: Value) -> Value {
        let bytes = owners
            .handle(method, &frame(method, params))
            .expect("locally owned method");
        assert_eq!(bytes.last(), Some(&b'\n'));
        serde_json::from_slice(&bytes).unwrap()
    }

    fn save(generation: &str) -> Value {
        json!({"expectedGeneration":generation,"search":"build","status":"failed",
            "mode":"all","sessionId":null,"targetId":null,"timeRange":"lastDay","activity":"all"})
    }

    #[test]
    fn only_history_filter_methods_are_served_here() {
        let root = Root::new();
        let owners = FacadeOwners::new(root.0.clone()).unwrap();
        for method in [
            "health",
            "job.list",
            "runtime.storage.status",
            "trace.cache.purge",
        ] {
            assert!(owners.handle(method, &frame(method, json!({}))).is_none());
        }
        assert!(!root.0.join(".history-filter.lock").exists());
        let listed = reply(&owners, "history.filter.list", json!({}));
        assert_eq!(listed["result"]["generation"], "1");
        assert_eq!(
            reply(&owners, "history.filter.save", save("1"))["result"]["generation"],
            "2"
        );
        let stale = reply(&owners, "history.filter.save", save("1"));
        assert_eq!(stale["error"]["code"], "resourceConflict");
        assert_eq!(stale["error"]["details"]["newDispatchCount"], 0);
        // A new facade process reads the same durable document.
        let restarted = FacadeOwners::new(root.0.clone()).unwrap();
        let persisted = reply(&restarted, "history.filter.list", json!({}));
        assert_eq!(
            persisted["result"]["filters"][0]["query"]["search"],
            "build"
        );
        assert_eq!(
            reply(
                &restarted,
                "history.filter.delete",
                json!({"expectedGeneration":"2"})
            )["result"]["generation"],
            "3"
        );
    }

    #[test]
    fn concurrent_requests_queue_instead_of_refusing_each_other() {
        let root = Root::new();
        let owners = Arc::new(FacadeOwners::new(root.0.clone()).unwrap());
        assert_eq!(
            reply(&owners, "history.filter.save", save("1"))["result"]["generation"],
            "2"
        );
        let workers: Vec<_> = (0..8)
            .map(|_| {
                let owners = Arc::clone(&owners);
                std::thread::spawn(move || {
                    (0..16)
                        .map(|_| reply(&owners, "history.filter.list", json!({})))
                        .collect::<Vec<_>>()
                })
            })
            .collect();
        for worker in workers {
            for answer in worker.join().unwrap() {
                assert_eq!(answer["ok"], true, "{answer}");
                assert_eq!(answer["result"]["generation"], "2");
            }
        }
    }

    #[test]
    fn a_foreign_lock_holder_is_refused_and_nothing_is_written() {
        let root = Root::new();
        let owners = FacadeOwners::new(root.0.clone()).unwrap();
        assert_eq!(
            reply(&owners, "history.filter.save", save("1"))["result"]["generation"],
            "2"
        );
        let document = root.0.join("history-filter.json");
        let before = fs::read(&document).unwrap();
        let lock = fs::OpenOptions::new()
            .read(true)
            .write(true)
            .open(root.0.join(".history-filter.lock"))
            .unwrap();
        lock.try_lock().unwrap();
        for (method, params) in [
            ("history.filter.list", json!({})),
            ("history.filter.save", save("2")),
            ("history.filter.delete", json!({"expectedGeneration":"2"})),
        ] {
            let refused = reply(&owners, method, params);
            assert_eq!(refused["error"]["code"], "resourceConflict", "{method}");
        }
        assert_eq!(fs::read(&document).unwrap(), before);
        lock.unlock().unwrap();
        assert_eq!(
            reply(&owners, "history.filter.save", save("2"))["result"]["generation"],
            "3"
        );
    }

    #[test]
    fn an_unsafe_directory_fails_only_that_request() {
        let root = Root::new();
        let owners = FacadeOwners::new(root.0.join("missing")).unwrap();
        let refused = reply(&owners, "history.filter.list", json!({}));
        assert_eq!(refused["error"]["code"], "recordUnreadable");
        assert_eq!(refused["error"]["details"]["phase"], "historyFilterOwner");
        fs::DirBuilder::new()
            .mode(0o755)
            .create(root.0.join("missing"))
            .unwrap();
        let public = reply(&owners, "history.filter.list", json!({}));
        assert_eq!(public["error"]["code"], "recordUnreadable");
        fs::set_permissions(
            root.0.join("missing"),
            std::os::unix::fs::PermissionsExt::from_mode(0o700),
        )
        .unwrap();
        let repaired = reply(&owners, "history.filter.list", json!({}));
        assert_eq!(repaired["result"]["generation"], "1");
        assert!(Path::new(&root.0.join("missing/.history-filter.lock")).exists());
    }
}
