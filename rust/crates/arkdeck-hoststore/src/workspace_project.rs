//! Runtime-owned workspace registration and its presets. Root paths and inode
//! grants stay private. A preset's DevEco toolchain and signing credential are
//! pinned only through the owners the composition root supplies; this store
//! never resolves, executes or signs with either.
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

#[path = "workspace_project_document.rs"]
mod document;
#[path = "workspace_project_mutations.rs"]
mod mutations;
#[path = "workspace_preset_mutations.rs"]
mod preset_mutations;
#[path = "workspace_project_presets.rs"]
mod presets;
const DOCUMENT: &str = "projects.json";
const LOCK: &str = ".projects.lock";
const MAXIMUM: usize = 1024 * 1024;

/// A refusal from a dependency owner. Swift rethrows its code and message.
pub type PinningResult = Result<(), WireError>;
/// A dependency owner's call over two references.
pub type PinPair = Box<dyn Fn(&str, &str) -> PinningResult + Send + Sync>;
/// The DevEco owner's acquire of (toolchain, generation, preset).
pub type ToolchainAcquire = Box<dyn Fn(&str, u64, &str) -> PinningResult + Send + Sync>;
/// The credential owner's acquire of (credential, preset, project).
pub type CredentialAcquire = Box<dyn Fn(&str, &str, &str) -> PinningResult + Send + Sync>;

/// Swift `RuntimeWorkspaceToolchainPinning`: the DevEco toolchain owner's
/// acquire (reference, generation, preset) and release (reference, preset).
pub struct WorkspaceToolchainPinning {
    pub acquire: ToolchainAcquire,
    pub release: PinPair,
}

/// Swift `RuntimeWorkspaceCredentialPinning`. `validate_binding` (credential,
/// project) runs before the store writes its intent; `acquire` (credential,
/// preset, project) and `release` (credential, preset) run inside it.
pub struct WorkspaceCredentialPinning {
    pub validate_binding: PinPair,
    pub acquire: CredentialAcquire,
    pub release: PinPair,
}

/// What a mutation asks the durable Job census about.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum WorkspaceReference<'a> {
    Project(&'a str),
    Preset(&'a str),
}

pub struct WorkspaceProjectStore {
    path: PathBuf,
    root: HostDirectory,
    transaction: Mutex<()>,
    toolchain_pinning: Option<WorkspaceToolchainPinning>,
    credential_pinning: Option<WorkspaceCredentialPinning>,
}
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Root {
    path: String,
    device: u64,
    inode: u64,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
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
    /// An owner with no dependency owners composed: a preset that pins a
    /// toolchain or credential is refused as Swift refuses it without them.
    pub fn open(path: &Path) -> io::Result<Self> {
        Ok(Self {
            path: path.into(),
            root: HostDirectory::open(path)?,
            transaction: Mutex::new(()),
            toolchain_pinning: None,
            credential_pinning: None,
        })
    }

    /// The dependency owners Swift's composition root passes to its store.
    pub fn with_dependency_pinning(
        mut self,
        toolchain: Option<WorkspaceToolchainPinning>,
        credential: Option<WorkspaceCredentialPinning>,
    ) -> Self {
        self.toolchain_pinning = toolchain;
        self.credential_pinning = credential;
        self
    }

    /// One workspace project or preset control request. `now` is read where
    /// Swift reads its injected clock, inside the owner transaction. A
    /// project or preset mutation first asks `require_no_active_reference`,
    /// the durable Job census Swift consults before it opens its document.
    pub fn handle(
        &self,
        method: &str,
        params: &Map<String, Value>,
        now: &dyn Fn() -> String,
        require_no_active_reference: &dyn Fn(WorkspaceReference<'_>) -> Result<(), WireError>,
    ) -> Result<Value, WireError> {
        let (fields, message): (&[&str], &str) = match method {
            "workspace.project.register" => (
                &["registrationRequestId", "kind", "root"],
                "workspace project register requires request identity, kind and root",
            ),
            "workspace.project.list" => (&[], "workspace project list accepts no parameters"),
            "workspace.project.show" => (&["projectRef"], "projectRef is required"),
            "workspace.project.update"
            | "workspace.project.remove"
            | "workspace.preset.list"
            | "workspace.preset.show" => {
                return self.handle_mutation(method, params, now, require_no_active_reference);
            }
            "workspace.preset.register" | "workspace.preset.update" | "workspace.preset.remove" => {
                return self.handle_preset_mutation(
                    method,
                    params,
                    now,
                    require_no_active_reference,
                );
            }
            _ => return Err(failure("unknownMethod", "not a workspace project method")),
        };
        if fields.len() != params.len()
            || fields
                .iter()
                .any(|k| !params.get(*k).is_some_and(Value::is_string))
        {
            return Err(preset_mutations::invalid_params(message));
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
        self.with_document(
            || Ok(()),
            |transaction, document| {
                let mut next = document;
                if let Some((request, family, root)) = registration {
                    let digest = root_digest(family, &root);
                    let reference = format!("project-{}", &sha256_hex(request.as_bytes())[..24]);
                    if let Some(existing) = next
                        .records
                        .iter()
                        .find(|r| r.registration_request_id == request)
                    {
                        if existing.registration_digest != digest
                            || existing.project_ref != reference
                        {
                            return Err(failure(
                                "idempotencyConflict",
                                "registration request identity belongs to another project",
                            ));
                        }
                        return Ok(resource(existing));
                    }
                    if next.records.len() >= 64 {
                        return Err(failure(
                            "quotaExceeded",
                            "workspace project registration limit is reached",
                        ));
                    }
                    if next
                        .records
                        .iter()
                        .any(|r| r.project_ref == reference || r.root == root)
                    {
                        return Err(failure(
                            "resourceConflict",
                            "workspace root or project reference is already registered",
                        ));
                    }
                    let at = preset_mutations::valid_timestamp(now)?;
                    let record = Record {
                        project_ref: reference,
                        generation: 1,
                        kind: family.into(),
                        root: root.clone(),
                        registration_request_id: request.into(),
                        registration_kind: family.into(),
                        registration_root: root,
                        registration_digest: digest,
                        registered_at: at.clone(),
                        updated_at: at,
                    };
                    let answer = resource(&record);
                    next.records.push(record);
                    transaction.save(&next)?;
                    Ok(answer)
                } else if method.ends_with(".list") {
                    next.records.sort_by(|a, b| a.project_ref.cmp(&b.project_ref));
                    Ok(
                        json!({"schemaVersion":"arkdeck.workspace-project-list/1","projects":next.records.iter().map(resource).collect::<Vec<_>>()}),
                    )
                } else {
                    next.records
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
            },
        )
    }
}
