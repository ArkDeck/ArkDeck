//! The Rust workspace provider as the Runtime composes it (TASK-XPA-015,
//! M3): Swift's daemon composition root over the registered projects
//! (`main.swift`), `WorkspaceOperationsProvider` routing a request to the
//! profile it names, and the registration a workspace Job holds while it is
//! materialized.
//!
//! At start-up every registered project whose root is still the directory
//! its registration pinned resolves to the profile of its kind, the
//! Runtime-owned copies a previous Runtime made are adopted again, and every
//! registered generation is marked applied. A project registered or changed
//! afterwards is refused until the Runtime restarts, as Swift refuses it.
use crate::operation_catalog::CatalogOperation;
use crate::workspace_isolation::{ISOLATION_DIRECTORY, IsolationIntent};
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
    projects: Option<Arc<WorkspaceProjectStore>>,
    /// The engine clock a materialization reads.
    pub(crate) now: fn() -> Option<String>,
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
                    projects: Some(Arc::clone(&projects)),
                    now,
                },
                Vec::new(),
            )
        } else {
            let composition = Self {
                registry: registry(&resolved).map_err(|error| error.to_string())?,
                primaries: resolved.iter().map(|p| p.project_ref.clone()).collect(),
                unavailable: None,
                isolation: Some(
                    isolation_at(&state_root.join(ISOLATION_DIRECTORY))
                        .map_err(|error| error.to_string())?,
                ),
                projects: Some(Arc::clone(&projects)),
                now,
            };
            let unadopted = composition.adopt_runtime_workspaces();
            (composition, unadopted)
        };
        projects.mark_applied(applied);
        Ok(composed)
    }

    /// A composition over the given primary profiles with its copies under
    /// `isolation_root`, and no registration owner: the Swift oracle's
    /// Runtime, whose engine has no workspace project store.
    pub fn with_profiles(
        profiles: Vec<WorkspaceProfile>,
        isolation_root: &Path,
        now: fn() -> Option<String>,
    ) -> io::Result<Self> {
        let mut primaries: Vec<String> = profiles.iter().map(|p| p.project_ref.clone()).collect();
        primaries.sort();
        Ok(Self {
            registry: registry(&profiles)?,
            primaries,
            unavailable: None,
            isolation: Some(isolation_at(isolation_root)?),
            projects: None,
            now,
        })
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
        let project_ref = text("projectRef")?;
        let profile = self
            .registry
            .profile(project_ref)
            .ok_or_else(|| format!("workspace.projectProfileUnavailable:{project_ref}"))?;
        if let Some(reason) = profile.unavailability(reference, self.isolation.is_some()) {
            return Err(reason);
        }
        // A caller that states which tree it decided against gets that
        // statement enforced over the whole profile scope.
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
}
