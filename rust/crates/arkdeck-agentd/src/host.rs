use arkdeck_contract::{
    DeviceObservationsResult, DeviceObservationsResultObservationsItem, WireError,
};
use arkdeck_control::{HdcStatus, HostServices};
use arkdeck_platform::{VerifiedTool, random_bytes};
use arkdeck_provider_hdc::HdcReadOnlyProvider;
use std::io;
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Default)]
pub(crate) struct ObservationState {
    pub(crate) generation: u64,
    pub(crate) snapshot: Option<DeviceObservationsResult>,
}

/// The Target observation owner's answer as the control layer's typed result.
#[cfg(any(target_os = "macos", windows))]
fn typed_observations(
    answer: Result<serde_json::Value, arkdeck_hoststore::ObservationError>,
) -> Result<DeviceObservationsResult, WireError> {
    serde_json::from_value(answer.map_err(|error| error.wire())?).map_err(|_| WireError {
        code: "internalError".into(),
        message: "observation encoding failed".into(),
        details: None,
    })
}

/// Why the Target owner adopts nothing without a registered HDC.
#[cfg(any(target_os = "macos", windows))]
pub(crate) const NO_REGISTERED_HDC: &str =
    "no registered HDC is selected: nothing was observed or dispatched, and no Target was adopted";

/// Swift's answer for a Job-owned resource when no Job owner is composed.
#[cfg(any(target_os = "macos", windows))]
fn job_owner_not_configured() -> WireError {
    WireError {
        code: "operationUnavailable".into(),
        message: "The Job owner is not configured".into(),
        details: None,
    }
}

/// The default Artifact quota, matching Swift's `ArtifactQuota()`.
#[cfg(any(target_os = "macos", windows))]
pub(crate) const ARTIFACT_QUOTA: u64 = 8 * 1024 * 1024 * 1024;

/// Explicit host capacity, fixed for this daemon. Invalid configuration must
/// not silently select a different limit or echo arbitrary environment text.
#[cfg(any(target_os = "macos", windows))]
pub(crate) fn artifact_quota_from(value: Option<std::ffi::OsString>) -> Result<u64, String> {
    let Some(value) = value else {
        return Ok(ARTIFACT_QUOTA);
    };
    value
        .to_str()
        .filter(|text| !text.is_empty() && text.bytes().all(|byte| byte.is_ascii_digit()))
        .and_then(|text| text.parse::<u64>().ok())
        .filter(|bytes| *bytes > 0 && *bytes <= i64::MAX as u64)
        .ok_or_else(|| {
            "ARKDECK_ARTIFACT_QUOTA_BYTES must be a decimal integer from 1 to 9223372036854775807; nothing was started".into()
        })
}

#[cfg(any(target_os = "macos", windows))]
pub(crate) fn configured_artifact_quota() -> Result<u64, String> {
    artifact_quota_from(std::env::var_os("ARKDECK_ARTIFACT_QUOTA_BYTES"))
}

/// The lane and per-action host are shared by direct and background Jobs.
#[cfg(any(target_os = "macos", windows))]
struct FlashRuntime {
    lane: std::sync::Arc<dyn arkdeck_provider_arkforge::FlashLane>,
    host: std::sync::Arc<dyn arkdeck_provider_arkforge::RockchipHost>,
    profile_id: String,
}

/// One Job's run, which every concurrent caller for that Job joins and a
/// cancellation reaches through the run's `cancellation`, or the cancellation
/// of a Job no run holds, which a concurrent run waits out.
#[cfg(any(target_os = "macos", windows))]
#[derive(Default)]
pub(crate) struct RunSlot {
    pub(crate) outcome: Mutex<Option<Result<serde_json::Value, WireError>>>,
    pub(crate) finished: std::sync::Condvar,
    pub(crate) cancelling: bool,
    pub(crate) cancellation: arkdeck_hoststore::RunCancellation,
}

#[cfg(any(target_os = "macos", windows))]
impl RunSlot {
    /// The holder's answer once it finished; none if the slot was poisoned.
    fn wait(&self) -> Option<Result<serde_json::Value, WireError>> {
        let mut outcome = self.outcome.lock().ok()?;
        while outcome.is_none() {
            outcome = self.finished.wait(outcome).ok()?;
        }
        outcome.clone()
    }
    pub(crate) fn finish(&self, result: &Result<serde_json::Value, WireError>) {
        if let Ok(mut outcome) = self.outcome.lock() {
            *outcome = Some(result.clone());
        }
        self.finished.notify_all();
    }
}

/// What a `job.run` of one Job meets in this owner.
#[cfg(any(target_os = "macos", windows))]
pub(crate) enum RunClaim {
    /// The slot this run now holds the Job in.
    Own(std::sync::Arc<RunSlot>),
    /// The run or cancellation already holding the Job.
    Held(std::sync::Arc<RunSlot>),
    /// A reconcile of the Job under way, which the run waits out.
    Reconciling(std::sync::Arc<RunSlot>),
}

pub struct Host {
    /// What start-up recovery set aside, in its order: a Job whose durable
    /// record this build cannot read, and the reason. `doctor` names them,
    /// as Swift's reads `engine.quarantinedJobRecords`.
    #[cfg(any(target_os = "macos", windows))]
    quarantined: std::sync::OnceLock<Vec<(String, String)>>,
    /// The staged Session entries the start kept in the active Sessions
    /// root, and why (`recover_staged_sessions`); `doctor` names them.
    #[cfg(any(target_os = "macos", windows))]
    staged_kept: std::sync::OnceLock<Vec<(String, String)>>,
    #[cfg(any(target_os = "macos", windows))]
    imports: Option<std::sync::Arc<arkdeck_hoststore::ImportUploadStore>>,
    // The owners a background agent run keeps using after its request has
    // answered are shared with it.
    #[cfg(any(target_os = "macos", windows))]
    targets: Option<std::sync::Arc<arkdeck_hoststore::TargetStore>>,
    #[cfg(any(target_os = "macos", windows))]
    artifacts: Option<std::sync::Arc<arkdeck_hoststore::ArtifactReadStore>>,
    #[cfg(any(target_os = "macos", windows))]
    jobs: Option<std::sync::Arc<arkdeck_hoststore::JobStore>>,
    /// The agent execution owner beside the Job state.
    #[cfg(any(target_os = "macos", windows))]
    agents: Option<std::sync::Arc<arkdeck_hoststore::AgentExecutionStore>>,
    #[cfg(any(target_os = "macos", windows))]
    capabilities: Option<std::sync::Arc<arkdeck_hoststore::CapabilityStore>>,
    /// The state root `job.plan` and `job.submit` plan against, and the
    /// analyzers the host composed, including a reviewed ArkTrace generation
    /// when its descriptor loaded on this host.
    #[cfg(any(target_os = "macos", windows))]
    planning: Option<(std::path::PathBuf, arkdeck_hoststore::AnalyzerProfiles)>,
    #[cfg(any(target_os = "macos", windows))]
    bootstrap: Option<crate::bootstrap_readers::BootstrapReaders>,
    pub(crate) provider: Option<HdcReadOnlyProvider>,
    #[cfg(any(target_os = "macos", windows))]
    history: Option<arkdeck_hoststore::HistoryStore>,
    #[cfg(any(target_os = "macos", windows))]
    workspace_projects: Option<std::sync::Arc<arkdeck_hoststore::WorkspaceProjectStore>>,
    /// The workspace provider composed over the registered projects, which a
    /// workspace Job plans, admits and runs through.
    #[cfg(any(target_os = "macos", windows))]
    workspace: Option<std::sync::Arc<arkdeck_hoststore::WorkspaceComposition>>,
    #[cfg(any(target_os = "macos", windows))]
    trace_cache: Option<arkdeck_hoststore::TraceCacheStore>,
    #[cfg(any(target_os = "macos", windows))]
    storage: Option<
        std::sync::Arc<(
            arkdeck_hoststore::SessionStore,
            arkdeck_hoststore::ArtifactUsage,
        )>,
    >,
    unavailable: &'static str,
    pub(crate) observations: Mutex<ObservationState>,
    #[cfg(any(target_os = "macos", windows))]
    pub(crate) running:
        std::sync::Arc<Mutex<std::collections::HashMap<String, std::sync::Arc<RunSlot>>>>,
    /// The `job.reconcile` of each Job under way, which a concurrent one of
    /// the same Job joins (Swift `jobReconciliations`).
    #[cfg(any(target_os = "macos", windows))]
    pub(crate) reconciling: Mutex<std::collections::HashMap<String, std::sync::Arc<RunSlot>>>,
    /// Swift `NSHomeDirectory()`, which Artifact redaction replaces.
    #[cfg(any(target_os = "macos", windows))]
    home: String,
    /// Where the files a device-bound Job receives land: Swift's
    /// `HDCObservationProviderAdapter` default,
    /// `FileManager.default.temporaryDirectory/arkdeck-receive`, which the
    /// receive argv, and so the plan digest, names. On Windows the account's
    /// temporary directory (`GetTempPath2`), the platform's equivalent.
    #[cfg(any(target_os = "macos", windows))]
    receive_root: std::path::PathBuf,
    #[cfg(any(target_os = "macos", windows))]
    default_mutation_root: Option<std::path::PathBuf>,
    /// Swift `HostStorageCoordinator`'s claims, held by the Session
    /// publications this process makes.
    #[cfg(any(target_os = "macos", windows))]
    claims: std::sync::Arc<arkdeck_hoststore::StorageClaims>,
    /// The isolated owner's development HDC: the executable its
    /// device-bound Jobs dispatch to, through the process dispatch every HDC
    /// plan takes, and the managed server it started, if it started one. On
    /// Windows only a registered HDC tuple's managed server is composed
    /// (`windows_hdc_gate`), and none is registered yet.
    #[cfg(any(target_os = "macos", windows))]
    hdc: Option<std::sync::Arc<crate::managed_hdc::DevelopmentHdc>>,
    /// The device sessions this daemon's control sessions hold (Swift
    /// `deviceSessionHolds`).
    #[cfg(any(target_os = "macos", windows))]
    holds: std::sync::Arc<arkdeck_hoststore::DeviceHolds>,
    /// The Runtime's Target observation owner over the development HDC.
    #[cfg(any(target_os = "macos", windows))]
    target_observations: arkdeck_hoststore::TargetObservations,
    /// Who reads the live USB relations that prove an observation's
    /// physical identity. By default nothing is read, so no observation is
    /// proved and nothing can be adopted; a composition that addresses a real
    /// device through a registered HDC it proved reads the Runtime's own
    /// (`UsbRegistryRelations`), as Swift's daemon composes
    /// `TargetUSBRelation.registeredDAYU200()`.
    #[cfg(any(target_os = "macos", windows))]
    usb: std::sync::Arc<dyn arkdeck_provider_hdc::UsbRelations + Send + Sync>,
    /// Whether `usb` is that reader of the Runtime's own, which the owner
    /// census names.
    #[cfg(any(target_os = "macos", windows))]
    usb_registry: bool,
    /// The bundled OpenHarmony code-sign helper this composition verified;
    /// without one a native deployment stays unavailable.
    #[cfg(any(target_os = "macos", windows))]
    code_sign_helper: Option<arkdeck_provider_hdc::CodeSignHelper>,
    /// The combined human-action owner over the agent executions and the
    /// union control-action owner.
    #[cfg(any(target_os = "macos", windows))]
    human_actions: Option<arkdeck_hoststore::HumanActionResources>,
    /// The union control-action owner, over the HDC control-action owner
    /// when the isolated owner starts a managed HDC server, and never over a
    /// tool-selection owner. On Windows the managed server is composed only
    /// behind a registered HDC tuple (`windows_hdc_gate`), so the union
    /// owner pages no HDC control action there yet.
    #[cfg(any(target_os = "macos", windows))]
    control_actions: Option<arkdeck_hoststore::ControlActionResources>,
    /// Swift `ProductRockchipPostFlashAliasReconciler`: the post-flash alias
    /// of the Application Support root, repaired against the one board the
    /// Runtime's USB census reads, over this host's Target store.
    #[cfg(any(target_os = "macos", windows))]
    flash_alias: Option<arkdeck_hoststore::FlashAliasReconciler>,
    /// The reads of Swift's `RuntimeDebugInvocationController`, over the
    /// invocation documents of the Job owner's state directory.
    #[cfg(any(target_os = "macos", windows))]
    flash_invocations: Option<arkdeck_hoststore::FlashInvocations>,
    /// Swift's bootloader status observer and Rockchip facts port: the
    /// binding and the alias of the Application Support root, the census,
    /// the native RockUSB identity and the live probe over this host's HDC.
    #[cfg(any(target_os = "macos", windows))]
    flash_facts: Option<std::sync::Arc<arkdeck_hoststore::FlashHostFacts>>,
    /// Test builds on Windows only (`tests/spawning`): an in-process fake HDC
    /// and the tool digest it answers as, which the Flash host facts replay
    /// probes over and the signed test daemon (`signed_daemon.rs`) composes.
    /// The production Windows daemon has no such seam: it composes an HDC
    /// only for a registered Windows HDC tuple.
    #[cfg(all(windows, test))]
    test_hdc: Option<(
        std::sync::Arc<dyn arkdeck_provider_hdc::HdcDispatch + Send + Sync>,
        String,
    )>,
    /// What a Flash `job.plan` reads beyond the Artifact and Import owners
    /// and those facts: the ArkForge provider's availability, the Rockchip
    /// dispatcher's reason and the lane's toolchain, as Swift's daemon
    /// composes them.
    #[cfg(any(target_os = "macos", windows))]
    flash_planning: Option<std::sync::Arc<arkdeck_hoststore::FlashPlanning>>,
    #[cfg(any(target_os = "macos", windows))]
    flash_runtime: Option<std::sync::Arc<FlashRuntime>>,
    /// Swift `ProductRockchipDeviceAccessObserver`: ArkForge's public socket
    /// in the lane's runtime directory, a fresh bounded session per read.
    #[cfg(any(target_os = "macos", windows))]
    device_access: Option<arkdeck_provider_arkforge::DeviceAccessObserver>,
    /// Swift's `ComposedLanePlanPreviewer`, which exists only with a composed
    /// ArkForge lane, holding only that generation's read-only preview ports.
    #[cfg(any(target_os = "macos", windows))]
    lane_plan_preview: Option<std::sync::Arc<dyn arkdeck_provider_arkforge::LanePlanPreview>>,
    /// Swift `ProductRockchipLoaderBindingCoordinator`: the binding of the
    /// Application Support root, the Runtime's records below it, the census
    /// and ArkForge's Loader observation.
    #[cfg(any(target_os = "macos", windows))]
    loader_binding: Option<arkdeck_hoststore::LoaderBinding>,
    #[cfg(all(test, any(target_os = "macos", windows)))]
    pub(crate) test_hdc_impact: Option<Box<dyn arkdeck_hoststore::ImpactSource + Send + Sync>>,
}

// Host construction and owner wiring. Included so this stays the same module.
include!("host/wiring.rs");

impl Host {
    /// A Job's reconcile (`reconcile`), unless a run of this owner holds the
    /// Job, whose status (`status`) is answered with nothing written; a
    /// concurrent reconcile of one Job joins the one under way, as Swift's
    /// callers join `jobReconciliations`.
    #[cfg(any(target_os = "macos", windows))]
    fn reconcile_once(
        &self,
        params: &serde_json::Map<String, serde_json::Value>,
        reconcile: &dyn Fn() -> Result<serde_json::Value, WireError>,
        status: &dyn Fn() -> Result<serde_json::Value, WireError>,
    ) -> Result<serde_json::Value, WireError> {
        // Swift attaches no details to any `job.reconcile` refusal.
        let uncertain = || WireError {
            code: "internalError".into(),
            message: "the Runtime could not complete the Job lifecycle request".into(),
            details: None,
        };
        let Some(job) = params.get("jobId").and_then(serde_json::Value::as_str) else {
            return reconcile();
        };
        let slot = {
            // `running`, then `reconciling`, as `claim_run` takes them: a run
            // and a reconcile never both begin on one Job.
            let running = self.running.lock().map_err(|_| uncertain())?;
            if running.get(job).is_some_and(|slot| !slot.cancelling) {
                drop(running);
                return status();
            }
            let mut reconciling = self.reconciling.lock().map_err(|_| uncertain())?;
            if let Some(slot) = reconciling.get(job).cloned() {
                drop(reconciling);
                drop(running);
                return slot.wait().unwrap_or_else(|| Err(uncertain()));
            }
            let slot = std::sync::Arc::new(RunSlot::default());
            reconciling.insert(job.to_owned(), slot.clone());
            slot
        };
        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(reconcile))
            .unwrap_or_else(|_| Err(uncertain()));
        if let Ok(mut reconciling) = self.reconciling.lock() {
            reconciling.remove(job);
        }
        slot.finish(&result);
        result
    }
}

/// Where a Windows composition's received files land: `arkdeck-receive`
/// below the account's temporary directory (`GetTempPath2`), in its
/// canonical, plain long spelling. `TEMP` may name it by an 8.3 short name
/// (an account name longer than eight characters does), and a landing is
/// inspected and published by the canonical path it resolves to, so a short
/// spelling would leave every received file unpublishable
/// (`artifactIntegrityFailed`). The receive argv names this path, and so does
/// the plan digest.
#[cfg(windows)]
fn windows_receive_root() -> std::path::PathBuf {
    let temporary = std::env::temp_dir();
    let canonical = std::fs::canonicalize(&temporary)
        .ok()
        .map(
            |path| match path.to_str().and_then(|text| text.strip_prefix(r"\\?\")) {
                Some(plain) => std::path::PathBuf::from(plain),
                None => path,
            },
        )
        .unwrap_or(temporary);
    canonical.join("arkdeck-receive")
}

/// The Job runner a Windows composition runs a Job with (`job.run`, an
/// agent execution's owned Job and `job.reconcile`'s finalization): the Job,
/// Artifact and Import owners, the analyzers the planning composed, the
/// Session publication writer, the mutation authority, the workspace
/// provider and the HDC composition, where one is composed (only over a
/// registered Windows HDC tuple's managed server).
/// One argument per owner, as the runner's own fields are: the background
/// run passes its own clones.
#[cfg(windows)]
#[allow(clippy::too_many_arguments)]
fn windows_runner<'a>(
    (state_root, analyzers): &'a (std::path::PathBuf, arkdeck_hoststore::AnalyzerProfiles),
    jobs: &'a arkdeck_hoststore::JobStore,
    artifacts: &'a arkdeck_hoststore::ArtifactReadStore,
    quota: u64,
    imports: Option<&'a arkdeck_hoststore::ImportUploadStore>,
    authority: Option<arkdeck_hoststore::MutationAuthority<'a>>,
    home: &'a str,
    sessions: Option<&'a arkdeck_hoststore::SessionPublisher<'a>>,
    cancellation: Option<&'a arkdeck_hoststore::RunCancellation>,
    workspace: Option<&'a arkdeck_hoststore::WorkspaceComposition>,
    hdc: Option<&'a arkdeck_hoststore::HdcComposition<'a>>,
) -> arkdeck_hoststore::JobRunner<'a> {
    arkdeck_hoststore::JobRunner {
        imports,
        mutation: authority.map(|authority| arkdeck_hoststore::MutationExecution {
            authority,
            state_root,
        }),
        jobs,
        artifacts,
        analyzer: Some(analyzers),
        quota,
        home,
        now: clock_now,
        precise_now: clock_precise_now,
        sessions,
        cancellation,
        after_commit: None,
        hdc,
        workspace,
    }
}

// HostServices answers. Included so this stays the same module.
include!("host/services.rs");
include!("host/services_runtime.rs");

#[cfg(any(target_os = "macos", windows))]
impl Host {
    /// Swift `targetStore.listActive()` for `doctor`, read in both modes.
    fn target_store_facts(&self) -> arkdeck_control::TargetStoreFacts {
        use arkdeck_control::TargetStoreFacts;
        match &self.targets {
            None => TargetStoreFacts::NotConfigured,
            Some(targets) => targets
                .handle("target.list", &serde_json::Map::new(), &utc_now())
                .ok()
                .and_then(|rows| rows.as_array().map(Vec::len))
                .map_or(TargetStoreFacts::Unreadable, |count| {
                    TargetStoreFacts::Adopted(count as u64)
                }),
        }
    }
}

#[cfg(any(target_os = "macos", windows))]
impl Host {
    /// The Import owner's answer with the transport provenance the caller's
    /// entry point proved: `app_owned` only for the authenticated App.
    fn imports_for(
        &self,
        method: &str,
        params: &serde_json::Map<String, serde_json::Value>,
        app_owned: bool,
    ) -> Result<serde_json::Value, WireError> {
        // Swift's `RuntimeImportControlHandler` without its Artifact or
        // Target owner refuses every Import method in these words.
        let unavailable = || WireError {
            code: "operationUnavailable".into(),
            message: "Import owner services are unavailable".into(),
            details: Some(serde_json::Map::from_iter([
                ("phase".into(), serde_json::json!("importOwner")),
                ("newDispatchCount".into(), serde_json::json!(0)),
            ])),
        };
        if [
            "artifact.import.release",
            "artifact.import.inspection",
            "artifact.import.inspect",
        ]
        .contains(&method)
        {
            return self
                .imports
                .as_ref()
                .ok_or_else(unavailable)?
                .lifecycle_resource(
                    self.artifacts.as_ref().ok_or_else(unavailable)?,
                    self.jobs.as_ref().ok_or_else(unavailable)?,
                    method,
                    params,
                    &utc_now(),
                );
        }
        if method == "artifact.import.list" {
            return self
                .imports
                .as_ref()
                .ok_or_else(unavailable)?
                .list_with_artifacts(params, self.artifacts.as_ref().ok_or_else(unavailable)?);
        }
        if method == "artifact.import.commit" {
            return self.imports.as_ref().ok_or_else(unavailable)?.commit(
                params,
                &utc_now(),
                app_owned,
                self.artifacts.as_ref().ok_or_else(unavailable)?,
                self.artifact_limit(),
                |intent| {
                    self.targets
                        .as_ref()
                        .ok_or_else(unavailable)?
                        .resolve_import_binding(intent)
                },
            );
        }
        self.imports
            .as_ref()
            .ok_or_else(unavailable)?
            .handle_resource(method, params, &utc_now(), app_owned, |intent| {
                self.targets
                    .as_ref()
                    .ok_or_else(unavailable)?
                    .resolve_import_binding(intent)
            })
    }
}

pub fn fresh_id() -> io::Result<String> {
    let mut bytes = random_bytes::<16>()?;
    bytes[6] = (bytes[6] & 15) | 0x40;
    bytes[8] = (bytes[8] & 63) | 0x80;
    let hex: String = bytes.iter().map(|b| format!("{b:02x}")).collect();
    Ok(format!(
        "{}-{}-{}-{}-{}",
        &hex[..8],
        &hex[8..12],
        &hex[12..16],
        &hex[16..20],
        &hex[20..]
    ))
}

/// Swift's `RuntimeWorkspaceToolchainPinning` over its
/// `BootstrapDevEcoToolchainRegistry`: a workspace preset's pin on its DevEco
/// toolchain, held by the preset in the registry at `bootstrap`. A refusal
/// keeps the registry's code and message, as Swift rethrows it. On Windows
/// the same registry owner over the daemon's Bootstrap registry.
#[cfg(any(target_os = "macos", windows))]
pub(crate) fn toolchain_pinning(
    bootstrap: &std::path::Path,
) -> io::Result<arkdeck_hoststore::WorkspaceToolchainPinning> {
    let acquiring = std::sync::Arc::new(arkdeck_hoststore::DevEcoRegistryStore::open_existing(
        bootstrap,
    )?);
    let releasing = std::sync::Arc::clone(&acquiring);
    Ok(arkdeck_hoststore::WorkspaceToolchainPinning {
        acquire: Box::new(move |reference, generation, preset| {
            acquiring
                .acquire(
                    reference,
                    &generation.to_string(),
                    "workspacePreset",
                    preset,
                )
                .map(|_| ())
        }),
        release: Box::new(move |reference, preset| {
            releasing.release(reference, "workspacePreset", preset)
        }),
    })
}

/// The Runtime clock the Host's owners read: the system's, or, in a Windows
/// test build whose process took one, the fixed clock a test chose
/// ([`TEST_CLOCK`]).
#[cfg(all(any(target_os = "macos", windows), not(all(windows, test))))]
use arkdeck_hoststore::{runtime_now as clock_now, runtime_precise_now as clock_precise_now};

/// Test builds on Windows only: the fixed clock (`now`, `precise now`) a
/// process of the signed test daemon (`tests/spawning/signed_daemon.rs`)
/// takes before it composes anything, so a replay of a Swift oracle reads the
/// oracle's own clock; a fixture that needs time to pass (a capability
/// lineage that expires) moves it forward between requests
/// ([`set_test_clock`]). The production daemon has no such clock.
#[cfg(all(windows, test))]
static TEST_CLOCK: std::sync::RwLock<Option<(String, String)>> = std::sync::RwLock::new(None);

/// Sets the test clock ([`TEST_CLOCK`]) every later Runtime read takes; only
/// the spawning tests call it.
#[cfg(all(windows, test))]
#[allow(dead_code)]
pub(crate) fn set_test_clock(now: &str, precise: &str) {
    *TEST_CLOCK.write().unwrap() = Some((now.to_owned(), precise.to_owned()));
}

#[cfg(all(windows, test))]
fn test_clock() -> Option<(String, String)> {
    TEST_CLOCK.read().unwrap().clone()
}

#[cfg(all(windows, test))]
fn clock_now() -> Option<String> {
    match test_clock() {
        Some((now, _)) => Some(now),
        None => arkdeck_hoststore::runtime_now(),
    }
}

#[cfg(all(windows, test))]
fn clock_precise_now() -> Option<String> {
    match test_clock() {
        Some((_, precise)) => Some(precise),
        None => arkdeck_hoststore::runtime_precise_now(),
    }
}

pub(crate) fn utc_now() -> String {
    #[cfg(all(windows, test))]
    if let Some((now, _)) = test_clock() {
        return now;
    }
    timestamp(
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs(),
    )
}

// Proleptic Gregorian conversion; the output uses the existing UTC seconds
// spelling. Monotonic generation ordering does not depend on this wall clock.
pub(crate) fn timestamp(seconds: u64) -> String {
    let days = (seconds / 86_400) as i64 + 719_468;
    let era = days / 146_097;
    let day_of_era = days - era * 146_097;
    let year_of_era =
        (day_of_era - day_of_era / 1460 + day_of_era / 36524 - day_of_era / 146096) / 365;
    let year = year_of_era + era * 400;
    let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    let month_index = (5 * day_of_year + 2) / 153;
    let day = day_of_year - (153 * month_index + 2) / 5 + 1;
    let month = month_index + if month_index < 10 { 3 } else { -9 };
    let year = year + i64::from(month <= 2);
    let time = seconds % 86_400;
    format!(
        "{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}Z",
        time / 3600,
        time / 60 % 60,
        time % 60
    )
}

daemon_unit_tests! {
    #[cfg(any(target_os = "macos", windows))]
    #[path = "doctor_owner_tests.rs"]
    mod doctor_owner_tests;
}
