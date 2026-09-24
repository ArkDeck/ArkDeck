//! The Rust workspace provider as the Runtime composes it (TASK-XPA-015,
//! M3): Swift's daemon composition root over the registered projects
//! (`main.swift`), `WorkspaceOperationsProvider` routing a request to the
//! profile it names, and the registration a workspace Job holds while it is
//! materialized.
//!
//! At start-up every registered project whose root is still the directory
//! its registration pinned resolves to the profile of its kind, the
//! Runtime-owned copies a previous Runtime made are adopted again — the base
//! revision vouching for an unpatched copy, the durable patch lineage for a
//! patched one — and every registered generation is marked applied. A project
//! registered or changed afterwards is refused until the Runtime restarts, as
//! Swift refuses it.
use crate::operation_catalog::CatalogOperation;
use crate::workspace_isolation::{ISOLATION_DIRECTORY, IsolationIntent};
use crate::workspace_patch::{
    self as patch, ATTEMPTS_DIRECTORY, AttemptStore, FileSnapshot, PatchAction, PatchAttempt,
    PatchIntent, RevertIntent, ToolReceipt, VerifiedToolDispatch, WorkspaceToolDispatch,
};
use crate::workspace_profile::{
    ProfileKind, ProfileRegistry, WorkspaceAuthorizationFacts, WorkspaceProfile,
};
use crate::workspace_project::{WorkspaceProjectStore, WorkspaceUse};
use crate::workspace_support::{self as support, foundation_standardized, is_narrower};
use arkdeck_contract::WireError;
use serde_json::{Map, Value};
use std::collections::BTreeMap;
use std::fs::DirBuilder;
use std::io;
use std::os::unix::fs::DirBuilderExt;
use std::path::Path;
use std::sync::{Arc, Mutex};

/// Swift `EvolutionWorkspaceManager`'s root and lock.
pub(crate) struct Isolation {
    pub(crate) root: String,
    pub(crate) lock: Mutex<()>,
}

/// The workspace provider of one Runtime.
pub struct WorkspaceComposition {
    pub(crate) registry: ProfileRegistry,
    /// Swift `availabilityProfiles`: the primary profiles resolved at
    /// start-up, by reference.
    primaries: Vec<String>,
    /// Swift `UnavailableWorkspaceOperationsProvider`'s reason, when no
    /// registered project resolved.
    unavailable: Option<String>,
    /// Present exactly when a primary profile resolved, as Swift creates its
    /// isolation manager.
    pub(crate) isolation: Option<Isolation>,
    /// Where the Runtime-owned copies live, whether or not a manager was
    /// composed over them this time.
    copies: String,
    projects: Option<Arc<WorkspaceProjectStore>>,
    /// The engine clock a materialization reads.
    pub(crate) now: fn() -> Option<String>,
    /// Swift `WorkspacePatchAttemptStore`: present exactly when a primary
    /// profile resolved, beside the isolation manager's directory, which
    /// reads it as the copies' patch lineage.
    pub(crate) attempts: Option<AttemptStore>,
    /// The dispatch a patch step runs its pinned tool through.
    pub(crate) tool: Box<dyn WorkspaceToolDispatch>,
    /// Swift `DeviceMutationLaneCoordinator` for the host target every
    /// workspace mutation names: a patch Job's steps hold it from its running
    /// transition to its last step, so one patch never overlaps another.
    pub(crate) lane: Mutex<()>,
}

/// A patch Artifact the engine resolved from its lease for this Job: the
/// facts the lease names and the payload they describe.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct LeasedPatch {
    pub(crate) artifact_id: String,
    pub(crate) path: String,
    pub(crate) sha256: String,
    pub(crate) byte_count: u64,
}

/// How a patch step's receipt was judged: Swift's `.verified` summary, its
/// `.failed` code and detail, or a judgement that could not be completed,
/// which leaves the step's outcome unknown.
pub(crate) enum PatchVerdict {
    Verified(BTreeMap<String, String>),
    Failed(&'static str, String),
    Unknown(String),
}

/// Swift `workspacePresetInputNames`.
const PRESET_INPUTS: [&str; 4] = [
    "buildPresetRef",
    "testPresetRef",
    "signingPresetRef",
    "symbolPresetRef",
];

fn isolation_at(root: &Path) -> io::Result<Isolation> {
    DirBuilder::new().recursive(true).mode(0o700).create(root)?;
    let root = root.to_str().ok_or_else(|| {
        io::Error::new(io::ErrorKind::InvalidInput, "isolation root is not UTF-8")
    })?;
    Ok(Isolation {
        root: foundation_standardized(root),
        lock: Mutex::new(()),
    })
}

/// The copies' root as the isolation manager spells it.
fn copies_root(root: &Path) -> String {
    foundation_standardized(&root.to_string_lossy())
}

fn registry(profiles: &[WorkspaceProfile]) -> io::Result<ProfileRegistry> {
    let registry = ProfileRegistry::default();
    for profile in profiles {
        if registry.profile(&profile.project_ref).is_some() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                format!("duplicate workspace projectRef {}", profile.project_ref),
            ));
        }
        registry
            .register(profile.clone())
            .map_err(|error| io::Error::new(io::ErrorKind::InvalidInput, error))?;
    }
    Ok(registry)
}

impl WorkspaceComposition {
    /// Swift's composition root over the registered projects under
    /// `state_root`: the profiles resolved, the isolation manager and its
    /// adoption, and the applied generations. Returns what adoption could
    /// not vouch for, which the daemon reports and leaves unresolvable.
    pub fn compose(
        projects: Arc<WorkspaceProjectStore>,
        state_root: &Path,
        home: &str,
        now: fn() -> Option<String>,
    ) -> Result<(Self, Vec<String>), String> {
        let records = projects.startup_records().map_err(|error| error.message)?;
        let mut failures: BTreeMap<String, String> = BTreeMap::new();
        let mut resolved = Vec::new();
        for record in &records {
            let root = match &record.root {
                Ok(root) => root,
                Err(failure) => {
                    failures.insert(
                        record.project_ref.clone(),
                        format!("workspace.projectRootUnavailable:{}", failure.message),
                    );
                    continue;
                }
            };
            let profile = match record.kind.as_str() {
                "arkdeck" => WorkspaceProfile::ark_deck(root, &record.project_ref),
                "openharmony" => WorkspaceProfile::water_flow(root, &record.project_ref, home),
                _ => Err(format!(
                    "workspace.projectProfileUnavailable:{} is unsupported",
                    record.project_ref
                )),
            };
            match profile {
                Ok(profile) => resolved.push(profile),
                Err(error) => {
                    failures.insert(
                        record.project_ref.clone(),
                        format!("workspace.projectProfileUnavailable:{error}"),
                    );
                }
            }
        }
        let applied = records
            .iter()
            .map(|record| (record.project_ref.clone(), record.generation))
            .collect();
        let composed = if resolved.is_empty() {
            let reason = if failures.is_empty() {
                "workspace.projectProfileUnavailable: no registered project profile resolved"
                    .to_owned()
            } else {
                failures.values().cloned().collect::<Vec<_>>().join("; ")
            };
            (
                Self {
                    registry: ProfileRegistry::default(),
                    primaries: Vec::new(),
                    unavailable: Some(reason),
                    isolation: None,
                    copies: copies_root(&state_root.join(ISOLATION_DIRECTORY)),
                    projects: Some(Arc::clone(&projects)),
                    now,
                    attempts: None,
                    tool: Box::new(VerifiedToolDispatch),
                    lane: Mutex::new(()),
                },
                Vec::new(),
            )
        } else {
            // Swift creates the attempt store first and hands it to the
            // isolation manager as its patch lineage.
            let attempts = AttemptStore::open(&state_root.join(ATTEMPTS_DIRECTORY))
                .map_err(|error| error.to_string())?;
            let composition = Self {
                registry: registry(&resolved).map_err(|error| error.to_string())?,
                primaries: resolved.iter().map(|p| p.project_ref.clone()).collect(),
                unavailable: None,
                copies: copies_root(&state_root.join(ISOLATION_DIRECTORY)),
                isolation: Some(
                    isolation_at(&state_root.join(ISOLATION_DIRECTORY))
                        .map_err(|error| error.to_string())?,
                ),
                projects: Some(Arc::clone(&projects)),
                now,
                attempts: Some(attempts),
                tool: Box::new(VerifiedToolDispatch),
                lane: Mutex::new(()),
            };
            let unadopted = composition.adopt_runtime_workspaces();
            (composition, unadopted)
        };
        projects.mark_applied(applied);
        Ok(composed)
    }

    /// A composition over the given primary profiles with its copies under
    /// `isolation_root` and its patch attempts beside them, as the daemon lays
    /// both out below its state root, and no registration owner: the Swift
    /// oracles' Runtime, whose engine has no workspace project store.
    pub fn with_profiles(
        profiles: Vec<WorkspaceProfile>,
        isolation_root: &Path,
        now: fn() -> Option<String>,
    ) -> io::Result<Self> {
        let mut primaries: Vec<String> = profiles.iter().map(|p| p.project_ref.clone()).collect();
        primaries.sort();
        let attempts = isolation_root
            .parent()
            .map(|parent| AttemptStore::open(&parent.join(ATTEMPTS_DIRECTORY)))
            .transpose()?;
        Ok(Self {
            registry: registry(&profiles)?,
            primaries,
            unavailable: None,
            copies: copies_root(isolation_root),
            isolation: Some(isolation_at(isolation_root)?),
            projects: None,
            now,
            attempts,
            tool: Box::new(VerifiedToolDispatch),
            lane: Mutex::new(()),
        })
    }

    /// The same composition, its patch steps dispatched through `tool`.
    pub fn with_tool_dispatch(mut self, tool: Box<dyn WorkspaceToolDispatch>) -> Self {
        self.tool = tool;
        self
    }

    /// Swift's registered provider's `runtimeAvailability(for:)`: available
    /// when some start-up profile serves the operation, otherwise the first
    /// profile's reason.
    pub(crate) fn provider_unavailability(&self, reference: &str) -> Option<String> {
        if let Some(reason) = &self.unavailable {
            return Some(reason.clone());
        }
        let mut first = None;
        for project_ref in &self.primaries {
            let Some(profile) = self.registry.profile(project_ref) else {
                continue;
            };
            // A profile with no reason to refuse makes the operation available.
            let reason = profile.unavailability(reference, self.isolation.is_some())?;
            first.get_or_insert(reason);
        }
        Some(first.unwrap_or_else(|| "no_workspace_project_registered".into()))
    }

    /// Swift `workspaceRegistrationProjectRef(for:)`: a primary profile is its
    /// own registration; a Runtime-owned copy acquires the project it was
    /// copied from; an unknown reference maps to nothing.
    pub fn registration_project_ref(&self, project_ref: &str) -> Option<String> {
        let profile = self.registry.profile(project_ref)?;
        match profile.kind {
            ProfileKind::Primary => Some(profile.project_ref),
            ProfileKind::Evolution => profile.source_project_ref,
        }
    }

    /// The registration a Job's `projectRef` belongs to, as the census of
    /// active Jobs reads it before a project may change: the provider's own
    /// mapping, then — for a Runtime-owned copy this Runtime did not adopt,
    /// whose Jobs may still be uncertain — the source its manifest names. A
    /// reference neither knows is its own.
    pub fn census_registration(&self, project_ref: &str) -> Option<String> {
        self.registration_project_ref(project_ref)
            .or_else(|| crate::workspace_isolation::manifest_source(&self.copies, project_ref))
    }

    /// Swift `acquireWorkspaceProjectInput`: the registration a per-project
    /// workspace Job materializes against, held for the materialization. A
    /// refusal is its control-plane code and message.
    pub(crate) fn acquire(
        &self,
        descriptor: &CatalogOperation,
        inputs: &Map<String, Value>,
    ) -> Result<Option<WorkspaceUse<'_>>, (&'static str, String)> {
        let Some(projects) = &self.projects else {
            return Ok(None);
        };
        if descriptor.provider != "workspace"
            || !descriptor
                .inputs
                .iter()
                .any(|field| field.name == "projectRef")
        {
            return Ok(None);
        }
        let Some(project_ref) = inputs.get("projectRef").and_then(Value::as_str) else {
            return Err((
                "invalidInput",
                "workspace operation requires a registered projectRef".into(),
            ));
        };
        let presets: Vec<String> = descriptor
            .inputs
            .iter()
            .filter(|field| PRESET_INPUTS.contains(&field.name.as_str()))
            .filter_map(|field| inputs.get(&field.name)?.as_str())
            .filter(|value| value.starts_with("preset-"))
            .map(str::to_owned)
            .collect();
        let registration = self
            .registration_project_ref(project_ref)
            .unwrap_or_else(|| project_ref.to_owned());
        projects
            .acquire_use(&registration, &presets)
            .map(Some)
            .map_err(|failure: WireError| {
                let code = match failure.code.as_str() {
                    "workspaceReferenceNotFound" => "invalidInput",
                    "operationUnavailable" => "operationUnavailable",
                    _ => "resourceConflict",
                };
                (code, failure.message)
            })
    }

    /// Swift `WorkspaceOperationsProvider.action`'s shared preamble: the
    /// profile the request names, the operation available for it, and the
    /// revision the caller decided against — when it states one — enforced
    /// over the whole profile scope.
    fn preamble(
        &self,
        reference: &str,
        inputs: &Map<String, Value>,
    ) -> Result<(String, WorkspaceProfile), String> {
        let project_ref = inputs
            .get("projectRef")
            .and_then(Value::as_str)
            .ok_or("workspace input projectRef is missing")?;
        let profile = self
            .registry
            .profile(project_ref)
            .ok_or_else(|| format!("workspace.projectProfileUnavailable:{project_ref}"))?;
        if let Some(reason) = profile.unavailability(reference, self.isolation.is_some()) {
            return Err(reason);
        }
        if let Some(declared) = inputs
            .get("expectedWorkspaceRevision")
            .and_then(Value::as_str)
        {
            let actual = support::workspace_revision(
                &profile.project_root,
                &profile.profile_id,
                &profile.allowed_file_globs,
            )?;
            if actual != declared {
                return Err(format!(
                    "workspace.revisionConflict:{}!={}",
                    declared.chars().take(12).collect::<String>(),
                    &actual[..12]
                ));
            }
        }
        Ok((project_ref.to_owned(), profile))
    }

    /// Swift `WorkspaceOperationsProvider.action` for
    /// `workspace.prepare-isolated-copy@1`: the profile the request names,
    /// its availability, the revision the caller decided against, the
    /// narrowed scopes and the typed intent owned by `job_id`. A refusal is
    /// the detail Swift's provider error describes itself by.
    pub(crate) fn isolation_action(
        &self,
        reference: &str,
        inputs: &Map<String, Value>,
        job_id: &str,
        now: &str,
    ) -> Result<IsolationIntent, String> {
        let text = |key: &str| {
            inputs
                .get(key)
                .and_then(Value::as_str)
                .ok_or_else(|| format!("workspace input {key} is missing"))
        };
        let (project_ref, profile) = self.preamble(reference, inputs)?;
        let project_ref = project_ref.as_str();
        if profile.kind != ProfileKind::Primary || self.isolation.is_none() {
            return Err("workspace.isolationManagerUnavailable".into());
        }
        let Some(values) = inputs.get("allowedFileGlobs").and_then(Value::as_array) else {
            return Err("workspace input allowedFileGlobs is missing".into());
        };
        let requested = values
            .iter()
            .map(|value| {
                value.as_str().map(str::to_owned).ok_or_else(|| {
                    "workspace input allowedFileGlobs contains a non-string".to_owned()
                })
            })
            .collect::<Result<Vec<String>, String>>()?;
        if requested.is_empty()
            || !requested.iter().all(|glob| {
                profile
                    .allowed_file_globs
                    .iter()
                    .any(|scope| is_narrower(glob, scope))
            })
        {
            return Err("workspace.isolationScopeOutsideProjectProfile".into());
        }
        let expected = text("expectedWorkspaceRevision")?.to_owned();
        let isolated =
            support::workspace_revision(&profile.project_root, &profile.profile_id, &requested)?;
        Ok(IsolationIntent::new(
            format!("runtime-{job_id}"),
            project_ref.to_owned(),
            expected,
            isolated,
            now.to_owned(),
            requested,
        ))
    }

    /// Swift `workspaceAuthorizationFacts(for:inputs:)`: the facts of the
    /// tree a workspace Job names, which its capability is matched against.
    pub(crate) fn authorization_facts(
        &self,
        inputs: &Map<String, Value>,
    ) -> Result<WorkspaceAuthorizationFacts, String> {
        let project_ref = inputs
            .get("projectRef")
            .and_then(Value::as_str)
            .ok_or("workspace input projectRef is missing")?;
        self.registry
            .profile(project_ref)
            .ok_or_else(|| format!("workspace.projectProfileUnavailable:{project_ref}"))?
            .authorization_facts()
    }

    fn attempt_store(&self) -> Result<&AttemptStore, String> {
        self.attempts
            .as_ref()
            .ok_or_else(|| "workspace patch attempt store is unavailable".to_owned())
    }

    /// Swift `WorkspaceOperationsProvider.action` for
    /// `workspace.apply-patch@1`: the preamble, then the leased patch read
    /// again and checked against its lease, its declared paths inside the
    /// profile's scopes and the request's, the files it touches as they are
    /// now, and the attempt it becomes for `job_id`. A refusal is the detail
    /// Swift's provider error describes itself by.
    pub(crate) fn apply_action(
        &self,
        reference: &str,
        inputs: &Map<String, Value>,
        job_id: &str,
        leased: Option<&LeasedPatch>,
    ) -> Result<PatchIntent, String> {
        let (project_ref, profile) = self.preamble(reference, inputs)?;
        let Some(leased) = leased else {
            return Err(
                "workspace patch Artifact lease was not resolved before materialization".into(),
            );
        };
        let request_globs = string_array(inputs, "allowedFileGlobs")?;
        let bytes = std::fs::read(&leased.path)
            .map_err(|_| "workspace patch Artifact bytes do not match their lease".to_owned())?;
        if bytes.len() as u64 != leased.byte_count
            || bytes.len() as u64 > patch::MAXIMUM_PATCH_BYTES
            || support::sha256(&bytes) != leased.sha256
        {
            return Err("workspace patch Artifact bytes do not match their lease".into());
        }
        let paths = patch::patch_paths(&bytes)?;
        patch::validate(
            &paths,
            &profile.project_root,
            &profile.allowed_file_globs,
            &request_globs,
        )?;
        let before = patch::snapshots(&paths, &profile.project_root)?;
        let digest =
            support::sha256(format!("{job_id}\n{}\n{project_ref}", leased.sha256).as_bytes());
        let previous = match profile.kind {
            ProfileKind::Evolution => Some(
                inputs
                    .get("expectedWorkspaceRevision")
                    .and_then(Value::as_str)
                    .ok_or("workspace input expectedWorkspaceRevision is missing")?
                    .to_owned(),
            ),
            ProfileKind::Primary => None,
        };
        let root = profile.project_root.clone();
        Ok(PatchIntent {
            invocation: profile
                .patch_invocation(reference, &["-f", "-p1", "-d", &root, "-i", &leased.path]),
            patch_attempt_ref: format!("patch-{}", &digest[..32]),
            patch_artifact_id: leased.artifact_id.clone(),
            patch_file_path: leased.path.clone(),
            patch_sha256: leased.sha256.clone(),
            allowed_file_globs: request_globs,
            before,
            previous_workspace_revision: previous,
        })
    }

    /// Swift `WorkspaceOperationsProvider.action` for
    /// `workspace.revert-patch@1`: the preamble, then the exact durable
    /// attempt, still active in this profile, and its durable bytes unchanged.
    pub(crate) fn revert_action(
        &self,
        reference: &str,
        inputs: &Map<String, Value>,
    ) -> Result<RevertIntent, String> {
        let (_, profile) = self.preamble(reference, inputs)?;
        let attempt_ref = inputs
            .get("patchAttemptRef")
            .and_then(Value::as_str)
            .ok_or("workspace input patchAttemptRef is missing")?;
        let attempt = self.attempt_store()?.load(attempt_ref)?;
        if attempt.project_ref != profile.project_ref
            || attempt.project_root != profile.project_root
            || attempt.reverted_at_utc.is_some()
        {
            return Err("workspace patch attempt is not active in this ProjectProfile".into());
        }
        let unchanged = std::fs::read(&attempt.patch_file_path)
            .is_ok_and(|bytes| support::sha256(&bytes) == attempt.patch_sha256);
        if !unchanged {
            return Err("workspace original patch bytes are unavailable or changed".into());
        }
        let root = profile.project_root.clone();
        let invocation = profile.patch_invocation(
            reference,
            &[
                "-f",
                "-R",
                "-p1",
                "-d",
                &root,
                "-i",
                &attempt.patch_file_path,
            ],
        );
        Ok(RevertIntent {
            invocation,
            attempt,
        })
    }

    /// The profile a typed patch action names, as Swift's provider routes
    /// every later call on it.
    fn acting_profile(&self, action: &PatchAction) -> Result<WorkspaceProfile, String> {
        let project_ref = &action.invocation().project_ref;
        self.registry
            .profile(project_ref)
            .ok_or_else(|| format!("workspace.projectProfileUnavailable:{project_ref}"))
    }

    /// Swift `WorkspaceOperationsProvider.lower(action:context:)` for a patch
    /// action, right before its dispatch: the executable one the profile
    /// pinned, and the tree exactly as the action found it — the pre-image
    /// for an apply, the attempt's post-image for a revert.
    pub(crate) fn lower(&self, action: &PatchAction) -> Result<(), String> {
        let profile = self.acting_profile(action)?;
        let invocation = action.invocation();
        if !profile.owns_executable(&invocation.executable_path, &invocation.executable_sha256) {
            return Err("workspace provider received a foreign action or executable".into());
        }
        match action {
            PatchAction::Apply(intent) => patch::require(&intent.before, &profile.project_root),
            PatchAction::Revert(intent) => {
                patch::require(&intent.attempt.after, &profile.project_root)
            }
        }
    }

    /// Swift `WorkspaceOperationsProvider.verify` for a patch action: the
    /// exit status, then the declared files read back from disk; an applied
    /// patch's bytes and attempt made durable, a reverted attempt closed.
    pub(crate) fn verify(
        &self,
        action: &PatchAction,
        receipt: &ToolReceipt,
        now: &str,
    ) -> PatchVerdict {
        let unknown = |detail: String| PatchVerdict::Unknown(detail);
        let profile = match self.acting_profile(action) {
            Ok(profile) => profile,
            Err(reason) => return unknown(reason),
        };
        if receipt.truncated {
            return PatchVerdict::Failed(
                "workspace.outputTruncated",
                "bounded output was truncated; semantic result is incomplete".into(),
            );
        }
        let mut summary: BTreeMap<String, String> = patch::output_summary(receipt)
            .into_iter()
            .filter_map(|(key, value)| Some((key, value.as_str()?.to_owned())))
            .collect();
        let attempts = match self.attempt_store() {
            Ok(attempts) => attempts,
            Err(reason) => return unknown(reason),
        };
        match action {
            PatchAction::Apply(intent) => {
                if receipt.exit_status != 0 {
                    return PatchVerdict::Failed(
                        "workspace.patchFailed",
                        patch::failed_detail(receipt),
                    );
                }
                let paths: Vec<String> = intent
                    .before
                    .iter()
                    .map(|snapshot| snapshot.relative_path.clone())
                    .collect();
                let after = match patch::snapshots(&paths, &profile.project_root) {
                    Ok(after) => after,
                    Err(reason) => return unknown(reason),
                };
                if after == intent.before {
                    return PatchVerdict::Failed(
                        "workspace.patchReadbackFailed",
                        "patch reported success but no declared file changed".into(),
                    );
                }
                let durable = match attempts.persist_patch(
                    &intent.patch_attempt_ref,
                    &intent.patch_file_path,
                    &intent.patch_sha256,
                ) {
                    Ok(durable) => durable,
                    Err(reason) => return unknown(reason),
                };
                let after_revision = match profile.kind {
                    ProfileKind::Evolution => match support::workspace_revision(
                        &profile.project_root,
                        &profile.profile_id,
                        &profile.allowed_file_globs,
                    ) {
                        Ok(revision) => Some(revision),
                        Err(reason) => return unknown(reason),
                    },
                    ProfileKind::Primary => None,
                };
                let attempt = PatchAttempt {
                    patch_attempt_ref: intent.patch_attempt_ref.clone(),
                    project_ref: profile.project_ref.clone(),
                    project_root: profile.project_root.clone(),
                    patch_artifact_id: intent.patch_artifact_id.clone(),
                    patch_file_path: durable,
                    patch_sha256: intent.patch_sha256.clone(),
                    allowed_file_globs: intent.allowed_file_globs.clone(),
                    before: intent.before.clone(),
                    after: after.clone(),
                    workspace_revision_before: intent.previous_workspace_revision.clone(),
                    workspace_revision_after: after_revision.clone(),
                    applied_at_utc: now.into(),
                    reverted_at_utc: None,
                };
                if let Err(reason) = attempts.save(&attempt) {
                    return unknown(reason);
                }
                summary.insert("patchAttemptRef".into(), intent.patch_attempt_ref.clone());
                summary.insert(
                    "workspaceRevision".into(),
                    after_revision.unwrap_or_else(|| patch::revision(&after)),
                );
                summary.insert(
                    "previousWorkspaceRevision".into(),
                    intent
                        .previous_workspace_revision
                        .clone()
                        .unwrap_or_else(|| patch::revision(&intent.before)),
                );
                summary.insert(
                    "touchedFiles".into(),
                    after
                        .iter()
                        .map(|snapshot: &FileSnapshot| snapshot.relative_path.as_str())
                        .collect::<Vec<_>>()
                        .join(","),
                );
                PatchVerdict::Verified(summary)
            }
            PatchAction::Revert(intent) => {
                if receipt.exit_status != 0 {
                    return PatchVerdict::Failed(
                        "workspace.revertFailed",
                        patch::failed_detail(receipt),
                    );
                }
                if let Err(error) = patch::require(&intent.attempt.before, &profile.project_root) {
                    return PatchVerdict::Failed(
                        "workspace.revertReadbackFailed",
                        format!("workspace did not return to the exact original revision: {error}"),
                    );
                }
                if let Err(reason) = attempts.save(&intent.attempt.marking_reverted(now)) {
                    return unknown(reason);
                }
                summary.insert(
                    "patchAttemptRef".into(),
                    intent.attempt.patch_attempt_ref.clone(),
                );
                summary.insert(
                    "workspaceRevision".into(),
                    intent
                        .attempt
                        .workspace_revision_before
                        .clone()
                        .unwrap_or_else(|| patch::revision(&intent.attempt.before)),
                );
                PatchVerdict::Verified(summary)
            }
        }
    }

    /// The durable patch lineage of one Runtime-owned copy, or why it cannot
    /// vouch.
    pub(crate) fn patch_lineage(&self, project_ref: &str) -> Result<Vec<PatchAttempt>, String> {
        self.attempt_store()?.attempts_for(project_ref)
    }
}

/// Swift `stringArray(_:in:)`.
fn string_array(inputs: &Map<String, Value>, key: &str) -> Result<Vec<String>, String> {
    let Some(values) = inputs.get(key).and_then(Value::as_array) else {
        return Err(format!("workspace input {key} is missing"));
    };
    values
        .iter()
        .map(|value| {
            value
                .as_str()
                .map(str::to_owned)
                .ok_or_else(|| format!("workspace input {key} contains a non-string"))
        })
        .collect()
}
