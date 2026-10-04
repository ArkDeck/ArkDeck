//! The Windows daemon's lifecycle (TASK-XPA-002 S5): which state root it
//! owns, how it becomes the one daemon of that root, what asks it to stop,
//! and what it lets go of once it has drained. The platform decision is in
//! `rust/README.md` (the Windows paragraph) and the S5 run record.
//!
//! Three compositions, decided from the environment before anything is
//! opened:
//!
//! * the account's daemon (no input): `%LOCALAPPDATA%\ArkDeck\Agentd`, its
//!   `instance.lock`, the guard `Local\ArkDeck.Agentd.<user SID>` and the
//!   logon-scoped pipe `\\.\pipe\arkdeck-agentd-<logon SID>`. This is the
//!   daemon decision 11's client starts (`arkdeck_client::start`). As the
//!   macOS production daemon, it composes an HDC only when `ARKDECK_HDC_PATH`
//!   is set, and then the account's Bootstrap registry's selection (the
//!   configured file adopted as its first while there is none), admitted only
//!   by a registered Windows HDC tuple and started as its managed server
//!   ([`AccountHdc`]);
//! * an isolated development root (`ARKDECK_DEVELOPMENT_STATE_ROOT`, an
//!   existing directory outside `%LOCALAPPDATA%\ArkDeck`): its `.owner.lock`,
//!   a guard and a pipe named after the root's file identity. Beside the
//!   lifecycle only the Job store and its capability store, the Target
//!   owners, the Artifact read and export owner, the Session owner, the
//!   History filter owner, the workspace project owner, the Job planner and
//!   admitter and the Trace cache owner are composed over it (see
//!   [`Authority::compose`]); every input that would compose another
//!   owner on macOS is refused, not ignored, until its store is ported (G01),
//!   and a development HDC is admitted only by a registered Windows HDC
//!   tuple (`windows_hdc_gate`, CHG-2026-078: DevEco's `hdc.exe` only),
//!   and then composed only as the root's managed server (`managed_hdc`);
//! * a private endpoint (`ARKDECK_ENDPOINT` alone): the read-only foundation
//!   over a pipe the caller names, owning no state root, as the Unix
//!   standalone daemon does (the black-box read-only check runs it).
//!
//! A daemon that owns a root takes, in this order and before anything else
//! is created or probed: the single-instance guard, the owner lock, its
//! named stop event and the pipe (`FILE_FLAG_FIRST_PIPE_INSTANCE`). Then it
//! reads the instance document its predecessor left — the state a restart
//! reads back — and replaces it with its own. A guard or owner lock another
//! daemon holds is answered as Swift's second instance answers: `already
//! running` from that daemon's instance document, exit 0, having composed
//! nothing. A guard its holder died with (`WAIT_ABANDONED`) is taken, named,
//! and the start goes on as the start after a crash that every start already
//! is: nothing is replayed.
//!
//! It stops for its named stop event ([`arkdeck_platform::InstanceScope::request_stop`],
//! SIGTERM's counterpart) or a console Ctrl+C / Ctrl+Break (SIGINT's), and
//! drains as the Unix daemon does (`serve_control`). After a complete drain
//! it releases the owner lock, then the guard, on the thread that took it;
//! after one its deadline cut short it exits holding them, so its successor
//! finds the guard abandoned and starts as after a crash.
use arkdeck_platform::{
    GuardAcquisition, LocalEndpoint, LocalListener, OwnerLock, SingleInstanceGuard, StateRoot,
    StopSignal,
};
use std::ffi::{OsStr, OsString};
use std::io::Write;
use std::path::Path;
use std::time::Duration;

/// The account's default Sessions root and Trace cache, in its product
/// directory `%LOCALAPPDATA%\ArkDeck` beside the state directory `Agentd`:
/// the names macOS gives `ArkDeck/Sessions` and the App's `ArkDeck/Trace`.
const ACCOUNT_SESSIONS: &str = "Sessions";
const ACCOUNT_TRACE: &str = "Trace";
/// The account's Bootstrap registry, `%LOCALAPPDATA%\ArkDeck\Bootstrap\v1`:
/// the macOS `ArkDeck/Bootstrap/v1` below the product directory.
const ACCOUNT_BOOTSTRAP: &str = "Bootstrap";
const BOOTSTRAP_VERSION: &str = "v1";

/// The account's product directory as this root spells it (its parent), for
/// messages.
fn product(root: &StateRoot) -> std::path::PathBuf {
    root.path()
        .parent()
        .map(Path::to_path_buf)
        .unwrap_or_default()
}

/// Swift `AgentDaemonServer`'s instance document, the name and shape the
/// macOS composition writes (`production.rs`).
const INSTANCE_DOCUMENT: &str = "instance.json";
/// The tool-selection owner's directory, the name macOS production gives it.
const TOOL_SELECTION_ACTIONS: &str = "tool-selection-control-actions";
const DOCUMENT_LIMIT: u64 = 64 * 1024;

/// Inputs from which the isolated macOS owner composes an owner that this
/// composition does not compose yet: each one set refuses the start. The
/// development HDC is decided by the tuple gate instead (`windows_hdc_gate`).
const NOT_COMPOSED: [&str; 6] = [
    "ARKDECK_DEVELOPMENT_USB_RELATIONS",
    "ARKDECK_DEVELOPMENT_USB_RELATIONS_WITH_REGISTERED_HDC",
    "ARKDECK_DEVELOPMENT_CODE_SIGN_HELPER",
    "ARKDECK_DEVELOPMENT_MUTATION_AUTHORITY",
    "ARKDECK_APP_INGRESS",
    "ARKDECK_ARKTRACE_DESCRIPTOR",
];

/// Swift `AgentDaemonInstance`: who holds the instance lock. The same
/// document as `production::Instance`, byte for byte.
#[derive(Clone, Debug, PartialEq, Eq, serde::Deserialize, serde::Serialize)]
pub(crate) struct Instance {
    pub(crate) pid: i32,
    #[serde(rename = "protocolVersion")]
    pub(crate) protocol_version: String,
    #[serde(rename = "socketPath")]
    pub(crate) socket_path: String,
    #[serde(rename = "startedAtUTC")]
    pub(crate) started_at_utc: String,
}

impl Instance {
    /// Swift's second instance's line (`main.swift` 1590-1592).
    pub(crate) fn running(&self) -> String {
        format!(
            "arkdeck-agentd already running: pid {}, socket {}, protocol {}",
            self.pid, self.socket_path, self.protocol_version
        )
    }
}

/// The account daemon's HDC inputs, read before its root is opened, from
/// which [`Authority::compose`] composes the Bootstrap registry's selection
/// as macOS production composes it (`production::registered_hdc`).
#[derive(Debug, PartialEq, Eq)]
pub(crate) struct AccountHdc {
    /// `ARKDECK_HDC_PATH`: an explicit absolute path, adopted as the
    /// registry's first selection while it holds none (Swift's
    /// `adoptInstalledHDC`); once a selection exists it is never the
    /// executable started.
    pub(crate) configured: std::path::PathBuf,
    /// The inherited `OHOS_HDC_SERVER_PORT`, which must select the
    /// registered tuple's endpoint.
    pub(crate) server_port: Option<OsString>,
}

impl AccountHdc {
    /// The account's HDC inputs, or the refusal: none without
    /// `ARKDECK_HDC_PATH`, as the macOS production daemon composes none;
    /// `ARKDECK_HDC_SHA256` is refused, as there (the registry pins the
    /// identity).
    pub(crate) fn from(
        variable: &dyn Fn(&str) -> Option<OsString>,
    ) -> Result<Option<Self>, String> {
        if variable("ARKDECK_HDC_SHA256").is_some() {
            return Err(
                "ARKDECK_HDC_SHA256 is not read: the account's Bootstrap registry pins the HDC \
                 identity; nothing was started"
                    .into(),
            );
        }
        let Some(configured) = variable("ARKDECK_HDC_PATH") else {
            return Ok(None);
        };
        let configured = std::path::PathBuf::from(configured);
        if !configured.is_absolute() {
            return Err("ARKDECK_HDC_PATH must be an explicit absolute path".into());
        }
        Ok(Some(Self {
            configured,
            server_port: variable(arkdeck_provider_hdc::SERVER_PORT_VARIABLE),
        }))
    }
}

/// The published identity a Windows HDC digest has against `tuples`: the
/// registered tuple's reported version, naming no profile, as
/// `bootstrap_readers::windows_hdc_identity` answers it for the registry.
fn tuple_identities(
    tuples: &'static [arkdeck_provider_hdc::WindowsHdcTuple],
) -> arkdeck_hoststore::PublishedIdentities {
    std::sync::Arc::new(move |sha256: &str| {
        arkdeck_provider_hdc::tuple_in(tuples, sha256).map(
            |tuple| serde_json::json!({"version": tuple.reported_version, "profileReferences": []}),
        )
    })
}

/// The account's Bootstrap selection, admitted: the selected registered
/// tool, the tuple its digest names and the endpoint its managed server
/// starts on.
struct SelectedHdc {
    selection: arkdeck_hoststore::StartupSelection,
    tuple: &'static arkdeck_provider_hdc::WindowsHdcTuple,
    endpoint: arkdeck_provider_hdc::EndpointSelection,
}

/// What a daemon owning a state root holds while it serves.
pub(crate) struct Authority {
    pub(crate) endpoint: LocalEndpoint,
    /// An isolated development root, whose owners keep the macOS isolated
    /// owner's directory names; otherwise the account's root, whose owners
    /// keep Swift's production layout.
    development: bool,
    /// The registered Windows HDC the tuple gate admitted for a development
    /// root, which [`Self::compose`] starts as its managed server. None
    /// while no Windows HDC tuple is registered.
    hdc: Option<Box<crate::windows_hdc_gate::AdmittedHdc>>,
    /// The account daemon's HDC inputs (never a development root's).
    account_hdc: Option<Box<AccountHdc>>,
    /// The registered Windows HDC tuples a selection is admitted by
    /// (`WINDOWS_HDC_TUPLES`; a test names its own).
    tuples: &'static [arkdeck_provider_hdc::WindowsHdcTuple],
    // Dropped in this order: the owner lock, then the guard, then the root's
    // pinned directories.
    owner: OwnerLock,
    guard: SingleInstanceGuard,
    root: StateRoot,
}

impl Authority {
    /// The owners a Windows daemon composes over its root, as the macOS
    /// isolated owner (`targets-state`) or production composition
    /// (`targets`) composes them, in a private child of the root created
    /// owner-only when absent (`StateRoot::private_child`):
    ///
    /// * the Job store (`jobs-state`, [`Self::job_store`]) and the capability
    ///   store beside it ([`Self::capability_store`]);
    /// * the Target store: `targets.json` and the display names under
    ///   `.targets.lock` and `.target-display-names.lock`, the same bytes
    ///   as on macOS; `target.list`, `target.show`, `target.availability`
    ///   and `target.display-name.*` answer from it, and a restart reads
    ///   back what it holds;
    /// * the Target observation owner over it, with the USB relations the
    ///   macOS rule names (`development_usb::relation_source`): the
    ///   Runtime's own census (`UsbRegistryRelations::system()`, the Windows
    ///   SetupAPI census) only beside a registered HDC this composition
    ///   started as its managed server. No Windows HDC tuple is registered
    ///   yet (its integration change waits for the maintainer's samples),
    ///   so no relation is read, nothing is observed or dispatched, and
    ///   `target.adopt` is refused before admission with zero dispatch;
    /// * the Artifact read and export owner (`ArtifactReadStore`) over the
    ///   root's `artifacts` (the name the macOS isolated owner and production
    ///   composition both give it): the same Job index documents, payloads
    ///   and `artifact.list` snapshot pages as on macOS. Every Artifact
    ///   belongs to a Job, which the Job store above proves before anything
    ///   is read, listed or exported;
    /// * the agent execution owner (`AgentExecutionStore`) in
    ///   `agent-executions` and the combined human-action owner
    ///   (`HumanActionResources`) in `human-action-snapshots`, the names both
    ///   macOS compositions give them: the same execution records and pages
    ///   as on macOS. `agent.*` and `human-action.*` answer from them; an
    ///   execution admits its Job as `job.submit` does here, observes no
    ///   Target (no Windows HDC tuple is registered), and no control action
    ///   is built, so the human-action owner pages the executions' actions
    ///   alone;
    /// * the Session owner and the Artifact usage owner
    ///   ([`Self::session_store`]): `runtime.storage.*`, `session.list|show|
    ///   pin|unpin`, `session.cleanup.*` and `session.export.*`;
    /// * the History filter owner (`HistoryStore`, [`Self::history_store`]):
    ///   `history.filter.list|save|delete` over `history-filter.json` under
    ///   `.history-filter.lock`, the same document as on macOS, in the root's
    ///   private `history-filter`;
    /// * the workspace project owner (`WorkspaceProjectStore`) in
    ///   `workspace-projects`, the name both macOS compositions give it:
    ///   `projects.json` under `.projects.lock`, the same document as on
    ///   macOS, a Windows root pinned by its volume serial and NTFS file
    ///   reference. `workspace.project.register|list|show` and
    ///   `workspace.preset.list|show` answer from it, and a restart reads
    ///   back what it holds. The installed daemon (not the development
    ///   root) pins a preset's signing credential in the account's preset
    ///   root `<LocalAppData>\ArkDeck\Signing\OpenHarmony`, the secrets read
    ///   from Credential Manager bound to this daemon's own image
    ///   (TASK-XPA-011), as the macOS installed daemon does; a preset's
    ///   DevEco toolchain is pinned in this composition's Bootstrap registry,
    ///   as both macOS compositions pin it;
    /// * the workspace provider (`WorkspaceComposition`, TASK-XPA-011) over
    ///   the registered projects, composed at the start as macOS composes it:
    ///   the Runtime-owned copies under the root's `evolution-workspaces`, the
    ///   source inspection by the inspector the host configured
    ///   (`ARKDECK_WORKSPACE_INSPECTOR`, pinned now; one that is no
    ///   executable ends the start), the symbolizer `ARKDECK_ANALYZER_PATH`
    ///   names, and, for the installed daemon only, signing over the
    ///   account's preset store with its attempts in the root's
    ///   `workspace-signing-attempts`. A registered project resolves to no
    ///   profile on Windows (no code-owned source tool is trusted there
    ///   yet), so every profile-served operation is unavailable with that
    ///   reason and only the source inspection runs;
    /// * the Job planner and admitter over the Job store and the root
    ///   (`job.plan`, `job.submit`), with no HDC provider (no Windows HDC
    ///   tuple is registered): a device operation is refused before admission
    ///   with zero dispatch, as macOS refuses it without an HDC provider;
    /// * the Trace cache owner (`TraceCacheStore`) over a `traces` directory
    ///   beside its `staging` ([`Self::trace_cache`]): a development root's
    ///   `trace-cache`, the layout the macOS isolated owner creates, or the
    ///   account's `%LOCALAPPDATA%\ArkDeck\Trace`, where the macOS App keeps
    ///   `ArkDeck/Trace` in its container caches. `trace.cache.status` reads
    ///   the same inventory as on macOS, and `trace.cache.purge` purges as on
    ///   macOS, under the Job owner's active-Session census and the Artifact
    ///   owner's Trace retention census.
    ///
    /// Once every store is open, the registered HDC the tuple gate admitted
    /// is started as the root's managed server, the first thing this
    /// composition launches, as the macOS isolated owner starts its own
    /// (`managed_hdc::ManagedHdc`): its process dispatch registers the HDC
    /// provider, its status answers `runtime.hdc.status`, the Runtime's own
    /// USB census is read beside it, and the daemon stops it after its drain
    /// (the returned [`crate::managed_hdc::Launched`]; a start that fails
    /// after the launch stops it on the way out). No Windows HDC tuple is
    /// registered yet, so the gate admits none, nothing is launched, and
    /// `runtime.hdc.status` answers that no HDC is configured.
    ///
    /// An existing owner directory is never re-permissioned; one that is not
    /// owner-only is refused when its owner opens it. Composing opens each
    /// store, which reads its documents under its locks; a store it cannot
    /// open or read ends the start, as on macOS.
    pub(crate) fn compose(
        &self,
        host: crate::host::Host,
    ) -> Result<
        (
            crate::host::Host,
            crate::arkforge_lane::Composed,
            Option<crate::managed_hdc::Launched>,
        ),
        String,
    > {
        use crate::development_usb::{RelationSource, relation_source};
        let host = host
            .with_jobs(self.job_store()?)
            .with_capabilities(self.capability_store()?);
        let host = match self.mutation_root() {
            Some(root) => host.with_mutation_root(root),
            None => host,
        };
        let name = if self.development {
            "targets-state"
        } else {
            "targets"
        };
        let path = self.root.private_child(name).map_err(|error| {
            format!(
                "the Target store {} is unusable: {error}; nothing was started",
                self.root.path().join(name).display()
            )
        })?;
        let targets = arkdeck_hoststore::TargetStore::open(&path).map_err(|error| {
            format!(
                "the Target store {} is unusable: {error}; nothing was started",
                path.display()
            )
        })?;
        let host = host.with_targets(targets);
        let name = "artifacts";
        let path = self.root.private_child(name).map_err(|error| {
            format!(
                "the Artifact store {} is unusable: {error}; nothing was started",
                self.root.path().join(name).display()
            )
        })?;
        let artifacts = arkdeck_hoststore::ArtifactReadStore::open(&path).map_err(|error| {
            format!(
                "the Artifact store {} is unusable: {error}; nothing was started",
                path.display()
            )
        })?;
        // The Import owner over the same Artifact root, in its private
        // `.imports-v1`, as both macOS compositions give it: `artifact.import.*`,
        // an Import's Artifacts and a Job's Import inputs.
        let imports = arkdeck_hoststore::ImportUploadStore::open(&path).map_err(|error| {
            format!(
                "the Import store {} is unusable: {error}; nothing was started",
                path.join(".imports-v1").display()
            )
        })?;
        let host = host.with_artifacts(artifacts).with_imports(imports);
        let host = host.with_storage(self.session_store()?, {
            // The Artifact read owner's directory, as it opened it.
            let path = self.root.private_child("artifacts").map_err(|error| {
                format!(
                    "the Artifact usage owner {} is unusable: {error}; nothing was started",
                    self.root.path().join("artifacts").display()
                )
            })?;
            arkdeck_hoststore::ArtifactUsage::open(&path, crate::host::ARTIFACT_QUOTA).map_err(
                |error| {
                    format!(
                        "the Artifact usage owner {} is unusable: {error}; nothing was started",
                        path.display()
                    )
                },
            )?
        });
        let host = host.with_history(self.history_store()?);
        // Beside the Job state, as the macOS daemons keep their agent
        // executions, and the combined human-action owner in its own
        // directory beside them (over no control-action owner: none is built
        // on Windows yet).
        let name = "agent-executions";
        let unusable = |path: &Path, error: std::io::Error| {
            format!(
                "the agent execution store {} is unusable: {error}; nothing was started",
                path.display()
            )
        };
        let path = self
            .root
            .private_child(name)
            .map_err(|error| unusable(&self.root.path().join(name), error))?;
        let agents = arkdeck_hoststore::AgentExecutionStore::open(&path)
            .map_err(|error| unusable(&path, error))?;
        let name = "human-action-snapshots";
        let unusable = |path: &Path, error: std::io::Error| {
            format!(
                "the human-action store {} is unusable: {error}; nothing was started",
                path.display()
            )
        };
        let path = self
            .root
            .private_child(name)
            .map_err(|error| unusable(&self.root.path().join(name), error))?;
        let humans = arkdeck_hoststore::HumanActionResources::open(&path)
            .map_err(|error| unusable(&path, error))?;
        let host = host
            .with_agent_executions(agents)
            .with_human_actions(humans);
        // The Bootstrap registry the account's HDC selection is read from,
        // and the selection, admitted and any pending pre-launch boundary
        // settled, before anything is launched.
        let bootstrap = self.bootstrap_root()?;
        let selected = match &self.account_hdc {
            Some(account) if !self.development => Some(self.selected_hdc(account, &bootstrap)?),
            _ => None,
        };
        let controls = self.control_actions(selected.is_some(), &bootstrap)?;
        let name = "workspace-projects";
        let unusable = |path: &Path, error: &dyn std::fmt::Display| {
            format!(
                "the workspace project store {} is unusable: {error}; nothing was started",
                path.display()
            )
        };
        let path = self
            .root
            .private_child(name)
            .map_err(|error| unusable(&self.root.path().join(name), &error))?;
        let projects = arkdeck_hoststore::WorkspaceProjectStore::open(&path)
            .map_err(|error| unusable(&path, &error))?;
        // A preset's DevEco toolchain is pinned in this daemon's own
        // Bootstrap registry, as both macOS compositions pin it in theirs.
        // A development root composes no signing credential owner, as the
        // macOS isolated owner composes none: a preset that pins a credential
        // is refused there.
        let toolchains = crate::host::toolchain_pinning(&bootstrap).map_err(|error| {
            format!(
                "the Bootstrap registry {} is unusable: {error}; nothing was started",
                bootstrap.display()
            )
        })?;
        let projects = if self.development {
            projects.with_dependency_pinning(Some(toolchains), None)
        } else {
            projects.with_dependency_pinning(Some(toolchains), Some(credential_pinning()?))
        };
        // Read now, as the macOS start reads it to compose the registered
        // projects: a document it cannot read ends the start.
        projects
            .startup_records()
            .map_err(|error| unusable(&path, &error.message))?;
        // The analyzers `ARKDECK_ANALYZER_PATH` names (TASK-XPA-011): the
        // crash-ledger analyzer, and the HiLog summary when it is this
        // daemon's own executable; a named path that is no executable ends
        // the start, as on macOS.
        let analyzers = crate::hilog_summary_analyzer::composed(
            std::env::var_os("ARKDECK_ANALYZER_PATH")
                .as_deref()
                .map(Path::new),
        )
        .map_err(|error| {
            format!("ARKDECK_ANALYZER_PATH is unusable: {error}; nothing was started")
        })?;
        let analyzer_path = std::env::var_os("ARKDECK_ANALYZER_PATH");
        let host = host
            .with_workspace_projects(projects)
            .with_workspace_operations(
                self.root.path(),
                &bootstrap,
                self.signing_setup()?,
                std::env::var_os("ARKDECK_WORKSPACE_INSPECTOR").as_deref(),
                analyzer_path.as_deref(),
            )
            .map_err(|error| {
                format!("the workspace provider is unusable: {error}; nothing was started")
            })?
            .with_planning(self.root.path(), Some(analyzers));
        // Swift's Flash invocation owner keeps its documents in the state
        // directory its engine plans in, and creates their directories at its
        // start, as both macOS compositions compose it: the recovery broker
        // writes an attempt's permit there and the planner reads it from
        // there (TASK-XPA-010).
        // The state directory is named as the file system resolves the
        // opened handle (`StateRoot::private_child`), the canonical plain
        // spelling the owner's private-directory check opens and compares,
        // which a short (`AD-FAK~1`) or verbatim spelling of the root is not.
        let unusable = |error: &dyn std::fmt::Display| {
            format!(
                "the Flash invocation owner {} is unusable: {error}; nothing was started",
                self.root.path().display()
            )
        };
        let documents = self
            .root
            .private_child("runtime-debug-invocations")
            .map_err(|error| unusable(&error))?;
        let state = documents
            .parent()
            .ok_or_else(|| unusable(&"the invocation documents have no state directory"))?;
        let invocations =
            arkdeck_hoststore::FlashInvocations::open(state).map_err(|error| unusable(&error))?;
        let host = host.with_flash_invocations(invocations);
        let host = host.with_trace_cache(self.trace_cache()?);
        let host = host.with_bootstrap(&bootstrap).map_err(|error| {
            format!(
                "the Bootstrap registry {} is unusable: {error}; nothing was started",
                bootstrap.display()
            )
        })?;
        // The managed server, the first thing this composition launches: a
        // development root's admitted HDC, or the account's selected one,
        // started and its pending selection settled as Swift's startup
        // transaction settles it (`tool_selection_startup`).
        let (launched, sha256) = match (&self.hdc, &selected) {
            (Some(hdc), _) => {
                let (dispatch, launched) = launch_managed(hdc)?;
                (Some((dispatch, launched)), Some(hdc.sha256.clone()))
            }
            (None, Some(selected)) => {
                let (dispatch, launched, sha256) = self.launch_selected(selected, &bootstrap)?;
                (Some((dispatch, launched)), Some(sha256))
            }
            (None, None) => (None, None),
        };
        let (host, managed) = match launched {
            Some((dispatch, launched)) => {
                let server = std::sync::Arc::clone(launched.server());
                server.monitor_foreground_exit().map_err(|error| {
                    format!("the managed HDC server cannot be watched: {error}")
                })?;
                (
                    host.with_managed_development_hdc(dispatch, server),
                    Some(launched),
                )
            }
            None => (host, None),
        };
        let host = host.with_control_actions(controls);
        // A registered HDC is composed only as this root's managed server.
        let (registered, managed_server) = (managed.is_some(), managed.is_some());
        let host = match relation_source(registered, managed_server, false) {
            RelationSource::Registry => host
                .with_usb_registry_relations(arkdeck_provider_hdc::UsbRegistryRelations::system()),
            RelationSource::File | RelationSource::Nothing => host,
        };
        match (&self.hdc, &selected) {
            (Some(hdc), _) if managed.is_some() => report(&format!(
                "arkdeck-agentd composes the registered Windows HDC {} (SHA-256 {}) as its \
                 managed server on {}",
                hdc.tuple.candidate, hdc.sha256, hdc.selection.endpoint
            )),
            (None, Some(selected)) if managed.is_some() => report(&format!(
                "arkdeck-agentd composes the selected registered Windows HDC {} ({}, SHA-256 {}) \
                 as its managed server on {}",
                selected.tuple.candidate,
                selected.selection.tool_ref,
                sha256.as_deref().unwrap_or_default(),
                selected.endpoint.endpoint
            )),
            _ if self.development => report(
                "arkdeck-agentd composes no HDC: no Windows HDC tuple is registered; device \
                 observation and target adoption are refused before any dispatch",
            ),
            _ => report(
                "arkdeck-agentd composes no HDC: no executable is configured (set \
                 ARKDECK_HDC_PATH); device observation and target adoption are refused before \
                 any dispatch",
            ),
        }
        let hdc_sha256 = managed.is_some().then_some(sha256.as_deref()).flatten();
        let (host, composed) = self.compose_arkforge(host, hdc_sha256);
        report(&format!(
            "arkdeck-agentd owners: {}",
            host.owner_census().join(", ")
        ));
        Ok((host, composed, managed))
    }

    /// The ArkForge lane (TASK-XPA-010), as the macOS compositions compose
    /// it beside the Job state: the account's root (the macOS production
    /// `Agentd`) or a development root's `jobs-state`, with the lane's
    /// runtime directory `arkforge` in it and the facts' root its
    /// Application Support (the account root's parent, or the development
    /// root itself).
    ///
    /// One validated `ARKDECK_ARKFORGE_BUNDLE_PATH` bundle names the
    /// `arkforged.exe` to start and pair, but its authority must name the
    /// managed-control HDC's digest (`hdc_sha256`, the managed server's), and
    /// no HDC is composed without the registered Windows HDC tuple: the lane
    /// is refused before anything is launched, and the start reports why. Its planning, its facts (over the
    /// Windows USB census, open since the DAYU200 sample confirmed its
    /// mapping) and the device access observer of the lane's
    /// directory are composed either way, as on macOS; no executable lane is
    /// installed without an HDC, so an admissible Flash is refused before
    /// admission with zero dispatch.
    fn compose_arkforge(
        &self,
        host: crate::host::Host,
        hdc_sha256: Option<&str>,
    ) -> (crate::host::Host, crate::arkforge_lane::Composed) {
        let root = self.root.path();
        let (state, application_support) = if self.development {
            (root.join("jobs-state"), root.to_path_buf())
        } else {
            (
                root.to_path_buf(),
                root.parent().unwrap_or(root).to_path_buf(),
            )
        };
        let composed =
            crate::arkforge_lane::compose(&state, |key| std::env::var(key).ok(), hdc_sha256);
        composed.report();
        let host = host
            .with_flash_planning(composed.planning(&state, hdc_sha256.is_some()))
            .with_flash_host_facts(
                arkdeck_hoststore::FlashHostFacts::new(
                    &application_support,
                    arkdeck_platform::usb_host_devices,
                )
                .with_rockusb(composed.rockusb())
                .with_arkforge_loader(&composed.runtime_directory),
            )
            .with_device_access(arkdeck_provider_arkforge::DeviceAccessObserver::new(
                &composed.runtime_directory,
            ))
            .with_lane_plan_preview(composed.lane_plan_preview())
            // Swift's post-flash alias reconciler over the same Application
            // Support root, reading the board from the same Windows USB census
            // as the facts, as the macOS compositions compose it.
            .with_flash_alias_reconciler(arkdeck_hoststore::FlashAliasReconciler::new(
                &application_support,
                arkdeck_platform::usb_host_devices,
                crate::host::utc_now,
            ))
            // The Loader binding coordinator, as the macOS compositions
            // compose it: the same root and census, ArkForge's half of the
            // Loader observation through the lane's directory, and the
            // Runtime's records below the root.
            .with_loader_binding(arkdeck_hoststore::LoaderBinding::new(
                &application_support,
                arkdeck_platform::usb_host_devices,
                arkdeck_hoststore::ArkForgeLoader::new(
                    arkdeck_platform::usb_host_devices,
                    &composed.runtime_directory,
                ),
            ));
        // The executable lane, installed only with a lane and a
        // descriptor-bound HDC: on Windows only when the registered tuple's
        // managed HDC is composed; otherwise nothing is installed.
        let host = crate::arkforge_execution::install(
            host,
            &composed,
            &state,
            &application_support,
            arkdeck_platform::usb_host_devices,
        );
        (host, composed)
    }

    /// Swift's union control-action owner (`ControlActionResources`) in
    /// `control-action-snapshots`, the name both macOS compositions give it:
    /// `control-action.list`, `.show` and `.reconcile` page and look up its
    /// actions, and `runtime.hdc.impact-preview` and `runtime.hdc.restart`
    /// are answered through it. It is over the HDC control-action owner
    /// (`HdcControlActions`, in `hdc-control-actions`) only beside the
    /// managed server a registered HDC tuple admits, as the macOS isolated
    /// owner composes it only beside its own, and over the tool-selection
    /// owner (`ToolSelectionActions`, in `tool-selection-control-actions`,
    /// over the Bootstrap registry `bootstrap`) only beside the account's
    /// selected one (`selected`), as macOS production composes it; every
    /// directory is created before that server is launched. Without a managed
    /// server the union owner pages no action, and an impact preview, a
    /// restart or a tool selection is refused as Swift's daemon refuses it
    /// with no HDC host.
    fn control_actions(
        &self,
        selected: bool,
        bootstrap: &Path,
    ) -> Result<arkdeck_hoststore::ControlActionResources, String> {
        let unusable = |path: &Path, error: &dyn std::fmt::Display| {
            format!(
                "the control-action store {} is unusable: {error}; nothing was started",
                path.display()
            )
        };
        let child = |name: &str| {
            self.root
                .private_child(name)
                .map_err(|error| unusable(&self.root.path().join(name), &error))
        };
        let path = child("control-action-snapshots")?;
        let resources = arkdeck_hoststore::ControlActionResources::open(&path)
            .map_err(|error| unusable(&path, &error))?;
        if self.hdc.is_none() && !selected {
            return Ok(resources);
        }
        let path = child("hdc-control-actions")?;
        let context = arkdeck_hoststore::OwnerContext::production()
            .map_err(|error| unusable(&path, &error.message))?;
        let actions = arkdeck_hoststore::HdcControlActions::open(&path, context)
            .map_err(|error| unusable(&path, &error))?;
        let resources = resources.with_hdc(actions);
        if !selected {
            return Ok(resources);
        }
        let path = child(TOOL_SELECTION_ACTIONS)?;
        let context = arkdeck_hoststore::OwnerContext::production()
            .map_err(|error| unusable(&path, &error.message))?;
        let actions = arkdeck_hoststore::ToolSelectionActions::open(
            &path,
            context,
            Box::new(self.tool_registry(bootstrap)?),
        )
        .map_err(|error| unusable(&path, &error))?;
        Ok(resources.with_tools(actions))
    }

    /// The account's Bootstrap tool registry, identifying an HDC only by a
    /// registered Windows tuple ([`Self::tuples`]).
    fn tool_registry(
        &self,
        bootstrap: &Path,
    ) -> Result<arkdeck_hoststore::ToolRegistryStore, String> {
        arkdeck_hoststore::ToolRegistryStore::open_existing(bootstrap)
            .map(|store| store.with_published_identities(tuple_identities(self.tuples)))
            .map_err(|error| {
                format!(
                    "the Bootstrap registry {} is unusable: {error}; nothing was started",
                    bootstrap.display()
                )
            })
    }

    /// Swift's production HDC (`production::registered_hdc`) on Windows:
    /// while the account's Bootstrap registry holds no selection, the
    /// configured file is adopted as its first (registered only when a
    /// registered Windows tuple names its digest); the registry's startup
    /// selection is the executable the managed server runs. It is admitted
    /// again by the tuple table, and its endpoint must be the tuple's. A
    /// pending selection that never entered its launch window is settled
    /// failed, and the prior active tool is started instead
    /// (`tool_selection_startup::recover_prelaunch`). Nothing is launched
    /// here.
    fn selected_hdc(&self, account: &AccountHdc, bootstrap: &Path) -> Result<SelectedHdc, String> {
        let registry = self.tool_registry(bootstrap)?;
        let selection = crate::tool_selection_startup::registered_hdc(
            &registry,
            &account.configured,
            &crate::host::utc_now(),
        )?;
        let selection = if selection.pending_action_id.is_some() {
            let records = self.tool_selection_records()?;
            let now = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .ok()
                .and_then(|elapsed| u64::try_from(elapsed.as_millis()).ok())
                .ok_or("tool-selection startup time is unavailable")?;
            crate::tool_selection_startup::recover_prelaunch(&registry, &records, selection, now)?
        } else {
            selection
        };
        let tuple = arkdeck_provider_hdc::tuple_in(self.tuples, &selection.executable_sha256)
            .ok_or_else(|| {
                format!(
                    "the selected HDC {} (SHA-256 {}) is not a registered Windows HDC: \
                     OPENHARMONY-HDC-WINDOWS-PROBES (CHG-2026-078) registers no tuple with that \
                     digest; nothing was started",
                    selection.tool_ref, selection.executable_sha256
                )
            })?;
        let endpoint = crate::windows_hdc_gate::tuple_endpoint(tuple, account.server_port.clone())?;
        Ok(SelectedHdc {
            selection,
            tuple,
            endpoint,
        })
    }

    /// The tool-selection owner's durable records, `records` in its private
    /// `tool-selection-control-actions`, created owner-only when absent.
    fn tool_selection_records(&self) -> Result<arkdeck_hoststore::ToolSelectionRecords, String> {
        let unusable = |path: &Path, error: std::io::Error| {
            format!(
                "the tool-selection store {} is unusable: {error}; nothing was started",
                path.display()
            )
        };
        let path = self
            .root
            .private_child(TOOL_SELECTION_ACTIONS)
            .map_err(|error| unusable(&self.root.path().join(TOOL_SELECTION_ACTIONS), error))?;
        let records = path.join("records");
        arkdeck_platform::HostDirectory::open(&path)
            .and_then(|directory| directory.private_child("records"))
            .and_then(|_| arkdeck_hoststore::ToolSelectionRecords::open(&records))
            .map_err(|error| unusable(&records, error))
    }

    /// The account's selected HDC started as its managed server through
    /// Swift's startup transaction (`tool_selection_startup::start_and_settle`):
    /// a pending selection is published once its server is ready, or failed
    /// and the prior active tool started instead; every tool it starts is a
    /// registered tuple's on that tuple's endpoint. Answers the process
    /// dispatch every HDC plan takes to it, the launch, and the digest of the
    /// tool that runs.
    fn launch_selected(
        &self,
        selected: &SelectedHdc,
        bootstrap: &Path,
    ) -> Result<
        (
            arkdeck_provider_hdc::ProcessDispatch,
            crate::managed_hdc::Launched,
            String,
        ),
        String,
    > {
        let registry = self.tool_registry(bootstrap)?;
        let tuples = self.tuples;
        let endpoint = selected.endpoint;
        let (launched, selection) = crate::tool_selection_startup::start_and_settle(
            &registry,
            selected.selection.clone(),
            |selection| {
                if arkdeck_provider_hdc::tuple_in(tuples, &selection.executable_sha256).is_none() {
                    return Err(format!(
                        "the selected HDC {} is not a registered Windows HDC; nothing was started",
                        selection.tool_ref
                    ));
                }
                let tool = arkdeck_platform::VerifiedTool::open(
                    &selection.executable,
                    &selection.executable_sha256,
                )
                .map_err(|error| error.to_string())?;
                crate::managed_hdc::ManagedHdc::start(
                    &tool,
                    &selection.executable.to_string_lossy(),
                    endpoint,
                )
                .map(crate::managed_hdc::Launched::new)
            },
        )?;
        let dispatch = arkdeck_platform::VerifiedTool::open(
            &selection.executable,
            &selection.executable_sha256,
        )
        .map_err(|error| {
            format!(
                "the selected HDC {} cannot be pinned: {error}; nothing was started",
                selection.executable.display()
            )
        })?;
        Ok((
            arkdeck_provider_hdc::ProcessDispatch::new(
                dispatch,
                Some(&endpoint.endpoint.port().to_string()),
            ),
            launched,
            selection.executable_sha256,
        ))
    }

    /// The Job store owner over its private child of the root (created
    /// owner-only when absent, an existing one opened as it is, never
    /// re-permissioned): `runtime-jobs.sqlite3` under `.rust-job-owner.lock`,
    /// `jobs/<id>/job-record.json` and `jobs/<id>/journal.jsonl`, as the macOS
    /// isolated owner keeps them in `jobs-state`. The account's root keeps it
    /// in the same private child rather than beside its other entries (as
    /// Swift's production daemon does): the host store cannot open the
    /// account root itself, whose DACL also grants SYSTEM. `job.status`,
    /// `job.show` and `job.events` answer from it, and `job.list` and
    /// `job.timeline` page through its snapshot pager (`cli-job-snapshots`,
    /// whose cursors read on across a restart), so `runtime service restart`
    /// reads the current Jobs; a restart reads back what it holds. Nothing
    /// admits a Job on Windows yet. Opening validates the index's layout and
    /// rows and its files' owner and identity; a store it cannot open ends
    /// the start.
    fn job_store(&self) -> Result<arkdeck_hoststore::JobStore, String> {
        const NAME: &str = "jobs-state";
        let path = self.root.private_child(NAME).map_err(|error| {
            format!(
                "the Job store {} is unusable: {error}; nothing was started",
                self.root.path().join(NAME).display()
            )
        })?;
        arkdeck_hoststore::JobStore::open_owner(&path).map_err(|error| {
            format!(
                "the Job store {} is unusable: {error}; nothing was started",
                path.display()
            )
        })
    }

    /// The root a device mutation proves the Runtime's state continuity
    /// against (`MutationAuthority::require_state`), as the macOS daemons
    /// name it: the installed Runtime's own Job state.
    /// * The account's daemon is that Runtime: its Job store's own
    ///   `jobs-state`, spelled as the root resolves it, as the production
    ///   composition names Swift's state directory.
    /// * A development root is not: as the macOS standalone and the
    ///   unacknowledged isolated owner, it names the account's
    ///   `%LOCALAPPDATA%\ArkDeck\Agentd\jobs-state`, which its own Job store
    ///   never is, so every device mutation it is asked for is refused before
    ///   anything of that root is read. Anchoring the proof at a development
    ///   root needs the acknowledged development authority beside a managed
    ///   HDC server, which Windows does not compose (the HDC tuple is not
    ///   registered).
    ///
    /// None when the root cannot be named; then no mutation is admitted.
    fn mutation_root(&self) -> Option<std::path::PathBuf> {
        if self.development {
            StateRoot::account_path()
                .ok()
                .map(|root| root.join("jobs-state"))
        } else {
            self.root.private_child("jobs-state").ok()
        }
    }

    /// The capability store beside the Job state (`jobs-state\capabilities`,
    /// created owner-only when absent), as the macOS isolated owner keeps
    /// it: `job.run` settles a device Job's capability use in it and the
    /// start's Job recovery re-asserts the uses it settles, and a device
    /// mutation's admission issues and checks its capability in it.
    fn capability_store(&self) -> Result<arkdeck_hoststore::CapabilityStore, String> {
        let path = self.root.path().join("jobs-state").join("capabilities");
        arkdeck_hoststore::CapabilityStore::open(&path).map_err(|error| {
            format!(
                "the capability store {} is unusable: {error}; nothing was started",
                path.display()
            )
        })
    }

    /// The Trace cache owner over `traces`, beside `staging`, each private
    /// and created when absent: in a development root below its
    /// `trace-cache`, the macOS isolated owner's layout; for the account in
    /// `%LOCALAPPDATA%\ArkDeck\Trace`, the product directory's counterpart
    /// of the macOS App's `Caches/ArkDeck/Trace` (the account location
    /// decision in `evidence/runs/TASK-XPA-005/windows-account-locations-run.md`).
    /// The macOS daemon only reads the App's cache and never creates it,
    /// because the App's container is the App's; on Windows the App, the
    /// daemon and the CLI share one physical `%LOCALAPPDATA%` (ruling 8), so
    /// the daemon, which owns the store, creates it as a development root's
    /// daemon does. An existing directory is never re-permissioned; one that
    /// is not owner-only refuses the start when the store opens it.
    fn trace_cache(&self) -> Result<arkdeck_hoststore::TraceCacheStore, String> {
        let unusable = |path: &Path, error: std::io::Error| {
            format!(
                "the Trace cache {} is unusable: {error}; nothing was started",
                path.display()
            )
        };
        let parent = if self.development {
            let name = "trace-cache";
            self.root
                .private_child(name)
                .map_err(|error| unusable(&self.root.path().join(name), error))?
        } else {
            let name = ACCOUNT_TRACE;
            self.root
                .product_child(name)
                .map_err(|error| unusable(&product(&self.root).join(name), error))?
        };
        let directory = arkdeck_platform::HostDirectory::open(&parent)
            .map_err(|error| unusable(&parent, error))?;
        for child in ["traces", "staging"] {
            directory
                .private_child(child)
                .map_err(|error| unusable(&parent.join(child), error))?;
        }
        let traces = parent.join("traces");
        arkdeck_hoststore::TraceCacheStore::open(&traces).map_err(|error| unusable(&traces, error))
    }

    /// The Bootstrap registry the bundle, HDC tool and DevEco toolchain owners
    /// share (`runtime.bundle.*`, `runtime.tool.*`), created owner-only when
    /// absent and opened as it is otherwise: a development root's private
    /// `bootstrap`, the macOS isolated owner's name; the account's
    /// `%LOCALAPPDATA%\ArkDeck\Bootstrap\v1`, beside the state directory as
    /// macOS keeps `ArkDeck/Bootstrap/v1` (the account location decision, see
    /// [`Self::trace_cache`]). Its indexes are created by the owners' first
    /// write or paged list, never here.
    fn bootstrap_root(&self) -> Result<std::path::PathBuf, String> {
        let unusable = |path: &Path, error: std::io::Error| {
            format!(
                "the Bootstrap registry {} is unusable: {error}; nothing was started",
                path.display()
            )
        };
        if self.development {
            let name = "bootstrap";
            return self
                .root
                .private_child(name)
                .map_err(|error| unusable(&self.root.path().join(name), error));
        }
        let parent = self
            .root
            .product_child(ACCOUNT_BOOTSTRAP)
            .map_err(|error| unusable(&product(&self.root).join(ACCOUNT_BOOTSTRAP), error))?;
        let path = parent.join(BOOTSTRAP_VERSION);
        arkdeck_platform::HostDirectory::open(&parent)
            .and_then(|directory| directory.private_child(BOOTSTRAP_VERSION))
            .map_err(|error| unusable(&path, error))?;
        Ok(path)
    }

    /// The workspace provider's signing: none for a development root (as the
    /// macOS isolated owner composes none: it must not read, pin or release
    /// the account's signing material); for the installed daemon the
    /// account's preset store, Credential Manager bound to this daemon's own
    /// image and the attempts in the root's `workspace-signing-attempts`,
    /// releasing at the start the pins no preset record carries, as the macOS
    /// installed daemon does.
    fn signing_setup(&self) -> Result<Option<arkdeck_hoststore::SigningSetup>, String> {
        if self.development {
            return Ok(None);
        }
        let (store, image) = signing_store()?;
        arkdeck_hoststore::SigningSetup::keychain(
            store,
            self.root.path().join("workspace-signing-attempts"),
            image,
            true,
        )
        .map(Some)
        .map_err(|error| format!("the signing credential store is unusable: {error}"))
    }

    /// The History filter owner over the root's private `history-filter`
    /// (created owner-only when absent, an existing one opened as it is).
    /// Both macOS compositions keep `history-filter.json` and its lock in
    /// the state directory itself; the host store cannot open a Windows
    /// root itself (a development root is any directory of this user, the
    /// account's root grants SYSTEM, ruling 23), so the same document and
    /// lock live one level down, as the Job store's do. The store reopens
    /// its directory on every request, so a directory made unsafe later
    /// fails that request only.
    fn history_store(&self) -> Result<arkdeck_hoststore::HistoryStore, String> {
        const NAME: &str = "history-filter";
        let unusable = |path: &Path, error: std::io::Error| {
            format!(
                "the History filter store {} is unusable: {error}; nothing was started",
                path.display()
            )
        };
        let path = self
            .root
            .private_child(NAME)
            .map_err(|error| unusable(&self.root.path().join(NAME), error))?;
        arkdeck_hoststore::HistoryStore::open(&path).map_err(|error| unusable(&path, error))
    }

    /// The Session storage owner: its settings in the private `session-state`
    /// and its default Sessions root, the Artifact usage owner (`artifacts`)
    /// the one the Artifact read owner reads.
    ///
    /// A development root keeps its default root in its private `sessions`,
    /// the macOS isolated owner's names, and its owner is isolated as the
    /// macOS one is: a selected Sessions root stays inside the development
    /// root and outside every other owner's directory.
    ///
    /// The account keeps its default root in `%LOCALAPPDATA%\ArkDeck\Sessions`,
    /// beside its state directory as macOS keeps `ArkDeck/Sessions` (the
    /// account location decision, see [`Self::trace_cache`]); its settings
    /// stay in `Agentd\session-state`, since the host store cannot open the
    /// account root itself, whose DACL also grants SYSTEM (ruling 23). A
    /// default root an earlier build kept in `Agentd\sessions` is moved there
    /// once ([`Self::move_account_sessions`]).
    fn session_store(&self) -> Result<arkdeck_hoststore::SessionStore, String> {
        let unusable = |path: &Path, error: &dyn std::fmt::Display| {
            format!(
                "the Session store {} is unusable: {error}; nothing was started",
                path.display()
            )
        };
        // Each child as the file system resolves the opened handle
        // (`StateRoot::private_child`): the canonical plain spelling (`D:\…`)
        // the Session owner opens its roots by and compares them with, which
        // a verbatim (`\\?\D:\…`) or short (`RUNNER~1`) spelling of the
        // root is not.
        let child = |name: &str| {
            self.root
                .private_child(name)
                .map_err(|error| unusable(&self.root.path().join(name), &error))
        };
        let state = child("session-state")?;
        let root = &state
            .parent()
            .ok_or_else(|| unusable(&state, &"it has no parent"))?
            .to_path_buf();
        if !self.development {
            let sessions = self.move_account_sessions(&state, root)?;
            return arkdeck_hoststore::SessionStore::open(&state, &sessions)
                .map_err(|error| unusable(&state, &error));
        }
        let sessions = child("sessions")?;
        let store = arkdeck_hoststore::SessionStore::open(&state, &sessions)
            .map_err(|error| unusable(&state, &error))?;
        store
            .isolated(
                root,
                [
                    "artifacts",
                    "trace-cache",
                    "bootstrap",
                    "jobs-state",
                    "targets-state",
                    "agent-executions",
                    "human-action-snapshots",
                    "control-action-snapshots",
                    "evolution-workspaces",
                    "workspace-projects",
                    "history-filter",
                ]
                .into_iter()
                // The HDC control-action owner's, beside a managed server.
                .chain(self.hdc.is_some().then_some("hdc-control-actions"))
                .map(|name| root.join(name))
                .collect(),
            )
            .map_err(|error| unusable(&state, &error))
    }

    /// The account's default Sessions root, `%LOCALAPPDATA%\ArkDeck\Sessions`,
    /// after the one-time move of an earlier build's `Agentd\sessions`
    /// (`root` is the state directory as the file system spells it):
    ///
    /// * no `Agentd\sessions`: nothing to move;
    /// * `Agentd\sessions` and no `Sessions`: the directory is renamed into
    ///   place, one rename on the same volume, so every Session, its staging
    ///   and its identity move together and nothing is copied;
    /// * both: an empty `Agentd\sessions` is removed; one holding anything
    ///   refuses the start, naming both, and neither is changed (Sessions
    ///   are never merged).
    ///
    /// Then settings that still select the default root at its old place are
    /// published selecting it at the new one
    /// (`SessionStore::rebase_default_root`), which also completes a move a
    /// start died in. The move runs under the owner lock and the
    /// single-instance guard, before any owner opens a Session root.
    fn move_account_sessions(
        &self,
        state: &Path,
        root: &Path,
    ) -> Result<std::path::PathBuf, String> {
        const OLD: &str = "sessions";
        let old = root.join(OLD);
        // The product directory as the file system spells the state
        // directory's parent, whatever spelling (a short name, say) the
        // Known Folder gave the root.
        let new = root
            .parent()
            .map_or_else(|| product(&self.root), Path::to_path_buf)
            .join(ACCOUNT_SESSIONS);
        let failed = |what: &str, error: &dyn std::fmt::Display| {
            format!(
                "the Sessions root {} could not be {what}: {error}; nothing was started",
                new.display()
            )
        };
        let has = |name: &str, product: bool| {
            self.root
                .has_entry(name, product)
                .map_err(|error| failed("inspected", &error))
        };
        if has(OLD, false)? {
            if !has(ACCOUNT_SESSIONS, true)? {
                self.root
                    .move_child_to_product(OLD, ACCOUNT_SESSIONS)
                    .map_err(|error| failed(&format!("moved from {}", old.display()), &error))?;
                report(&format!(
                    "arkdeck-agentd moved the default Sessions root from {} to {}",
                    old.display(),
                    new.display()
                ));
            } else if self
                .root
                .remove_empty_child(OLD)
                .map_err(|error| failed("inspected", &error))?
            {
                report(&format!(
                    "arkdeck-agentd removed the empty earlier Sessions root {}",
                    old.display()
                ));
            } else {
                return Err(format!(
                    "both {} and the earlier {} hold Sessions; move or remove one of them,                      Sessions are never merged; nothing was changed or started",
                    new.display(),
                    old.display()
                ));
            }
        }
        let sessions = self
            .root
            .product_child(ACCOUNT_SESSIONS)
            .map_err(|error| failed("opened", &error))?;
        if arkdeck_hoststore::SessionStore::rebase_default_root(state, &old, &sessions)
            .map_err(|error| failed("recorded in the Session settings", &error))?
        {
            report(&format!(
                "arkdeck-agentd recorded the default Sessions root {} in the Session settings",
                sessions.display()
            ));
        }
        Ok(sessions)
    }

    /// After a complete drain: the owner lock, then the guard, on the thread
    /// that took the guard.
    pub(crate) fn release(self) {
        let Self {
            owner, guard, root, ..
        } = self;
        drop(owner);
        drop(guard);
        drop(root);
    }
}

/// What serves.
pub(crate) struct Serving {
    pub(crate) stop: StopSignal,
    pub(crate) listener: LocalListener,
    pub(crate) authority: Option<Authority>,
}

pub(crate) enum Start {
    Serve(Serving),
    /// Another daemon owns the root; its instance document names it.
    AlreadyRunning(Instance),
}

fn report(line: &str) {
    println!("{line}");
    let _ = std::io::stdout().flush();
}

/// The instance document a daemon of this root left, if one decodes.
fn read_instance(root: &StateRoot) -> Option<Instance> {
    let bytes = root
        .read_document(INSTANCE_DOCUMENT, DOCUMENT_LIMIT)
        .ok()??;
    serde_json::from_slice(&bytes).ok()
}

fn already_running(root: &StateRoot) -> Result<Start, String> {
    match read_instance(root) {
        Some(instance) => Ok(Start::AlreadyRunning(instance)),
        None => Err(format!(
            "another Runtime holds the state root {} but left no instance document; nothing \
             was started",
            root.path().display()
        )),
    }
}

/// The guard is held by another daemon: Swift's second instance answer when
/// this root's instance document names it. When it does not (a daemon of
/// another root that shares this guard and pipe, as the account's daemon of
/// another profile does), the start is refused naming the guard, the pipe
/// and the process that serves it, so the holder can be found.
fn guard_held(
    root: &StateRoot,
    scope: &arkdeck_platform::InstanceScope,
    endpoint: &LocalEndpoint,
) -> Result<Start, String> {
    if let Some(instance) = read_instance(root) {
        return Ok(Start::AlreadyRunning(instance));
    }
    let served = match arkdeck_platform::pipe_server_pid(endpoint) {
        Ok(Some(pid)) => format!(
            ", and its pipe {} is served by pid {pid}",
            endpoint.as_path().display()
        ),
        Ok(None) => format!(
            ", and its pipe {} is not served",
            endpoint.as_path().display()
        ),
        Err(error) => format!(
            ", and the process serving its pipe {} is unknown: {error}",
            endpoint.as_path().display()
        ),
    };
    Err(format!(
        "another Runtime holds this daemon's single-instance guard {}{served}; it left no \
         instance document in the state root {}, so it serves another root; nothing was \
         started",
        scope.guard_name(),
        root.path().display()
    ))
}

/// Decides the composition and, for one that owns a state root, takes it
/// (see the module's documentation).
pub(crate) fn start(
    development: Option<&OsStr>,
    endpoint: Option<&OsStr>,
    started_at_utc: &str,
    variable: &dyn Fn(&str) -> Option<OsString>,
) -> Result<Start, String> {
    if let (None, Some(endpoint)) = (development, endpoint) {
        let stop = StopSignal::install(None).map_err(|error| error.to_string())?;
        let listener = LocalListener::bind(&LocalEndpoint::new(endpoint))
            .map_err(|error| error.to_string())?;
        return Ok(Start::Serve(Serving {
            stop,
            listener,
            authority: None,
        }));
    }
    if development.is_some()
        && let Some(input) = NOT_COMPOSED.iter().find(|name| variable(name).is_some())
    {
        return Err(format!(
            "{input} is not composed by the Windows development root yet; nothing was started"
        ));
    }
    // Only a registered Windows HDC tuple (CHG-2026-078) admits a development
    // HDC, and it is decided before the root is opened; the composition
    // starts it as the root's managed server.
    let hdc = match development {
        Some(_) => {
            crate::windows_hdc_gate::admit(variable, arkdeck_provider_hdc::WINDOWS_HDC_TUPLES)?
        }
        None => None,
    };
    // The account's HDC is the Bootstrap registry's selection, configured by
    // `ARKDECK_HDC_PATH` as on macOS; its inputs are decided here too.
    let account_hdc = match development {
        Some(_) => None,
        None => AccountHdc::from(variable)?.map(Box::new),
    };
    let root = match development {
        Some(root) => StateRoot::development(Path::new(root)),
        None => StateRoot::account(),
    }
    .map_err(|error| format!("the daemon state root is unusable: {error}"))?;
    let unusable = |what: &str, error: std::io::Error| {
        format!("{what} of {} is unusable: {error}", root.path().display())
    };
    let scope = root
        .scope()
        .map_err(|error| unusable("the instance scope", error))?;
    let expected = root
        .endpoint()
        .map_err(|error| unusable("the endpoint", error))?;
    if let Some(endpoint) = endpoint
        && Path::new(endpoint) != expected.as_path()
    {
        return Err(format!(
            "a development root's endpoint is named after the root: {}",
            expected.as_path().display()
        ));
    }
    let (guard, abandoned) = match SingleInstanceGuard::acquire(&scope, Duration::ZERO)
        .map_err(|error| unusable("the single-instance guard", error))?
    {
        GuardAcquisition::Owned { guard, abandoned } => (guard, abandoned),
        GuardAcquisition::Held => return guard_held(&root, &scope, &expected),
    };
    let Some(owner) = root
        .lock_owner()
        .map_err(|error| unusable("the owner lock", error))?
    else {
        return already_running(&root);
    };
    if abandoned {
        report(
            "arkdeck-agentd: the previous daemon of this state root ended holding its \
             single-instance guard; starting as after a crash",
        );
    }
    let stop =
        StopSignal::install(Some(&scope)).map_err(|error| unusable("the stop event", error))?;
    let listener = LocalListener::bind(&expected).map_err(|error| {
        format!(
            "the endpoint {} is not this Runtime's: {error}; nothing was started",
            expected.as_path().display()
        )
    })?;
    // The state a restart reads back: what its predecessor left.
    if let Some(previous) = read_instance(&root) {
        report(&format!(
            "arkdeck-agentd previous instance: pid {}, started {}",
            previous.pid, previous.started_at_utc
        ));
    }
    let document = Instance {
        pid: i32::try_from(std::process::id()).map_err(|_| "the process id is unrepresentable")?,
        protocol_version: arkdeck_contract::PROTOCOL_VERSION.into(),
        socket_path: expected.as_path().to_string_lossy().into_owned(),
        started_at_utc: started_at_utc.into(),
    };
    let bytes = serde_json::to_vec(&document).map_err(|error| error.to_string())?;
    root.publish_document(INSTANCE_DOCUMENT, &bytes)
        .map_err(|error| unusable("the instance document", error))?;
    report(&format!(
        "arkdeck-agentd state root {}",
        root.path().display()
    ));
    Ok(Start::Serve(Serving {
        stop,
        listener,
        authority: Some(Authority {
            endpoint: expected,
            development: development.is_some(),
            hdc: hdc.map(Box::new),
            account_hdc,
            tuples: arkdeck_provider_hdc::WINDOWS_HDC_TUPLES,
            owner,
            guard,
            root,
        }),
    }))
}

/// The admitted HDC's managed server, started on the tuple's endpoint, and
/// the process dispatch every HDC plan takes to it: both tools pinned to the
/// digest the gate admitted before anything is launched, as the macOS owner
/// verifies every tool it needs first (`MeasuredHdc`). The dispatch names the
/// managed server's port.
fn launch_managed(
    hdc: &crate::windows_hdc_gate::AdmittedHdc,
) -> Result<
    (
        arkdeck_provider_hdc::ProcessDispatch,
        crate::managed_hdc::Launched,
    ),
    String,
> {
    let tool = || {
        arkdeck_platform::VerifiedTool::open(&hdc.path, &hdc.sha256).map_err(|error| {
            format!(
                "the registered Windows HDC {} cannot be pinned: {error}; nothing was started",
                hdc.path.display()
            )
        })
    };
    let (server, dispatch) = (tool()?, tool()?);
    let managed =
        crate::managed_hdc::ManagedHdc::start(&server, &hdc.path.to_string_lossy(), hdc.selection)?;
    Ok((
        arkdeck_provider_hdc::ProcessDispatch::new(
            dispatch,
            Some(&hdc.selection.endpoint.port().to_string()),
        ),
        crate::managed_hdc::Launched::new(managed),
    ))
}

/// The installed daemon's credential pinning: the account's signing preset
/// root and the Credential Manager secrets bound to this process's own image,
/// in its canonical `X:\…` spelling (the spelling a receipt's identity is
/// computed over).
fn credential_pinning() -> Result<arkdeck_hoststore::WorkspaceCredentialPinning, String> {
    let (root, image) = signing_store()?;
    arkdeck_hoststore::keychain_credential_pinning(root, image)
        .map_err(|error| format!("the signing credential store is unusable: {error}"))
}

/// The account's signing preset root and this process's own image, in its
/// canonical `X:\…` spelling.
fn signing_store() -> Result<(std::path::PathBuf, std::path::PathBuf), String> {
    let root = arkdeck_platform::arkdeck_application_support_root()
        .ok_or("this account has no local application data for the signing preset")?
        .join("Signing")
        .join("OpenHarmony");
    let image = std::env::current_exe()
        .and_then(|image| image.canonicalize())
        .map_err(|error| format!("this daemon's image cannot be named: {error}"))?;
    let image = image
        .to_str()
        .ok_or("this daemon's image path is not text")?;
    let image = std::path::PathBuf::from(image.strip_prefix(r"\\?\").unwrap_or(image));
    Ok((root, image))
}

// Run by this binary's unit-test build only (`daemon_unit_tests!`).
daemon_unit_tests! {
mod tests {
    use super::*;

    #[test]
    fn the_instance_document_keeps_swift_s_shape() {
        let instance = Instance {
            pid: 7,
            protocol_version: "p".into(),
            socket_path: r"\\.\pipe\arkdeck-agentd-x".into(),
            started_at_utc: "t".into(),
        };
        assert_eq!(
            serde_json::to_string(&instance).unwrap(),
            r#"{"pid":7,"protocolVersion":"p","socketPath":"\\\\.\\pipe\\arkdeck-agentd-x","startedAtUTC":"t"}"#
        );
        assert_eq!(
            instance.running(),
            r"arkdeck-agentd already running: pid 7, socket \\.\pipe\arkdeck-agentd-x, protocol p"
        );
    }

    mod loopback_ports {
        include!("../../../tests/support/loopback_ports.rs");
    }

    /// A stand-in HDC compiled from Rust at test time (the macOS tests
    /// compile theirs from C): `-s <endpoint> -m` listens on the endpoint and
    /// accepts until it is ended; `-s <endpoint> checkserver` answers agreeing
    /// versions; `list targets -v` answers the registered UART-only listing,
    /// so the managed start settles past the server-startup listing at once
    /// (CHG-2026-078 r3); anything else is unregistered (status 64). No real
    /// HDC runs.
    const STAND_IN: &str = r#"
fn main() {
    let arguments: Vec<String> = std::env::args().collect();
    if arguments[1..] == ["list", "targets", "-v"] {
        print!("COM1\t\tUART\tReady\tunknown...\thdc\r\n");
        return;
    }
    match arguments.get(3).map(String::as_str) {
        Some("-m") => {
            let listener = std::net::TcpListener::bind(&arguments[2]).unwrap();
            for connection in listener.incoming() {
                drop(connection);
            }
        }
        Some("checkserver") => {
            println!("Client version:Ver: 3.2.0d, server version:Ver: 3.2.0d");
        }
        _ => std::process::exit(64),
    }
}
"#;

    /// The compiled stand-in in a fresh directory, removed when dropped.
    struct StandIn(std::path::PathBuf);
    impl StandIn {
        fn compile() -> Self {
            let nonce = u64::from_ne_bytes(arkdeck_platform::random_bytes::<8>().unwrap());
            let directory = std::env::temp_dir()
                .canonicalize()
                .unwrap()
                .join(format!("ad-winmanagedhdc-{nonce:016x}"));
            let directory = std::path::PathBuf::from(
                directory
                    .to_str()
                    .unwrap()
                    .strip_prefix(r"\\?\")
                    .unwrap_or(directory.to_str().unwrap()),
            );
            std::fs::create_dir(&directory).unwrap();
            std::fs::write(directory.join("hdc.rs"), STAND_IN).unwrap();
            let rustc = std::env::var_os("RUSTC").unwrap_or_else(|| "rustc".into());
            let output = std::process::Command::new(rustc)
                .arg("--edition=2021")
                .arg("-o")
                .arg(directory.join("hdc.exe"))
                .arg(directory.join("hdc.rs"))
                .output()
                .unwrap();
            assert!(output.status.success(), "{output:?}");
            Self(directory)
        }
        fn path(&self) -> std::path::PathBuf {
            self.0.join("hdc.exe")
        }
    }
    impl Drop for StandIn {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    /// What the composition does once the gate admits an HDC, which only a
    /// registered tuple does: here a table naming the stand-in's digest, as
    /// the gate's own tests inject one; the real (draft) registry admits
    /// none. The admitted HDC is started as the managed server on the tuple's
    /// endpoint, proved to be this launch, registered as the HDC provider
    /// with its status and tool facts, named by the owner census, and ended
    /// by the daemon's stop, leaving the endpoint free. The stand-in's
    /// checkserver line is the macOS fakes' (`3.2.0d`).
    #[test]
    fn an_admitted_hdc_is_composed_as_the_managed_server_and_stopped() {
        let stand_in = StandIn::compile();
        let path = stand_in.path();
        let sha256: &'static str = Box::leak(
            arkdeck_contract::sha256_hex(&std::fs::read(&path).unwrap()).into_boxed_str(),
        );
        let endpoint = loopback_ports::free_endpoint();
        let table: &'static [arkdeck_provider_hdc::WindowsHdcTuple] =
            Box::leak(Box::new([arkdeck_provider_hdc::WindowsHdcTuple {
                candidate: "stand-in",
                executable_sha256: sha256,
                reported_version: "3.2.0d",
                version_stdout: b"Ver: 3.2.0d\r\n",
                endpoint,
            }]));
        let port = endpoint.port().to_string();
        let environment = [
            ("ARKDECK_DEVELOPMENT_HDC_PATH", path.to_str().unwrap()),
            ("ARKDECK_DEVELOPMENT_HDC_SERVER", "managed"),
            ("OHOS_HDC_SERVER_PORT", port.as_str()),
        ];
        let variable = |name: &str| {
            environment
                .iter()
                .find(|(key, _)| *key == name)
                .map(|(_, value)| OsString::from(value))
        };
        // The registered table (DevEco's `hdc.exe` only) refuses this
        // stand-in before anything is launched.
        assert!(
            crate::windows_hdc_gate::admit(&variable, arkdeck_provider_hdc::WINDOWS_HDC_TUPLES)
                .is_err()
        );
        let hdc = crate::windows_hdc_gate::admit(&variable, table)
            .unwrap()
            .unwrap();
        let (dispatch, launched) = launch_managed(&hdc).unwrap();
        let server = std::sync::Arc::clone(launched.server());
        assert!(std::net::TcpStream::connect(endpoint).is_ok());
        let host = crate::host::Host::from_environment()
            .with_managed_development_hdc(dispatch, std::sync::Arc::clone(&server));
        let census = host.owner_census();
        assert!(
            census.contains(&"hdc") && census.contains(&"managedHdc"),
            "{census:?}"
        );
        // `runtime.hdc.status` answers from the managed server's observer.
        // Its commandless identity family is the provider's own registry's
        // (`CommandlessIdentity::family`), which this table does not reach:
        // with no Windows HDC tuple registered, no listener is observed and
        // the server is never called managed, so the status fails closed.
        use arkdeck_control::HostServices;
        let status = host.runtime_hdc_status().unwrap();
        assert_eq!(
            (
                &status["executablePath"],
                &status["executableSHA256"],
                &status["endpoint"],
                &status["ownership"],
                &status["reasonCode"],
                &status["startupVersions"]["server"],
            ),
            (
                &serde_json::json!(path.to_str().unwrap()),
                &serde_json::json!(sha256),
                &serde_json::json!(endpoint.to_string()),
                &serde_json::json!("unknown"),
                &serde_json::json!("hdc.identityFamilyUnavailable"),
                &serde_json::json!("3.2.0d"),
            ),
            "{status}"
        );
        assert_eq!(
            host.managed_hdc_tool(),
            Some(arkdeck_control::ManagedToolFacts {
                tool_sha256: sha256.to_owned(),
                client_version: "3.2.0d".into(),
                server_version: "3.2.0d".into(),
                endpoint_source: "inheritedEnvironment".into(),
            })
        );
        assert!(!server.requires_recomposition());
        // Device-bound Jobs plan, admit, run and reconcile over this HDC
        // (TASK-XPA-005): with a Target store its composition is built over
        // the admitted tool, and `operation.list` asks after its identity
        // rather than calling the provider unregistered.
        // The temporary directory in its canonical, plain long spelling, which
        // the Target store compares its root with (an 8.3 TEMP is refused).
        let temporary = std::fs::canonicalize(std::env::temp_dir()).unwrap();
        let temporary = temporary
            .to_str()
            .and_then(|text| text.strip_prefix(r"\\?\"))
            .map_or(temporary.clone(), std::path::PathBuf::from);
        let state = temporary.join(format!(
            "arkdeck-job-hdc-{:x}",
            u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap())
        ));
        arkdeck_platform::HostDirectory::open_or_create_private(&state.join("targets")).unwrap();
        assert_eq!(host.operation_availability("observe.device@1", "hdc"), None);
        let host = host
            .with_targets(arkdeck_hoststore::TargetStore::open(&state.join("targets")).unwrap())
            .with_planning(&state, None);
        {
            let composition = host.hdc().expect("the Jobs' HDC composition");
            assert_eq!(composition.tool_sha256, sha256);
            assert!(composition.receive_root.is_some());
        }
        let reasons = host
            .operation_availability("observe.device@1", "hdc")
            .expect("the HDC provider is registered");
        assert!(
            !reasons
                .iter()
                .any(|(code, _)| *code == "tool_identity_drift"),
            "{reasons:?}"
        );
        drop(host);
        let _ = std::fs::remove_dir_all(&state);
        let stopped = launched.stop().unwrap();
        assert!(stopped.server.is_ok(), "{stopped:?}");
        assert!(stopped.report(true).is_empty(), "{stopped:?}");
        drop(server);
        drop(launched);
        assert!(std::net::TcpStream::connect(endpoint).is_err());
    }

    #[test]
    fn the_accounts_hdc_inputs_are_decided_before_anything_is_opened() {
        let none = |_: &str| None::<OsString>;
        assert_eq!(AccountHdc::from(&none), Ok(None));
        let only_sha = |name: &str| (name == "ARKDECK_HDC_SHA256").then(|| OsString::from("a"));
        assert!(
            matches!(AccountHdc::from(&only_sha), Err(message) if message.starts_with("ARKDECK_HDC_SHA256"))
        );
        let relative = |name: &str| (name == "ARKDECK_HDC_PATH").then(|| OsString::from("hdc.exe"));
        assert_eq!(
            AccountHdc::from(&relative),
            Err("ARKDECK_HDC_PATH must be an explicit absolute path".into())
        );
        let configured = |name: &str| match name {
            "ARKDECK_HDC_PATH" => Some(OsString::from(r"C:\sdk\hdc.exe")),
            "OHOS_HDC_SERVER_PORT" => Some(OsString::from("8710")),
            _ => None,
        };
        assert_eq!(
            AccountHdc::from(&configured),
            Ok(Some(AccountHdc {
                configured: std::path::PathBuf::from(r"C:\sdk\hdc.exe"),
                server_port: Some(OsString::from("8710")),
            }))
        );
    }

    /// The account's HDC as macOS production composes it, over a root that
    /// stands in for the account's directories: the configured file is
    /// adopted as the Bootstrap registry's first selection only when a
    /// registered tuple names it (here a table naming the stand-in's digest,
    /// as the gate's tests inject one); the registry's retained copy, never
    /// the configured file, is started as the managed server on the tuple's
    /// endpoint; the tool-selection owner is composed beside it and answers
    /// `runtime.tool.select`; a later start reads the same selection without
    /// the configured file.
    #[test]
    fn the_accounts_selected_registered_hdc_is_started_beside_the_tool_selection_owner() {
        use arkdeck_control::HostServices;
        let stand_in = StandIn::compile();
        let bytes = std::fs::read(stand_in.path()).unwrap();
        let sha256: &'static str = Box::leak(arkdeck_contract::sha256_hex(&bytes).into_boxed_str());
        let endpoint = loopback_ports::free_endpoint();
        let table: &'static [arkdeck_provider_hdc::WindowsHdcTuple] =
            Box::leak(Box::new([arkdeck_provider_hdc::WindowsHdcTuple {
                candidate: "stand-in",
                executable_sha256: sha256,
                reported_version: "3.2.0d",
                version_stdout: b"Ver: 3.2.0d\r\n",
                endpoint,
            }]));
        let temporary = std::fs::canonicalize(std::env::temp_dir()).unwrap();
        let temporary = temporary
            .to_str()
            .and_then(|text| text.strip_prefix(r"\\?\"))
            .map_or(temporary.clone(), std::path::PathBuf::from);
        let directory = temporary.join(format!(
            "arkdeck-account-hdc-{:x}",
            u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap())
        ));
        arkdeck_platform::create_private_directory(&directory).unwrap();
        // The configured file in a private directory of this user, as an
        // installed DevEco keeps its `hdc.exe`.
        let sdk = directory.join("sdk");
        arkdeck_platform::create_private_directory(&sdk).unwrap();
        let path = sdk.join("hdc.exe");
        std::io::Write::write_all(
            &mut arkdeck_platform::create_private_file(&path).unwrap(),
            &bytes,
        )
        .unwrap();
        let Start::Serve(serving) = start(Some(directory.as_os_str()), None, "t", &|_| None).unwrap()
        else {
            panic!("the root is this test's own");
        };
        let mut authority = serving.authority.unwrap();
        let port = OsString::from(endpoint.port().to_string());
        let account = AccountHdc {
            configured: path.clone(),
            server_port: Some(port.clone()),
        };
        let bootstrap = authority.bootstrap_root().unwrap();
        // With the registered table (DevEco's `hdc.exe` only) the stand-in
        // is never adopted, and nothing is selected.
        let refused = authority.selected_hdc(&account, &bootstrap).err().unwrap();
        assert!(refused.contains("admissionDenied"), "{refused}");
        authority.tuples = table;
        // Another endpoint than the tuple's is refused before any launch.
        let elsewhere = AccountHdc {
            configured: path.clone(),
            server_port: Some(OsString::from("1")),
        };
        assert!(authority.selected_hdc(&elsewhere, &bootstrap).is_err());
        let selected = authority.selected_hdc(&account, &bootstrap).unwrap();
        assert_eq!(selected.tuple.candidate, "stand-in");
        assert_eq!(selected.endpoint.endpoint, endpoint);
        assert_eq!(selected.selection.active_generation, 1);
        assert_eq!(selected.selection.pending_action_id, None);
        assert_eq!(selected.selection.executable_sha256, sha256);
        assert!(selected.selection.executable.starts_with(&bootstrap));
        assert!(selected.selection.executable.ends_with("hdc.exe"));
        assert_ne!(selected.selection.executable, path);

        let controls = authority.control_actions(true, &bootstrap).unwrap();
        let (dispatch, launched, started) =
            authority.launch_selected(&selected, &bootstrap).unwrap();
        assert_eq!(started, sha256);
        assert!(std::net::TcpStream::connect(endpoint).is_ok());
        let server = std::sync::Arc::clone(launched.server());
        // The impact source a selection reads: the managed server beside
        // the Job owner and the Target store, as `compose` gives them.
        let host = crate::host::Host::from_environment()
            .with_jobs(authority.job_store().unwrap())
            .with_targets(
                arkdeck_hoststore::TargetStore::open(
                    &authority.root.private_child("targets").unwrap(),
                )
                .unwrap(),
            )
            .with_managed_development_hdc(dispatch, std::sync::Arc::clone(&server))
            .with_control_actions(controls);
        // The tool-selection owner answers: the active tool is no candidate,
        // so the action records why, and nothing is selected or launched.
        let params = serde_json::json!({
            "actionRequestId": "request-account-hdc",
            "tool": selected.selection.tool_ref,
            "expectedActiveGeneration": "1",
        });
        let answer = host.control_action("runtime.tool.select", params.as_object().unwrap());
        let action = answer.unwrap();
        assert_eq!(action["kind"], "runtimeToolSelection", "{action}");
        assert_eq!(action["blockerReasonCode"], "tool.selectionFactsUnavailable");
        assert_eq!(action["dispatchCount"], 0);
        drop(host);
        // A later start reads the durable selection, not a configured file.
        let later = AccountHdc {
            configured: temporary.join("absent").join("hdc.exe"),
            server_port: Some(port),
        };
        assert_eq!(
            authority.selected_hdc(&later, &bootstrap).unwrap().selection,
            selected.selection
        );
        let stopped = launched.stop().unwrap();
        assert!(stopped.server.is_ok(), "{stopped:?}");
        drop(server);
        drop(launched);
        assert!(std::net::TcpStream::connect(endpoint).is_err());
        authority.release();
        drop(serving.listener);
        let _ = std::fs::remove_dir_all(&directory);
    }

    #[test]
    fn a_development_root_refuses_an_input_it_does_not_compose() {
        for input in NOT_COMPOSED {
            let refused = start(Some(OsStr::new(r"C:\unused")), None, "t", &|name| {
                (name == input).then(|| OsString::from("x"))
            });
            assert!(
                matches!(&refused, Err(message) if message.starts_with(input)),
                "{input}"
            );
        }
    }
}
}
