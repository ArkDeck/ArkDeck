//! Session configuration owner. The fixed private owner directory and default
//! Session tree are disjoint; requests can only select an existing private root.
use crate::{decode_session_configuration, session_inventory_owned};
use arkdeck_contract::WireError;
use arkdeck_platform::{DocumentPublishError, HostDirectory};
use serde_json::{Map, Value, json};
use std::{
    io,
    path::{Path, PathBuf},
};
const DOCUMENT: &str = "session-storage.json";
const LOCK: &str = ".session-storage.lock";
const MAXIMUM: usize = 64 * 1024;

#[path = "session_cleanup_owner.rs"]
mod cleanup;
#[path = "session_export_owner.rs"]
mod export;

pub struct SessionStore {
    path: PathBuf,
    root: HostDirectory,
    default_sessions: PathBuf,
    boundary: Option<PathBuf>,
    reserved: Vec<PathBuf>,
}
fn failure(code: &str, message: &str) -> WireError {
    WireError {
        code: code.into(),
        message: message.into(),
        details: Some(Map::from_iter([
            ("phase".into(), json!("runtimeStorageOwner")),
            ("newDispatchCount".into(), json!(0)),
        ])),
    }
}
fn unreadable(_: impl std::fmt::Debug) -> WireError {
    failure(
        "recordUnreadable",
        "Session storage is unavailable or unsafe",
    )
}
fn positive(value: Option<&Value>) -> Result<u64, WireError> {
    let text = value.and_then(Value::as_str).unwrap_or("");
    text.parse::<u64>()
        .ok()
        .filter(|n| *n > 0 && *n <= i64::MAX as u64 && n.to_string() == text)
        .ok_or_else(|| {
            failure(
                "invalidInput",
                "Session settings require canonical positive integers",
            )
        })
}
fn bytes(value: &Value) -> Result<Vec<u8>, WireError> {
    let mut bytes = serde_json::to_vec(value).map_err(unreadable)?;
    bytes.push(b'\n');
    Ok(bytes)
}
impl SessionStore {
    pub fn handle_resource(
        &self,
        method: &str,
        params: &Map<String, Value>,
    ) -> Result<Value, WireError> {
        use crate::snapshot_pager::{SnapshotPager, failure};
        if method == "session.list" {
            if params
                .keys()
                .any(|key| !["pageSize", "cursor"].contains(&key.as_str()))
            {
                return Err(failure("invalidInput", "Session list options are closed"));
            }
            let page_size = match params.get("pageSize") {
                None => 100,
                Some(value) => value
                    .as_u64()
                    .filter(|count| (1..=1000).contains(count))
                    .ok_or_else(|| failure("invalidInput", "pageSize must be between 1 and 1000"))?
                    as usize,
            };
            let cursor = match params.get("cursor") {
                None => None,
                Some(Value::String(value)) if !value.is_empty() && value.len() <= 2048 => {
                    Some(value.as_str())
                }
                _ => return Err(failure("invalidCursor", "Session cursor is malformed")),
            };
            self.root
                .validate_path(&self.path)
                .map_err(|_| failure("recordUnreadable", "Session owner is unavailable"))?;
            self.root
                .private_child("session-resource-snapshots")
                .map_err(|_| {
                    failure(
                        "recordUnreadable",
                        "Session snapshot directory is unavailable",
                    )
                })?;
            let pager = SnapshotPager::open(&self.path.join("session-resource-snapshots"))
                .map_err(|_| {
                    failure(
                        "recordUnreadable",
                        "Session snapshot directory is unavailable",
                    )
                })?;
            return pager.page(
                method,
                "completedAtDescSessionIdAsc",
                page_size,
                cursor,
                || self.resource_rows(None, None),
            );
        }
        let mutation = matches!(method, "session.pin" | "session.unpin");
        if !mutation && method != "session.show" {
            return Err(failure("unknownMethod", "Not a Session resource method"));
        }
        let keys: &[&str] = if mutation {
            &["sessionId", "expectedGeneration"]
        } else {
            &["sessionId"]
        };
        if params.len() != keys.len() || keys.iter().any(|key| !params.contains_key(*key)) {
            return Err(failure(
                "invalidInput",
                "Session resource parameters are closed",
            ));
        }
        let id = params["sessionId"]
            .as_str()
            .filter(|id| crate::session_manifest::identifier(id))
            .ok_or_else(|| {
                failure(
                    "invalidInput",
                    "sessionId must be one bounded Runtime identifier",
                )
            })?;
        let pin = if mutation {
            let text = params["expectedGeneration"].as_str().unwrap_or("");
            let expected = text
                .parse::<u64>()
                .ok()
                .filter(|value| *value <= i64::MAX as u64 && value.to_string() == text)
                .ok_or_else(|| {
                    failure(
                        "invalidInput",
                        "Session pin requires a canonical catalog generation",
                    )
                })?;
            Some((expected, method == "session.pin"))
        } else {
            None
        };
        self.resource_rows(Some(id), pin)?
            .into_iter()
            .next()
            .ok_or_else(|| {
                failure(
                    "resourceNotFound",
                    "Session is not present in the Runtime catalog",
                )
            })
    }

    fn resource_rows(
        &self,
        selected: Option<&str>,
        pin: Option<(u64, bool)>,
    ) -> Result<Vec<Value>, WireError> {
        use crate::snapshot_pager::failure;
        let unavailable = |_| {
            failure(
                "recordUnreadable",
                "Session storage is unavailable or unsafe",
            )
        };
        self.root.validate_path(&self.path).map_err(unavailable)?;
        let lock = self.root.lock_document(LOCK).map_err(|error| {
            if error.kind() == io::ErrorKind::WouldBlock {
                failure("resourceConflict", "Session storage is being updated")
            } else {
                unavailable(error)
            }
        })?;
        let loaded = match self.root.read(DOCUMENT, MAXIMUM) {
            Ok(value) => value,
            Err(error) if error.kind() == io::ErrorKind::NotFound => bytes(&json!({
                "schemaVersion":"arkdeck.session-storage-store/1", "generation":1,
                "rootKind":"default", "rootPath":self.default_sessions,
                "policy":{"totalQuotaBytes":21474836480_u64,"safetyMarginBytes":2147483648_u64,"retentionDays":90}}))?,
            Err(error) => return Err(unavailable(error)),
        };
        let document = decode_session_configuration(&loaded)
            .map_err(|_| unavailable(io::Error::other("invalid configuration")))?;
        let path = PathBuf::from(
            document.projection["rootPath"]
                .as_str()
                .ok_or_else(|| unavailable(io::Error::other("missing root")))?,
        );
        if document.projection["rootKind"] == "default" && path != self.default_sessions {
            return Err(unavailable(io::Error::other("default root mismatch")));
        }
        self.selected_root(&path)
            .map_err(|_| unavailable(io::Error::other("invalid selected root")))?;
        let result =
            crate::session_inventory::session_resource_rows(&loaded, &path, selected, pin)?;
        if lock.validate_link(&self.root, LOCK).is_err()
            || self.root.validate_path(&self.path).is_err()
        {
            return Err(failure(
                if pin.is_some() {
                    "outcomeUnknown"
                } else {
                    "recordUnreadable"
                },
                "Session owner changed while reading the catalog",
            ));
        }
        Ok(result)
    }

    pub fn open(path: &Path, default_sessions: &Path) -> io::Result<Self> {
        let root = HostDirectory::open(path)?;
        let default_root = HostDirectory::open(default_sessions)?;
        default_root.validate_path(default_sessions)?;
        if path.starts_with(default_sessions) || default_sessions.starts_with(path) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "Session root must be disjoint from owner state",
            ));
        }
        Ok(Self {
            path: path.into(),
            root,
            default_sessions: default_sessions.into(),
            boundary: None,
            reserved: Vec::new(),
        })
    }
    pub fn isolated(mut self, boundary: &Path, reserved: Vec<PathBuf>) -> io::Result<Self> {
        HostDirectory::open(boundary)?.validate_path(boundary)?;
        if !self.path.starts_with(boundary) || !self.default_sessions.starts_with(boundary) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "Session owner is outside development state",
            ));
        }
        self.boundary = Some(boundary.into());
        self.reserved = reserved;
        self.selected_root(&self.default_sessions).map_err(|_| {
            io::Error::new(
                io::ErrorKind::InvalidInput,
                "Session default root overlaps reserved state",
            )
        })?;
        Ok(self)
    }
    fn selected_root(&self, path: &Path) -> Result<HostDirectory, WireError> {
        if self
            .boundary
            .as_ref()
            .is_some_and(|root| !path.starts_with(root))
            || self
                .reserved
                .iter()
                .any(|root| path.starts_with(root) || root.starts_with(path))
        {
            return Err(failure(
                "invalidInput",
                "Development Session root is outside isolated storage",
            ));
        }
        if path.starts_with(&self.path) || self.path.starts_with(path) {
            return Err(failure(
                "invalidInput",
                "Session root must be disjoint from owner state",
            ));
        }
        if path == self.default_sessions
            && matches!(std::fs::symlink_metadata(path), Err(e) if e.kind() == io::ErrorKind::NotFound)
        {
            let parent = path.parent().ok_or_else(|| unreadable(()))?;
            let name = path
                .file_name()
                .and_then(|v| v.to_str())
                .ok_or_else(|| unreadable(()))?;
            HostDirectory::open(parent)
                .and_then(|root| root.private_child(name))
                .map_err(unreadable)?;
        }
        let root = HostDirectory::open(path).map_err(unreadable)?;
        root.probe_writable().map_err(|error| {
            if matches!(
                error.kind(),
                io::ErrorKind::PermissionDenied
                    | io::ErrorKind::InvalidData
                    | io::ErrorKind::InvalidInput
            ) {
                failure(
                    "invalidInput",
                    "Session root is not safely writable by the Runtime owner",
                )
            } else {
                failure("ioFailure", "Session root write probe failed")
            }
        })?;
        root.validate_path(path).map_err(unreadable)?;
        Ok(root)
    }
    pub fn handle(&self, method: &str, params: &Map<String, Value>) -> Result<Value, WireError> {
        let status = method == "runtime.storage.status";
        let policy = method == "runtime.storage.policy";
        if !status && !policy && method != "runtime.storage.root" {
            return Err(failure("unknownMethod", "Not a Session storage method"));
        }
        let expected = if status {
            if !params.is_empty() {
                return Err(failure(
                    "invalidInput",
                    "Storage status accepts no parameters",
                ));
            }
            None
        } else {
            Some(positive(params.get("expectedGeneration"))?)
        };
        let replacement_policy = if policy {
            if params.len() != 4
                || ![
                    "expectedGeneration",
                    "totalQuotaBytes",
                    "safetyMarginBytes",
                    "retentionDays",
                ]
                .iter()
                .all(|k| params.contains_key(*k))
            {
                return Err(failure(
                    "invalidInput",
                    "Storage policy requires one closed policy document",
                ));
            }
            let quota = positive(params.get("totalQuotaBytes"))?;
            let margin = positive(params.get("safetyMarginBytes"))?;
            let days = positive(params.get("retentionDays"))?;
            if quota <= margin {
                return Err(failure(
                    "invalidInput",
                    "Storage quota must exceed its positive safety margin",
                ));
            }
            Some(json!({"totalQuotaBytes":quota,"safetyMarginBytes":margin,"retentionDays":days}))
        } else {
            None
        };
        let selection = if !status && !policy {
            if params.keys().any(|k| {
                !["expectedGeneration", "rootPath", "resetToDefault"].contains(&k.as_str())
            }) {
                return Err(failure("invalidInput", "Unexpected storage root parameter"));
            }
            match (params.get("rootPath"), params.get("resetToDefault")) {
                (None, Some(Value::Bool(true))) => Some((self.default_sessions.clone(), "default")),
                (Some(Value::String(path)), None)
                    if path.starts_with('/')
                        && path.len() <= 4096
                        && path.trim() == path
                        && !path.contains('\0') =>
                {
                    Some((
                        PathBuf::from(path).canonicalize().map_err(unreadable)?,
                        "custom",
                    ))
                }
                _ => {
                    return Err(failure(
                        "invalidInput",
                        "Select exactly one existing root or resetToDefault",
                    ));
                }
            }
        } else {
            None
        };
        self.root.validate_path(&self.path).map_err(unreadable)?;
        let lock = self.root.lock_document(LOCK).map_err(|e| {
            if e.kind() == io::ErrorKind::WouldBlock {
                failure("resourceConflict", "Session storage is being updated")
            } else {
                unreadable(e)
            }
        })?;
        let loaded = match self.root.read(DOCUMENT, MAXIMUM) {
            Ok(value) => value,
            Err(e) if e.kind() == io::ErrorKind::NotFound => bytes(&json!({
                "schemaVersion":"arkdeck.session-storage-store/1", "generation":1,
                "rootKind":"default", "rootPath":self.default_sessions,
                "policy":{"totalQuotaBytes":21474836480_u64,"safetyMarginBytes":2147483648_u64,"retentionDays":90}}))?,
            Err(e) => return Err(unreadable(e)),
        };
        let decoded = decode_session_configuration(&loaded).map_err(unreadable)?;
        let mut document: Value = serde_json::from_slice(&decoded.document).map_err(unreadable)?;
        let current_path = PathBuf::from(
            document["rootPath"]
                .as_str()
                .ok_or_else(|| unreadable(()))?,
        );
        let canonical = match current_path.canonicalize() {
            Ok(path) => path == current_path,
            Err(e)
                if e.kind() == io::ErrorKind::NotFound
                    && (selection.is_some() || current_path == self.default_sessions) =>
            {
                true
            }
            Err(_) => false,
        };
        if !canonical
            || (document["rootKind"] == "default" && current_path != self.default_sessions)
        {
            return Err(unreadable(()));
        }
        let generation = document["generation"]
            .as_u64()
            .ok_or_else(|| unreadable(()))?;
        if let Some(expected) = expected {
            if expected != generation || generation == i64::MAX as u64 {
                return Err(failure(
                    "resourceConflict",
                    "Session settings generation changed or is exhausted",
                ));
            }
            if let Some(policy) = replacement_policy {
                document["policy"] = policy;
            }
            if let Some((path, kind)) = selection {
                self.selected_root(&path).map_err(|error| {
                    if error.code == "recordUnreadable" {
                        failure(
                            "invalidInput",
                            "Selected Session root is unavailable or unsafe",
                        )
                    } else {
                        error
                    }
                })?;
                document["rootPath"] = json!(path);
                document["rootKind"] = json!(kind);
            }
            document["generation"] = json!(generation + 1);
        }
        let next = bytes(&document)?;
        decode_session_configuration(&next).map_err(unreadable)?;
        let selected = PathBuf::from(
            document["rootPath"]
                .as_str()
                .ok_or_else(|| unreadable(()))?,
        );
        self.selected_root(&selected).map_err(|error| {
            if error.code == "invalidInput" {
                unreadable(error)
            } else {
                error
            }
        })?;
        // Reconcile the real tree before committing config. A measurement
        // failure cannot hide a completed config mutation or invite its replay.
        let result = session_inventory_owned(&next, &selected).map_err(|e| {
            if e.kind() == io::ErrorKind::WouldBlock {
                failure("resourceConflict", "Session catalog is being updated")
            } else {
                unreadable(e)
            }
        })?;
        lock.validate_link(&self.root, LOCK).map_err(unreadable)?;
        self.root.validate_path(&self.path).map_err(unreadable)?;
        if !status {
            self.root.publish_document(DOCUMENT, &next, MAXIMUM).map_err(|e| match e {
                DocumentPublishError::BeforePublication(_) => failure("ioFailure", "Session configuration could not be published"),
                DocumentPublishError::OutcomeUnknown(_) => failure("outcomeUnknown", "Session configuration publication is uncertain; read current generation before another update"),
            })?;
            lock.validate_link(&self.root, LOCK)
                .and_then(|()| self.root.validate_path(&self.path))
                .map_err(|_| {
                    failure(
                        "outcomeUnknown",
                        "Session owner namespace changed during publication",
                    )
                })?;
        }
        Ok(result)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{fs, os::unix::fs::DirBuilderExt};
    struct Root(PathBuf);
    impl Root {
        fn new() -> Self {
            let nonce = u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap());
            let path = std::env::temp_dir()
                .canonicalize()
                .unwrap()
                .join(format!("session-config-{nonce:x}"));
            fs::DirBuilder::new().mode(0o700).create(&path).unwrap();
            for name in ["state", "sessions", "custom"] {
                fs::DirBuilder::new()
                    .mode(0o700)
                    .create(path.join(name))
                    .unwrap();
            }
            Self(path)
        }
        fn open(&self) -> SessionStore {
            SessionStore::open(&self.0.join("state"), &self.0.join("sessions")).unwrap()
        }
    }
    impl Drop for Root {
        fn drop(&mut self) {
            fs::remove_dir_all(&self.0).unwrap();
        }
    }
    fn params(value: Value) -> Map<String, Value> {
        value.as_object().unwrap().clone()
    }
    fn policy(generation: &str) -> Map<String, Value> {
        params(
            json!({"expectedGeneration":generation,"totalQuotaBytes":"500000","safetyMarginBytes":"1000","retentionDays":"30"}),
        )
    }
    #[test]
    fn cleanup_preview_is_durable_and_refuses_configuration_contention_or_unknown_content() {
        use std::collections::BTreeSet;
        let root = Root::new();
        let store = root.open();
        let now = crate::session_time::session_timestamp("2026-09-11T00:00:00Z").unwrap();
        let preview = store.preview_cleanup(&BTreeSet::new(), now).unwrap();
        assert_eq!(preview["sessions"], json!([]));
        assert_eq!(preview["currentBytes"], "0");
        assert_eq!(preview["generation"], "0");
        let id = preview["previewId"].as_str().unwrap();
        let owner = HostDirectory::open(&root.0.join("state")).unwrap();
        let lock = owner.lock_document(LOCK).unwrap();
        let records = crate::SessionCleanupRecords::open(
            &root.0.join("state/session-cleanup-previews"),
            &owner,
            &lock,
        )
        .unwrap();
        assert_eq!(records.load(id).unwrap().preview, preview);
        assert_eq!(
            store
                .preview_cleanup(&BTreeSet::new(), now)
                .unwrap_err()
                .code,
            "resourceConflict"
        );
        drop(records);
        drop(lock);
        fs::write(root.0.join("sessions/unaccounted"), b"retain this").unwrap();
        assert_eq!(
            store
                .preview_cleanup(&BTreeSet::new(), now)
                .unwrap_err()
                .code,
            "operationUnavailable"
        );
        assert_eq!(
            fs::read(root.0.join("sessions/unaccounted")).unwrap(),
            b"retain this"
        );
        assert_eq!(
            fs::read_dir(root.0.join("state/session-cleanup-previews"))
                .unwrap()
                .count(),
            1
        );
    }
    #[test]
    fn initialized_readonly_root_cannot_be_selected_or_advance_configuration() {
        use std::os::unix::fs::PermissionsExt;
        let root = Root::new();
        let store = root.open();
        let custom = root.0.join("custom");
        store
            .handle(
                "runtime.storage.root",
                &params(json!({"expectedGeneration":"1","rootPath":custom})),
            )
            .unwrap();
        store
            .handle(
                "runtime.storage.root",
                &params(json!({"expectedGeneration":"2","resetToDefault":true})),
            )
            .unwrap();
        let before = fs::read(root.0.join("state/session-storage.json")).unwrap();
        fs::set_permissions(&custom, fs::Permissions::from_mode(0o500)).unwrap();
        let result = store.handle(
            "runtime.storage.root",
            &params(json!({"expectedGeneration":"3","rootPath":custom})),
        );
        fs::set_permissions(&custom, fs::Permissions::from_mode(0o700)).unwrap();
        assert_eq!(result.unwrap_err().code, "invalidInput");
        assert_eq!(
            fs::read(root.0.join("state/session-storage.json")).unwrap(),
            before
        );
    }
    #[test]
    fn a_lost_custom_root_can_be_reset_after_cas_without_recreating_it() {
        let root = Root::new();
        let store = root.open();
        let custom = root.0.join("custom");
        store
            .handle(
                "runtime.storage.root",
                &params(json!({"expectedGeneration":"1","rootPath":custom})),
            )
            .unwrap();
        fs::remove_dir_all(&custom).unwrap();
        assert_eq!(
            store
                .handle(
                    "runtime.storage.root",
                    &params(json!({"expectedGeneration":"1","resetToDefault":true}))
                )
                .unwrap_err()
                .code,
            "resourceConflict"
        );
        assert_eq!(
            store
                .handle(
                    "runtime.storage.root",
                    &params(json!({"expectedGeneration":"2","resetToDefault":true}))
                )
                .unwrap()["generation"],
            "3"
        );
        assert!(!custom.exists());
    }
    #[test]
    fn policy_and_root_survive_reopen_with_cas() {
        let root = Root::new();
        assert_eq!(
            root.open()
                .handle("runtime.storage.status", &Map::new())
                .unwrap()["generation"],
            "1"
        );
        assert_eq!(
            root.open()
                .handle("runtime.storage.policy", &policy("1"))
                .unwrap()["generation"],
            "2"
        );
        assert_eq!(
            root.open()
                .handle("runtime.storage.policy", &policy("1"))
                .unwrap_err()
                .code,
            "resourceConflict"
        );
        let custom = root.0.join("custom");
        let result = root
            .open()
            .handle(
                "runtime.storage.root",
                &params(json!({"expectedGeneration":"2","rootPath":custom})),
            )
            .unwrap();
        assert_eq!(result["generation"], "3");
        assert_eq!(result["rootPath"], json!(custom));
        assert_eq!(
            root.open()
                .handle("runtime.storage.status", &Map::new())
                .unwrap(),
            result
        );
        assert_eq!(
            root.open()
                .handle(
                    "runtime.storage.root",
                    &params(json!({"expectedGeneration":"3","resetToDefault":true}))
                )
                .unwrap()["generation"],
            "4"
        );
    }
    #[test]
    fn stale_selection_does_not_initialize_catalog_and_unsafe_selection_does_not_publish() {
        let root = Root::new();
        let custom = root.0.join("custom");
        assert_eq!(
            root.open()
                .handle(
                    "runtime.storage.root",
                    &params(json!({"expectedGeneration":"2","rootPath":custom}))
                )
                .unwrap_err()
                .code,
            "resourceConflict"
        );
        assert!(fs::read_dir(&custom).unwrap().next().is_none());
        assert_eq!(
            root.open()
                .handle(
                    "runtime.storage.root",
                    &params(json!({"expectedGeneration":"1","rootPath":root.0}))
                )
                .unwrap_err()
                .code,
            "invalidInput"
        );
        assert!(!root.0.join("state/session-storage.json").exists());
        assert!(SessionStore::open(&root.0, &root.0.join("sessions")).is_err());
    }
    #[test]
    fn corrupt_configuration_is_not_replaced_and_catalog_lock_failure_prevents_policy_write() {
        let root = Root::new();
        let sessions = HostDirectory::open(&root.0.join("sessions")).unwrap();
        let lock = sessions
            .lock_document(".arkdeck-retention-catalog.lock")
            .unwrap();
        assert_eq!(
            root.open()
                .handle("runtime.storage.policy", &policy("1"))
                .unwrap_err()
                .code,
            "resourceConflict"
        );
        assert!(!root.0.join("state/session-storage.json").exists());
        drop(lock);
        fs::write(root.0.join("state/session-storage.json"), b"damaged").unwrap();
        assert_eq!(
            root.open()
                .handle("runtime.storage.policy", &policy("1"))
                .unwrap_err()
                .code,
            "recordUnreadable"
        );
        assert_eq!(
            fs::read(root.0.join("state/session-storage.json")).unwrap(),
            b"damaged"
        );
    }
}
