//! Runtime-owned workspace registration. Root paths and inode grants stay private;
//! this owner does not compose presets, execute tools or acquire signing authority.
use arkdeck_contract::{WireError, sha256_hex, strict_json};
use arkdeck_platform::{DocumentPublishError, HostDirectory};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};
use std::{
    collections::HashSet,
    fs::OpenOptions,
    io,
    os::unix::fs::{MetadataExt, OpenOptionsExt},
    path::{Path, PathBuf},
    sync::Mutex,
};

#[path = "workspace_project_presets.rs"]
mod presets;
const DOCUMENT: &str = "projects.json";
const LOCK: &str = ".projects.lock";
const MAXIMUM: usize = 1024 * 1024;

pub struct WorkspaceProjectStore {
    path: PathBuf,
    root: HostDirectory,
    transaction: Mutex<()>,
}
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Root {
    path: String,
    device: u64,
    inode: u64,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Record {
    project_ref: String,
    generation: u64,
    kind: String,
    root: Root,
    #[serde(rename = "registrationRequestID")]
    registration_request_id: String,
    registration_kind: String,
    registration_root: Root,
    registration_digest: String,
    #[serde(rename = "registeredAtUTC")]
    registered_at: String,
    #[serde(rename = "updatedAtUTC")]
    updated_at: String,
}
fn failure(code: &str, message: &str) -> WireError {
    WireError {
        code: code.into(),
        message: message.into(),
        details: Some(Map::from_iter([
            ("phase".into(), json!("workspaceProjectOwner")),
            ("newDispatchCount".into(), json!(0)),
        ])),
    }
}
fn unreadable(_: impl std::fmt::Debug) -> WireError {
    failure(
        "recordUnreadable",
        "workspace project document or storage is inconsistent",
    )
}
fn identifier(s: &str, max: usize) -> bool {
    !s.is_empty()
        && s.len() <= max
        && s.bytes()
            .all(|c| c.is_ascii_alphanumeric() || b"-_.".contains(&c))
}
fn kind(s: &str) -> bool {
    matches!(s, "arkdeck" | "openharmony")
}
fn timestamp(s: &str) -> Option<f64> {
    crate::format_time::format_timestamp_seconds(s)
}
fn canonical(s: &str) -> bool {
    s.starts_with('/')
        && s != "/"
        && s.len() <= 4096
        && !s.contains('\0')
        && s[1..]
            .split('/')
            .all(|c| !c.is_empty() && c != "." && c != "..")
}
fn root_digest(kind: &str, root: &Root) -> String {
    sha256_hex(format!("{kind}\0{}\0{}\0{}", root.path, root.device, root.inode).as_bytes())
}
fn inspect_root(path: &str) -> Result<Root, WireError> {
    if !canonical(path) {
        return Err(failure(
            "invalidInput",
            "workspace root must be a canonical absolute directory",
        ));
    }
    let ancestry = || -> io::Result<()> {
        let mut cursor = PathBuf::from("/");
        for component in Path::new(path).components().skip(1) {
            cursor.push(component);
            if std::fs::symlink_metadata(&cursor)?.file_type().is_symlink() {
                return Err(io::Error::other("symbolic ancestry"));
            }
        }
        Ok(())
    };
    ancestry().map_err(|_| {
        failure(
            "invalidInput",
            "workspace root ancestry cannot contain a symbolic link",
        )
    })?;
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_CLOEXEC | libc::O_NOFOLLOW)
        .open(path)
        .map_err(|_| {
            failure(
                "invalidInput",
                "workspace root cannot be opened as a directory",
            )
        })?;
    let opened = file.metadata().map_err(unreadable)?;
    let named = std::fs::symlink_metadata(path)
        .map_err(|_| failure("factsDrifted", "workspace root changed during registration"))?;
    if !opened.is_dir()
        || !named.is_dir()
        || opened.dev() != named.dev()
        || opened.ino() != named.ino()
        || ancestry().is_err()
    {
        return Err(failure(
            "factsDrifted",
            "workspace root changed during registration",
        ));
    }
    Ok(Root {
        path: path.into(),
        device: opened.dev(),
        inode: opened.ino(),
    })
}
fn validate_records(document: &Value) -> Result<Vec<Record>, WireError> {
    let fields = document.as_object().ok_or_else(|| unreadable(()))?;
    if fields.keys().any(|k| {
        ![
            "schemaVersion",
            "records",
            "presets",
            "pendingToolchainMutation",
        ]
        .contains(&k.as_str())
    }) || !matches!(
        document["schemaVersion"].as_str(),
        Some(
            "arkdeck.workspace-project-store/1"
                | "arkdeck.workspace-project-store/2"
                | "arkdeck.workspace-project-store/3"
        )
    ) {
        return Err(unreadable(()));
    }
    let records: Vec<Record> =
        serde_json::from_value(document["records"].clone()).map_err(unreadable)?;
    let mut refs = HashSet::new();
    let mut requests = HashSet::new();
    let mut roots = HashSet::new();
    if records.len() > 64 {
        return Err(unreadable(()));
    }
    for r in &records {
        if !identifier(&r.project_ref, 128)
            || !identifier(&r.registration_request_id, 128)
            || !kind(&r.kind)
            || !kind(&r.registration_kind)
            || r.generation == 0
            || r.generation > i64::MAX as u64
            || !canonical(&r.root.path)
            || !canonical(&r.registration_root.path)
            || r.root.inode == 0
            || r.registration_root.inode == 0
            || root_digest(&r.registration_kind, &r.registration_root) != r.registration_digest
            || !timestamp(&r.registered_at)
                .zip(timestamp(&r.updated_at))
                .is_some_and(|(a, b)| b >= a)
            || !refs.insert(&r.project_ref)
            || !requests.insert(&r.registration_request_id)
            || !roots.insert(&r.root)
        {
            return Err(unreadable(()));
        }
    }
    presets::validate(document, &refs)?;
    Ok(records)
}
fn resource(r: &Record) -> Value {
    json!({"schemaVersion":"arkdeck.workspace-project/1","projectRef":r.project_ref,"generation":r.generation.to_string(),"kind":r.kind,"registeredAtUtc":r.registered_at,"updatedAtUtc":r.updated_at,"configurationStatus":"runtimeRestartRequired","availability":"unavailable","reasonCode":"workspace_runtime_restart_required","reason":"restart the Runtime to compose the registered root before submitting a workspace Job","allowedFileGlobs":[],"presetRefs":[],"operations":[]})
}
impl WorkspaceProjectStore {
    pub fn open(path: &Path) -> io::Result<Self> {
        Ok(Self {
            path: path.into(),
            root: HostDirectory::open(path)?,
            transaction: Mutex::new(()),
        })
    }
    pub fn handle(
        &self,
        method: &str,
        params: &Map<String, Value>,
        now: &str,
    ) -> Result<Value, WireError> {
        let fields: &[&str] = match method {
            "workspace.project.register" => &["registrationRequestId", "kind", "root"],
            "workspace.project.list" => &[],
            "workspace.project.show" => &["projectRef"],
            _ => return Err(failure("unknownMethod", "not a workspace project method")),
        };
        if fields.len() != params.len()
            || fields
                .iter()
                .any(|k| !params.get(*k).is_some_and(Value::is_string))
        {
            return Err(failure(
                "invalidParams",
                "workspace project request requires its exact typed parameters",
            ));
        }
        let registration = if method.ends_with(".register") {
            let request = params["registrationRequestId"].as_str().unwrap();
            let family = params["kind"].as_str().unwrap();
            if !identifier(request, 128) || !kind(family) {
                return Err(failure(
                    "invalidInput",
                    "workspace registration identity or kind is malformed",
                ));
            }
            Some((
                request,
                family,
                inspect_root(params["root"].as_str().unwrap())?,
            ))
        } else {
            None
        };
        if method.ends_with(".show") && !identifier(params["projectRef"].as_str().unwrap(), 128) {
            return Err(failure(
                "invalidInput",
                "workspace project reference is malformed",
            ));
        }
        let _transaction = self.transaction.lock().map_err(unreadable)?;
        self.root.validate_path(&self.path).map_err(unreadable)?;
        let lock = self.root.lock_document(LOCK).map_err(|e| {
            if e.kind() == io::ErrorKind::WouldBlock {
                failure("resourceConflict", "workspace project store lock is busy")
            } else {
                unreadable(e)
            }
        })?;
        let bytes = self
            .root
            .read_owner_only(DOCUMENT, MAXIMUM)
            .map_err(unreadable)?;
        let mut document = match bytes {
            Some(bytes) => strict_json(&bytes).map_err(unreadable)?,
            None => {
                json!({"schemaVersion":"arkdeck.workspace-project-store/3","records":[],"presets":[]})
            }
        };
        let mut records = validate_records(&document)?;
        lock.validate_link(&self.root, LOCK).map_err(unreadable)?;
        self.root.validate_path(&self.path).map_err(unreadable)?;
        if !document["pendingToolchainMutation"].is_null() {
            return Err(failure(
                "operationUnavailable",
                "workspace preset dependency owners are unavailable; pending mutation is retained",
            ));
        }
        if let Some((request, family, root)) = registration {
            let digest = root_digest(family, &root);
            let reference = format!("project-{}", &sha256_hex(request.as_bytes())[..24]);
            if let Some(existing) = records
                .iter()
                .find(|r| r.registration_request_id == request)
            {
                if existing.registration_digest != digest || existing.project_ref != reference {
                    return Err(failure(
                        "idempotencyConflict",
                        "registration request identity belongs to another project",
                    ));
                }
                return Ok(resource(existing));
            }
            if records.len() >= 64 {
                return Err(failure(
                    "quotaExceeded",
                    "workspace project registration limit is reached",
                ));
            }
            if records
                .iter()
                .any(|r| r.project_ref == reference || r.root == root)
            {
                return Err(failure(
                    "resourceConflict",
                    "workspace root or project reference is already registered",
                ));
            }
            if timestamp(now).is_none() {
                return Err(failure(
                    "recordUnreadable",
                    "workspace project clock is unavailable",
                ));
            }
            let record = Record {
                project_ref: reference,
                generation: 1,
                kind: family.into(),
                root: root.clone(),
                registration_request_id: request.into(),
                registration_kind: family.into(),
                registration_root: root,
                registration_digest: digest,
                registered_at: now.into(),
                updated_at: now.into(),
            };
            let answer = resource(&record);
            records.push(record);
            records.sort_by(|a, b| a.project_ref.cmp(&b.project_ref));
            document["schemaVersion"] = json!("arkdeck.workspace-project-store/3");
            document["records"] = serde_json::to_value(records).map_err(unreadable)?;
            if document.get("presets").is_none() {
                document["presets"] = json!([]);
            }
            let encoded = crate::session_json::encode(&document).map_err(unreadable)?;
            if encoded.len() > MAXIMUM {
                return Err(failure(
                    "quotaExceeded",
                    "workspace project store document exceeds its bound",
                ));
            }
            self.root
                .publish_document(DOCUMENT, &encoded, MAXIMUM)
                .map_err(|e| match e {
                    DocumentPublishError::BeforePublication(_) => failure(
                        "ioFailure",
                        "workspace project publication failed before commit",
                    ),
                    DocumentPublishError::OutcomeUnknown(_) => failure(
                        "outcomeUnknown",
                        "workspace project publication could not be verified",
                    ),
                })?;
            lock.validate_link(&self.root, LOCK)
                .and_then(|_| self.root.validate_path(&self.path))
                .map_err(|_| {
                    failure(
                        "outcomeUnknown",
                        "workspace project namespace changed during publication",
                    )
                })?;
            Ok(answer)
        } else if method.ends_with(".list") {
            records.sort_by(|a, b| a.project_ref.cmp(&b.project_ref));
            Ok(
                json!({"schemaVersion":"arkdeck.workspace-project-list/1","projects":records.iter().map(resource).collect::<Vec<_>>()}),
            )
        } else {
            records
                .iter()
                .find(|r| Some(r.project_ref.as_str()) == params["projectRef"].as_str())
                .map(resource)
                .ok_or_else(|| {
                    failure(
                        "workspaceReferenceNotFound",
                        "workspace project is not registered",
                    )
                })
        }
    }
}
