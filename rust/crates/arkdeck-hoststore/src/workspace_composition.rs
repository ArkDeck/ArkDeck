//! The Rust workspace provider as the Runtime composes it (TASK-XPA-015,
//! M3): Swift's daemon composition root over the registered projects
//! (`main.swift`), `WorkspaceOperationsProvider` routing a request to the
//! profile it names, and the registration a workspace Job holds while it is
//! materialized.
//!
//! At start-up every registered project whose root is still the directory
//! its registration pinned resolves to the profile of its kind — an
//! OpenHarmony project with the Hvigor presets registered against it whose
//! exact DevEco toolchain pin resolved — the Runtime-owned copies a previous
//! Runtime made are adopted again — the base revision vouching for an
//! unpatched copy, the durable patch lineage for a patched one — and every
//! registered generation, project and preset, that composed is marked
//! applied. A project or preset registered or changed afterwards is refused
//! until the Runtime restarts, as Swift refuses it.
use crate::operation_catalog::CatalogOperation;
use crate::workspace_build::{BuildAction, BuildVerdict, Landed, Landing};
use crate::workspace_checkpoint::{self as checkpoint, ArchiveCheckpoint, CheckpointAction};
use crate::workspace_isolation::{ISOLATION_DIRECTORY, IsolationIntent};
use crate::workspace_patch::{
    self as patch, ATTEMPTS_DIRECTORY, AttemptStore, FileSnapshot, PatchAction, PatchAttempt,
    PatchIntent, RevertIntent, ToolReceipt, VerifiedToolDispatch, WorkspaceToolDispatch,
};
use crate::workspace_profile::{
    PRESET_UNAVAILABLE, ProfileKind, ProfileRegistry, RegisteredBuildPreset, RegisteredKind,
    SigningPresetRef, Unavailability, VerifiedResource, WorkspaceAuthorizationFacts,
    WorkspaceProfile,
};
use crate::workspace_project::{WorkspaceProjectStore, WorkspaceUse};
use crate::workspace_read::{
    self as read, DIFF, INSPECT, Inspector, RANGE, ReadAction, ReadLowering, STATUS,
    SourceInspection,
};
use crate::workspace_signing::SigningSetup;
use crate::workspace_support::{self as support, foundation_standardized, is_narrower};
use arkdeck_contract::WireError;
use arkdeck_provider_workspace::credential_owner::CredentialOwner;
use arkdeck_provider_workspace::signer::{self, SignedHap, SigningFailure};
use arkdeck_provider_workspace::signing_action::{SigningAction, SigningAttemptPaths};
use arkdeck_provider_workspace::signing_preset::{
    DEFAULT_PRESET_ID, SigningPresetStore, SigningSecrets, remeasure_for_dispatch,
};
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
    /// The dispatch a patch or build step runs its pinned tool through.
    pub(crate) tool: Box<dyn WorkspaceToolDispatch>,
    /// Swift `WorkspaceActionExecutableResolver.resourcesByExecutable` over
    /// the start-up profiles: what a dispatch of each pinned executable holds
    /// open while its child runs.
    resources: BTreeMap<(String, String), Vec<VerifiedResource>>,
    /// Swift `childEnvironmentByExecutablePath`: what a child of each pinned
    /// executable finds in its environment (a registered Hvigor preset's
    /// `DEVECO_SDK_HOME`).
    environment: BTreeMap<String, Vec<(String, String)>>,
    /// Swift `DeviceMutationLaneCoordinator` for the host target every
    /// workspace mutation names: a patch or checkpoint Job's steps hold it
    /// from its running transition to its last step, so one never overlaps
    /// another.
    pub(crate) lane: Mutex<()>,
    /// The signing half of Swift's provider; without it nothing is signed.
    pub(crate) signing: Option<Signing>,
    /// Swift `WorkspaceProvider`'s inspector: the one a host configured
    /// (`ARKDECK_WORKSPACE_INSPECTOR`), pinned when the Runtime composed it.
    inspector: Option<Inspector>,
    /// Swift `WorkspaceProjectRegistry`: the root every registered project
    /// still pins, whether or not its profile resolved, by reference.
    inspection_roots: BTreeMap<String, String>,
}

/// Swift's `signingPresetStore`, `signingCredentialOwner` and
/// `signingAttemptStore`, and the Keychain the store reads its secrets from.
pub(crate) struct Signing {
    pub(crate) owner: CredentialOwner,
    pub(crate) secrets: Box<dyn SigningSecrets + Send + Sync>,
    /// Swift `OpenHarmonySigningAttemptStore`'s root, as it spells it.
    pub(crate) attempts: String,
}

impl Signing {
    /// The preset installed at `store_root` through its credential owner,
    /// its passwords read from `secrets`, its attempts below `attempts_root`
    /// — created owner-only, as Swift's attempt store creates it.
    fn at(
        store_root: &Path,
        secrets: Box<dyn SigningSecrets + Send + Sync>,
        attempts_root: &Path,
    ) -> io::Result<Self> {
        use std::os::unix::fs::PermissionsExt;
        DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(attempts_root)?;
        std::fs::set_permissions(attempts_root, std::fs::Permissions::from_mode(0o700))?;
        let spelled = |path: &Path| foundation_standardized(&path.to_string_lossy());
        Ok(Self {
            owner: CredentialOwner::new(SigningPresetStore::new(spelled(store_root))),
            secrets,
            attempts: spelled(attempts_root),
        })
    }
}

/// What composing reports for the daemon to print, as Swift prints it at
/// start-up.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct CompositionNotes {
    /// Swift `adoptRuntimeWorkspaces()`: the copies adoption could not vouch
    /// for, which stay unresolvable.
    pub unadopted: Vec<String>,
    /// Swift `releaseOwners(absentFrom:)` at start-up: the presets whose
    /// credential pins no store record carries any more, released — or why
    /// the reconciliation was skipped. `None` where this Runtime does not own
    /// the default state directory and so must not judge the pins.
    pub released_credential_owners: Option<Result<Vec<String>, String>>,
}

/// The operation signing serves.
pub(crate) const SIGN: &str = "workspace.sign-openharmony-hap@1";
/// Swift's bound on an unsigned HAP.
const MAXIMUM_UNSIGNED_HAP_BYTES: u64 = 64 * 1024 * 1024;

/// How a signed product was judged: Swift's `.verified` summary or its
/// `.failed` code and detail.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum SignVerdict {
    Verified(BTreeMap<String, String>),
    Failed(&'static str, String),
}

/// Swift `journalStep`'s arguments for `signWorkspaceOpenHarmonyHap`: the
/// project, the selected preset and the input's identity.
pub(crate) fn sign_journal_arguments(action: &SigningAction) -> Value {
    serde_json::json!({
        "projectRef": action.project_ref,
        "signingPresetRef": action.selected_signing_preset_ref(),
        "inputArtifactId": action.input_artifact_id,
        "inputSha256": action.input_sha256,
    })
}

/// Swift `ProviderReconcileOutcome` for a parked signing action.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum SignReconcile {
    NotExecuted,
    Completed(BTreeMap<String, String>),
    Unknown(String),
}

/// Swift `BootstrapDevEcoToolchainRegistry.ResolvedToolchain`, the part a
/// registered Hvigor preset composes from: the Node launcher, the Hvigor
/// script and SDK root the exact pin names, and every other file the record
/// pins, each re-measured by the registry before it answered.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ResolvedToolchain {
    pub node_path: String,
    pub hvigor_script_path: String,
    pub sdk_root_path: String,
    pub verified_resources: Vec<VerifiedResource>,
}

/// Swift `devecoToolchains.resolve(_:expectedGeneration:owner:)` as the
/// composition root hands it over: (toolchain, generation, preset) to the
/// toolchain that exact pin names, or why it cannot be.
pub type ToolchainResolver<'a> = &'a dyn Fn(&str, u64, &str) -> Result<ResolvedToolchain, String>;

/// How a lowered build step runs: the landing a copy's product needs, the
/// environment its executable's children get and the files it holds open.
pub(crate) struct BuildLowering {
    pub(crate) landing: Option<Landing>,
    pub(crate) environment: Vec<(String, String)>,
    pub(crate) resources: Vec<VerifiedResource>,
}

/// The parts of Swift's child base a Hvigor build reads beyond this Runtime's
/// clean one: the home it keeps its caches in and its temporary directory,
/// as the daemon's own environment names them.
fn inherited_base() -> Vec<(String, String)> {
    ["HOME", "TMPDIR"]
        .into_iter()
        .filter_map(|key| {
            let value = std::env::var(key).ok()?;
            (!value.is_empty() && !value.contains('\0')).then(|| (key.to_owned(), value))
        })
        .collect()
}

/// An input Artifact the engine resolved from its lease for this Job — a
/// patch, an unsigned HAP: the facts the lease names and the payload they
/// describe.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct LeasedInput {
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

/// Swift's composition-root pass over the registered presets: each build or
/// test preset's exact DevEco pin resolved to the toolchain it names, with
/// the environment its Node children get; a symbol preset needs nothing to
/// resolve. Answers the resolved Hvigor presets by project, the environment
/// by executable path, the presets that composed and those that did not.
struct RegisteredPresets {
    by_project: BTreeMap<String, Vec<RegisteredBuildPreset>>,
    /// The signing presets whose toolchain pin and credential resolved for
    /// their own project.
    signing: BTreeMap<String, Vec<SigningPresetRef>>,
    environment: BTreeMap<String, Vec<(String, String)>>,
    composed: BTreeMap<String, (String, u64)>,
    failures: BTreeMap<String, String>,
}

/// Swift's `case "signing"` of the same pass: the toolchain pin and the
/// credential both resolve for the preset — the credential pinned by this
/// preset, its secrets present, bound to the preset's own project.
fn resolve_signing(
    preset: &crate::workspace_project::WorkspacePresetComposition,
    toolchains: ToolchainResolver<'_>,
    signing: &Signing,
) -> Result<SigningPresetRef, String> {
    let (Some(toolchain), Some(generation), Some(credential)) = (
        preset.toolchain_ref.as_deref(),
        preset.toolchain_generation,
        preset.credential_ref.as_deref(),
    ) else {
        return Err(" registered signing preset has incomplete dependencies".into());
    };
    toolchains(toolchain, generation, &preset.preset_ref)?;
    let receipt = signing
        .owner
        .resolve(
            credential,
            Some(&preset.preset_ref),
            true,
            &*signing.secrets,
        )
        .map_err(|error| error.to_string())?;
    if receipt.project_ref != preset.project_ref {
        return Err("resourceConflict: signing credential project binding changed".into());
    }
    SigningPresetRef::new(&preset.preset_ref, credential, preset.timeout_seconds)
}

fn resolve_registered(
    presets: &[crate::workspace_project::WorkspacePresetComposition],
    toolchains: ToolchainResolver<'_>,
    signing: Option<&Signing>,
) -> RegisteredPresets {
    let mut resolved = RegisteredPresets {
        by_project: BTreeMap::new(),
        signing: BTreeMap::new(),
        environment: BTreeMap::new(),
        composed: BTreeMap::new(),
        failures: BTreeMap::new(),
    };
    for preset in presets {
        let kind = match preset.kind.as_str() {
            "build" => RegisteredKind::Build,
            "test" => RegisteredKind::Test,
            "symbol" => {
                resolved.composed.insert(
                    preset.preset_ref.clone(),
                    (preset.project_ref.clone(), preset.generation),
                );
                continue;
            }
            // A signing preset pins a credential: without the owner that
            // holds it, it resolves to nothing.
            "signing" => {
                let outcome = match signing {
                    Some(signing) => resolve_signing(preset, toolchains, signing),
                    None => Err(" signing credential owner is unavailable".into()),
                };
                match outcome {
                    Ok(reference) => {
                        resolved
                            .signing
                            .entry(preset.project_ref.clone())
                            .or_default()
                            .push(reference);
                        resolved.composed.insert(
                            preset.preset_ref.clone(),
                            (preset.project_ref.clone(), preset.generation),
                        );
                    }
                    Err(error) => {
                        resolved.failures.insert(
                            preset.preset_ref.clone(),
                            format!("workspace.presetResolutionFailed:{error}"),
                        );
                    }
                }
                continue;
            }
            _ => {
                resolved.failures.insert(
                    preset.preset_ref.clone(),
                    "workspace.presetKindUnsupported".into(),
                );
                continue;
            }
        };
        let (Some(toolchain), Some(generation), Some(module), Some(product), Some(mode)) = (
            preset.toolchain_ref.as_deref(),
            preset.toolchain_generation,
            preset.module.as_ref(),
            preset.product.as_ref(),
            preset.build_mode.as_ref(),
        ) else {
            resolved.failures.insert(
                preset.preset_ref.clone(),
                "workspace.presetResolutionFailed: registered Hvigor preset has no toolchain pin"
                    .into(),
            );
            continue;
        };
        match toolchains(toolchain, generation, &preset.preset_ref) {
            Ok(toolchain) => {
                resolved.environment.insert(
                    crate::workspace_support::foundation_standardized(&toolchain.node_path),
                    vec![(
                        "DEVECO_SDK_HOME".to_owned(),
                        toolchain.sdk_root_path.clone(),
                    )],
                );
                resolved
                    .by_project
                    .entry(preset.project_ref.clone())
                    .or_default()
                    .push(RegisteredBuildPreset {
                        kind,
                        preset_ref: preset.preset_ref.clone(),
                        module: module.clone(),
                        product: product.clone(),
                        build_mode: mode.clone(),
                        timeout_seconds: preset.timeout_seconds,
                        node_path: toolchain.node_path,
                        hvigor_script_path: toolchain.hvigor_script_path,
                        sdk_root_path: toolchain.sdk_root_path,
                        verified_resources: toolchain.verified_resources,
                    });
                resolved.composed.insert(
                    preset.preset_ref.clone(),
                    (preset.project_ref.clone(), preset.generation),
                );
            }
            Err(error) => {
                resolved.failures.insert(
                    preset.preset_ref.clone(),
                    format!("workspace.presetResolutionFailed:{error}"),
                );
            }
        }
    }
    resolved
}

impl WorkspaceComposition {
    /// Swift's composition root over the registered projects under
    /// `state_root`: the credential owner's pins reconciled with the preset
    /// store where `signing` says this Runtime owns them, the registered
    /// presets resolved through `toolchains` and — signing presets — the
    /// credential owner, the profiles resolved, the isolation manager and its
    /// adoption, and the applied generations. Returns what the daemon
    /// reports: the reconciliation and what adoption could not vouch for,
    /// which stays unresolvable. Without `signing` nothing is signed.
    pub fn compose(
        projects: Arc<WorkspaceProjectStore>,
        state_root: &Path,
        home: &str,
        now: fn() -> Option<String>,
        toolchains: ToolchainResolver<'_>,
        signing: Option<SigningSetup>,
    ) -> Result<(Self, CompositionNotes), String> {
        let records = projects.startup_records().map_err(|error| error.message)?;
        let preset_records = projects
            .preset_composition_records()
            .map_err(|error| error.message)?;
        let mut notes = CompositionNotes::default();
        let signing = match signing {
            Some(setup) => {
                if setup.releases_orphaned_owners {
                    // The preset store is the authority on which presets
                    // exist; the ledger beside the signing material keeps
                    // pins for presets a retired state directory dropped.
                    let registered = preset_records
                        .iter()
                        .map(|preset| preset.preset_ref.clone())
                        .collect();
                    notes.released_credential_owners = Some(
                        CredentialOwner::new(SigningPresetStore::new(setup.store_root.clone()))
                            .release_owners(&registered)
                            .map_err(|error| error.to_string()),
                    );
                }
                Some(
                    Signing::at(&setup.store_root, setup.secrets, &setup.attempts_root)
                        .map_err(|error| error.to_string())?,
                )
            }
            None => None,
        };
        let presets = resolve_registered(&preset_records, toolchains, signing.as_ref());
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
                "openharmony" => WorkspaceProfile::water_flow_registered(
                    root,
                    &record.project_ref,
                    home,
                    presets
                        .by_project
                        .get(&record.project_ref)
                        .map(Vec::as_slice)
                        .unwrap_or_default(),
                    presets
                        .signing
                        .get(&record.project_ref)
                        .cloned()
                        .unwrap_or_default(),
                ),
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
        // Swift marks a preset applied when its project composed and it
        // resolved.
        let applied_presets: BTreeMap<String, u64> = presets
            .composed
            .iter()
            .filter(|(_, (project, _))| resolved.iter().any(|p| &p.project_ref == project))
            .map(|(preset, (_, generation))| (preset.clone(), *generation))
            .collect();
        // Swift `WorkspaceProjectRegistry(roots:)`: every registered root the
        // registration still pins, which the inspection reads.
        let inspection_roots: BTreeMap<String, String> = records
            .iter()
            .filter_map(|record| {
                let root = record.root.as_ref().ok()?;
                Some((record.project_ref.clone(), root.clone()))
            })
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
                    resources: BTreeMap::new(),
                    environment: BTreeMap::new(),
                    signing,
                    inspector: None,
                    inspection_roots,
                },
                notes,
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
                resources: WorkspaceProfile::resources_by_executable(&resolved),
                environment: presets.environment.clone(),
                signing,
                inspector: None,
                inspection_roots,
            };
            notes.unadopted = composition.adopt_runtime_workspaces();
            (composition, notes)
        };
        projects.mark_applied(applied);
        projects.mark_applied_presets(applied_presets);
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
            resources: WorkspaceProfile::resources_by_executable(&profiles),
            environment: BTreeMap::new(),
            signing: None,
            inspector: None,
            inspection_roots: BTreeMap::new(),
        })
    }

    /// The same composition, inspecting source with the inspector a host
    /// configured (Swift's `ARKDECK_WORKSPACE_INSPECTOR`), pinned now.
    pub fn with_inspector(mut self, inspector: Option<Inspector>) -> Self {
        self.inspector = inspector;
        self
    }

    /// The same composition, the inspection reading the given registered
    /// roots by project, as Swift's daemon hands `WorkspaceProvider` its
    /// `WorkspaceProjectRegistry`.
    pub fn with_inspection_roots(mut self, roots: BTreeMap<String, String>) -> Self {
        self.inspection_roots = roots;
        self
    }

    /// The same composition, its patch and build steps dispatched through
    /// `tool`.
    pub fn with_tool_dispatch(mut self, tool: Box<dyn WorkspaceToolDispatch>) -> Self {
        self.tool = tool;
        self
    }

    /// The same composition, the children of the executable at `path` given
    /// `environment` (Swift `childEnvironmentByExecutablePath`, keyed by the
    /// executable identity's own path).
    pub fn with_child_environment(mut self, path: &str, environment: &[(&str, &str)]) -> Self {
        self.environment.insert(
            foundation_standardized(path),
            environment
                .iter()
                .map(|(key, value)| ((*key).to_owned(), (*value).to_owned()))
                .collect(),
        );
        self
    }

    /// The same composition, signing with the preset installed at
    /// `store_root` through its credential owner, its passwords read from
    /// `secrets`, its attempts below `attempts_root` (Swift's
    /// `workspace-signing-attempts`, created owner-only).
    pub fn with_signing(
        mut self,
        store_root: &Path,
        secrets: Box<dyn SigningSecrets + Send + Sync>,
        attempts_root: &Path,
    ) -> io::Result<Self> {
        self.signing = Some(Signing::at(store_root, secrets, attempts_root)?);
        Ok(self)
    }

    /// Swift's registered provider's `runtimeAvailability(for:)`, as
    /// `operation.list` codes it: the inspection is `WorkspaceProvider`'s
    /// own — an inspector configured and some registered root; any other
    /// operation is available when some start-up profile serves it,
    /// otherwise it carries the first profile's reason.
    pub(crate) fn provider_unavailability(&self, reference: &str) -> Option<Unavailability> {
        if reference == INSPECT {
            if self.inspector.is_none() {
                return Some((
                    "provider_tool_unavailable",
                    "no_workspace_inspector_configured".into(),
                ));
            }
            if self.inspection_roots.is_empty() {
                return Some((PRESET_UNAVAILABLE, "no_workspace_project_registered".into()));
            }
            return None;
        }
        if let Some(reason) = &self.unavailable {
            return Some(("provider_tool_unavailable", reason.clone()));
        }
        let mut first = None;
        for project_ref in &self.primaries {
            let Some(profile) = self.registry.profile(project_ref) else {
                continue;
            };
            // A profile with no reason to refuse makes the operation available.
            let reason = self.unavailability_of(&profile, reference)?;
            first.get_or_insert(reason);
        }
        Some(
            first.unwrap_or_else(|| (PRESET_UNAVAILABLE, "no_workspace_project_registered".into())),
        )
    }

    /// Swift `runtimeAvailability(for:profile:)`, signing included: a
    /// registered signing preset whose credential resolves for this project,
    /// or — only where the profile may fall back — the installed receipt of
    /// this project ready to sign.
    fn unavailability_of(
        &self,
        profile: &WorkspaceProfile,
        reference: &str,
    ) -> Option<Unavailability> {
        if reference != SIGN {
            return profile.unavailability(reference, self.isolation.is_some());
        }
        let has_preset = if !profile.signing.is_empty() {
            let Some(signing) = &self.signing else {
                return Some((
                    PRESET_UNAVAILABLE,
                    "workspace.signingCredentialOwnerUnavailable".into(),
                ));
            };
            profile.signing.values().any(|preset| {
                signing
                    .owner
                    .resolve(
                        &preset.credential_ref,
                        Some(&preset.preset_id),
                        true,
                        &*signing.secrets,
                    )
                    .is_ok_and(|receipt| receipt.project_ref == profile.project_ref)
            })
        } else if profile.allows_legacy_signing {
            let Some(signing) = &self.signing else {
                return Some((
                    PRESET_UNAVAILABLE,
                    "workspace.signingPresetUnavailable".into(),
                ));
            };
            // Swift `status()`: ready when the fixed preset validates with
            // its secrets present.
            signing
                .owner
                .store()
                .load_validated(DEFAULT_PRESET_ID, true, &*signing.secrets)
                .is_ok_and(|receipt| receipt.project_ref == profile.project_ref)
        } else {
            false
        };
        profile.preset_unavailability(has_preset)
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
        if let Some((_, reason)) = self.unavailability_of(&profile, reference) {
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

    /// Swift `action(for:operation:inputs:context:)` for a read:
    /// - an inspection by `WorkspaceProvider` — the root the project
    ///   registered, the scope and the symbol screened;
    /// - any other read by `WorkspaceOperationsProvider` — its preamble, then
    ///   the pinned tool the profile offers for it and the argv built from
    ///   the screened inputs.
    ///
    /// A refusal is the detail Swift's provider error describes itself by.
    pub(crate) fn read_action(
        &self,
        reference: &str,
        inputs: &Map<String, Value>,
    ) -> Result<ReadAction, String> {
        let text = |key: &str| inputs.get(key).and_then(Value::as_str);
        if reference == INSPECT {
            let (Some(project_ref), Some(symbol), Some(scope)) =
                (text("projectRef"), text("symbol"), text("fileScope"))
            else {
                return Err(
                    "inspect-workspace-source requires typed projectRef, symbol and fileScope \
                     inputs"
                        .into(),
                );
            };
            let root = self
                .inspection_roots
                .get(project_ref)
                .ok_or_else(|| read::unknown_project(project_ref))?;
            read::validate_scope(scope)?;
            read::validate_symbol(symbol)?;
            return Ok(ReadAction::InspectSource(SourceInspection {
                project_ref: project_ref.into(),
                project_root: root.clone(),
                symbol: symbol.into(),
                file_scope: scope.into(),
            }));
        }
        let string =
            |key: &str| text(key).ok_or_else(|| format!("workspace input {key} is missing"));
        let integer = |key: &str| {
            inputs
                .get(key)
                .and_then(Value::as_i64)
                .ok_or_else(|| format!("workspace input {key} is missing"))
        };
        let (_, profile) = self.preamble(reference, inputs)?;
        let root = profile.project_root.clone();
        let control = || "workspace.sourceControlPresetUnavailable".to_owned();
        match reference {
            STATUS => profile
                .source_control_invocation(
                    reference,
                    &[
                        "-C",
                        &root,
                        "status",
                        "--porcelain=v1",
                        "--untracked-files=all",
                        "--",
                        ".",
                    ],
                )
                .map(ReadAction::GitStatus)
                .ok_or_else(control),
            DIFF => {
                if profile.source_control_invocation(reference, &[]).is_none() {
                    return Err(control());
                }
                let base = string("baseRevision")?;
                let scope = string("pathScope")?;
                read::validate_revision_expression(base)?;
                read::validate_path_scope(scope)?;
                profile
                    .source_control_invocation(
                        reference,
                        &["-C", &root, "diff", "--stat", base, "--", scope],
                    )
                    .map(ReadAction::Diff)
                    .ok_or_else(control)
            }
            RANGE => {
                let reader = || "workspace.sourceReaderPresetUnavailable".to_owned();
                if profile.source_reader_invocation(reference, &[]).is_none() {
                    return Err(reader());
                }
                let file = string("filePath")?;
                let start = integer("lineStart")?;
                let end = integer("lineEnd")?;
                // An unbounded range is how a read becomes "ship the
                // repository": the span is part of the contract.
                if !(start >= 1 && end >= start && end - start < 2000) {
                    return Err("workspace.malformedLineRange".into());
                }
                let path = read::resolved_readable_path(file, &root, &profile.allowed_file_globs)?;
                profile
                    .source_reader_invocation(reference, &["-n", &format!("{start},{end}p"), &path])
                    .map(ReadAction::SourceRange)
                    .ok_or_else(reader)
            }
            other => Err(format!("{other} is not a workspace read")),
        }
    }

    /// Swift `lower(action:context:)` for a read: the inspection by the
    /// inspector a host configured; any other read by the executable its
    /// profile pinned, in that profile's root.
    pub(crate) fn lower_read(&self, action: &ReadAction) -> Result<ReadLowering, String> {
        let invocation = match action {
            ReadAction::InspectSource(inspection) => {
                let inspector = self
                    .inspector
                    .as_ref()
                    .ok_or("no_workspace_inspector_configured")?;
                return Ok(ReadLowering::inspection(inspection, inspector));
            }
            ReadAction::GitStatus(invocation)
            | ReadAction::Diff(invocation)
            | ReadAction::SourceRange(invocation) => invocation,
        };
        let profile = self
            .registry
            .profile(&invocation.project_ref)
            .ok_or_else(|| {
                format!(
                    "workspace.projectProfileUnavailable:{}",
                    invocation.project_ref
                )
            })?;
        if !profile.owns_executable(&invocation.executable_path, &invocation.executable_sha256) {
            return Err("workspace provider received a foreign action or executable".into());
        }
        Ok(ReadLowering::invocation(invocation))
    }

    /// Swift `WorkspaceActionExecutableResolver`'s verified resources for one
    /// pinned executable: what its dispatch holds open while the child runs.
    pub(crate) fn resources_for(&self, path: &str, sha256: &str) -> Vec<VerifiedResource> {
        self.resources
            .get(&(path.to_owned(), sha256.to_owned()))
            .cloned()
            .unwrap_or_default()
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
        leased: Option<&LeasedInput>,
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

    /// Swift `WorkspaceOperationsProvider.action` for
    /// `workspace.create-checkpoint@1`: the preamble, then — with a pinned
    /// source-control tool — `git -C <root> stash create`, which writes a
    /// commit object and moves no ref, index or working file; otherwise the
    /// pinned archive writer over exactly the declared files, each inside
    /// the profile's scope and present, bounded together, into `job_id`'s
    /// fresh destination in the provider-owned attempt store, with `--`
    /// before the sorted names so none can become an option. A refusal is
    /// the detail Swift's provider error describes itself by.
    pub(crate) fn checkpoint_action(
        &self,
        reference: &str,
        inputs: &Map<String, Value>,
        job_id: &str,
    ) -> Result<CheckpointAction, String> {
        let (_, profile) = self.preamble(reference, inputs)?;
        let root = profile.project_root.clone();
        if let Some(invocation) =
            profile.source_control_invocation(reference, &["-C", &root, "stash", "create"])
        {
            return Ok(CheckpointAction::Git(invocation));
        }
        let unavailable = || "workspace.checkpointPresetUnavailable".to_owned();
        if profile
            .archive_checkpoint_invocation(reference, &[])
            .is_none()
        {
            return Err(unavailable());
        }
        let paths = string_array(inputs, "checkpointFilePaths")?;
        patch::validate(&paths, &root, &profile.allowed_file_globs, &paths)?;
        let snapshots = patch::snapshots(&paths, &root)?;
        if snapshots.iter().any(|snapshot| snapshot.sha256.is_none()) {
            return Err("workspace checkpoint cannot seal a missing source file".into());
        }
        checkpoint::require_bounded_sources(&paths, &root)?;
        let archive_path = self.attempt_store()?.checkpoint_archive_path(job_id);
        // Anything already there — a dangling link included — refuses.
        if std::fs::symlink_metadata(&archive_path).is_ok() {
            return Err("workspace checkpoint destination already exists".into());
        }
        let mut sorted = paths;
        support::swift_sort(&mut sorted);
        let mut arguments: Vec<&str> = vec!["-c", "-f", &archive_path, "-C", &root, "--"];
        arguments.extend(sorted.iter().map(String::as_str));
        let invocation = profile
            .archive_checkpoint_invocation(reference, &arguments)
            .ok_or_else(unavailable)?;
        Ok(CheckpointAction::Archive(ArchiveCheckpoint {
            invocation,
            archive_path,
            source_snapshots: snapshots,
        }))
    }

    /// Swift `lower(action:context:)` for a checkpoint: the executable one
    /// the acting profile pinned; an archive's destination still this Job's
    /// own and still absent, and its declared files still what the step was
    /// materialized against.
    pub(crate) fn lower_checkpoint(
        &self,
        action: &CheckpointAction,
        job_id: &str,
    ) -> Result<(), String> {
        let invocation = action.invocation();
        let profile = self
            .registry
            .profile(&invocation.project_ref)
            .ok_or_else(|| {
                format!(
                    "workspace.projectProfileUnavailable:{}",
                    invocation.project_ref
                )
            })?;
        if !profile.owns_executable(&invocation.executable_path, &invocation.executable_sha256) {
            return Err("workspace provider received a foreign action or executable".into());
        }
        if let CheckpointAction::Archive(archive) = action {
            let owned = self.attempt_store()?.checkpoint_archive_path(job_id);
            if archive.archive_path != owned
                || std::fs::symlink_metadata(&archive.archive_path).is_ok()
            {
                return Err(
                    "workspace checkpoint destination is not fresh and provider-owned".into(),
                );
            }
            patch::require(&archive.source_snapshots, &profile.project_root)?;
        }
        Ok(())
    }

    /// Swift `WorkspaceOperationsProvider.verify` for a checkpoint, in the
    /// acting profile: a judgement that cannot be made leaves the outcome
    /// unknown.
    pub(crate) fn verify_checkpoint(
        &self,
        action: &CheckpointAction,
        receipt: &ToolReceipt,
        job_id: &str,
    ) -> PatchVerdict {
        let project_ref = &action.invocation().project_ref;
        let Some(profile) = self.registry.profile(project_ref) else {
            return PatchVerdict::Unknown(format!(
                "workspace.projectProfileUnavailable:{project_ref}"
            ));
        };
        let owned = match self.attempt_store() {
            Ok(attempts) => attempts.checkpoint_archive_path(job_id),
            Err(reason) => return PatchVerdict::Unknown(reason),
        };
        action.verify(receipt, &owned, &profile.project_root)
    }

    /// Swift `WorkspaceOperationsProvider.action` for
    /// `workspace.build-openharmony@1`: the preamble, then the build preset
    /// the request names in that profile, resolved to its own invocation.
    pub(crate) fn build_action(
        &self,
        reference: &str,
        inputs: &Map<String, Value>,
    ) -> Result<BuildAction, String> {
        let (_, profile) = self.preamble(reference, inputs)?;
        let preset = inputs
            .get("buildPresetRef")
            .and_then(Value::as_str)
            .ok_or("workspace input buildPresetRef is missing")?;
        profile
            .build_invocation(reference, preset)
            .map(|invocation| BuildAction { invocation })
            .ok_or_else(|| format!("workspace.buildPresetUnavailable:{preset}"))
    }

    fn build_profile(&self, action: &BuildAction) -> Result<WorkspaceProfile, String> {
        let project_ref = &action.invocation.project_ref;
        self.registry
            .profile(project_ref)
            .ok_or_else(|| format!("workspace.projectProfileUnavailable:{project_ref}"))
    }

    /// Swift `WorkspaceOperationsProvider.lower` for a build: the executable
    /// one the profile pinned; for a Runtime-owned copy whose preset declares
    /// a product, the landing its dispatch prepares and reads back; and what
    /// the dispatcher gives the executable's children and holds open for
    /// them.
    pub(crate) fn lower_build(&self, action: &BuildAction) -> Result<BuildLowering, String> {
        let profile = self.build_profile(action)?;
        let invocation = &action.invocation;
        if !profile.owns_executable(&invocation.executable_path, &invocation.executable_sha256) {
            return Err("workspace provider received a foreign action or executable".into());
        }
        let landing = match profile.kind {
            ProfileKind::Evolution => {
                profile
                    .build_product(&invocation.preset_id)
                    .map(|product| Landing {
                        destination: format!(
                            "{}/{product}",
                            profile.project_root.trim_end_matches('/')
                        ),
                    })
            }
            ProfileKind::Primary => None,
        };
        let mut environment = inherited_base();
        for (key, value) in self
            .environment
            .get(&invocation.executable_path)
            .into_iter()
            .flatten()
        {
            environment.retain(|(existing, _)| existing != key);
            environment.push((key.clone(), value.clone()));
        }
        let resources = self
            .resources
            .get(&(
                invocation.executable_path.clone(),
                invocation.executable_sha256.clone(),
            ))
            .cloned()
            .unwrap_or_default();
        Ok(BuildLowering {
            landing,
            environment,
            resources,
        })
    }

    /// Swift `WorkspaceOperationsProvider.verify` for a build: the receipt,
    /// and for a copy whose preset declares a product, the product landed.
    /// A profile that is gone leaves the verdict unreadable.
    pub(crate) fn verify_build(
        &self,
        action: &BuildAction,
        receipt: &ToolReceipt,
        landed: Option<&Landed>,
    ) -> Result<BuildVerdict, String> {
        let profile = self.build_profile(action)?;
        let declares_product = profile.kind == ProfileKind::Evolution
            && profile
                .build_product(&action.invocation.preset_id)
                .is_some();
        Ok(crate::workspace_build::verify(
            receipt,
            declares_product,
            landed,
        ))
    }

    /// Swift `WorkspaceOperationsProvider.action` for
    /// `workspace.sign-openharmony-hap@1`: the preamble, the unsigned HAP the
    /// engine resolved from its lease, the receipt the named preset resolves
    /// to — a registered preset through its pinned credential, or the
    /// installed receipt itself where the profile may fall back — bound to the
    /// request's project, the input a bounded ZIP container, and the attempt
    /// paths owned by `job_id`.
    pub(crate) fn sign_action(
        &self,
        reference: &str,
        inputs: &Map<String, Value>,
        job_id: &str,
        leased: Option<&LeasedInput>,
    ) -> Result<SigningAction, String> {
        let (project_ref, profile) = self.preamble(reference, inputs)?;
        let Some(leased) = leased else {
            return Err(
                "workspace unsigned HAP Artifact lease was not resolved before materialization"
                    .into(),
            );
        };
        let preset_id = inputs
            .get("signingPresetRef")
            .and_then(Value::as_str)
            .ok_or("workspace input signingPresetRef is missing")?;
        let Some(signing) = &self.signing else {
            return Err("workspace.signingPresetUnavailable".into());
        };
        let receipt = if let Some(configured) = profile.signing.get(preset_id) {
            signing
                .owner
                .resolve(
                    &configured.credential_ref,
                    Some(preset_id),
                    true,
                    &*signing.secrets,
                )
                .map_err(|error| format!("workspace.signingPresetUnavailable:{error}"))?
        } else if profile.signing.is_empty() && profile.allows_legacy_signing {
            signing
                .owner
                .store()
                .load_validated(preset_id, true, &*signing.secrets)
                .map_err(|error| format!("workspace.signingPresetUnavailable:{error}"))?
        } else {
            return Err(format!("workspace.signingPresetUnavailable:{preset_id}"));
        };
        if receipt.project_ref != project_ref {
            return Err("workspace.signingPresetProjectMismatch".into());
        }
        let mut magic = [0u8; 4];
        let zip = std::fs::File::open(&leased.path)
            .and_then(|mut file| std::io::Read::read_exact(&mut file, &mut magic))
            .is_ok()
            && magic == [0x50, 0x4b, 0x03, 0x04];
        if leased.byte_count == 0 || leased.byte_count > MAXIMUM_UNSIGNED_HAP_BYTES || !zip {
            return Err("workspace unsigned HAP is not a bounded ZIP container".into());
        }
        Ok(SigningAction {
            job_id: job_id.into(),
            project_ref,
            signing_preset_ref: Some(preset_id.into()),
            preset: receipt,
            input_artifact_id: leased.artifact_id.clone(),
            input_file_path: leased.path.clone(),
            input_sha256: leased.sha256.clone(),
            input_byte_count: leased.byte_count,
            output: SigningAttemptPaths::for_job(Path::new(&signing.attempts), job_id),
        })
    }

    /// Swift `WorkspaceOperationsProvider.lower` for a signing action, which
    /// Swift's provider answers before routing by project: the action owned
    /// by `job_id` and by the provider's own profile — the first registered
    /// profile, as Swift composes its provider over it — then every pinned
    /// signing file measured again.
    pub(crate) fn lower_sign(&self, action: &SigningAction, job_id: &str) -> Result<(), String> {
        let owned = self.signing.as_ref().is_some_and(|signing| {
            action.output == SigningAttemptPaths::for_job(Path::new(&signing.attempts), job_id)
        }) && action.job_id == job_id
            && self.primaries.first() == Some(&action.project_ref);
        if !owned {
            return Err("workspace signing action is not owned by this Job/Profile".into());
        }
        remeasure_for_dispatch(&action.preset).map_err(|error| error.to_string())
    }

    /// Swift `OpenHarmonySigningWorkspaceDispatcher.dispatch` for a lowered
    /// signing action: both passwords answered only on the signer's terminal.
    pub(crate) fn sign(&self, action: &SigningAction) -> Result<SignedHap, SigningFailure> {
        let Some(signing) = &self.signing else {
            return Err(SigningFailure::Refused(
                "signing preset unavailable before dispatch: no signing preset store".into(),
            ));
        };
        signer::sign_hap(action, signing.owner.store(), &*signing.secrets, &|| false)
    }

    /// Swift `WorkspaceOperationsProvider.verify` for a signing receipt: the
    /// recorded verification read back, equal to the receipt's summary and
    /// naming exactly the product that landed.
    pub(crate) fn verify_sign(action: &SigningAction, signed: &SignedHap) -> SignVerdict {
        if signed.result_record != action.output.result_record {
            return SignVerdict::Failed(
                "workspace.signingPostflightMissing",
                "signing receipt has no exact verified output".into(),
            );
        }
        match signer::read_verified_result(action) {
            Ok(durable)
                if durable == signed.summary
                    && durable.get("signedHapSha256") == Some(&signed.sha256)
                    && durable.get("signedHapByteCount")
                        == Some(&signed.byte_count.to_string()) =>
            {
                SignVerdict::Verified(durable)
            }
            Ok(_) => SignVerdict::Failed(
                "workspace.signingPostflightDrift",
                "signing result, output and process receipt disagree".into(),
            ),
            Err(error) => {
                SignVerdict::Failed("workspace.signingPostflightInvalid", error.to_string())
            }
        }
    }

    /// Swift `WorkspaceOperationsProvider.reconcile` for a signing action:
    /// nothing written is not executed; a record without its product is
    /// unknown; a product is read back — its record, or `verify-app` once
    /// more — and never signed again.
    pub(crate) fn reconcile_sign(action: &SigningAction) -> SignReconcile {
        let has_output = Path::new(&action.output.signed_hap).exists();
        let has_result = Path::new(&action.output.result_record).exists();
        if !has_output && !has_result {
            return SignReconcile::NotExecuted;
        }
        if !has_output {
            return SignReconcile::Unknown("signing result exists without its exact output".into());
        }
        let summary = if has_result {
            signer::read_verified_result(action)
        } else {
            signer::verify_and_record(action)
        };
        match summary {
            Ok(summary) => SignReconcile::Completed(summary),
            Err(error) => {
                SignReconcile::Unknown(format!("signing output cannot be verified: {error}"))
            }
        }
    }

    /// Swift `cleanupTerminalJob(jobID:)`: a known terminal Job's attempt
    /// directory removed.
    pub(crate) fn cleanup_sign(&self, job_id: &str) {
        if let Some(signing) = &self.signing {
            let paths = SigningAttemptPaths::for_job(Path::new(&signing.attempts), job_id);
            let _ = std::fs::remove_dir_all(&paths.directory);
        }
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

/// Swift `PersistedTypedProviderAction` of a signing action: the workspace
/// action `{"signOpenHarmonyHap": {"_0": action}}` as canonical JSON, base64.
pub(crate) fn persisted_sign_action(
    action: &arkdeck_provider_workspace::signing_action::SigningAction,
) -> Result<Value, ()> {
    let value = serde_json::json!({"signOpenHarmonyHap": {"_0": serde_json::to_value(action).map_err(|_| ())?}});
    let bytes = crate::session_json::encode(&value).map_err(|_| ())?;
    Ok(serde_json::json!({"kind": "workspace.action",
        "arguments": {"payload": crate::agent_execution::base64(&bytes)}}))
}

/// Swift `PersistedTypedProviderAction.materialize()` for a signing action.
pub(crate) fn materialize_sign_action(
    persisted: &Value,
) -> Result<arkdeck_provider_workspace::signing_action::SigningAction, String> {
    let kind = persisted["kind"].as_str().unwrap_or_default();
    if kind != "workspace.action" {
        return Err(format!(
            "persisted typed provider action kind {kind} is unknown"
        ));
    }
    persisted["arguments"]["payload"]
        .as_str()
        .and_then(crate::agent_execution::unbase64)
        .and_then(|bytes| serde_json::from_slice::<Value>(&bytes).ok())
        .and_then(|payload| {
            serde_json::from_value(payload.get("signOpenHarmonyHap")?.get("_0")?.clone()).ok()
        })
        .ok_or_else(|| "persisted workspace.action is not a signing action".to_owned())
}
