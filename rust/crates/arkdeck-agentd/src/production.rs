//! The standalone production composition (TASK-XPA-017): the third mode of
//! this daemon, the one M5's cutover points the LaunchAgent at (design §G.1
//! r11, §G.4). It is written and tested here, not activated: only a process
//! started with [`COMPOSITION`] set to `production` reaches it, and nothing
//! sets that today. Without it the standalone daemon is the read-only
//! foundation it was.
//!
//! It composes the owners the isolated development owner composes, in the
//! layout Swift's daemon keeps under the account's Application Support, so
//! that at the cutover the durable state Swift wrote — Jobs with their intents
//! and outcomes, recovery epochs, capabilities, Targets, Artifacts, Sessions —
//! is the state this Runtime owns, in place (§G.2's third row; §G.4's
//! outcomeUnknown lane and recovery epochs). [`Layout`] names every root, each
//! from the one account home Swift's Foundation resolves
//! (`CFFIXED_USER_HOME`, else the account's own), as
//! `ArkDeckAgentFilesystemLayout.defaultStateDirectory()` does.
//!
//! One authority. Before any store is created or probed, the process takes
//! Swift's single-instance lock, `Agentd/instance.lock`, as
//! `AgentDaemonServer.start` flocks it, then the facade's transport lock on the
//! `Agentd` directory with the installed socket (`LocalListener::bind_facade`),
//! and writes Swift's instance document naming itself. A standalone Swift
//! daemon holds the first lock and the facade the second, and neither lock
//! blocks the other; holding both excludes each, and each of them refuses to
//! start beside this one. When another Runtime holds the instance lock and
//! its document names it, this process answers as Swift's second instance
//! does — `already running`, exit 0 — having composed nothing; any other held
//! lock or a live listener on the installed socket refuses the start. It
//! never stands by: a standby would read another authority's stores, whose
//! reads are not side-effect free in Swift, and could not serve the socket
//! that authority holds. Unlike Swift, which composes every owner, starts its
//! HDC server and recovers Jobs before it learns that it is the second
//! instance, nothing here runs before both locks are held.
//!
//! What it cannot prove it refuses: an `ARKDECK_HDC_PATH` the account's
//! bootstrap registry cannot select, a pending tool selection it has no owner
//! to settle, an endpoint another server holds, a recovery that fails — each
//! ends the start with its reason, as Swift's does (exit 69 here, 1 there).
//! Beside the registered HDC it starts as its managed server it reads the
//! Runtime's own trusted USB relations, as Swift's daemon reads
//! `registeredDAYU200()` ([`with_trusted_usb`]). What it composes without is
//! named on stdout: no HDC configured (dispatch refused, as Swift's
//! `RefusingDispatcher`; nothing is observed, so no USB relation is read and
//! nothing is adopted), no Trace cache the App has created, no App ingress
//! over an overridden home, and each input Swift's LaunchAgent sets for an
//! owner not ported yet.
use crate::development_usb::{self, RelationSource};
use crate::host::Host;
use arkdeck_platform::{
    HostDirectory, HostReadLock, LocalEndpoint, LocalListener, RegistryUnavailable, UsbHostDevice,
};
use arkdeck_provider_hdc::UsbRegistryRelations;
use std::ffi::OsStr;
use std::io::{self, Read, Write};
use std::os::unix::fs::DirBuilderExt;
use std::path::{Path, PathBuf};
use std::sync::Arc;

/// Names the production composition; its one value is `production`.
pub(crate) const COMPOSITION: &str = "ARKDECK_RUNTIME_COMPOSITION";

/// Swift `ArkDeckAgentFilesystemLayout.applicationSupportRelativeStateDirectory`.
const STATE: &str = "ArkDeck/Agentd";
/// Swift `ArkDeckAgentFilesystemLayout.socketFilename`.
const SOCKET: &str = "agentd.sock";
/// Swift `AgentDaemonServer`'s single-instance lock and instance document.
const INSTANCE_LOCK: &str = "instance.lock";
const INSTANCE_DOCUMENT: &str = "instance.json";
/// Swift `ArkDeckTraceConfiguration.bundleIdentifier`: the App whose
/// container caches hold the Trace cache.
const APP_BUNDLE: &str = "com.arkdeck.desktop";

/// Inputs of another composition. Each refuses the production composition
/// before anything is touched: its socket, state root and HDC identity are
/// the account's, never a caller's. (`main.rs` refuses every development
/// HDC, USB, code-sign and mutation input for any composition without a
/// development root.)
const REFUSED: [&str; 7] = [
    "ARKDECK_DEVELOPMENT_STATE_ROOT",
    "ARKDECK_ENDPOINT",
    // A facade pairing: its Swift authority, that authority's pin and the
    // private socket a paired Swift daemon is handed.
    "ARKDECK_SWIFT_DAEMON",
    "ARKDECK_SWIFT_SHA256",
    "ARKDECK_PRIVATE_SOCKET",
    // The read-only foundation's HDC pair; the registry pins the identity.
    "ARKDECK_HDC_SHA256",
    // The isolated owner's App ingress opt-in.
    "ARKDECK_APP_INGRESS",
];

/// Whether the caller asked for the production composition.
pub(crate) fn requested(value: Option<&OsStr>) -> Result<bool, String> {
    match value {
        None => Ok(false),
        Some(value) if value == "production" => Ok(true),
        Some(_) => Err(format!("{COMPOSITION} accepts only production")),
    }
}

/// Refuses a production start that another composition's input also names,
/// or that the facade executable would run.
pub(crate) fn refuse_other_compositions(
    set: &dyn Fn(&str) -> bool,
    facade_executable: bool,
) -> Result<(), String> {
    if let Some(name) = REFUSED.iter().find(|name| set(name)) {
        return Err(format!(
            "the production composition takes no {name}: its socket, state and HDC identity \
             are the account's own"
        ));
    }
    if facade_executable {
        return Err("the facade executable does not run the production composition".into());
    }
    Ok(())
}

/// Every root the production composition owns or reads, laid out as Swift's
/// daemon lays them out.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Layout {
    /// The account home everything below resolves from: `CFFIXED_USER_HOME`,
    /// else the account's own, as Swift's `NSHomeDirectory()`.
    pub(crate) home: PathBuf,
    /// Whether `CFFIXED_USER_HOME` overrides the account's own home.
    pub(crate) overridden: bool,
    /// `…/Application Support/ArkDeck/Agentd`, Swift's state directory: the
    /// Job owner's root (`runtime-jobs.sqlite3`, `jobs/`,
    /// `cli-job-snapshots/`, recovery epochs) and the Session storage,
    /// History and planning owners', beside the instance lock and the socket.
    /// Its parent holds the default Session root and the bootstrap registry.
    pub(crate) state: PathBuf,
    pub(crate) socket: PathBuf,
    pub(crate) capabilities: PathBuf,
    pub(crate) targets: PathBuf,
    pub(crate) artifacts: PathBuf,
    pub(crate) agent_executions: PathBuf,
    pub(crate) human_actions: PathBuf,
    pub(crate) control_actions: PathBuf,
    pub(crate) hdc_control_actions: PathBuf,
    pub(crate) workspace_projects: PathBuf,
    /// `…/Application Support/ArkDeck`, the state directory's parent: where
    /// Swift keeps the Rockchip bindings, the post-flash alias among them.
    pub(crate) application_support: PathBuf,
    /// `…/ArkDeck/Sessions`, the default Session root.
    pub(crate) sessions: PathBuf,
    /// `…/ArkDeck/Bootstrap/v1`: the tool, bundle and DevEco registries.
    pub(crate) bootstrap: PathBuf,
    /// `…/ArkDeck/Signing/OpenHarmony`, Swift's
    /// `OpenHarmonyLocalSigning.defaultRootURL()`: the installed signing
    /// preset and its credential owner's ledger, outside the state directory.
    pub(crate) signing: PathBuf,
    /// Swift `defaultAgentDaemonURL()`: the installed daemon whose code
    /// identity a signing receipt is bound to.
    pub(crate) installed_daemon: PathBuf,
    /// `ArkDeck/Trace/traces` in the App's container caches, which the App
    /// creates and this Runtime never does.
    pub(crate) trace_cache: PathBuf,
}

impl Layout {
    /// The layout under `home`, which must be absolute.
    pub(crate) fn for_home(home: &Path, overridden: bool) -> Result<Self, String> {
        if !home.is_absolute() {
            return Err("the account home is not an absolute path".into());
        }
        let support = home.join("Library/Application Support");
        let state = support.join(STATE);
        let product = support.join("ArkDeck");
        Ok(Self {
            home: home.to_owned(),
            overridden,
            socket: state.join(SOCKET),
            capabilities: state.join("capabilities"),
            targets: state.join("targets"),
            artifacts: state.join("artifacts"),
            agent_executions: state.join("agent-executions"),
            human_actions: state.join("human-action-snapshots"),
            control_actions: state.join("control-action-snapshots"),
            hdc_control_actions: state.join("hdc-control-actions"),
            workspace_projects: state.join("workspace-projects"),
            sessions: product.join("Sessions"),
            bootstrap: product.join("Bootstrap/v1"),
            signing: product.join("Signing/OpenHarmony"),
            installed_daemon: product
                .join("Helpers/ArkDeckAgent.app/Contents/MacOS/arkdeck-agentd"),
            application_support: product,
            trace_cache: home
                .join("Library/Containers")
                .join(APP_BUNDLE)
                .join("Data/Library/Caches/ArkDeck/Trace/traces"),
            state,
        })
    }

    /// The account's layout, from the home Swift's Foundation resolves.
    pub(crate) fn account() -> Result<Self, String> {
        let overridden =
            std::env::var_os("CFFIXED_USER_HOME").is_some_and(|value| !value.is_empty());
        let home = arkdeck_platform::runtime_home().ok_or("the account home is unavailable")?;
        Self::for_home(Path::new(&home), overridden)
    }

    /// Every root below the home, by name.
    #[cfg(test)]
    pub(crate) fn roots(&self) -> [(&'static str, &Path); 14] {
        [
            ("state", &self.state),
            ("socket", &self.socket),
            ("capabilities", &self.capabilities),
            ("targets", &self.targets),
            ("artifacts", &self.artifacts),
            ("agentExecutions", &self.agent_executions),
            ("humanActions", &self.human_actions),
            ("controlActions", &self.control_actions),
            ("hdcControlActions", &self.hdc_control_actions),
            ("workspaceProjects", &self.workspace_projects),
            ("applicationSupport", &self.application_support),
            ("sessions", &self.sessions),
            ("bootstrap", &self.bootstrap),
            ("traceCache", &self.trace_cache),
        ]
    }
}

/// Swift `AgentDaemonInstance`: who holds the instance lock.
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

/// The instance document another Runtime left, read as Swift's second
/// instance reads it, whatever its mode; `None` if there is none it decodes.
fn read_instance(state: &Path) -> Option<Instance> {
    let mut bytes = Vec::new();
    std::fs::File::open(state.join(INSTANCE_DOCUMENT))
        .ok()?
        .take(64 * 1024)
        .read_to_end(&mut bytes)
        .ok()?;
    serde_json::from_slice(&bytes).ok()
}

/// What holds the account's Runtime while this process serves: Swift's
/// instance lock, and the facade's transport lock with the installed socket.
/// The daemon keeps both until it exits.
pub(crate) struct Authority {
    pub(crate) instance: HostReadLock,
    pub(crate) listener: LocalListener,
}

/// The claim's answer.
pub(crate) enum Claim {
    Owned(Authority),
    /// Another Runtime holds the instance lock, and its document names it.
    AlreadyRunning(Instance),
}

/// Takes the account's Runtime before anything in it is created or probed
/// (see the module's documentation), then writes the instance document that
/// names this process once its socket is bound, as Swift's server writes it.
pub(crate) fn claim(layout: &Layout, started_at_utc: &str) -> Result<Claim, String> {
    let unusable = |what: &str, error: io::Error| {
        format!("{what} of {} is unusable: {error}", layout.state.display())
    };
    // Swift's server creates its state directory owner-only first.
    std::fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(&layout.state)
        .map_err(|error| unusable("the state directory", error))?;
    let state = HostDirectory::open(&layout.state)
        .map_err(|error| unusable("the state directory", error))?;
    let instance = match state.lock_document(INSTANCE_LOCK) {
        Ok(lock) => lock,
        Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
            return match read_instance(&layout.state) {
                Some(instance) => Ok(Claim::AlreadyRunning(instance)),
                None => Err(format!(
                    "another Runtime holds the instance lock of {} but left no instance \
                     document; nothing was started",
                    layout.state.display()
                )),
            };
        }
        Err(error) => return Err(unusable("the instance lock", error)),
    };
    let listener = LocalListener::bind_facade(&LocalEndpoint::new(layout.socket.clone())).map_err(
        |error| {
            format!(
                "the installed transport {} is not this Runtime's: {error}; nothing was started",
                layout.socket.display()
            )
        },
    )?;
    let document = Instance {
        pid: i32::try_from(std::process::id()).map_err(|_| "the process id is unrepresentable")?,
        protocol_version: arkdeck_contract::PROTOCOL_VERSION.into(),
        socket_path: layout.socket.to_string_lossy().into_owned(),
        started_at_utc: started_at_utc.into(),
    };
    let bytes = serde_json::to_vec(&document).map_err(|error| error.to_string())?;
    state
        .publish_document(INSTANCE_DOCUMENT, &bytes, 64 * 1024)
        .map_err(|error| format!("the instance document could not be written: {error:?}"))?;
    Ok(Claim::Owned(Authority { instance, listener }))
}

/// What Swift's LaunchAgent may hand its daemon for an owner this Runtime
/// does not compose yet (`LaunchAgentService.renderTemplate`): each one set
/// is named at the start rather than quietly ignored.
const UNREAD: [(&str, &str); 3] = [
    // The workspace provider is composed over the registered projects; the
    // legacy environment roots are not read.
    (
        "ARKDECK_WORKSPACE_PROJECTS",
        "legacy workspace project roots",
    ),
    (
        "ARKDECK_WORKSPACE_ACTIVE_PROJECT",
        "legacy workspace project roots",
    ),
    ("ARKDECK_DEVECO_SDK_HOME", "legacy workspace project roots"),
];

/// What Swift's LaunchAgent hands its daemon that this composition reads —
/// the HDC adopted when no selection exists, the analyzer, the ArkTrace
/// distribution descriptor and the HDC server port — and which of its other
/// inputs are set.
#[derive(Clone, Debug, Default)]
pub(crate) struct Inputs {
    pub(crate) hdc: Option<PathBuf>,
    pub(crate) analyzer: Option<PathBuf>,
    /// As it is set: Swift's loader judges it, a relative path included.
    pub(crate) arktrace_descriptor: Option<std::ffi::OsString>,
    /// As it is set: Swift's resolver judges it, a relative path included.
    pub(crate) workspace_inspector: Option<std::ffi::OsString>,
    pub(crate) server_port: Option<String>,
    pub(crate) unread: Vec<(&'static str, &'static str)>,
    /// The ArkForge lane's environment: its bundle, its campaign and the
    /// retired names it refuses.
    pub(crate) arkforge: Vec<(&'static str, String)>,
}

impl Inputs {
    pub(crate) fn from_environment() -> Result<Self, String> {
        let absolute = |name: &str| -> Result<Option<PathBuf>, String> {
            match std::env::var_os(name) {
                None => Ok(None),
                Some(value) if Path::new(&value).is_absolute() => Ok(Some(value.into())),
                Some(_) => Err(format!("{name} must be an explicit absolute path")),
            }
        };
        Ok(Self {
            hdc: absolute("ARKDECK_HDC_PATH")?,
            analyzer: absolute("ARKDECK_ANALYZER_PATH")?,
            arktrace_descriptor: std::env::var_os("ARKDECK_ARKTRACE_DESCRIPTOR"),
            workspace_inspector: std::env::var_os("ARKDECK_WORKSPACE_INSPECTOR"),
            server_port: arkdeck_provider_hdc::ProcessDispatch::inherited_server_port(),
            unread: UNREAD
                .into_iter()
                .filter(|(name, _)| std::env::var_os(name).is_some())
                .collect(),
            arkforge: [
                arkdeck_provider_arkforge::BUNDLE_PATH_KEY,
                arkdeck_provider_arkforge::CAMPAIGN_KEY,
            ]
            .into_iter()
            .chain(arkdeck_provider_arkforge::RETIRED_KEYS)
            .filter_map(|name| {
                std::env::var_os(name).map(|value| (name, value.to_string_lossy().into_owned()))
            })
            .collect(),
        })
    }
}

/// Swift's production HDC (`main.swift` 462-584): only `ARKDECK_HDC_PATH`
/// configures one. While the account's bootstrap registry holds no
/// selection, that file is adopted as its first, as Swift's
/// `adoptInstalledHDC` adopts it; the registry's startup selection — never
/// the configured path once a selection exists — is the executable the
/// managed server runs. A pending selection refuses the start: this Runtime
/// composes no tool-selection owner to publish or fail it, and the selection
/// is left as it is.
pub(crate) fn registered_hdc(
    registry: &arkdeck_hoststore::ToolRegistryStore,
    configured: &Path,
    now: &str,
) -> Result<arkdeck_hoststore::StartupSelection, String> {
    let refused = |error: arkdeck_contract::WireError| {
        format!(
            "the registered HDC is unavailable: {}: {}",
            error.code, error.message
        )
    };
    if registry.startup_selection().map_err(refused)?.is_none() {
        registry
            .adopt_installed_hdc(configured, now)
            .map_err(refused)?;
    }
    let selection = registry
        .startup_selection()
        .map_err(refused)?
        .ok_or("the registered HDC selection is absent after its adoption")?;
    if let Some(action) = &selection.pending_action_id {
        return Err(format!(
            "HDC tool selection {action} is pending; this Runtime composes no tool-selection \
             owner to settle it, so nothing was started and the selection is left as it is"
        ));
    }
    Ok(selection)
}

/// The USB relations the Target observations read, by the isolated owner's
/// rule (`development_usb::relation_source`): beside the registered HDC this
/// composition started as its managed server (`managed`; its registry selects
/// only a published HDC, so a managed one is a registered one) the Runtime's
/// own reader, `registry`, as Swift's daemon reads
/// `TargetUSBRelation.registeredDAYU200()` beside its `HeadlessHDCServerHost`
/// (the maintainer's decision Q1=B of 2026-09-24). Without one nothing is
/// read: no observation is proved and adoption stays refused. No development
/// relation file is ever read here; `main.rs` refuses one without a
/// development root. Composing reads nothing; each observation takes its own
/// census.
pub(crate) fn with_trusted_usb<C>(
    host: Host,
    managed: bool,
    registry: UsbRegistryRelations<C>,
) -> Host
where
    C: Fn() -> Result<Vec<UsbHostDevice>, RegistryUnavailable> + Send + Sync + 'static,
{
    match development_usb::relation_source(managed, managed, false) {
        RelationSource::Registry => host.with_usb_registry_relations(registry),
        RelationSource::File | RelationSource::Nothing => host,
    }
}

/// What [`compose`] composed.
pub(crate) struct Composition {
    pub(crate) host: Host,
    /// The managed HDC server it started, which the daemon stops last.
    pub(crate) managed: Option<Arc<crate::managed_hdc::ManagedHdc>>,
    /// The ArkForge lane, or why there is none; its daemon is stopped after
    /// the drain, before the managed HDC server.
    pub(crate) arkforge: crate::arkforge_lane::Composed,
    /// The App ingress over the account's state root, unless its home is
    /// overridden.
    pub(crate) ingress: Option<crate::app_ingress::Configuration>,
    /// What it composed without, and why.
    pub(crate) omitted: Vec<String>,
    /// What the start-up Rockchip reconciliation left for after Job
    /// recovery.
    pub(crate) rockchip: arkdeck_hoststore::RockchipStartup,
}

/// Composes every owner over `layout` into `host`, as Swift's composition
/// root composes them over its state directory (`main.swift` 398-1447),
/// once [`claim`] holds the account's Runtime.
pub(crate) fn compose(
    layout: &Layout,
    inputs: &Inputs,
    host: Host,
    now: &str,
) -> Result<Composition, Box<dyn std::error::Error>> {
    let mut omitted = Vec::new();
    let state = HostDirectory::open(&layout.state)?;
    state.validate_path(&layout.state)?;
    for root in [
        &layout.targets,
        &layout.artifacts,
        &layout.agent_executions,
        &layout.human_actions,
        &layout.control_actions,
        &layout.workspace_projects,
    ] {
        let name = root
            .file_name()
            .and_then(OsStr::to_str)
            .ok_or("a state child has no name")?;
        state.private_child(name)?.validate_path(root)?;
    }
    // Swift creates the default Session root and the registry's missing
    // directories owner-only, and requires their leaves to be owner-only.
    for root in [&layout.sessions, &layout.bootstrap] {
        std::fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(root)?;
        HostDirectory::open(root)?.validate_path(root)?;
    }
    // Swift's start-up Rockchip reconciliation over the Target store it has
    // just opened, before any other owner reads a Target (`main.swift`
    // 404–460): the Target carried along its Loader binding's lineage, the
    // binding's recovery proof kept for after Job recovery, and a post-flash
    // alias proved from terminal Flash history. A binding it cannot read ends
    // the start, as Swift's does.
    let targets = arkdeck_hoststore::TargetStore::open(&layout.targets)?;
    let rockchip = arkdeck_hoststore::reconcile_rockchip_startup(&targets, &layout.state)?;
    for line in &rockchip.lines {
        report(line);
    }
    let host = host
        .with_targets(targets)
        .with_history(arkdeck_hoststore::HistoryStore::open(&layout.state)?)
        // Swift pins a preset's DevEco toolchain in the bootstrap registry and
        // its signing credential in the account's signing owner, the secrets
        // read from the Data Protection Keychain bound to the installed
        // daemon.
        .with_workspace_projects(
            arkdeck_hoststore::WorkspaceProjectStore::open(&layout.workspace_projects)?
                .with_dependency_pinning(
                    Some(crate::host::toolchain_pinning(&layout.bootstrap)?),
                    Some(arkdeck_hoststore::keychain_credential_pinning(
                        layout.signing.clone(),
                        layout.installed_daemon.clone(),
                    )?),
                ),
        )
        // Swift's registered projects over its state directory, whose
        // `evolution-workspaces` holds the Runtime-owned copies, and signing
        // over the account's preset store. This composition owns the default
        // state directory, so it releases the credential pins no preset
        // record carries, as Swift's default daemon does.
        .with_workspace_operations(
            &layout.state,
            &layout.bootstrap,
            Some(arkdeck_hoststore::SigningSetup::keychain(
                layout.signing.clone(),
                layout.state.join("workspace-signing-attempts"),
                layout.installed_daemon.clone(),
                true,
            )?),
            inputs.workspace_inspector.as_deref(),
        )?
        .with_imports(arkdeck_hoststore::ImportUploadStore::open(
            &layout.artifacts,
        )?)
        .with_artifacts(arkdeck_hoststore::ArtifactReadStore::open(
            &layout.artifacts,
        )?)
        .with_storage(
            arkdeck_hoststore::SessionStore::open(&layout.state, &layout.sessions)?,
            arkdeck_hoststore::ArtifactUsage::open(&layout.artifacts, crate::host::ARTIFACT_QUOTA)?,
        )
        .with_bootstrap(&layout.bootstrap)?
        .with_jobs(arkdeck_hoststore::JobStore::open_state_root_owner(
            &layout.state,
        )?)
        .with_agent_executions(arkdeck_hoststore::AgentExecutionStore::open(
            &layout.agent_executions,
        )?)
        .with_human_actions(arkdeck_hoststore::HumanActionResources::open(
            &layout.human_actions,
        )?)
        .with_capabilities(arkdeck_hoststore::CapabilityStore::open(
            &layout.capabilities,
        )?)
        // The Job owner's root is Swift's state directory, the root a device
        // mutation proves its state continuity against.
        .with_mutation_root(layout.state.clone())
        .with_planning(
            &layout.state,
            crate::hilog_summary_analyzer::composed(
                inputs.analyzer.as_deref(),
                inputs.arktrace_descriptor.as_deref(),
                &layout.state,
            )?,
        )
        // Swift's Flash invocation owner keeps its documents beside the Job
        // state it runs through, and creates their directories at its start;
        // its post-flash alias reconciler repairs the alias of the
        // Application Support root against the host's I/O Registry, as
        // Swift's `RockchipProductUSBProbe` reads it (the maintainer's
        // decision Q1=B of 2026-09-24).
        .with_flash_invocations(arkdeck_hoststore::FlashInvocations::open(&layout.state)?)
        .with_flash_alias_reconciler(arkdeck_hoststore::FlashAliasReconciler::new(
            &layout.application_support,
            arkdeck_platform::usb_host_devices,
            crate::host::utc_now,
        ));
    // The App creates its Trace cache in its container; this Runtime reads it
    // where it is and never creates it.
    let host = match arkdeck_hoststore::TraceCacheStore::open(&layout.trace_cache) {
        Ok(cache) => host.with_trace_cache(cache),
        Err(error) => {
            omitted.push(format!(
                "Trace cache {}: {error}",
                layout.trace_cache.display()
            ));
            host
        }
    };
    // Swift's HDC host over the registry's selection. Without
    // `ARKDECK_HDC_PATH` dispatch stays refused, as Swift's does, and no
    // HDC control action is composed.
    let controls = arkdeck_hoststore::ControlActionResources::open(&layout.control_actions)?;
    let mut hdc_sha256 = None;
    let (host, managed) = match &inputs.hdc {
        None => {
            omitted.push(
                "HDC: no executable is configured (set ARKDECK_HDC_PATH); dispatch stays \
                 fail-closed"
                    .into(),
            );
            (host.with_control_actions(controls), None)
        }
        Some(configured) => {
            let registry = arkdeck_hoststore::ToolRegistryStore::open_existing(&layout.bootstrap)?;
            let selection = registered_hdc(&registry, configured, now)?;
            hdc_sha256 = Some(selection.executable_sha256.clone());
            let tool = || {
                arkdeck_platform::VerifiedTool::open(
                    &selection.executable,
                    &selection.executable_sha256,
                )
            };
            let endpoint =
                arkdeck_provider_hdc::EndpointSelection::select(inputs.server_port.as_deref())?;
            let managed = Arc::new(crate::managed_hdc::ManagedHdc::start(
                &tool()?,
                &selection.executable.to_string_lossy(),
                endpoint,
            )?);
            managed.monitor_foreground_exit()?;
            state
                .private_child("hdc-control-actions")?
                .validate_path(&layout.hdc_control_actions)?;
            let controls = controls.with_hdc(arkdeck_hoststore::HdcControlActions::open(
                &layout.hdc_control_actions,
                arkdeck_hoststore::OwnerContext::production().map_err(|error| error.message)?,
            )?);
            let dispatch =
                arkdeck_provider_hdc::ProcessDispatch::new(tool()?, inputs.server_port.as_deref());
            (
                host.with_control_actions(controls)
                    .with_managed_development_hdc(dispatch, Arc::clone(&managed)),
                Some(managed),
            )
        }
    };
    // The host's I/O Registry beside the managed server started above; no
    // reader without one.
    let host = with_trusted_usb(host, managed.is_some(), UsbRegistryRelations::system());
    // Swift's ArkForge lane beside it, over `…/Agentd/arkforge`: the one
    // generation of `arkforged` a validated bundle names, paired and proved
    // ready, or why there is none (`main.swift` 1118-1200). Its device access
    // observer and the facts' Loader observation read that directory's public
    // socket whether or not a lane runs; the facts measure the bundle's
    // daemon as Swift's `rockchipResolver` does.
    let arkforge = crate::arkforge_lane::compose(
        &layout.state,
        |key| {
            inputs
                .arkforge
                .iter()
                .find(|(name, _)| *name == key)
                .map(|(_, value)| value.clone())
        },
        hdc_sha256.as_deref(),
    );
    let host = host
        // Swift's Flash planning over that lane, the per-action host's
        // records in `…/Agentd/rockchip-runtime` when an HDC is composed.
        .with_flash_planning(arkforge.planning(&layout.state, hdc_sha256.is_some()))
        .with_flash_host_facts(
            arkdeck_hoststore::FlashHostFacts::new(
                &layout.application_support,
                arkdeck_platform::usb_host_devices,
            )
            .with_rockusb(arkforge.rockusb())
            .with_arkforge_loader(&arkforge.runtime_directory),
        )
        .with_device_access(arkdeck_provider_arkforge::DeviceAccessObserver::new(
            &arkforge.runtime_directory,
        ))
        .with_lane_plan_preview(arkforge.lane_plan_preview())
        // Swift's Loader binding coordinator (`main.swift` 1549): the same
        // root and census, ArkForge's half of the Loader observation through
        // the lane's directory, and the Runtime's records in
        // `…/Agentd/rockchip-runtime`.
        .with_loader_binding(arkdeck_hoststore::LoaderBinding::new(
            &layout.application_support,
            arkdeck_platform::usb_host_devices,
            arkdeck_hoststore::ArkForgeLoader::new(
                arkdeck_platform::usb_host_devices,
                &arkforge.runtime_directory,
            ),
        ));
    for (name, owner) in &inputs.unread {
        omitted.push(format!(
            "{owner}: {name} is set, but this Runtime has not ported that owner yet"
        ));
    }
    let ingress = if layout.overridden {
        omitted.push(
            "App ingress com.arkdeck.agentd: the account home is overridden \
             (CFFIXED_USER_HOME), so the account's Mach service is not this Runtime's"
                .into(),
        );
        None
    } else {
        Some(crate::app_ingress::Configuration::production(
            &layout.state,
        )?)
    };
    Ok(Composition {
        host,
        managed,
        arkforge,
        ingress,
        omitted,
        rockchip,
    })
}

/// One line on stdout at once: a LaunchAgent's log is block buffered.
pub(crate) fn report(line: &str) {
    let mut stdout = io::stdout().lock();
    let _ = writeln!(stdout, "{line}");
    let _ = stdout.flush();
}

#[cfg(test)]
mod tests;
