//! Swift `EvolutionWorkspaceManager`'s isolation lifecycle and the typed
//! `WorkspaceIsolationIntent` behind `workspace.prepare-isolated-copy@1`
//! (TASK-XPA-015, M3): a Runtime-owned copy of a registered project's tree
//! under `evolution-workspaces/<workspaceID>/`, its manifest, the independent
//! readback that verifies it, and its adoption when a Runtime starts.
//!
//! The copy runs no tool. It is Swift's bounded POSIX copy: at most 100,000
//! entries, 512 MiB per file and 4 GiB in all; every `.build` directory left
//! out; a `.git` pointer file left out and a `.git` directory copied by value;
//! a symbolic link kept only when it resolves inside the source tree, an
//! absolute one rewritten relative; a special file refused; each regular file
//! read through `O_NOFOLLOW` and written through `O_EXCL` with its mode, then
//! checked unchanged. The copy is published by one rename and then measured
//! against the source's truth before its manifest is written, so a copy that
//! is not what was asked for is never registered as one.
//!
//! Differences from Swift, each on the refusing side: entries are copied in
//! byte order of their names, so when several would be refused the first in
//! that order is named; a link is read once, so the target that was admitted
//! is the one recreated; the manifest is written owner-only and read without
//! following a link. A copy whose tree moved from its base revision is
//! adopted only where the durable patch lineage (`workspace_patch.rs`)
//! derives exactly the revision it measures.
use crate::workspace_composition::{Isolation, WorkspaceComposition};
use crate::workspace_profile::ProfileKind;
use crate::workspace_support::{
    self as support, foundation_resolved, is_identifier, is_sha256, swift_sort,
};
use serde::Deserialize;
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::fs::{self, DirBuilder, OpenOptions};
use std::io::{self, Read, Write};
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::Path;

/// The Runtime-owned copies' directory below the state root.
pub(crate) const ISOLATION_DIRECTORY: &str = "evolution-workspaces";
/// Swift's `hostManagedDescriptor` identifier of the isolation step.
pub(crate) const DESCRIPTOR: &str = "workspace.prepare-isolated-copy/v1";
const MANIFEST: &str = "workspace.json";
const MAXIMUM_MANIFEST: u64 = 1024 * 1024;
const MAXIMUM_ENTRIES: usize = 100_000;
const MAXIMUM_FILE_BYTES: u64 = 512 * 1024 * 1024;
const MAXIMUM_TREE_BYTES: u64 = 4 * 1024 * 1024 * 1024;
const MAXIMUM_RELATIVE_PATH_BYTES: usize = 4_096;
/// Swift `EvolutionWorkspacePolicy.allowedOperations` of every copy.
const COPY_OPERATIONS: [&str; 4] = [
    "workspace.apply-patch@1",
    "workspace.build-openharmony@1",
    "workspace.run-tests@1",
    "workspace.revert-patch@1",
];

/// Swift `WorkspaceIsolationIntent`: every identity a copy will carry,
/// derived from the Job that asks for it, the source it copies and the
/// narrowed revision it must equal.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct IsolationIntent {
    pub(crate) runtime_owner_id: String,
    pub(crate) source_project_ref: String,
    pub(crate) expected_workspace_revision: String,
    pub(crate) isolated_workspace_revision: String,
    pub(crate) allowed_file_globs: Vec<String>,
    pub(crate) created_at_utc: String,
    pub(crate) workspace_id: String,
    pub(crate) workspace_project_ref: String,
    pub(crate) allowed_file_scopes_digest: String,
}

impl IsolationIntent {
    pub(crate) fn new(
        runtime_owner_id: String,
        source_project_ref: String,
        expected_workspace_revision: String,
        isolated_workspace_revision: String,
        created_at_utc: String,
        mut allowed_file_globs: Vec<String>,
    ) -> Self {
        swift_sort(&mut allowed_file_globs);
        let digest = support::sha256(
            format!("{runtime_owner_id}|{source_project_ref}|{isolated_workspace_revision}")
                .as_bytes(),
        );
        let allowed_file_scopes_digest = support::sha256(allowed_file_globs.join("\n").as_bytes());
        Self {
            workspace_id: format!("evo-{}", &digest[..24]),
            workspace_project_ref: format!("evolution-{}", &digest[..20]),
            runtime_owner_id,
            source_project_ref,
            expected_workspace_revision,
            isolated_workspace_revision,
            allowed_file_globs,
            created_at_utc,
            allowed_file_scopes_digest,
        }
    }

    /// Swift's synthesized encoding of the intent.
    pub(crate) fn value(&self) -> Value {
        json!({
            "runtimeOwnerID": self.runtime_owner_id,
            "sourceProjectRef": self.source_project_ref,
            "expectedWorkspaceRevision": self.expected_workspace_revision,
            "isolatedWorkspaceRevision": self.isolated_workspace_revision,
            "allowedFileGlobs": self.allowed_file_globs,
            "createdAtUTC": self.created_at_utc,
            "workspaceID": self.workspace_id,
            "workspaceProjectRef": self.workspace_project_ref,
            "allowedFileScopesDigest": self.allowed_file_scopes_digest,
        })
    }

    /// Swift `actionSHA256`: the digest of the intent's canonical JSON, the
    /// pin between the materialized plan and the descriptor dispatched.
    pub(crate) fn action_sha256(&self) -> Result<String, ()> {
        let bytes = crate::session_json::encode(&self.value()).map_err(|_| ())?;
        Ok(support::sha256(&bytes))
    }

    /// Swift `PersistedTypedProviderAction` of the typed action: the
    /// workspace action's canonical JSON, base64.
    pub(crate) fn persisted(&self) -> Result<Value, ()> {
        let action = json!({"prepareIsolatedCopy": {"_0": self.value()}});
        let bytes = crate::session_json::encode(&action).map_err(|_| ())?;
        Ok(json!({"kind": "workspace.action",
            "arguments": {"payload": crate::agent_execution::base64(&bytes)}}))
    }

    /// Swift `journalStep`'s arguments for `prepareWorkspaceIsolation`.
    pub(crate) fn journal_arguments(&self) -> Value {
        json!({
            "sourceProjectRef": self.source_project_ref,
            "expectedWorkspaceRevision": self.expected_workspace_revision,
            "workspaceRevision": self.isolated_workspace_revision,
            "allowedFileScopesDigest": self.allowed_file_scopes_digest,
            "workspaceProjectRef": self.workspace_project_ref,
            "artifactId": "isolated-workspace.json",
        })
    }
}

/// Swift `WorkspaceIsolationResult`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct IsolationResult {
    pub(crate) workspace_id: String,
    pub(crate) project_ref: String,
    pub(crate) source_project_ref: String,
    pub(crate) source_workspace_revision: String,
    pub(crate) workspace_revision: String,
    pub(crate) allowed_file_scopes_digest: String,
}

impl IsolationResult {
    /// Swift `summary`, the verified facts the Artifact carries.
    pub(crate) fn summary(&self) -> BTreeMap<String, String> {
        BTreeMap::from([
            ("workspaceId".into(), self.workspace_id.clone()),
            ("projectRef".into(), self.project_ref.clone()),
            ("sourceProjectRef".into(), self.source_project_ref.clone()),
            (
                "sourceWorkspaceRevision".into(),
                self.source_workspace_revision.clone(),
            ),
            ("workspaceRevision".into(), self.workspace_revision.clone()),
            (
                "allowedFileScopesDigest".into(),
                self.allowed_file_scopes_digest.clone(),
            ),
            ("isolation".into(), "runtimeOwned".into()),
        ])
    }
}

/// Swift `WorkspaceIsolationInspection`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum Inspection {
    Absent,
    Prepared(IsolationResult),
    Conflicted(&'static str),
}

/// Swift `EvolutionWorkspaceError`, the refusals a receipt may name: they
/// carry tree-relative entries, references, revisions or reason tokens, never
/// a host path.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum EvolutionError {
    MalformedTaskId,
    SourceProfileUnavailable(String),
    PolicyScopeOutsideProfile(String),
    BaseRevisionMismatch { expected: String, actual: String },
    UnsafeSourceEntry(String),
    WorkspaceManifestConflict,
    WorkspaceAlreadyDestroyed(String),
}

impl EvolutionError {
    /// Swift's `String(describing:)` of the case.
    fn swift(&self) -> String {
        let quoted = crate::artifact_read_owner::swift_string;
        match self {
            Self::MalformedTaskId => "malformedTaskID".into(),
            Self::SourceProfileUnavailable(reference) => {
                format!("sourceProfileUnavailable({})", quoted(reference))
            }
            Self::PolicyScopeOutsideProfile(scope) => {
                format!("policyScopeOutsideProfile({})", quoted(scope))
            }
            Self::BaseRevisionMismatch { expected, actual } => format!(
                "baseRevisionMismatch(expected: {}, actual: {})",
                quoted(expected),
                quoted(actual)
            ),
            Self::UnsafeSourceEntry(entry) => format!("unsafeSourceEntry({})", quoted(entry)),
            Self::WorkspaceManifestConflict => "workspaceManifestConflict".into(),
            Self::WorkspaceAlreadyDestroyed(workspace) => {
                format!("workspaceAlreadyDestroyed({})", quoted(workspace))
            }
        }
    }
}

/// Why a preparation stopped: a named refusal, or any other failure, which
/// Swift's dispatcher reports without a cause.
#[derive(Debug)]
pub(crate) enum IsolationFailure {
    Refused(EvolutionError),
    Other,
}

impl IsolationFailure {
    /// Swift `RuntimeOwnedWorkspaceDispatcher`'s failed receipt reason.
    pub(crate) fn reason(&self) -> String {
        match self {
            Self::Refused(error) => format!("workspace isolation refused: {}", error.swift()),
            Self::Other => "workspace isolation refused".into(),
        }
    }
}

impl From<EvolutionError> for IsolationFailure {
    fn from(error: EvolutionError) -> Self {
        Self::Refused(error)
    }
}

fn other<T>(_: T) -> IsolationFailure {
    IsolationFailure::Other
}

fn unsafe_entry(entry: &str) -> IsolationFailure {
    EvolutionError::UnsafeSourceEntry(entry.into()).into()
}

/// Swift `EvolutionWorkspaceRecord`.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Record {
    #[serde(rename = "workspaceID")]
    workspace_id: String,
    #[serde(rename = "htaskID")]
    htask_id: String,
    source_project_ref: String,
    project_ref: String,
    base_revision: String,
    allowed_paths_digest: String,
    #[serde(rename = "createdAtUTC")]
    created_at_utc: String,
}

/// Swift's `Manifest`: the record and, when written by this lifecycle, the
/// sorted scopes the copy may write.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Manifest {
    workspace: Record,
    allowed_paths: Option<Vec<String>>,
}

impl Manifest {
    /// Swift's `CanonicalJSONEncoders.canonicalPretty()` spelling.
    fn encode(&self) -> Result<Vec<u8>, IsolationFailure> {
        let record = &self.workspace;
        let mut value = json!({"workspace": {
            "workspaceID": record.workspace_id, "htaskID": record.htask_id,
            "sourceProjectRef": record.source_project_ref, "projectRef": record.project_ref,
            "baseRevision": record.base_revision, "allowedPathsDigest": record.allowed_paths_digest,
            "createdAtUTC": record.created_at_utc,
        }});
        if let Some(paths) = &self.allowed_paths {
            value["allowedPaths"] = json!(paths);
        }
        crate::session_json::encode_canonical_pretty(&value).map_err(other)
    }
}

/// A manifest's bytes, read through no link and within its bound.
fn read_manifest(path: &str) -> Option<Manifest> {
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)
        .ok()?;
    let mut bytes = Vec::new();
    file.take(MAXIMUM_MANIFEST + 1)
        .read_to_end(&mut bytes)
        .ok()?;
    if bytes.len() as u64 > MAXIMUM_MANIFEST {
        return None;
    }
    serde_json::from_slice(&bytes).ok()
}

/// Swift `write(to:options: .atomic)`: staged beside it, then renamed.
fn write_manifest(path: &str, bytes: &[u8]) -> Result<(), IsolationFailure> {
    let suffix = u64::from_ne_bytes(arkdeck_platform::random_bytes::<8>().map_err(other)?);
    let staged = format!("{path}.{suffix:016x}.tmp");
    let written = (|| {
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(&staged)?;
        file.write_all(bytes)?;
        file.sync_all()?;
        fs::rename(&staged, path)
    })();
    if written.is_err() {
        let _ = fs::remove_file(&staged);
    }
    written.map_err(other)
}

fn exists(path: &str) -> bool {
    Path::new(path).exists()
}

fn private_directory(path: &str) -> io::Result<()> {
    DirBuilder::new().mode(0o700).create(path)
}

/// Swift `allowedPathsDigest`: one definition shared by creation and
/// adoption.
fn allowed_paths_digest(allowed_paths: &[String]) -> String {
    let mut sorted = allowed_paths.to_vec();
    swift_sort(&mut sorted);
    support::sha256(sorted.join("\n").as_bytes())
}

/// Swift `EvolutionWorkspaceManager.isNarrower(_:thanAny:)`: equal, or inside
/// a `/**` scope. It is deliberately stricter than the provider's rule.
fn narrower_than_any(requested: &str, permitted: &[String]) -> bool {
    permitted.iter().any(|parent| {
        requested == parent
            || parent
                .strip_suffix("/**")
                .is_some_and(|prefix| requested.starts_with(&format!("{prefix}/")))
    })
}

/// Swift `EvolutionWorkspacePolicy.isSafeScope`.
fn safe_scope(value: &str) -> bool {
    if value.is_empty()
        || value.len() > 512
        || value.starts_with('/')
        || value.contains('\\')
        || value.contains('[')
        || value.contains(']')
        || value.chars().any(arkdeck_platform::host_control_character)
    {
        return false;
    }
    let literal = value.replace("**", "").replace(['*', '?'], "");
    !literal
        .split('/')
        .any(|component| component == "." || component == "..")
        && value != ".git"
        && !value.starts_with(".git/")
        && !value.contains("/.git/")
}

/// The part of Swift's `EvolutionWorkspacePolicy` a preparation reads: its
/// base revision and its deduplicated, sorted scopes, validated as Swift's
/// initializer validates them. A refusal here is not an isolation refusal.
struct Policy {
    base_revision: String,
    allowed_paths: Vec<String>,
}

impl Policy {
    fn for_intent(intent: &IsolationIntent) -> Result<Self, IsolationFailure> {
        if !is_sha256(&intent.isolated_workspace_revision) {
            return Err(IsolationFailure::Other);
        }
        let mut allowed_paths: Vec<String> = intent.allowed_file_globs.clone();
        allowed_paths.sort();
        allowed_paths.dedup();
        swift_sort(&mut allowed_paths);
        if allowed_paths.is_empty() || !allowed_paths.iter().all(|path| safe_scope(path)) {
            return Err(IsolationFailure::Other);
        }
        // Every operation a copy allows exists and is not destructive.
        for reference in COPY_OPERATIONS {
            let (id, version) = reference.split_once('@').ok_or(IsolationFailure::Other)?;
            let descriptor =
                crate::operation_catalog::CatalogOperation::lookup(id, version.parse().ok())
                    .ok_or(IsolationFailure::Other)?;
            if descriptor.permits_destructive() {
                return Err(IsolationFailure::Other);
            }
        }
        Ok(Self {
            base_revision: intent.isolated_workspace_revision.clone(),
            allowed_paths,
        })
    }
}

/// Swift `relativeLinkTarget(fromLinkAt:toTreeRelativeTarget:)`.
fn relative_link_target(link: &str, target: &str) -> String {
    let directory: Vec<&str> = link.split('/').filter(|c| !c.is_empty()).collect();
    let directory = &directory[..directory.len().saturating_sub(1)];
    let target: Vec<&str> = target.split('/').filter(|c| !c.is_empty()).collect();
    let mut shared = 0;
    while shared < directory.len() && shared < target.len() && directory[shared] == target[shared] {
        shared += 1;
    }
    let components: Vec<&str> = std::iter::repeat_n("..", directory.len() - shared)
        .chain(target[shared..].iter().copied())
        .collect();
    if components.is_empty() {
        ".".into()
    } else {
        components.join("/")
    }
}

/// The name Swift's bounded copy refuses a regular file by: its last path
/// component, not its tree-relative path.
fn leaf(relative: &str) -> &str {
    relative.rsplit('/').next().unwrap_or(relative)
}

/// Swift `copyBoundedRegularFile`: read through no link and without
/// blocking, written exclusively with the source's mode, and refused unless
/// the source is the same unchanged regular file from first byte to last.
fn copy_regular_file(source: &str, destination: &str, name: &str) -> Result<u64, IsolationFailure> {
    let mut input = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(source)
        .map_err(|_| unsafe_entry(name))?;
    let initial = input.metadata().map_err(|_| unsafe_entry(name))?;
    if !initial.file_type().is_file() || initial.size() > MAXIMUM_FILE_BYTES {
        return Err(unsafe_entry(name));
    }
    let mode = initial.mode() & 0o777;
    let mut output = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(mode)
        .custom_flags(libc::O_NOFOLLOW)
        .open(destination)
        .map_err(|_| unsafe_entry(name))?;
    let mut remaining = initial.size();
    let mut buffer = vec![0u8; 64 * 1024];
    while remaining > 0 {
        let requested = buffer.len().min(remaining as usize);
        let read = input
            .read(&mut buffer[..requested])
            .map_err(|_| unsafe_entry(name))?;
        if read == 0 {
            return Err(unsafe_entry(name));
        }
        output
            .write_all(&buffer[..read])
            .map_err(|_| unsafe_entry(name))?;
        remaining -= read as u64;
    }
    let mut extra = [0u8; 1];
    if input.read(&mut extra).map_err(|_| unsafe_entry(name))? != 0 {
        return Err(unsafe_entry(name));
    }
    let last = input.metadata().map_err(|_| unsafe_entry(name))?;
    let unchanged = last.dev() == initial.dev()
        && last.ino() == initial.ino()
        && last.mode() == initial.mode()
        && last.size() == initial.size()
        && last.mtime() == initial.mtime()
        && last.mtime_nsec() == initial.mtime_nsec()
        && last.ctime() == initial.ctime()
        && last.ctime_nsec() == initial.ctime_nsec();
    if !unchanged
        || output
            .set_permissions(fs::Permissions::from_mode(mode))
            .is_err()
    {
        return Err(unsafe_entry(name));
    }
    Ok(initial.size())
}

/// One run of Swift's `copyIsolatedTree`.
struct Copy {
    /// The canonical source root links must resolve inside.
    source: String,
    /// The physical spelling Foundation's enumerator reports entries under.
    physical: String,
    destination: String,
    entries: usize,
    bytes: u64,
}

impl Copy {
    fn directory(&mut self, relative: Option<&str>) -> Result<(), IsolationFailure> {
        let directory = match relative {
            Some(relative) => format!("{}/{relative}", self.source),
            None => self.source.clone(),
        };
        let mut names = Vec::new();
        for entry in fs::read_dir(&directory).map_err(|_| unsafe_entry("enumerationFailed"))? {
            let entry = entry.map_err(|_| unsafe_entry("enumerationFailed"))?;
            names.push(
                entry
                    .file_name()
                    .into_string()
                    .map_err(|_| unsafe_entry("enumerationFailed"))?,
            );
        }
        names.sort();
        for name in names {
            let relative = match relative {
                Some(parent) => format!("{parent}/{name}"),
                None => name,
            };
            self.entry(&relative)?;
        }
        Ok(())
    }

    fn entry(&mut self, relative: &str) -> Result<(), IsolationFailure> {
        self.entries += 1;
        if self.entries > MAXIMUM_ENTRIES {
            return Err(unsafe_entry("entryCountExceeded"));
        }
        if relative.is_empty() || relative.len() > MAXIMUM_RELATIVE_PATH_BYTES {
            return Err(unsafe_entry("relativePathExceeded"));
        }
        // SwiftPM's path-bound caches are neither part of the revision nor
        // portable into another tree.
        if relative.split('/').any(|component| component == ".build") {
            return Ok(());
        }
        let path = format!("{}/{relative}", self.source);
        let kind = fs::symlink_metadata(&path).map_err(other)?.file_type();
        // A worktree's `.git` pointer file would address primary metadata.
        if relative == ".git" && !kind.is_dir() {
            return Ok(());
        }
        let output = format!("{}/{relative}", self.destination);
        if kind.is_symlink() {
            let target = fs::read_link(&path).map_err(other)?;
            let target = target.to_str().ok_or_else(|| unsafe_entry(relative))?;
            let resolved = if target.starts_with('/') {
                foundation_resolved(target)
            } else {
                let parent = match relative.rfind('/') {
                    Some(index) => format!("{}/{}", self.physical, &relative[..index]),
                    None => self.physical.clone(),
                };
                foundation_resolved(&format!("{parent}/{target}"))
            };
            let inside =
                resolved == self.source || resolved.starts_with(&format!("{}/", self.source));
            if !inside {
                return Err(unsafe_entry(relative));
            }
            let recreated = if target.starts_with('/') {
                let tree_relative = if resolved == self.source {
                    ""
                } else {
                    &resolved[self.source.len() + 1..]
                };
                relative_link_target(relative, tree_relative)
            } else {
                target.to_owned()
            };
            std::os::unix::fs::symlink(recreated, &output).map_err(other)?;
        } else if kind.is_dir() {
            private_directory(&output).map_err(other)?;
            self.directory(Some(relative))?;
        } else if kind.is_file() {
            let copied = copy_regular_file(&path, &output, leaf(relative))?;
            self.bytes = self
                .bytes
                .checked_add(copied)
                .filter(|total| *total <= MAXIMUM_TREE_BYTES)
                .ok_or_else(|| unsafe_entry("treeBytesExceeded"))?;
        } else {
            return Err(unsafe_entry(relative));
        }
        Ok(())
    }
}

/// Swift `copyIsolatedTree(from:to:)`.
fn copy_isolated_tree(source: &str, destination: &str) -> Result<(), IsolationFailure> {
    let source = foundation_resolved(source);
    let physical = fs::canonicalize(&source)
        .ok()
        .and_then(|path| path.to_str().map(str::to_owned))
        .unwrap_or_else(|| source.clone());
    let (parent, name) = destination
        .rsplit_once('/')
        .ok_or(IsolationFailure::Other)?;
    let destination = format!("{}/{name}", foundation_resolved(parent));
    if destination == source || destination.starts_with(&format!("{source}/")) {
        return Err(unsafe_entry("destinationInsideSource"));
    }
    private_directory(&destination).map_err(other)?;
    Copy {
        source,
        physical,
        destination,
        entries: 0,
        bytes: 0,
    }
    .directory(None)
}

impl Isolation {
    fn task_root(&self, workspace_id: &str) -> String {
        format!("{}/{workspace_id}", self.root)
    }
}

/// The source project a Runtime-owned copy's manifest names for the copy
/// `project_ref`, read from disk whether or not the copy was adopted: a copy
/// that cannot be vouched for is still a copy of that project.
pub(crate) fn manifest_source(copies: &str, project_ref: &str) -> Option<String> {
    let mut names: Vec<String> = fs::read_dir(copies)
        .ok()?
        .filter_map(|entry| entry.ok()?.file_name().into_string().ok())
        .take(4_097)
        .collect();
    if names.len() > 4_096 {
        return None;
    }
    names.sort();
    names.into_iter().find_map(|name| {
        let stored = read_manifest(&format!("{copies}/{name}/{MANIFEST}"))?;
        let record = stored.workspace;
        (record.htask_id.starts_with("runtime-") && record.project_ref == project_ref)
            .then_some(record.source_project_ref)
    })
}

impl WorkspaceComposition {
    /// Swift `EvolutionWorkspaceManager.prepare(_:)`: the copy the intent
    /// describes, made or found, then read back as a separate inspection.
    pub(crate) fn prepare(
        &self,
        intent: &IsolationIntent,
    ) -> Result<IsolationResult, IsolationFailure> {
        let isolation = self.isolation.as_ref().ok_or(IsolationFailure::Other)?;
        let policy = Policy::for_intent(intent)?;
        let record = {
            let _held = isolation.lock.lock().map_err(other)?;
            self.prepare_bound(isolation, intent, &policy)?
        };
        if record.workspace_id != intent.workspace_id
            || record.project_ref != intent.workspace_project_ref
            || record.allowed_paths_digest != intent.allowed_file_scopes_digest
        {
            return Err(EvolutionError::WorkspaceManifestConflict.into());
        }
        match self.inspect(intent) {
            Inspection::Prepared(result) => Ok(result),
            _ => Err(EvolutionError::WorkspaceManifestConflict.into()),
        }
    }

    /// Swift `prepareWorkspaceBound`, under the isolation lock.
    fn prepare_bound(
        &self,
        isolation: &Isolation,
        intent: &IsolationIntent,
        policy: &Policy,
    ) -> Result<Record, IsolationFailure> {
        let htask = &intent.runtime_owner_id;
        let source_ref = &intent.source_project_ref;
        if !is_identifier(htask) {
            return Err(EvolutionError::MalformedTaskId.into());
        }
        let source = self
            .registry
            .profile(source_ref)
            .filter(|profile| profile.kind == ProfileKind::Primary)
            .ok_or_else(|| EvolutionError::SourceProfileUnavailable(source_ref.clone()))?;
        let expected = &intent.expected_workspace_revision;
        let actual = support::workspace_revision(
            &source.project_root,
            &source.profile_id,
            &source.allowed_file_globs,
        )
        .map_err(other)?;
        if actual != *expected {
            return Err(EvolutionError::BaseRevisionMismatch {
                expected: expected.clone(),
                actual,
            }
            .into());
        }
        for scope in &policy.allowed_paths {
            if !narrower_than_any(scope, &source.allowed_file_globs) {
                return Err(EvolutionError::PolicyScopeOutsideProfile(scope.clone()).into());
            }
        }
        let actual = support::workspace_revision(
            &source.project_root,
            &source.profile_id,
            &policy.allowed_paths,
        )
        .map_err(other)?;
        if actual != policy.base_revision {
            return Err(EvolutionError::BaseRevisionMismatch {
                expected: policy.base_revision.clone(),
                actual,
            }
            .into());
        }
        let digest =
            support::sha256(format!("{htask}|{source_ref}|{}", policy.base_revision).as_bytes());
        let workspace_id = format!("evo-{}", &digest[..24]);
        let project_ref = format!("evolution-{}", &digest[..20]);
        let task_root = isolation.task_root(&workspace_id);
        let workspace_root = format!("{task_root}/workspace");
        let manifest_path = format!("{task_root}/{MANIFEST}");
        let record = Record {
            workspace_id: workspace_id.clone(),
            htask_id: htask.clone(),
            source_project_ref: source_ref.clone(),
            project_ref: project_ref.clone(),
            base_revision: policy.base_revision.clone(),
            allowed_paths_digest: allowed_paths_digest(&policy.allowed_paths),
            created_at_utc: intent.created_at_utc.clone(),
        };
        if exists(&manifest_path) {
            let stored = read_manifest(&manifest_path).ok_or(IsolationFailure::Other)?;
            if stored.workspace != record
                || stored
                    .allowed_paths
                    .as_ref()
                    .is_some_and(|stored| *stored != policy.allowed_paths)
            {
                return Err(EvolutionError::WorkspaceManifestConflict.into());
            }
            if !exists(&workspace_root) {
                // A swept copy keeps its manifest for audit; reopening it
                // is an identity being reused, never a recovery.
                return Err(if exists(&format!("{task_root}/teardown.json")) {
                    EvolutionError::WorkspaceAlreadyDestroyed(workspace_id)
                } else {
                    EvolutionError::WorkspaceManifestConflict
                }
                .into());
            }
            let profile = source
                .derived(&workspace_root, &project_ref, &policy.allowed_paths)
                .map_err(other)?;
            self.registry.register(profile).map_err(other)?;
            return Ok(record);
        }
        private_directory(&task_root).map_err(other)?;
        let temporary = format!("{task_root}/.workspace.tmp");
        let prepared = (|| {
            copy_isolated_tree(&source.project_root, &temporary)?;
            if fs::symlink_metadata(&workspace_root).is_ok() {
                return Err(IsolationFailure::Other);
            }
            fs::rename(&temporary, &workspace_root).map_err(other)?;
            let copied = support::workspace_revision(
                &workspace_root,
                &source.profile_id,
                &policy.allowed_paths,
            )
            .map_err(other)?;
            if copied != policy.base_revision {
                return Err(EvolutionError::BaseRevisionMismatch {
                    expected: policy.base_revision.clone(),
                    actual: copied,
                }
                .into());
            }
            let copied_source = support::workspace_revision(
                &workspace_root,
                &source.profile_id,
                &source.allowed_file_globs,
            )
            .map_err(other)?;
            if copied_source != *expected {
                return Err(EvolutionError::BaseRevisionMismatch {
                    expected: expected.clone(),
                    actual: copied_source,
                }
                .into());
            }
            let profile = source
                .derived(&workspace_root, &project_ref, &policy.allowed_paths)
                .map_err(other)?;
            self.registry.register(profile).map_err(other)?;
            let manifest = Manifest {
                workspace: record.clone(),
                allowed_paths: Some(policy.allowed_paths.clone()),
            };
            write_manifest(&manifest_path, &manifest.encode()?)?;
            private_directory(&format!("{task_root}/attempts")).map_err(other)?;
            Ok(record)
        })();
        if prepared.is_err() && exists(&temporary) {
            let _ = fs::remove_dir_all(&temporary);
        }
        prepared
    }

    /// Swift `EvolutionWorkspaceManager.inspect(_:)`: the copy read back from
    /// disk, never from a receipt, and its derived profile registered.
    pub(crate) fn inspect(&self, intent: &IsolationIntent) -> Inspection {
        let Some(isolation) = self.isolation.as_ref() else {
            return Inspection::Conflicted("workspace isolation cannot be revalidated");
        };
        let Ok(_held) = isolation.lock.lock() else {
            return Inspection::Conflicted("workspace isolation cannot be revalidated");
        };
        let task_root = isolation.task_root(&intent.workspace_id);
        let manifest_path = format!("{task_root}/{MANIFEST}");
        let workspace_root = format!("{task_root}/workspace");
        if !exists(&manifest_path) {
            return if exists(&task_root) {
                Inspection::Conflicted("workspace isolation manifest is absent")
            } else {
                Inspection::Absent
            };
        }
        let Some(stored) = read_manifest(&manifest_path) else {
            return Inspection::Conflicted("workspace isolation manifest is unreadable");
        };
        let record = &stored.workspace;
        let source = self
            .registry
            .profile(&intent.source_project_ref)
            .filter(|profile| profile.kind == ProfileKind::Primary);
        let agrees = record.workspace_id == intent.workspace_id
            && record.htask_id == intent.runtime_owner_id
            && record.source_project_ref == intent.source_project_ref
            && record.project_ref == intent.workspace_project_ref
            && record.base_revision == intent.isolated_workspace_revision
            && record.allowed_paths_digest == intent.allowed_file_scopes_digest
            && stored.allowed_paths.as_ref() == Some(&intent.allowed_file_globs)
            && exists(&workspace_root);
        let (true, Some(source)) = (agrees, source) else {
            return Inspection::Conflicted(
                "workspace isolation identity disagrees with its typed action",
            );
        };
        let revision = match support::workspace_revision(
            &workspace_root,
            &source.profile_id,
            &intent.allowed_file_globs,
        ) {
            Ok(revision) => revision,
            Err(_) => return Inspection::Conflicted("workspace isolation cannot be revalidated"),
        };
        if revision != intent.isolated_workspace_revision {
            return Inspection::Conflicted("workspace isolation copied revision drifted");
        }
        let registered = source
            .derived(
                &workspace_root,
                &intent.workspace_project_ref,
                &intent.allowed_file_globs,
            )
            .and_then(|profile| self.registry.register(profile));
        if registered.is_err() {
            return Inspection::Conflicted("workspace isolation cannot be revalidated");
        }
        Inspection::Prepared(IsolationResult {
            workspace_id: intent.workspace_id.clone(),
            project_ref: intent.workspace_project_ref.clone(),
            source_project_ref: intent.source_project_ref.clone(),
            source_workspace_revision: intent.expected_workspace_revision.clone(),
            workspace_revision: revision,
            allowed_file_scopes_digest: intent.allowed_file_scopes_digest.clone(),
        })
    }

    /// Swift `adoptRuntimeWorkspaces()`: every Runtime-owned copy a previous
    /// Runtime left registered again, when its manifest, its scopes and its
    /// tree still agree with its source; each copy that cannot be vouched for
    /// is named with why, and stays unresolvable.
    pub fn adopt_runtime_workspaces(&self) -> Vec<String> {
        let Some(isolation) = self.isolation.as_ref() else {
            return Vec::new();
        };
        let Ok(_held) = isolation.lock.lock() else {
            return vec!["runtime workspace lock is unavailable".into()];
        };
        let mut names: Vec<String> = match fs::read_dir(&isolation.root) {
            Ok(entries) => entries
                .filter_map(|entry| entry.ok()?.file_name().into_string().ok())
                .collect(),
            Err(_) => return Vec::new(),
        };
        if names.len() > 4_096 {
            return vec!["runtime workspace entry bound exceeded".into()];
        }
        names.sort();
        let mut failures = Vec::new();
        for name in names {
            let entry = format!("{}/{name}", isolation.root);
            let Some(stored) = read_manifest(&format!("{entry}/{MANIFEST}")) else {
                continue;
            };
            let record = &stored.workspace;
            if !record.htask_id.starts_with("runtime-") {
                continue;
            }
            let failed = |why: &str| format!("{}:{why}", record.workspace_id);
            let source = self
                .registry
                .profile(&record.source_project_ref)
                .filter(|profile| profile.kind == ProfileKind::Primary);
            let (Some(allowed_paths), Some(source)) = (&stored.allowed_paths, source) else {
                failures.push(failed("metadata"));
                continue;
            };
            let workspace_root = format!("{entry}/workspace");
            let adopted = (|| {
                let revision =
                    support::workspace_revision(&workspace_root, &source.profile_id, allowed_paths)
                        .map_err(|_| "profile")?;
                // The base vouches for an unpatched tree; the durable patch
                // lineage vouches for every revision it derives from that
                // base. Anything else — a lineage the store cannot read
                // included — keeps the named refusal.
                if revision != record.base_revision {
                    let derived =
                        self.patch_lineage(&record.project_ref)
                            .ok()
                            .and_then(|attempts| {
                                crate::workspace_patch::lineage_derived_revision(
                                    &record.base_revision,
                                    &attempts,
                                )
                            });
                    if derived.as_deref() != Some(revision.as_str()) {
                        return Err("revision");
                    }
                }
                if allowed_paths_digest(allowed_paths) != record.allowed_paths_digest {
                    return Err("scopes");
                }
                source
                    .derived(&workspace_root, &record.project_ref, allowed_paths)
                    .and_then(|profile| self.registry.register(profile))
                    .map_err(|_| "profile")
            })();
            if let Err(why) = adopted {
                failures.push(failed(why));
            }
        }
        failures
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn link_targets_are_rewritten_tree_relative() {
        assert_eq!(
            relative_link_target("Sources/abs-in", "Sources/App.txt"),
            "App.txt"
        );
        assert_eq!(relative_link_target("Sources/abs-root", ""), "..");
        assert_eq!(relative_link_target("link", "a/b"), "a/b");
        assert_eq!(relative_link_target("a/b/link", "a/c/d"), "../c/d");
        assert_eq!(relative_link_target("a/link", "a"), ".");
    }

    #[test]
    fn errors_are_described_as_swift_describes_them() {
        assert_eq!(
            IsolationFailure::from(EvolutionError::UnsafeSourceEntry("Sources/x\"y".into()))
                .reason(),
            "workspace isolation refused: unsafeSourceEntry(\"Sources/x\\\"y\")"
        );
        assert_eq!(
            IsolationFailure::from(EvolutionError::BaseRevisionMismatch {
                expected: "a".into(),
                actual: "b".into()
            })
            .reason(),
            "workspace isolation refused: baseRevisionMismatch(expected: \"a\", actual: \"b\")"
        );
        assert_eq!(
            IsolationFailure::Other.reason(),
            "workspace isolation refused"
        );
    }

    #[test]
    fn the_intent_derives_swifts_identities() {
        let intent = IsolationIntent::new(
            "runtime-job-825787507429b81047c9726a1373a83b".into(),
            "IsolationOracleProject".into(),
            "59c1ac4a2252facd778903b7e8dce3f175c0ab7e748d945db45c644fac4ab092".into(),
            "f55c16a181e89d99f439585ec7fff7fb037b62a2d3236bdf24141e6c572fa684".into(),
            "2026-09-20T00:00:00.000Z".into(),
            vec!["Sources/App.txt".into()],
        );
        assert_eq!(intent.workspace_id, "evo-e2ae7c7152894a5b51d95e92");
        assert_eq!(
            intent.workspace_project_ref,
            "evolution-e2ae7c7152894a5b51d9"
        );
        assert_eq!(
            intent.allowed_file_scopes_digest,
            "3427fcf49cad72b72643b9724e6fc2107d75e572a8efb16c1fc044bcc44b151b"
        );
    }

    #[test]
    fn a_policy_scope_is_stricter_than_a_glob_where_swift_is() {
        assert!(narrower_than_any("Sources/App.txt", &["Sources/**".into()]));
        assert!(!narrower_than_any("Sources", &["Sources/**".into()]));
        assert!(!narrower_than_any("Sources/App.txt", &["Sources/*".into()]));
        assert!(safe_scope("Sources/**"));
        assert!(!safe_scope("Sources/[ab]"));
        assert!(!safe_scope("Sources/./x"));
        assert!(!safe_scope(".git/config"));
    }
}
