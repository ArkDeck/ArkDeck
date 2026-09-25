//! Session configuration owner. The fixed private owner directory and default
//! Session tree are disjoint; requests can only select an existing private root.
use crate::{decode_session_configuration, session_inventory_owned};
use arkdeck_contract::WireError;
use arkdeck_platform::{DocumentPublishError, HostDirectory, HostReadLock};
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
            // Swift's `listSessions` takes the storage lock for a first page
            // before its pager, and reads a cursor's page under none: a first
            // page waiting for the lock holds no snapshot lock meanwhile.
            let lock = match cursor {
                None => Some(self.resource_lock()?),
                Some(_) => None,
            };
            return pager.page(
                method,
                "completedAtDescSessionIdAsc",
                page_size,
                cursor,
                || match &lock {
                    Some(lock) => self.resource_rows(lock, None, None),
                    None => Err(failure(
                        "recordUnreadable",
                        "Session storage is unavailable or unsafe",
                    )),
                },
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
        self.resource_rows(&self.resource_lock()?, Some(id), pin)?
            .into_iter()
            .next()
            .ok_or_else(|| {
                failure(
                    "resourceNotFound",
                    "Session is not present in the Runtime catalog",
                )
            })
    }

    /// The storage lock for a Session resource request: Swift's
    /// `listSessions`, `showSession` and `updateSessionPin` run under
    /// `withLockedDocument`, which waits for it.
    fn resource_lock(&self) -> Result<HostReadLock, WireError> {
        use crate::snapshot_pager::failure;
        let unavailable = |_| {
            failure(
                "recordUnreadable",
                "Session storage is unavailable or unsafe",
            )
        };
        self.root.validate_path(&self.path).map_err(unavailable)?;
        self.root.wait_lock(LOCK, false).map_err(unavailable)
    }

    fn resource_rows(
        &self,
        lock: &HostReadLock,
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
    /// Swift `RuntimeSessionStorageStore.status()` as the Runtime reads it for
    /// a device mutation's admission: the status once the read has reconciled
    /// (and the first time initialized) the catalog. Swift's status read waits
    /// for the storage lock, so a request or a publication holding it at this
    /// instant delays the read rather than refusing it, as
    /// `runtime.storage.status` waits. The lock is held for the read alone.
    pub(crate) fn waited_status(&self) -> Result<Value, WireError> {
        self.hold()?.status()
    }

    /// The same read without waiting, for the operation availability report,
    /// which Swift composes without any storage read: a held lock is refused
    /// at once rather than making `operation.list` wait behind a publication
    /// or an export.
    pub(crate) fn status_without_waiting(&self) -> Result<Value, WireError> {
        self.root.validate_path(&self.path).map_err(unreadable)?;
        let lock = self.root.lock_document(LOCK).map_err(|error| {
            if error.kind() == io::ErrorKind::WouldBlock {
                failure("resourceConflict", "Session storage is being updated")
            } else {
                unreadable(error)
            }
        })?;
        self.locked_storage(&lock, None, None, None)
    }

    /// The storage lock, waited for as Swift's `withLockedDocument` waits for
    /// it: a request or a publication holding it at this instant delays the
    /// holder rather than refusing it.
    pub(crate) fn hold(&self) -> Result<StorageHold<'_>, WireError> {
        self.root.validate_path(&self.path).map_err(unreadable)?;
        let lock = self.root.wait_lock(LOCK, false).map_err(unreadable)?;
        Ok(StorageHold { store: self, lock })
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
        // Swift's `RuntimeStorageResourceHandler` reads and writes under
        // `withLockedDocument`, which waits for the storage lock: a request
        // made while a publication or another request holds it is answered
        // once the lock is released, never refused because it is held.
        let lock = self.root.wait_lock(LOCK, false).map_err(unreadable)?;
        self.locked_storage(&lock, expected, replacement_policy, selection)
    }

    /// A storage request once `lock` holds the storage lock: the settings
    /// read, an expected-generation update applied, the real tree reconciled
    /// with the catalog, and changed settings published. A status read is
    /// the request with no expected generation.
    fn locked_storage(
        &self,
        lock: &HostReadLock,
        expected: Option<u64>,
        replacement_policy: Option<Value>,
        selection: Option<(PathBuf, &'static str)>,
    ) -> Result<Value, WireError> {
        let status = expected.is_none();
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
        let result = session_inventory_owned(&next, &selected).map_err(unreadable)?;
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

/// The Session storage lock, held for reads and writes nothing may come
/// between: a publication renames its staged Session to its published name
/// and registers the catalog entry under one hold (`SessionPublisher::attempt`).
/// Each read and write here works under the lock already held, which a
/// second `flock` on another descriptor would wait for.
pub(crate) struct StorageHold<'a> {
    store: &'a SessionStore,
    lock: HostReadLock,
}

impl StorageHold<'_> {
    /// Swift `RuntimeSessionStorageStore.status()`: the status once the read
    /// has reconciled (and the first time initialized) the catalog.
    pub(crate) fn status(&self) -> Result<Value, WireError> {
        self.store.locked_storage(&self.lock, None, None, None)
    }

    /// The Session root the settings select, read without the status's
    /// reconciliation of the catalog, which writes one where there is none:
    /// the daemon's start reads it and writes nothing.
    pub(crate) fn configured_root(&self) -> Result<PathBuf, WireError> {
        let store = self.store;
        let loaded = match store.root.read(DOCUMENT, MAXIMUM) {
            Ok(value) => value,
            Err(e) if e.kind() == io::ErrorKind::NotFound => {
                return Ok(store.default_sessions.clone());
            }
            Err(e) => return Err(unreadable(e)),
        };
        let decoded = decode_session_configuration(&loaded).map_err(unreadable)?;
        let document: Value = serde_json::from_slice(&decoded.document).map_err(unreadable)?;
        document["rootPath"]
            .as_str()
            .map(PathBuf::from)
            .ok_or_else(|| unreadable(()))
    }

    /// The status as the publication writer reads it: the active Session
    /// root, the settings generation and the retention days. A refusal is
    /// spelled `code: message`.
    pub(crate) fn publication_status(&self) -> Result<(PathBuf, u64, u64), String> {
        let status = self
            .status()
            .map_err(|error| format!("{}: {}", error.code, error.message))?;
        let number = |value: &Value| value.as_str().and_then(|text| text.parse::<u64>().ok());
        match (
            status["rootPath"].as_str(),
            number(&status["generation"]),
            number(&status["policy"]["retentionDays"]),
        ) {
            (Some(root), Some(generation), Some(days)) => {
                Ok((PathBuf::from(root), generation, days))
            }
            _ => Err("recordUnreadable: Session storage status is unreadable".into()),
        }
    }

    /// Swift `registerPublishedSession`: under the storage lock, the catalog
    /// registers the published Session at `location` (`yyyy`, `mm`, Session
    /// identity) with the configured retention and generation, and reads the
    /// entry back. Answers the catalog generation.
    pub(crate) fn register_published_session(
        &self,
        root: &Path,
        location: [&str; 3],
    ) -> Result<u64, String> {
        fn unreadable<E>(_: E) -> String {
            "recordUnreadable: Session storage is unavailable or unsafe".to_owned()
        }
        let store = self.store;
        store.root.validate_path(&store.path).map_err(unreadable)?;
        let loaded = match store.root.read(DOCUMENT, MAXIMUM) {
            Ok(value) => value,
            Err(error) if error.kind() == io::ErrorKind::NotFound => bytes(&json!({
                "schemaVersion":"arkdeck.session-storage-store/1", "generation":1,
                "rootKind":"default", "rootPath":store.default_sessions,
                "policy":{"totalQuotaBytes":21474836480_u64,"safetyMarginBytes":2147483648_u64,"retentionDays":90}}))
            .map_err(unreadable)?,
            Err(error) => return Err(unreadable(error)),
        };
        let projection = decode_session_configuration(&loaded)
            .map_err(unreadable)?
            .projection;
        let number = |value: &Value| value.as_str().and_then(|text| text.parse::<u64>().ok());
        let (Some(generation), Some(days)) = (
            number(&projection["generation"]),
            number(&projection["policy"]["retentionDays"]),
        ) else {
            return Err(unreadable(()));
        };
        let registered = crate::session_inventory::register_session(
            root, location, days, generation,
        )
        .map_err(|_| {
            "recordUnreadable: the Session catalog does not hold the entry it just registered"
                .to_owned()
        })?;
        self.lock
            .validate_link(&store.root, LOCK)
            .map_err(unreadable)?;
        Ok(registered)
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
    /// The status a publication reads, once it holds the storage lock.
    fn publication_status(store: &SessionStore) -> Result<(PathBuf, u64, u64), String> {
        store
            .hold()
            .map_err(|error| format!("{}: {}", error.code, error.message))?
            .publication_status()
    }
    fn policy(generation: &str) -> Map<String, Value> {
        params(
            json!({"expectedGeneration":generation,"totalQuotaBytes":"500000","safetyMarginBytes":"1000","retentionDays":"30"}),
        )
    }
    #[test]
    fn the_publication_status_read_waits_for_a_held_storage_lock() {
        let root = Root::new();
        let store = root.open();
        let held = store.root.lock_document(LOCK).unwrap();
        let (sender, receiver) = std::sync::mpsc::channel();
        std::thread::scope(|scope| {
            let store = &store;
            scope.spawn(move || sender.send(publication_status(store)).unwrap());
            // The publication's read, as Swift's, is still waiting for it.
            assert!(
                receiver
                    .recv_timeout(std::time::Duration::from_millis(200))
                    .is_err()
            );
            drop(held);
            let status = receiver
                .recv_timeout(std::time::Duration::from_secs(30))
                .unwrap()
                .unwrap();
            assert_eq!(status, (root.0.join("sessions"), 1, 90));
        });
    }

    #[test]
    fn storage_requests_wait_for_a_held_storage_lock() {
        // Swift's `RuntimeStorageResourceHandler` reads and writes under the
        // blocking `withLockedDocument`: a request made while the lock is
        // held is answered once it is released, and a write then lands.
        // These methods refused a held lock here ("Session storage is being
        // updated").
        let root = Root::new();
        let store = root.open();
        let custom = root.0.join("custom");
        for (method, request, generation) in [
            ("runtime.storage.status", Map::new(), "1"),
            ("runtime.storage.policy", policy("1"), "2"),
            (
                "runtime.storage.root",
                params(json!({"expectedGeneration":"2","rootPath":custom})),
                "3",
            ),
        ] {
            let held = store.root.lock_document(LOCK).unwrap();
            let (sender, receiver) = std::sync::mpsc::channel();
            std::thread::scope(|scope| {
                let (store, request) = (&store, &request);
                scope.spawn(move || sender.send(store.handle(method, request)).unwrap());
                assert!(
                    receiver
                        .recv_timeout(std::time::Duration::from_millis(200))
                        .is_err(),
                    "{method} answered while the storage lock was held"
                );
                drop(held);
                let answer = receiver
                    .recv_timeout(std::time::Duration::from_secs(30))
                    .unwrap()
                    .unwrap();
                assert_eq!(answer["generation"], generation, "{method}");
            });
        }
        assert_eq!(
            store.handle("runtime.storage.status", &Map::new()).unwrap()["rootPath"],
            json!(custom)
        );
    }

    #[test]
    fn storage_writes_and_publication_reads_wait_for_each_other() {
        // #2147's shape for the storage methods: a policy write and a
        // publication's status read meet at a Barrier before each of 64
        // rounds, so each round they contend for the storage lock. Both wait
        // for it, as Swift's blocking `flock` does, so every write lands in
        // turn and every read sees one whole generation; neither is refused
        // because the other holds the lock. No sleeps and no time bound.
        let root = Root::new();
        let store = root.open();
        let barrier = std::sync::Barrier::new(2);
        std::thread::scope(|scope| {
            let reads = scope.spawn(|| {
                (0..64)
                    .map(|_| {
                        barrier.wait();
                        publication_status(&store)
                    })
                    .collect::<Vec<_>>()
            });
            let writes = scope.spawn(|| {
                (1..=64_u64)
                    .map(|expected| {
                        barrier.wait();
                        store.handle("runtime.storage.policy", &policy(&expected.to_string()))
                    })
                    .collect::<Vec<_>>()
            });
            for (written, generation) in writes.join().unwrap().into_iter().zip(2_u64..) {
                assert_eq!(written.unwrap()["generation"], generation.to_string());
            }
            let mut last = 1;
            for read in reads.join().unwrap() {
                let (sessions, generation, days) = read.unwrap();
                assert_eq!(sessions, root.0.join("sessions"));
                assert!(
                    (last..=65).contains(&generation),
                    "{generation} after {last}"
                );
                assert_eq!(days, if generation == 1 { 90 } else { 30 });
                last = generation;
            }
        });
    }

    #[test]
    fn a_device_mutation_admission_waits_for_a_held_storage_lock() {
        // Swift's `validateMutationState` reads the storage status as the
        // publication does. A mutation submitted while the previous Job's
        // Session is being published was refused here (`admissionDenied`,
        // "Session storage is being updated"), failing its execution.
        let root = Root::new();
        let store = root.open();
        let state = root.0.join("jobs-state");
        fs::DirBuilder::new().mode(0o700).create(&state).unwrap();
        let jobs = crate::JobStore::open_owner(&state).unwrap();
        let capabilities = crate::CapabilityStore::open(&state.join("capabilities")).unwrap();
        let holds = crate::DeviceHolds::default();
        let authority = crate::MutationAuthority {
            default_root: &state,
            sessions: Some(&store),
            capabilities: &capabilities,
            holds: &holds,
        };
        let held = store.root.lock_document(LOCK).unwrap();
        let (sender, receiver) = std::sync::mpsc::channel();
        std::thread::scope(|scope| {
            let (authority, jobs) = (&authority, &jobs);
            scope.spawn(move || sender.send(authority.require_state(jobs)).unwrap());
            assert!(
                receiver
                    .recv_timeout(std::time::Duration::from_millis(200))
                    .is_err()
            );
            drop(held);
            receiver
                .recv_timeout(std::time::Duration::from_secs(30))
                .unwrap()
                .unwrap();
        });
    }

    #[test]
    fn admissions_and_publication_reads_wait_for_each_other() {
        // #2147's shape for the Session storage lock: a publication's status
        // read and a device mutation's admission meet at a Barrier before
        // each of 64 rounds, so each round they contend for the storage lock.
        // Both wait for it, as Swift's blocking `flock` does, so every
        // publication reads the status and every admission is proved; neither
        // is refused because the other holds the lock, and neither waits on
        // anything the other holds. No sleeps and no time bound.
        let root = Root::new();
        let store = root.open();
        let state = root.0.join("jobs-state");
        fs::DirBuilder::new().mode(0o700).create(&state).unwrap();
        let jobs = crate::JobStore::open_owner(&state).unwrap();
        let capabilities = crate::CapabilityStore::open(&state.join("capabilities")).unwrap();
        let holds = crate::DeviceHolds::default();
        let authority = crate::MutationAuthority {
            default_root: &state,
            sessions: Some(&store),
            capabilities: &capabilities,
            holds: &holds,
        };
        let barrier = std::sync::Barrier::new(2);
        std::thread::scope(|scope| {
            let publications = scope.spawn(|| {
                (0..64)
                    .map(|_| {
                        barrier.wait();
                        publication_status(&store)
                    })
                    .collect::<Vec<_>>()
            });
            let admissions = scope.spawn(|| {
                (0..64)
                    .map(|_| {
                        barrier.wait();
                        authority.require_state(&jobs)
                    })
                    .collect::<Vec<_>>()
            });
            for status in publications.join().unwrap() {
                assert_eq!(status.unwrap(), (root.0.join("sessions"), 1, 90));
            }
            for admitted in admissions.join().unwrap() {
                admitted.unwrap();
            }
        });
    }

    #[test]
    fn the_availability_report_reads_the_state_without_waiting() {
        // Swift's operation availability reads no storage, so the report asks
        // whether the state is proved now: a held lock reads as not proved at
        // once, where an admission waits. The bound only turns a wait that
        // never ends into a failure; the answer never depends on it.
        let root = Root::new();
        let store = root.open();
        let state = root.0.join("jobs-state");
        fs::DirBuilder::new().mode(0o700).create(&state).unwrap();
        let jobs = crate::JobStore::open_owner(&state).unwrap();
        let capabilities = crate::CapabilityStore::open(&state.join("capabilities")).unwrap();
        let holds = crate::DeviceHolds::default();
        let authority = crate::MutationAuthority {
            default_root: &state,
            sessions: Some(&store),
            capabilities: &capabilities,
            holds: &holds,
        };
        let held = store.root.lock_document(LOCK).unwrap();
        let (sender, receiver) = std::sync::mpsc::channel();
        std::thread::scope(|scope| {
            let (authority, jobs) = (&authority, &jobs);
            scope.spawn(move || sender.send(authority.state_proven_now(jobs)).unwrap());
            let proven = receiver
                .recv_timeout(std::time::Duration::from_secs(60))
                .unwrap();
            assert!(!proven);
        });
        drop(held);
        assert!(authority.state_proven_now(&jobs));
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
    fn corrupt_configuration_is_not_replaced_and_a_held_catalog_lock_delays_a_policy_write() {
        let root = Root::new();
        let sessions = HostDirectory::open(&root.0.join("sessions")).unwrap();
        let lock = sessions
            .lock_document(".arkdeck-retention-catalog.lock")
            .unwrap();
        // Swift's retention catalog waits for its lock, and so does the
        // policy write that reconciles it: nothing is written while it is
        // held, and the write lands once it is released.
        let store = root.open();
        let (sender, receiver) = std::sync::mpsc::channel();
        std::thread::scope(|scope| {
            let store = &store;
            scope.spawn(move || {
                sender
                    .send(store.handle("runtime.storage.policy", &policy("1")))
                    .unwrap()
            });
            assert!(
                receiver
                    .recv_timeout(std::time::Duration::from_millis(200))
                    .is_err()
            );
            assert!(!root.0.join("state/session-storage.json").exists());
            drop(lock);
            let written = receiver
                .recv_timeout(std::time::Duration::from_secs(30))
                .unwrap()
                .unwrap();
            assert_eq!(written["generation"], "2");
        });
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
