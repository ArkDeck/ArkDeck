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
struct ObservationState {
    generation: u64,
    snapshot: Option<DeviceObservationsResult>,
}

/// The Target observation owner's answer as the control layer's typed result.
#[cfg(target_os = "macos")]
fn typed_observations(
    answer: Result<serde_json::Value, arkdeck_hoststore::ObservationError>,
) -> Result<DeviceObservationsResult, WireError> {
    serde_json::from_value(answer.map_err(|error| error.wire())?).map_err(|_| WireError {
        code: "internalError".into(),
        message: "observation encoding failed".into(),
        details: None,
    })
}

/// The Artifact quota the Swift daemon composes (`ArtifactQuota()`).
#[cfg(target_os = "macos")]
pub(crate) const ARTIFACT_QUOTA: u64 = 8 * 1024 * 1024 * 1024;

/// One Job's run, which every concurrent caller for that Job joins and a
/// cancellation reaches through the run's `cancellation`, or the cancellation
/// of a Job no run holds, which a concurrent run waits out.
#[cfg(target_os = "macos")]
#[derive(Default)]
struct RunSlot {
    outcome: Mutex<Option<Result<serde_json::Value, WireError>>>,
    finished: std::sync::Condvar,
    cancelling: bool,
    cancellation: arkdeck_hoststore::RunCancellation,
}

#[cfg(target_os = "macos")]
impl RunSlot {
    /// The holder's answer once it finished; none if the slot was poisoned.
    fn wait(&self) -> Option<Result<serde_json::Value, WireError>> {
        let mut outcome = self.outcome.lock().ok()?;
        while outcome.is_none() {
            outcome = self.finished.wait(outcome).ok()?;
        }
        outcome.clone()
    }
    fn finish(&self, result: &Result<serde_json::Value, WireError>) {
        if let Ok(mut outcome) = self.outcome.lock() {
            *outcome = Some(result.clone());
        }
        self.finished.notify_all();
    }
}

pub struct Host {
    /// What start-up recovery set aside, in its order: a Job whose durable
    /// record this build cannot read, and the reason. `doctor` names them,
    /// as Swift's reads `engine.quarantinedJobRecords`.
    #[cfg(target_os = "macos")]
    quarantined: std::sync::OnceLock<Vec<(String, String)>>,
    #[cfg(target_os = "macos")]
    imports: Option<std::sync::Arc<arkdeck_hoststore::ImportUploadStore>>,
    // The owners a background agent run keeps using after its request has
    // answered are shared with it.
    #[cfg(target_os = "macos")]
    targets: Option<std::sync::Arc<arkdeck_hoststore::TargetStore>>,
    #[cfg(target_os = "macos")]
    artifacts: Option<std::sync::Arc<arkdeck_hoststore::ArtifactReadStore>>,
    #[cfg(target_os = "macos")]
    jobs: Option<std::sync::Arc<arkdeck_hoststore::JobStore>>,
    /// The agent execution owner beside the Job state.
    #[cfg(target_os = "macos")]
    agents: Option<std::sync::Arc<arkdeck_hoststore::AgentExecutionStore>>,
    #[cfg(target_os = "macos")]
    capabilities: Option<std::sync::Arc<arkdeck_hoststore::CapabilityStore>>,
    #[cfg(target_os = "macos")]
    planning: Option<(
        std::path::PathBuf,
        Option<arkdeck_hoststore::AnalyzerProfile>,
    )>,
    #[cfg(target_os = "macos")]
    bootstrap: Option<crate::bootstrap_readers::BootstrapReaders>,
    provider: Option<HdcReadOnlyProvider>,
    #[cfg(target_os = "macos")]
    history: Option<arkdeck_hoststore::HistoryStore>,
    #[cfg(target_os = "macos")]
    workspace_projects: Option<arkdeck_hoststore::WorkspaceProjectStore>,
    #[cfg(target_os = "macos")]
    trace_cache: Option<arkdeck_hoststore::TraceCacheStore>,
    #[cfg(target_os = "macos")]
    storage: Option<
        std::sync::Arc<(
            arkdeck_hoststore::SessionStore,
            arkdeck_hoststore::ArtifactUsage,
        )>,
    >,
    unavailable: &'static str,
    observations: Mutex<ObservationState>,
    #[cfg(target_os = "macos")]
    running: std::sync::Arc<Mutex<std::collections::HashMap<String, std::sync::Arc<RunSlot>>>>,
    /// The `job.reconcile` of each Job under way, which a concurrent one of
    /// the same Job joins (Swift `jobReconciliations`).
    #[cfg(target_os = "macos")]
    reconciling: Mutex<std::collections::HashMap<String, std::sync::Arc<RunSlot>>>,
    /// Swift `NSHomeDirectory()`, which Artifact redaction replaces.
    #[cfg(target_os = "macos")]
    home: String,
    /// Where the files a device-bound Job receives land: Swift's
    /// `HDCObservationProviderAdapter` default,
    /// `FileManager.default.temporaryDirectory/arkdeck-receive`, which the
    /// receive argv, and so the plan digest, names.
    #[cfg(target_os = "macos")]
    receive_root: std::path::PathBuf,
    #[cfg(target_os = "macos")]
    default_mutation_root: Option<std::path::PathBuf>,
    /// Swift `HostStorageCoordinator`'s claims, held by the Session
    /// publications this process makes.
    #[cfg(target_os = "macos")]
    claims: std::sync::Arc<arkdeck_hoststore::StorageClaims>,
    /// The isolated owner's development HDC: the executable its
    /// device-bound Jobs dispatch to, through the process dispatch every HDC
    /// plan takes, and the managed server it started, if it started one.
    #[cfg(target_os = "macos")]
    hdc: Option<std::sync::Arc<crate::managed_hdc::DevelopmentHdc>>,
    /// The device sessions this daemon's control sessions hold (Swift
    /// `deviceSessionHolds`).
    #[cfg(target_os = "macos")]
    holds: std::sync::Arc<arkdeck_hoststore::DeviceHolds>,
    /// The Runtime's Target observation owner over the development HDC.
    #[cfg(target_os = "macos")]
    target_observations: arkdeck_hoststore::TargetObservations,
    /// Who reads the live USB relations that prove an observation's
    /// physical identity. By default nothing is read, until the ArkForge
    /// lane's reader lands, so no observation is proved and nothing can be
    /// adopted.
    #[cfg(target_os = "macos")]
    usb: std::sync::Arc<dyn arkdeck_provider_hdc::UsbRelations + Send + Sync>,
    /// The bundled OpenHarmony code-sign helper this composition verified;
    /// without one a native deployment stays unavailable.
    #[cfg(target_os = "macos")]
    code_sign_helper: Option<arkdeck_provider_hdc::CodeSignHelper>,
    /// The combined human-action owner over the agent executions and the
    /// union control-action owner.
    #[cfg(target_os = "macos")]
    human_actions: Option<arkdeck_hoststore::HumanActionResources>,
    /// The union control-action owner, over the HDC control-action owner
    /// when the isolated owner starts a managed HDC server, and never over a
    /// tool-selection owner.
    #[cfg(target_os = "macos")]
    control_actions: Option<arkdeck_hoststore::ControlActionResources>,
    #[cfg(all(test, target_os = "macos"))]
    pub(crate) test_hdc_impact: Option<Box<dyn arkdeck_hoststore::ImpactSource + Send + Sync>>,
}

impl Host {
    #[cfg(target_os = "macos")]
    pub fn with_imports(mut self, imports: arkdeck_hoststore::ImportUploadStore) -> Self {
        self.imports = Some(std::sync::Arc::new(imports));
        self
    }

    #[cfg(target_os = "macos")]
    pub fn with_targets(mut self, targets: arkdeck_hoststore::TargetStore) -> Self {
        self.targets = Some(std::sync::Arc::new(targets));
        self
    }
    #[cfg(target_os = "macos")]
    pub fn with_jobs(mut self, jobs: arkdeck_hoststore::JobStore) -> Self {
        self.jobs = Some(std::sync::Arc::new(jobs));
        self
    }
    /// Swift `recoverActiveJobs()` at the daemon's start, before it serves:
    /// every active Job of this owner reopened, its unresolved intents parked
    /// and nothing dispatched, each use its capability store settles
    /// re-asserted. None without a Job owner.
    #[cfg(target_os = "macos")]
    pub fn recover_active_jobs(
        &self,
    ) -> Result<Option<arkdeck_hoststore::RecoveredJobs>, arkdeck_hoststore::RecoveryError> {
        let Some(jobs) = &self.jobs else {
            return Ok(None);
        };
        let recovered = arkdeck_hoststore::recover_active_jobs(
            jobs,
            self.capabilities.as_deref(),
            arkdeck_hoststore::runtime_now,
        )?;
        // Recovery answered which records it could not read; `doctor` says so
        // rather than reading them again.
        let _ = self.quarantined.set(recovered.quarantined.clone());
        Ok(Some(recovered))
    }
    /// `agent.run` and `agent.status` advance and read this owner's
    /// executions, which own Jobs of the Job owner.
    #[cfg(target_os = "macos")]
    pub fn with_agent_executions(mut self, agents: arkdeck_hoststore::AgentExecutionStore) -> Self {
        self.agents = Some(std::sync::Arc::new(agents));
        self
    }
    /// `capability.list` and `capability.inspect` read this capability store.
    #[cfg(target_os = "macos")]
    pub fn with_capabilities(mut self, capabilities: arkdeck_hoststore::CapabilityStore) -> Self {
        self.capabilities = Some(std::sync::Arc::new(capabilities));
        self
    }
    /// `job.plan` reads the Artifact owner, the configured analyzer and the
    /// state root's Runtime debug attempt permits.
    #[cfg(target_os = "macos")]
    pub fn with_planning(
        mut self,
        state_root: &std::path::Path,
        analyzer: Option<arkdeck_hoststore::AnalyzerProfile>,
    ) -> Self {
        self.planning = Some((state_root.to_owned(), analyzer));
        self
    }
    #[cfg(target_os = "macos")]
    pub fn with_artifacts(mut self, artifacts: arkdeck_hoststore::ArtifactReadStore) -> Self {
        self.artifacts = Some(std::sync::Arc::new(artifacts));
        self
    }
    /// Swift's daemon startup `collectGarbage`: the expired Artifacts this
    /// host's owners may reclaim, reclaimed now, or why nothing more was;
    /// `None` without a Job and an Artifact owner.
    #[cfg(target_os = "macos")]
    pub fn collect_expired_artifacts(&self) -> Option<Result<Vec<String>, String>> {
        let (jobs, artifacts) = (self.jobs.as_ref()?, self.artifacts.as_ref()?);
        Some(match arkdeck_hoststore::runtime_now() {
            Some(now) => arkdeck_hoststore::collect_expired_artifacts(jobs, artifacts, &now),
            None => Err("the Runtime clock is unavailable".into()),
        })
    }
    /// Device-bound Jobs plan against the Target owner and run through this
    /// development HDC; without one no HDC provider is registered.
    #[cfg(target_os = "macos")]
    pub fn with_development_hdc(
        mut self,
        dispatch: Option<arkdeck_provider_hdc::ProcessDispatch>,
    ) -> Self {
        self.hdc = dispatch.map(|dispatch| {
            std::sync::Arc::new(crate::managed_hdc::DevelopmentHdc::new(dispatch, None))
        });
        self
    }
    /// The development HDC with the managed server it addresses: its status
    /// answers `runtime.hdc.status`, its startup facts the tool leg of
    /// `target.availability`, and no plan is dispatched once it is not the
    /// server launched.
    #[cfg(target_os = "macos")]
    pub fn with_managed_development_hdc(
        mut self,
        dispatch: arkdeck_provider_hdc::ProcessDispatch,
        managed: std::sync::Arc<crate::managed_hdc::ManagedHdc>,
    ) -> Self {
        self.hdc = Some(std::sync::Arc::new(
            crate::managed_hdc::DevelopmentHdc::new(dispatch, Some(managed)),
        ));
        self
    }
    /// The managed server this composition started, if it started one.
    #[cfg(target_os = "macos")]
    fn managed_hdc(&self) -> Option<&crate::managed_hdc::ManagedHdc> {
        self.hdc.as_ref().and_then(|hdc| hdc.managed())
    }
    /// The USB relations the Target observation owner reads: a test's, or
    /// the development source the isolated owner names.
    #[cfg(target_os = "macos")]
    pub fn with_usb_relations(
        mut self,
        usb: std::sync::Arc<dyn arkdeck_provider_hdc::UsbRelations + Send + Sync>,
    ) -> Self {
        self.usb = usb;
        self
    }
    /// Runs `run` over the Target observation owner's sources — the
    /// development HDC, the USB relations, the Target store and the clock —
    /// when this composition has them.
    #[cfg(target_os = "macos")]
    fn observe<T>(&self, run: impl FnOnce(&arkdeck_hoststore::Sources<'_>) -> T) -> Option<T> {
        let (dispatch, targets) = (self.hdc.as_ref()?, self.targets.as_ref()?);
        Some(run(&arkdeck_hoststore::Sources {
            dispatch: &**dispatch,
            relations: &*self.usb,
            targets,
            now: &utc_now,
        }))
    }
    /// The Target observation owner an execution that names no target
    /// observes through, when this composition has its sources.
    #[cfg(target_os = "macos")]
    fn observing(&self) -> Option<arkdeck_hoststore::Observing<'_>> {
        let (dispatch, targets) = (self.hdc.as_ref()?, self.targets.as_ref()?);
        Some(arkdeck_hoststore::Observing {
            owner: &self.target_observations,
            sources: arkdeck_hoststore::Sources {
                dispatch: &**dispatch,
                relations: &*self.usb,
                targets,
                now: &utc_now,
            },
        })
    }
    /// `human-action.list` and `human-action.show` read the physical
    /// assistance this owner's agent executions ask for and the impact
    /// approvals of the union control-action owner's actions.
    #[cfg(target_os = "macos")]
    pub fn with_human_actions(
        mut self,
        resources: arkdeck_hoststore::HumanActionResources,
    ) -> Self {
        self.human_actions = Some(resources);
        self
    }
    /// `control-action.list`, `.show` and `.reconcile` page and look up the
    /// control actions of this union owner; `runtime.hdc.impact-preview`
    /// previews and `runtime.hdc.restart` requests an impact approval through
    /// its HDC control-action owner, if it has one.
    #[cfg(target_os = "macos")]
    pub fn with_control_actions(
        mut self,
        resources: arkdeck_hoststore::ControlActionResources,
    ) -> Self {
        self.control_actions = Some(resources);
        self
    }
    #[cfg(target_os = "macos")]
    fn with_hdc_impact<R>(
        &self,
        run: impl FnOnce(Option<&dyn arkdeck_hoststore::ImpactSource>) -> R,
    ) -> R {
        #[cfg(test)]
        if let Some(source) = &self.test_hdc_impact {
            return run(Some(&**source));
        }
        let (Some(hdc), Some(targets), Some(jobs)) = (&self.hdc, &self.targets, &self.jobs) else {
            return run(None);
        };
        let Some(managed) = hdc.managed() else {
            return run(None);
        };
        // Swift `host.controlImpactSource`: the managed server's executable,
        // endpoint and launch; the Job owner, the Target store and the
        // Target observation owner over this daemon's development HDC, whose
        // gate refuses any command once the server is not the one launched.
        let launch = || managed.active_launch();
        let identity = arkdeck_provider_hdc::CommandlessIdentity::default();
        let current_jobs = || jobs.current_jobs().map_err(|error| error.message);
        let target_records = || targets.records().map_err(|error| error.message);
        let devices = || {
            let sources = arkdeck_hoststore::Sources {
                dispatch: &**hdc,
                relations: &*self.usb,
                targets,
                now: &utc_now,
            };
            self.target_observations
                .snapshot(&sources, None)
                .map(|snapshot| arkdeck_hoststore::DeviceReading {
                    generation: snapshot.generation,
                    rows: snapshot
                        .observations
                        .iter()
                        .map(|observation| arkdeck_hoststore::DeviceRow {
                            observation_id: observation.observation_id.clone(),
                            state: observation.candidate.state.clone(),
                            relation: observation.relation.clone(),
                        })
                        .collect(),
                })
                .map_err(|error| error.wire().message)
        };
        let source = arkdeck_hoststore::ManagedServerImpact {
            executable: managed.executable().clone(),
            endpoint: managed.endpoint().to_owned(),
            launch: &launch,
            supervisor: Some(managed),
            identity: &identity,
            signature: &arkdeck_provider_hdc::NativeSignature,
            verifier: &arkdeck_provider_hdc::SystemManagedProcess,
            dispatch: &**hdc,
            jobs: &current_jobs,
            targets: &target_records,
            devices: &devices,
        };
        run(Some(&source))
    }

    #[cfg(target_os = "macos")]
    fn hdc(&self) -> Option<arkdeck_hoststore::HdcComposition<'_>> {
        let (dispatch, targets) = (self.hdc.as_ref()?, self.targets.as_ref()?);
        Some(arkdeck_hoststore::HdcComposition {
            targets,
            dispatch: &**dispatch,
            receive_root: Some(&self.receive_root),
            tool_sha256: dispatch.tool_sha256(),
            now: arkdeck_hoststore::runtime_now,
            code_sign_helper: self.code_sign_helper.as_ref(),
        })
    }
    /// The bundled code-sign helper a native deployment stages, verified by
    /// the composition that found it (`code_sign_helper.rs`). With one,
    /// `deploy.native-library.app-owned@1` is available and planned; without
    /// one it stays unavailable, as Swift's composition leaves it.
    #[cfg(target_os = "macos")]
    pub fn with_code_sign_helper(mut self, helper: arkdeck_provider_hdc::CodeSignHelper) -> Self {
        self.code_sign_helper = Some(helper);
        self
    }
    /// The state root a device mutation proves its continuity against, in
    /// place of the installed Runtime's, which an isolated development owner
    /// is not: its own Job state, taken only as `development_mutation::admit`
    /// allows.
    #[cfg(target_os = "macos")]
    pub fn with_development_mutation_root(mut self, root: std::path::PathBuf) -> Self {
        self.default_mutation_root = Some(root);
        self
    }
    /// What a device mutation is authorized from: the capability store and
    /// this daemon's device sessions. Without a store no mutation is admitted.
    #[cfg(target_os = "macos")]
    fn authority(&self) -> Option<arkdeck_hoststore::MutationAuthority<'_>> {
        Some(arkdeck_hoststore::MutationAuthority {
            default_root: self.default_mutation_root.as_deref()?,
            sessions: self.storage.as_ref().map(|storage| &storage.0),
            capabilities: self.capabilities.as_ref()?,
            holds: &self.holds,
        })
    }
    /// Swift `startJob`: the Job an execution has just come to own runs in
    /// the background, in the slot every `job.run` and `job.cancel` of it
    /// meets, registered before the owning request answers; its end is
    /// reported to the execution (Swift `finishJob`).
    #[cfg(target_os = "macos")]
    fn start_agent_run(&self, start: arkdeck_hoststore::AgentStart) {
        let (Some(agents), Some(jobs), Some(artifacts)) = (
            self.agents.clone(),
            self.jobs.clone(),
            self.artifacts.clone(),
        ) else {
            return;
        };
        let (targets, dispatch, storage, claims, running, home) = (
            self.targets.clone(),
            self.hdc.clone(),
            self.storage.clone(),
            self.claims.clone(),
            self.running.clone(),
            self.home.clone(),
        );
        let imports = self.imports.clone();
        let receive_root = self.receive_root.clone();
        let helper = self.code_sign_helper.clone();
        let default_mutation_root = self.default_mutation_root.clone();
        let capabilities = self.capabilities.clone();
        let holds = self.holds.clone();
        let state_root = self.planning.as_ref().map(|(root, _)| root.clone());
        let slot = std::sync::Arc::new(RunSlot::default());
        match running.lock() {
            Ok(mut runs) if !runs.contains_key(&start.job) => {
                runs.insert(start.job.clone(), slot.clone());
            }
            _ => return,
        }
        std::thread::spawn(move || {
            let probe = arkdeck_hoststore::SystemStorageProbe;
            let publisher = storage
                .as_ref()
                .map(|storage| arkdeck_hoststore::SessionPublisher {
                    sessions: &storage.0,
                    claims: &claims,
                    probe: &probe,
                });
            let hdc = match (&dispatch, &targets) {
                (Some(dispatch), Some(targets)) => Some(arkdeck_hoststore::HdcComposition {
                    targets,
                    dispatch: &**dispatch,
                    receive_root: Some(&receive_root),
                    tool_sha256: dispatch.tool_sha256(),
                    now: arkdeck_hoststore::runtime_now,
                    code_sign_helper: helper.as_ref(),
                }),
                _ => None,
            };
            let params =
                serde_json::Map::from_iter([("jobId".into(), serde_json::json!(start.job))]);
            let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                arkdeck_hoststore::JobRunner {
                    imports: imports.as_deref(),
                    mutation: capabilities
                        .as_deref()
                        .zip(state_root.as_deref())
                        .zip(default_mutation_root.as_deref())
                        .map(|((capabilities, state_root), default_root)| {
                            arkdeck_hoststore::MutationExecution {
                                authority: arkdeck_hoststore::MutationAuthority {
                                    default_root,
                                    sessions: storage.as_ref().map(|storage| &storage.0),
                                    capabilities,
                                    holds: &holds,
                                },
                                state_root,
                            }
                        }),
                    jobs: &jobs,
                    artifacts: &artifacts,
                    analyzer: None,
                    quota: ARTIFACT_QUOTA,
                    home: &home,
                    now: arkdeck_hoststore::runtime_now,
                    precise_now: arkdeck_hoststore::runtime_precise_now,
                    sessions: publisher.as_ref(),
                    cancellation: Some(&slot.cancellation),
                    after_commit: None,
                    hdc: hdc.as_ref(),
                }
                .handle(&params)
                .map_err(|refusal| WireError {
                    code: refusal.code.into(),
                    message: refusal.message,
                    details: Some(refusal.details),
                })
            }))
            .unwrap_or_else(|_| {
                Err(WireError {
                    code: "internalError".into(),
                    message: "the Runtime could not complete the Job lifecycle request".into(),
                    details: Some(serde_json::Map::new()),
                })
            });
            slot.cancellation.end();
            slot.finish(&result);
            if let Ok(mut runs) = running.lock() {
                runs.remove(&start.job);
            }
            agents.finish(&start, &jobs);
        });
    }
    #[cfg(target_os = "macos")]
    fn require_artifact_job(&self, job_id: &str) -> Result<(), WireError> {
        self.jobs
            .as_ref()
            .ok_or_else(|| WireError {
                code: "operationUnavailable".into(),
                message: "The Job owner is not configured".into(),
                details: None,
            })?
            .read_snapshot(job_id)
            .map(|_| ())
    }
    #[cfg(target_os = "macos")]
    pub fn with_trace_cache(mut self, cache: arkdeck_hoststore::TraceCacheStore) -> Self {
        self.trace_cache = Some(cache);
        self
    }
    #[cfg(target_os = "macos")]
    pub fn with_bootstrap(mut self, root: &std::path::Path) -> io::Result<Self> {
        self.bootstrap = Some(crate::bootstrap_readers::BootstrapReaders::open_existing(
            root,
        )?);
        Ok(self)
    }

    #[cfg(target_os = "macos")]
    pub fn with_storage(
        mut self,
        sessions: arkdeck_hoststore::SessionStore,
        artifacts: arkdeck_hoststore::ArtifactUsage,
    ) -> Self {
        self.storage = Some(std::sync::Arc::new((sessions, artifacts)));
        self
    }
    #[cfg(target_os = "macos")]
    pub fn with_workspace_projects(
        mut self,
        store: arkdeck_hoststore::WorkspaceProjectStore,
    ) -> Self {
        self.workspace_projects = Some(store);
        self
    }
    #[cfg(target_os = "macos")]
    pub fn with_history(mut self, history: arkdeck_hoststore::HistoryStore) -> Self {
        self.history = Some(history);
        self
    }

    pub fn from_environment() -> Self {
        let path = std::env::var_os("ARKDECK_HDC_PATH");
        let digest = std::env::var("ARKDECK_HDC_SHA256").ok();
        let (provider, unavailable) = match (path, digest) {
            (None, None) => (None, "hdc.notConfigured"),
            (Some(path), Some(digest)) => match VerifiedTool::open(path, &digest) {
                Ok(tool) => match HdcReadOnlyProvider::new(tool) {
                    Ok(provider) => (Some(provider), ""),
                    Err(_) => (None, "hdc.platformEvidenceUnavailable"),
                },
                Err(_) => (None, "hdc.toolIdentityUnavailable"),
            },
            _ => (None, "hdc.toolConfigurationIncomplete"),
        };
        Self {
            #[cfg(target_os = "macos")]
            quarantined: std::sync::OnceLock::new(),
            #[cfg(target_os = "macos")]
            imports: None,
            #[cfg(target_os = "macos")]
            targets: None,
            #[cfg(target_os = "macos")]
            artifacts: None,
            #[cfg(target_os = "macos")]
            jobs: None,
            #[cfg(target_os = "macos")]
            capabilities: None,
            #[cfg(target_os = "macos")]
            planning: None,
            #[cfg(target_os = "macos")]
            bootstrap: None,
            provider,
            #[cfg(target_os = "macos")]
            history: None,
            #[cfg(target_os = "macos")]
            workspace_projects: None,
            #[cfg(target_os = "macos")]
            trace_cache: None,
            #[cfg(target_os = "macos")]
            storage: None,
            unavailable,
            observations: Mutex::new(ObservationState::default()),
            #[cfg(target_os = "macos")]
            running: Default::default(),
            #[cfg(target_os = "macos")]
            reconciling: Default::default(),
            #[cfg(target_os = "macos")]
            home: arkdeck_platform::runtime_home().unwrap_or_default(),
            #[cfg(target_os = "macos")]
            receive_root: arkdeck_platform::foundation_temporary_directory()
                .join("arkdeck-receive"),
            #[cfg(target_os = "macos")]
            default_mutation_root: arkdeck_platform::runtime_home()
                .map(std::path::PathBuf::from)
                .filter(|home| home.is_absolute())
                .map(|home| home.join("Library/Application Support/ArkDeck/Agentd")),
            #[cfg(target_os = "macos")]
            claims: Default::default(),
            #[cfg(target_os = "macos")]
            hdc: None,
            #[cfg(target_os = "macos")]
            agents: None,
            #[cfg(target_os = "macos")]
            holds: Default::default(),
            #[cfg(target_os = "macos")]
            target_observations: Default::default(),
            #[cfg(target_os = "macos")]
            usb: std::sync::Arc::new(arkdeck_provider_hdc::NoUsbRelations),
            #[cfg(target_os = "macos")]
            code_sign_helper: None,
            #[cfg(target_os = "macos")]
            human_actions: None,
            #[cfg(target_os = "macos")]
            control_actions: None,
            #[cfg(all(test, target_os = "macos"))]
            test_hdc_impact: None,
        }
    }
}

impl HostServices for Host {
    #[cfg(target_os = "macos")]
    fn operation_availability(
        &self,
        reference: &str,
        provider: &str,
    ) -> Option<Vec<(&'static str, String)>> {
        arkdeck_hoststore::operation_unavailability(
            reference,
            provider,
            &arkdeck_hoststore::OperationAvailabilityContext {
                planning_owner: self.planning.is_some(),
                job_owner: self.jobs.is_some(),
                artifacts: self.artifacts.is_some(),
                analyzer: self
                    .planning
                    .as_ref()
                    .and_then(|(_, analyzer)| analyzer.as_ref()),
                hdc_registered: self.hdc.is_some() && self.targets.is_some(),
                mutation_owner: self
                    .authority()
                    .zip(self.jobs.as_deref())
                    .is_some_and(|(authority, jobs)| authority.require_state(jobs).is_ok()),
                code_sign_helper: self.code_sign_helper.is_some(),
                hdc_tool_current: if provider == "hdc"
                    && [
                        "observe.device@1",
                        "capture.diagnostics@1",
                        "input.tap@1",
                        "input.long-press@1",
                        "input.swipe@1",
                        "port-forward.create@1",
                        "port-forward.remove@1",
                        "debug.hap@1",
                        "capture.screen-sequence@1",
                        "deploy.native-library.app-owned@1",
                    ]
                    .contains(&reference)
                {
                    self.hdc
                        .as_ref()
                        .is_some_and(|dispatch| dispatch.tool_identity_current())
                } else {
                    false
                },
            },
        )
    }

    #[cfg(target_os = "macos")]
    fn import_resource(
        &self,
        method: &str,
        params: &serde_json::Map<String, serde_json::Value>,
    ) -> Result<serde_json::Value, WireError> {
        let unavailable = || WireError {
            code: "operationUnavailable".into(),
            message: "Import requires the Runtime Target owner and publication services".into(),
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
                false,
                self.artifacts.as_ref().ok_or_else(unavailable)?,
                ARTIFACT_QUOTA,
                |intent| {
                    self.targets
                        .as_ref()
                        .ok_or_else(unavailable)?
                        .resolve_import_binding(intent)
                },
            );
        }
        // Local control clients never inherit the App's trusted transport provenance.
        self.imports
            .as_ref()
            .ok_or_else(unavailable)?
            .handle_resource(method, params, &utc_now(), false, |intent| {
                self.targets
                    .as_ref()
                    .ok_or_else(unavailable)?
                    .resolve_import_binding(intent)
            })
    }

    #[cfg(target_os = "macos")]
    fn target_resource(
        &self,
        method: &str,
        params: &serde_json::Map<String, serde_json::Value>,
    ) -> Result<serde_json::Value, WireError> {
        self.targets
            .as_ref()
            .ok_or_else(|| WireError {
                code: "internalError".into(),
                message: "Target owner is not configured".into(),
                details: None,
            })?
            .handle(method, params, &utc_now())
    }
    #[cfg(target_os = "macos")]
    fn candidate_display_name(
        &self,
        method: &str,
        params: &serde_json::Map<String, serde_json::Value>,
    ) -> Result<serde_json::Value, WireError> {
        let fail = |code: &str, message: &str| WireError {
            code: code.into(),
            message: message.into(),
            details: Some(serde_json::Map::from_iter([
                (
                    "phase".into(),
                    serde_json::json!("candidateDisplayNameOwner"),
                ),
                ("newDispatchCount".into(), serde_json::json!(0)),
            ])),
        };
        let targets = self
            .targets
            .as_ref()
            .ok_or_else(|| fail("internalError", "Target owner is not configured"))?;
        let set = method == "device.display-name.set";
        let keys: &[&str] = if set {
            &[
                "candidate",
                "observationId",
                "observationGeneration",
                "name",
            ]
        } else {
            &["candidate", "observationId", "observationGeneration"]
        };
        if params.len() != keys.len()
            || keys
                .iter()
                .any(|k| !params.get(*k).is_some_and(serde_json::Value::is_string))
        {
            return Err(fail(
                "invalidParams",
                "Candidate name requires exact typed parameters",
            ));
        }
        let generation_text = params["observationGeneration"].as_str().unwrap();
        let generation = generation_text
            .parse::<u64>()
            .ok()
            .filter(|n| (1..=i64::MAX as u64).contains(n) && n.to_string() == generation_text)
            .ok_or_else(|| {
                fail(
                    "invalidInput",
                    "Observation generation must be canonical and positive",
                )
            })?;
        let reference = arkdeck_hoststore::ObservationReference {
            candidate: params["candidate"].as_str().unwrap().into(),
            observation_id: params["observationId"].as_str().unwrap().into(),
            generation,
        };
        let mut state = self
            .observations
            .lock()
            .map_err(|_| fail("recordUnreadable", "Observation state is unavailable"))?;
        let snapshot = state
            .snapshot
            .as_ref()
            .ok_or_else(|| fail("resourceConflict", "No current observation snapshot exists"))?;
        let active: Vec<_> = snapshot
            .observations
            .iter()
            .map(|row| arkdeck_hoststore::ObservationReference {
                candidate: row.candidate_key.clone(),
                observation_id: row.observation_id.clone(),
                generation: state.generation,
            })
            .collect();
        let result = targets.mutate_candidate(
            &reference,
            &active,
            params.get("name").and_then(serde_json::Value::as_str),
            &utc_now(),
        );
        match result {
            Ok(value) => {
                let next = generation + 1;
                state.generation = next;
                let snapshot = state.snapshot.as_mut().expect("retained snapshot");
                snapshot.snapshot_generation = next.to_string();
                for row in &mut snapshot.observations {
                    if row.adopted_target_id.is_none() {
                        row.display_name_generation = next.to_string();
                    }
                    if row.observation_id == reference.observation_id {
                        row.display_name = value["name"].as_str().map(str::to_owned);
                    }
                }
                Ok(value)
            }
            Err(error) => {
                if error.code == "outcomeUnknown" {
                    state.snapshot = None;
                }
                Err(error)
            }
        }
    }

    #[cfg(target_os = "macos")]
    fn artifact_resource(
        &self,
        method: &str,
        params: &serde_json::Map<String, serde_json::Value>,
    ) -> Result<serde_json::Value, WireError> {
        let artifacts = self.artifacts.as_ref().ok_or_else(|| WireError {
            code: "operationUnavailable".into(),
            message: "Artifact owner is not configured".into(),
            details: Some(serde_json::Map::from_iter([
                ("phase".into(), serde_json::json!("artifactOwner")),
                ("newDispatchCount".into(), serde_json::json!(0)),
            ])),
        })?;
        if params
            .get("owner")
            .and_then(|v| v.get("kind"))
            .and_then(serde_json::Value::as_str)
            == Some("import")
        {
            let imports = self.imports.as_ref().ok_or_else(|| WireError {
                code: "operationUnavailable".into(),
                message: "Import owner is unavailable".into(),
                details: None,
            })?;
            let jobs = self.jobs.as_ref().ok_or_else(|| WireError {
                code: "operationUnavailable".into(),
                message: "Artifact snapshot storage is unavailable".into(),
                details: None,
            })?;
            return imports.artifact_resource(
                artifacts,
                method,
                params,
                &jobs.snapshot_directory(),
            );
        }
        if method == "artifact.list" {
            // The pages are kept in the Job owner's snapshot directory, never
            // in the Artifact root, whose every entry the quota and Trace
            // census read.
            let jobs = self.jobs.as_ref().ok_or_else(|| WireError {
                code: "operationUnavailable".into(),
                message: "Artifact Job owner is unavailable".into(),
                details: Some(serde_json::Map::from_iter([
                    ("phase".into(), serde_json::json!("artifactOwner")),
                    ("newDispatchCount".into(), serde_json::json!(0)),
                ])),
            })?;
            return artifacts.handle_list(params, &jobs.snapshot_directory(), |job| {
                self.require_artifact_job(job)
            });
        }
        artifacts.handle_resource(method, params, |job| self.require_artifact_job(job))
    }

    /// `agent.run`, `agent.status`, `agent.list` and `agent.abandon`, as the
    /// Swift daemon's `agentExecutionRequest` answers them: the execution
    /// advanced, read, listed or abandoned by its owner, its newly owned Job
    /// started in the background, then the Job projected over an execution's
    /// own answer.
    #[cfg(target_os = "macos")]
    fn agent_execution(
        &self,
        method: &str,
        params: &serde_json::Map<String, serde_json::Value>,
    ) -> Result<serde_json::Value, WireError> {
        // Swift's handlers look the resume reference up in the combined
        // human-action owner first: a control action's impact approval is
        // answered there, never by the agent execution owner.
        if matches!(method, "agent.resume" | "human-action.resume")
            && let (Some(agents), Some(resources), Some(controls)) =
                (&self.agents, &self.human_actions, &self.control_actions)
            && let Some(answer) = resources.resume_control_action(method, params, agents, controls)
        {
            return answer;
        }
        let (
            Some(agents),
            Some((state_root, analyzer)),
            Some(jobs),
            Some(artifacts),
            Some(targets),
        ) = (
            &self.agents,
            &self.planning,
            &self.jobs,
            &self.artifacts,
            &self.targets,
        )
        else {
            return Err(WireError {
                code: "operationUnavailable".into(),
                message: "AgentExecution owner is unavailable".into(),
                details: Some(serde_json::Map::from_iter([
                    ("phase".into(), serde_json::json!("preAdmission")),
                    ("newDispatchCount".into(), serde_json::json!(0)),
                ])),
            });
        };
        let hdc = self.hdc();
        let admitter = arkdeck_hoststore::JobAdmitter {
            planner: arkdeck_hoststore::JobPlanner {
                imports: self.imports.as_deref(),
                artifacts: Some(&**artifacts),
                analyzer: analyzer.as_ref(),
                state_root,
                hdc: hdc.as_ref(),
            },
            jobs,
            now: arkdeck_hoststore::runtime_now,
            authority: self.authority(),
        };
        let engine = arkdeck_hoststore::AgentEngine {
            targets,
            jobs,
            admitter: &admitter,
            now: arkdeck_hoststore::runtime_precise_now,
            observations: self.observing(),
        };
        let answer = agents
            .advance(method, params, &engine)
            .map_err(|mut error| {
                // The combined Swift HAR handler attaches its pre-admission proof
                // to physical owner refusals; internal/storage uncertainty keeps
                // the existing internal-error envelope.
                if method == "human-action.resume" && error.code != "internalError" {
                    let details = error.details.get_or_insert_with(Default::default);
                    details.insert("phase".into(), serde_json::json!("preAdmission"));
                    details.insert("newDispatchCount".into(), serde_json::json!(0));
                }
                error
            })?;
        if let Some(start) = answer.start {
            self.start_agent_run(start);
        }
        // Swift projects the owned Job over run, status and physical resume;
        // pages and abandonment answer as the owner wrote.
        if !matches!(
            method,
            "agent.run" | "agent.status" | "agent.resume" | "human-action.resume"
        ) {
            return Ok(answer.value);
        }
        arkdeck_hoststore::AgentExecutionStore::project(
            answer.value,
            jobs,
            &arkdeck_hoststore::JobResultReader { jobs, artifacts },
        )
    }

    #[cfg(target_os = "macos")]
    fn interactive_human_action_resume(
        &self,
        params: &serde_json::Map<String, serde_json::Value>,
    ) -> Result<serde_json::Value, WireError> {
        if let (Some(agents), Some(resources), Some(controls)) =
            (&self.agents, &self.human_actions, &self.control_actions)
            && let Some(answer) =
                resources.resume_control_action("human-action.resume", params, agents, controls)
        {
            let approval = answer?;
            let refusal = |code: &str, message: &str| WireError {
                code: code.into(),
                message: message.into(),
                details: Some(serde_json::Map::from_iter([
                    ("phase".into(), serde_json::json!("preAdmission")),
                    ("newDispatchCount".into(), serde_json::json!(0)),
                ])),
            };
            let result = if let Some(response) = params.get("challengeResponse") {
                (|| {
                    let response = response.as_str().ok_or_else(|| {
                        refusal(
                            "invalidInput",
                            "challengeResponse must be the bounded console challenge",
                        )
                    })?;
                    let id = approval["owner"]["id"].as_str().ok_or_else(|| {
                        refusal("recordUnreadable", "impact approval owner is unavailable")
                    })?;
                    let reference = approval["resumeReference"].as_str().ok_or_else(|| {
                        refusal(
                            "recordUnreadable",
                            "impact approval reference is unavailable",
                        )
                    })?;
                    let (Some(driver), Some(jobs)) = (
                        self.hdc.as_ref().and_then(|hdc| hdc.managed()),
                        self.jobs.as_ref(),
                    ) else {
                        return Err(refusal(
                            "admissionDenied",
                            "interactive HDC lifecycle execution is unavailable",
                        ));
                    };
                    self.with_hdc_impact(|source| {
                        let source = source.ok_or_else(|| {
                            refusal(
                                "admissionDenied",
                                "interactive HDC lifecycle execution is unavailable",
                            )
                        })?;
                        controls.consume_interactive_challenge(
                            id, reference, response, jobs, source, driver,
                        )
                    })
                })()
            } else {
                let action = approval["actionId"].as_str().ok_or_else(|| WireError {
                    code: "recordUnreadable".into(),
                    message: "impact approval identity is unavailable".into(),
                    details: None,
                })?;
                let reference = approval["resumeReference"]
                    .as_str()
                    .ok_or_else(|| WireError {
                        code: "recordUnreadable".into(),
                        message: "impact approval reference is unavailable".into(),
                        details: None,
                    })?;
                controls
                    .issue_interactive_challenge(action, reference)
                    .map_err(|mut error| {
                        let details = error.details.get_or_insert_with(serde_json::Map::new);
                        details.insert("phase".into(), serde_json::json!("preAdmission"));
                        details.insert("newDispatchCount".into(), serde_json::json!(0));
                        error
                    })
            };
            return result.map_err(|mut error| {
                // The owner supplies this proof only before launch, or after
                // durable recovery proved the launch window was never entered.
                if let Some(details) = &mut error.details
                    && details.get("newDispatchCount") == Some(&serde_json::json!(0))
                {
                    details.insert("phase".into(), serde_json::json!("preAdmission"));
                }
                error
            });
        }
        self.agent_execution("human-action.resume", params)
    }

    /// `human-action.list` and `human-action.show`, as the Swift daemon
    /// answers them with its combined human-action owner over the agent
    /// executions and the union control-action owner.
    #[cfg(target_os = "macos")]
    fn human_action(
        &self,
        method: &str,
        params: &serde_json::Map<String, serde_json::Value>,
    ) -> Result<serde_json::Value, WireError> {
        let (Some(agents), Some(resources)) = (&self.agents, &self.human_actions) else {
            return Err(WireError {
                code: "operationUnavailable".into(),
                message: "AgentExecution owner is unavailable".into(),
                details: Some(serde_json::Map::from_iter([
                    ("phase".into(), serde_json::json!("preAdmission")),
                    ("newDispatchCount".into(), serde_json::json!(0)),
                ])),
            });
        };
        resources.answer(method, params, agents, self.control_actions.as_ref())
    }

    /// `runtime.hdc.impact-preview`, `runtime.hdc.restart`,
    /// `runtime.tool.select` and `control-action.list`, `.show` and
    /// `.reconcile`, as Swift's daemon answers them: with the union owner the
    /// isolated composition makes — over the HDC control-action owner and the
    /// impact source of its managed HDC server, when it started one — or,
    /// without it, as Swift's handler answers with no control-action owner.
    /// Neither composes a tool-selection owner.
    #[cfg(target_os = "macos")]
    fn control_action(
        &self,
        method: &str,
        params: &serde_json::Map<String, serde_json::Value>,
    ) -> Result<serde_json::Value, WireError> {
        let Some(owner) = &self.control_actions else {
            return arkdeck_hoststore::control_action_without_owner(method, params);
        };
        self.with_hdc_impact(|source| owner.answer(method, params, source))
    }

    #[cfg(target_os = "macos")]
    fn job_resource(
        &self,
        method: &str,
        params: &serde_json::Map<String, serde_json::Value>,
    ) -> Result<serde_json::Value, WireError> {
        self.jobs
            .as_ref()
            .ok_or_else(|| WireError {
                code: "rejected".into(),
                message: "The Job owner is not configured".into(),
                details: None,
            })?
            .handle_resource(method, params)
    }
    #[cfg(target_os = "macos")]
    fn job_plan(
        &self,
        params: &serde_json::Map<String, serde_json::Value>,
    ) -> Result<serde_json::Value, WireError> {
        let Some((state_root, analyzer)) = &self.planning else {
            return Err(WireError {
                code: "rejected".into(),
                message: "this method is unavailable in the read-only Rust foundation".into(),
                details: None,
            });
        };
        let hdc = self.hdc();
        arkdeck_hoststore::JobPlanner {
            imports: self.imports.as_deref(),
            artifacts: self.artifacts.as_deref(),
            analyzer: analyzer.as_ref(),
            state_root,
            hdc: hdc.as_ref(),
        }
        .handle(params)
        // Planning never admits: every refusal is pre-admission with zero dispatch.
        .map_err(|refusal| WireError {
            code: refusal.code.into(),
            message: refusal.message,
            details: Some(serde_json::Map::from_iter([
                ("phase".into(), serde_json::json!("preAdmission")),
                ("newDispatchCount".into(), serde_json::json!(0)),
            ])),
        })
    }
    /// `job.submit` admits into the Job owner the planner materializes for.
    #[cfg(target_os = "macos")]
    fn job_submit(
        &self,
        params: &serde_json::Map<String, serde_json::Value>,
    ) -> Result<serde_json::Value, WireError> {
        let (Some((state_root, analyzer)), Some(jobs)) = (&self.planning, &self.jobs) else {
            return Err(WireError {
                code: "rejected".into(),
                message: "this method is unavailable in the read-only Rust foundation".into(),
                details: None,
            });
        };
        let hdc = self.hdc();
        arkdeck_hoststore::JobAdmitter {
            planner: arkdeck_hoststore::JobPlanner {
                imports: self.imports.as_deref(),
                artifacts: self.artifacts.as_deref(),
                analyzer: analyzer.as_ref(),
                state_root,
                hdc: hdc.as_ref(),
            },
            jobs,
            now: arkdeck_hoststore::runtime_now,
            authority: self.authority(),
        }
        .handle(params)
        // A refusal before the admission point proves zero dispatch; Swift
        // attaches empty details to any later failure.
        .map_err(|refusal| WireError {
            code: refusal.code.into(),
            message: refusal.message,
            details: Some(if refusal.proven {
                serde_json::Map::from_iter([
                    ("phase".into(), serde_json::json!("preAdmission")),
                    ("newDispatchCount".into(), serde_json::json!(0)),
                ])
            } else {
                serde_json::Map::new()
            }),
        })
    }
    /// `job.result` and `job.evidence` read from the Job and Artifact owners
    /// the isolated composition opened.
    #[cfg(target_os = "macos")]
    fn job_result_resource(
        &self,
        method: &str,
        params: &serde_json::Map<String, serde_json::Value>,
    ) -> Result<serde_json::Value, WireError> {
        let (Some(jobs), Some(artifacts)) = (&self.jobs, &self.artifacts) else {
            return Err(WireError {
                code: "rejected".into(),
                message: "this method is unavailable in the read-only Rust foundation".into(),
                details: None,
            });
        };
        arkdeck_hoststore::JobResultReader { jobs, artifacts }.handle(method, params)
    }
    /// `job.run` runs an admitted analyzer Job in the owner that admitted it.
    /// Every concurrent caller for one Job joins its one run, as Swift's
    /// callers join the one driver of a Job.
    #[cfg(target_os = "macos")]
    fn job_run(
        &self,
        params: &serde_json::Map<String, serde_json::Value>,
    ) -> Result<serde_json::Value, WireError> {
        let (Some((_, analyzer)), Some(jobs), Some(artifacts)) =
            (&self.planning, &self.jobs, &self.artifacts)
        else {
            return Err(WireError {
                code: "rejected".into(),
                message: "this method is unavailable in the read-only Rust foundation".into(),
                details: None,
            });
        };
        // As the standalone Swift daemon: every terminal Job is published as
        // a Session through the Session owner this composition holds.
        let probe = arkdeck_hoststore::SystemStorageProbe;
        let publisher =
            self.storage
                .as_deref()
                .map(|(sessions, _)| arkdeck_hoststore::SessionPublisher {
                    sessions,
                    claims: &self.claims,
                    probe: &probe,
                });
        let hdc = self.hdc();
        let run = |cancellation: Option<&arkdeck_hoststore::RunCancellation>| {
            arkdeck_hoststore::JobRunner {
                imports: self.imports.as_deref(),
                mutation: self.authority().zip(self.planning.as_ref()).map(
                    |(authority, (state_root, _))| arkdeck_hoststore::MutationExecution {
                        authority,
                        state_root,
                    },
                ),
                jobs,
                artifacts,
                analyzer: analyzer.as_ref(),
                quota: ARTIFACT_QUOTA,
                home: &self.home,
                now: arkdeck_hoststore::runtime_now,
                precise_now: arkdeck_hoststore::runtime_precise_now,
                sessions: publisher.as_ref(),
                cancellation,
                after_commit: None,
                hdc: hdc.as_ref(),
            }
            .handle(params)
            .map_err(|refusal| WireError {
                code: refusal.code.into(),
                message: refusal.message,
                details: Some(refusal.details),
            })
        };
        let uncertain = || WireError {
            code: "internalError".into(),
            message: "the Runtime could not complete the Job lifecycle request".into(),
            details: Some(serde_json::Map::new()),
        };
        let Some(job) = params.get("jobId").and_then(serde_json::Value::as_str) else {
            return run(None);
        };
        let slot = loop {
            let mut running = self.running.lock().map_err(|_| uncertain())?;
            let Some(slot) = running.get(job).cloned() else {
                let slot = std::sync::Arc::new(RunSlot::default());
                running.insert(job.to_owned(), slot.clone());
                break slot;
            };
            drop(running);
            let outcome = slot.wait();
            // A run waits out a cancellation of its Job, then meets what the
            // cancellation left.
            if !slot.cancelling {
                return outcome.unwrap_or_else(|| Err(uncertain()));
            }
        };
        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            run(Some(&slot.cancellation))
        }))
        .unwrap_or_else(|_| Err(uncertain()));
        // A request the run never acted on falls back to the Job's record,
        // which the run no longer holds.
        slot.cancellation.end();
        slot.finish(&result);
        if let Ok(mut running) = self.running.lock() {
            running.remove(job);
        }
        result
    }
    /// `artifact.quota` walks this owner's Artifact root as the Swift daemon
    /// walks its own before it has cached a total, and writes nothing.
    #[cfg(target_os = "macos")]
    fn artifact_quota(&self) -> Result<serde_json::Value, WireError> {
        let Some((_, usage)) = self.storage.as_deref() else {
            return Err(WireError {
                code: "rejected".into(),
                message: "this method is unavailable in the read-only Rust foundation".into(),
                details: None,
            });
        };
        usage.quota().map_err(|message| WireError {
            code: "internalError".into(),
            message,
            details: None,
        })
    }
    /// `capability.list` and `capability.inspect` read the capability store as
    /// the Swift daemon reads it, under the store's lock; nothing mints,
    /// reserves or settles a use here.
    #[cfg(target_os = "macos")]
    fn capability_resource(
        &self,
        method: &str,
        params: &serde_json::Map<String, serde_json::Value>,
    ) -> Result<serde_json::Value, WireError> {
        let Some(capabilities) = &self.capabilities else {
            return Err(WireError {
                code: "rejected".into(),
                message: "this method is unavailable in the read-only Rust foundation".into(),
                details: None,
            });
        };
        capabilities
            .handle(method, params)
            .map_err(|refusal| WireError {
                code: refusal.code.into(),
                message: refusal.message,
                details: None,
            })
    }
    /// `cleanupDebt.list` reads the cleanup debt ledger beside this owner's
    /// Artifacts as the Swift daemon lists it, and writes nothing; Swift reads
    /// no parameter of it. `cleanupDebt.continue` continues one debt through
    /// the owners `job.run` runs with: the Job's record, its capability use
    /// and the HDC composition. Swift answers any failure of the store as an
    /// internal error.
    #[cfg(target_os = "macos")]
    fn cleanup_debt(
        &self,
        method: &str,
        params: &serde_json::Map<String, serde_json::Value>,
    ) -> Result<serde_json::Value, WireError> {
        let foundation = || WireError {
            code: "rejected".into(),
            message: "this method is unavailable in the read-only Rust foundation".into(),
            details: None,
        };
        let Some(artifacts) = &self.artifacts else {
            return Err(foundation());
        };
        if method == "cleanupDebt.list" {
            return arkdeck_hoststore::list_cleanup_debt(artifacts).map_err(|message| WireError {
                code: "internalError".into(),
                message,
                details: None,
            });
        }
        let Some(jobs) = &self.jobs else {
            return Err(foundation());
        };
        let hdc = self.hdc();
        arkdeck_hoststore::JobRunner {
            imports: self.imports.as_deref(),
            mutation: self.authority().zip(self.planning.as_ref()).map(
                |(authority, (state_root, _))| arkdeck_hoststore::MutationExecution {
                    authority,
                    state_root,
                },
            ),
            jobs,
            artifacts,
            analyzer: self
                .planning
                .as_ref()
                .and_then(|(_, analyzer)| analyzer.as_ref()),
            quota: ARTIFACT_QUOTA,
            home: &self.home,
            now: arkdeck_hoststore::runtime_now,
            precise_now: arkdeck_hoststore::runtime_precise_now,
            // A continuation publishes no Session and cancels nothing.
            sessions: None,
            cancellation: None,
            after_commit: None,
            hdc: hdc.as_ref(),
        }
        .continue_cleanup_debt(params)
    }
    /// `job.cancel` cancels an admitted Job in the owner that admitted it. A
    /// Job this owner is running is cancelled by its run, which alone writes
    /// the Job's Journal. A run of a Job no run holds waits the cancellation
    /// out, and a concurrent cancellation joins it.
    #[cfg(target_os = "macos")]
    fn job_cancel(
        &self,
        params: &serde_json::Map<String, serde_json::Value>,
    ) -> Result<serde_json::Value, WireError> {
        let Some(jobs) = &self.jobs else {
            return Err(WireError {
                code: "rejected".into(),
                message: "this method is unavailable in the read-only Rust foundation".into(),
                details: None,
            });
        };
        // A Job the cancellation closes is published as a Session, as the
        // standalone Swift daemon publishes every terminal Job.
        let probe = arkdeck_hoststore::SystemStorageProbe;
        let publisher =
            self.storage
                .as_deref()
                .map(|(sessions, _)| arkdeck_hoststore::SessionPublisher {
                    sessions,
                    claims: &self.claims,
                    probe: &probe,
                });
        let cancel = || {
            arkdeck_hoststore::JobCanceller {
                jobs,
                now: arkdeck_hoststore::runtime_now,
                sessions: publisher.as_ref(),
            }
            .handle(params)
        };
        // Swift attaches no details to any `job.cancel` refusal.
        let uncertain = || WireError {
            code: "internalError".into(),
            message: "the Runtime could not complete the Job lifecycle request".into(),
            details: None,
        };
        let Some(job) = params.get("jobId").and_then(serde_json::Value::as_str) else {
            return cancel();
        };
        let slot = loop {
            let mut running = self.running.lock().map_err(|_| uncertain())?;
            let Some(slot) = running.get(job).cloned() else {
                let slot = std::sync::Arc::new(RunSlot {
                    cancelling: true,
                    ..RunSlot::default()
                });
                running.insert(job.to_owned(), slot.clone());
                break slot;
            };
            drop(running);
            if slot.cancelling {
                return slot.wait().unwrap_or_else(|| Err(uncertain()));
            }
            if let Some(answer) = arkdeck_hoststore::cancel_running(&slot.cancellation) {
                return Ok(answer);
            }
            // The run ended without acting on the request: once it has let
            // go of the Job, the Job's record decides.
            let _ = slot.wait();
            while self.running.lock().is_ok_and(|running| {
                running
                    .get(job)
                    .is_some_and(|current| std::sync::Arc::ptr_eq(current, &slot))
            }) {
                std::thread::sleep(std::time::Duration::from_millis(1));
            }
        };
        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(cancel))
            .unwrap_or_else(|_| Err(uncertain()));
        // Released before its waiters wake, so a waiting run starts its own.
        if let Ok(mut running) = self.running.lock() {
            running.remove(job);
        }
        slot.finish(&result);
        result
    }
    /// `job.reconcile` in the owner that admitted the Job, with the Session
    /// publication writer its runs use. A Job a run of this owner holds is
    /// decided by that run alone: its status is answered and nothing is
    /// written. A concurrent reconcile of one Job joins the one under way, as
    /// Swift's callers join `jobReconciliations`.
    #[cfg(target_os = "macos")]
    fn job_reconcile(
        &self,
        params: &serde_json::Map<String, serde_json::Value>,
    ) -> Result<serde_json::Value, WireError> {
        let (Some(jobs), Some(artifacts)) = (&self.jobs, &self.artifacts) else {
            return Err(WireError {
                code: "rejected".into(),
                message: "this method is unavailable in the read-only Rust foundation".into(),
                details: None,
            });
        };
        let probe = arkdeck_hoststore::SystemStorageProbe;
        let publisher =
            self.storage
                .as_deref()
                .map(|(sessions, _)| arkdeck_hoststore::SessionPublisher {
                    sessions,
                    claims: &self.claims,
                    probe: &probe,
                });
        // A device-bound Job is reconciled against fresh facts through the
        // HDC composition its runs use, and its use settled in the store its
        // admission reserved it in.
        let hdc = self.hdc();
        let reconciler = arkdeck_hoststore::JobReconciler {
            jobs,
            artifacts,
            imports: self.imports.as_deref(),
            now: arkdeck_hoststore::runtime_now,
            sessions: publisher.as_ref(),
            hdc: hdc.as_ref(),
            capabilities: self.capabilities.as_deref(),
        };
        // Swift attaches no details to any `job.reconcile` refusal.
        let uncertain = || WireError {
            code: "internalError".into(),
            message: "the Runtime could not complete the Job lifecycle request".into(),
            details: None,
        };
        let Some(job) = params.get("jobId").and_then(serde_json::Value::as_str) else {
            return reconciler.handle(params);
        };
        let executing = self
            .running
            .lock()
            .map_err(|_| uncertain())?
            .get(job)
            .is_some_and(|slot| !slot.cancelling);
        if executing {
            return reconciler.status(params);
        }
        let slot = {
            let mut reconciling = self.reconciling.lock().map_err(|_| uncertain())?;
            if let Some(slot) = reconciling.get(job).cloned() {
                drop(reconciling);
                return slot.wait().unwrap_or_else(|| Err(uncertain()));
            }
            let slot = std::sync::Arc::new(RunSlot::default());
            reconciling.insert(job.to_owned(), slot.clone());
            slot
        };
        let result =
            std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| reconciler.handle(params)))
                .unwrap_or_else(|_| Err(uncertain()));
        if let Ok(mut reconciling) = self.reconciling.lock() {
            reconciling.remove(job);
        }
        slot.finish(&result);
        result
    }
    #[cfg(target_os = "macos")]
    fn bootstrap_register_bundle(&self, source: &str) -> Result<serde_json::Value, WireError> {
        self.bootstrap
            .as_ref()
            .ok_or_else(|| WireError {
                code: "operationUnavailable".into(),
                message: "Bundle registration owner is not configured".into(),
                details: Some(serde_json::Map::from_iter([
                    ("phase".into(), serde_json::json!("bootstrapRegistryOwner")),
                    ("newDispatchCount".into(), serde_json::json!(0)),
                ])),
            })?
            .register_bundle(std::path::Path::new(source), &utc_now())
    }
    #[cfg(target_os = "macos")]
    fn bootstrap_register_deveco(&self, source: &str) -> Result<serde_json::Value, WireError> {
        self.bootstrap
            .as_ref()
            .ok_or_else(|| WireError {
                code: "operationUnavailable".into(),
                message: "DevEco registration owner is not configured".into(),
                details: Some(serde_json::Map::from_iter([
                    ("phase".into(), serde_json::json!("bootstrapRegistryOwner")),
                    ("newDispatchCount".into(), serde_json::json!(0)),
                ])),
            })?
            .register_deveco(std::path::Path::new(source), &utc_now())
    }
    #[cfg(target_os = "macos")]
    fn bootstrap_register_hdc(&self, source: &str) -> Result<serde_json::Value, WireError> {
        self.bootstrap
            .as_ref()
            .ok_or_else(|| WireError {
                code: "operationUnavailable".into(),
                message: "HDC registration owner is not configured".into(),
                details: Some(serde_json::Map::from_iter([
                    ("phase".into(), serde_json::json!("bootstrapRegistryOwner")),
                    ("newDispatchCount".into(), serde_json::json!(0)),
                ])),
            })?
            .register_hdc(std::path::Path::new(source), &utc_now())
    }
    #[cfg(target_os = "macos")]
    fn trace_cache_purge(&self) -> Result<serde_json::Value, WireError> {
        // An unconfigured owner is a deterministic refusal with zero dispatch,
        // the same answer `trace.cache.status` gives; `outcomeUnknown` is
        // reserved for a census or maintenance failure once owners exist.
        let unconfigured = || WireError {
            code: "rejected".into(),
            message: "Trace cache owner is not configured".into(),
            details: None,
        };
        let cache = self.trace_cache.as_ref().ok_or_else(unconfigured)?;
        let jobs = self.jobs.as_ref().ok_or_else(unconfigured)?;
        let artifacts = self.artifacts.as_ref().ok_or_else(unconfigured)?;
        let refuse = || {
            arkdeck_hoststore::TraceCacheStore::purge_refusal(
                "Trace cache or authoritative Job/Artifact retention owner is unavailable",
            )
        };
        jobs.with_active_sessions(|active| {
            artifacts
                .with_trace_retention(|retain_artifacts| {
                    cache.purge(retain_artifacts || !active.is_empty())
                })
                .map_err(|_| refuse())?
        })
        .map_err(|_| refuse())
    }
    #[cfg(target_os = "macos")]
    fn trace_cache_status(&self) -> Result<serde_json::Value, WireError> {
        self.trace_cache
            .as_ref()
            .ok_or_else(|| WireError {
                code: "rejected".into(),
                message: "Trace cache maintenance is not configured".into(),
                details: None,
            })?
            .status()
    }
    #[cfg(target_os = "macos")]
    fn bootstrap_tool_remove(
        &self,
        reference: &str,
        generation: &str,
    ) -> Result<serde_json::Value, WireError> {
        self.bootstrap
            .as_ref()
            .ok_or_else(|| WireError {
                code: "operationUnavailable".into(),
                message: "Bootstrap tool retirement owner is not configured".into(),
                details: Some(serde_json::Map::from_iter([
                    ("phase".into(), serde_json::json!("bootstrapRegistryOwner")),
                    ("newDispatchCount".into(), serde_json::json!(0)),
                ])),
            })?
            .tool_remove(reference, generation)
    }
    #[cfg(target_os = "macos")]
    fn bootstrap_tool_list(
        &self,
        page_size: usize,
        cursor: Option<&str>,
    ) -> Result<serde_json::Value, WireError> {
        self.bootstrap
            .as_ref()
            .ok_or_else(|| WireError {
                code: "operationUnavailable".into(),
                message: "Bootstrap tool list owner is not configured".into(),
                details: Some(serde_json::Map::from_iter([
                    ("phase".into(), serde_json::json!("bootstrapRegistryOwner")),
                    ("newDispatchCount".into(), serde_json::json!(0)),
                ])),
            })?
            .tool_list(page_size, cursor)
    }
    #[cfg(target_os = "macos")]
    fn bootstrap_bundle_list(
        &self,
        page_size: usize,
        cursor: Option<&str>,
    ) -> Result<serde_json::Value, WireError> {
        self.bootstrap
            .as_ref()
            .ok_or_else(|| WireError {
                code: "operationUnavailable".into(),
                message: "Bootstrap bundle list owner is not configured".into(),
                details: Some(serde_json::Map::from_iter([
                    ("phase".into(), serde_json::json!("bootstrapRegistryOwner")),
                    ("newDispatchCount".into(), serde_json::json!(0)),
                ])),
            })?
            .bundle_list(page_size, cursor)
    }
    #[cfg(target_os = "macos")]
    fn bootstrap_bundle_remove(
        &self,
        reference: &str,
        generation: &str,
    ) -> Result<serde_json::Value, WireError> {
        self.bootstrap
            .as_ref()
            .ok_or_else(|| WireError {
                code: "operationUnavailable".into(),
                message: "Bootstrap bundle retirement owner is not configured".into(),
                details: Some(serde_json::Map::from_iter([
                    ("phase".into(), serde_json::json!("bootstrapRegistryOwner")),
                    ("newDispatchCount".into(), serde_json::json!(0)),
                ])),
            })?
            .bundle_remove(reference, generation)
    }
    #[cfg(target_os = "macos")]
    fn bootstrap_inspect(
        &self,
        kind: arkdeck_control::BootstrapRegistryKind,
        reference: &str,
    ) -> Result<serde_json::Value, WireError> {
        self.bootstrap
            .as_ref()
            .ok_or_else(|| WireError {
                code: "operationUnavailable".into(),
                message: "Bootstrap read owner is not configured".into(),
                details: Some(serde_json::Map::from_iter([
                    ("phase".into(), serde_json::json!("bootstrapRegistryOwner")),
                    ("newDispatchCount".into(), serde_json::json!(0)),
                ])),
            })?
            .inspect(kind, reference)
    }

    #[cfg(target_os = "macos")]
    fn session_resource(
        &self,
        method: &str,
        params: &serde_json::Map<String, serde_json::Value>,
    ) -> Result<serde_json::Value, WireError> {
        let (sessions, _) = self.storage.as_deref().ok_or_else(|| WireError {
            code: "rejected".into(),
            message: "Session owner is not configured".into(),
            details: None,
        })?;
        if method == "session.export.apply" {
            let invalid = || WireError {
                code: "invalidParams".into(),
                message: "Session export apply requires one exact preview tuple".into(),
                details: None,
            };
            if params.len() != 2
                || !params.contains_key("previewId")
                || !params.contains_key("previewDigest")
            {
                return Err(invalid());
            }
            let id = params["previewId"].as_str().ok_or_else(invalid)?;
            let digest = params["previewDigest"].as_str().ok_or_else(invalid)?;
            return sessions.apply_export(id, digest, || {
                SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .map(|n| n.as_secs_f64() - 978307200.0)
                    .unwrap_or(f64::NAN)
            });
        }
        if method == "session.export.preview" {
            let invalid = || WireError {
                code: "invalidParams".into(),
                message: "Session export preview requires a Session and destination".into(),
                details: None,
            };
            if params.keys().any(|key| {
                !["sessionId", "destinationPath", "allowSensitive"].contains(&key.as_str())
            }) {
                return Err(invalid());
            }
            let id = params
                .get("sessionId")
                .and_then(serde_json::Value::as_str)
                .ok_or_else(invalid)?;
            let destination = params
                .get("destinationPath")
                .and_then(serde_json::Value::as_str)
                .ok_or_else(invalid)?;
            let sensitive = match params.get("allowSensitive") {
                None => false,
                Some(value) => value.as_bool().ok_or_else(invalid)?,
            };
            let now = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map_err(|_| WireError {
                    code: "operationUnavailable".into(),
                    message: "Runtime clock is unavailable".into(),
                    details: None,
                })?
                .as_secs_f64()
                - 978307200.0;
            return sessions.preview_export(id, destination, sensitive, now);
        }
        if matches!(method, "session.cleanup.preview" | "session.cleanup.apply") {
            let invalid = || WireError {
                code: "invalidParams".into(),
                message: "Session cleanup requires the exact method parameters".into(),
                details: None,
            };
            let tuple = if method == "session.cleanup.apply" {
                if params.len() != 2 {
                    return Err(invalid());
                }
                Some((
                    params
                        .get("previewId")
                        .and_then(serde_json::Value::as_str)
                        .ok_or_else(invalid)?,
                    params
                        .get("previewDigest")
                        .and_then(serde_json::Value::as_str)
                        .ok_or_else(invalid)?,
                ))
            } else {
                if !params.is_empty() {
                    return Err(invalid());
                }
                None
            };
            let jobs = self.jobs.as_ref().ok_or_else(|| WireError {
                code: "operationUnavailable".into(),
                message: "Session cleanup requires the Job owner's active Session inventory".into(),
                details: Some(serde_json::Map::from_iter([
                    ("phase".into(), serde_json::json!("sessionOwner")),
                    ("newDispatchCount".into(), serde_json::json!(0)),
                ])),
            })?;
            jobs.with_active_sessions(|active| {
                let now = SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .map(|value| value.as_secs_f64() - 978307200.0)
                    .unwrap_or(f64::NAN);
                if let Some((id, digest)) = tuple {
                    sessions.apply_cleanup(id, digest, active, || {
                        SystemTime::now()
                            .duration_since(UNIX_EPOCH)
                            .map(|value| value.as_secs_f64() - 978307200.0)
                            .unwrap_or(f64::NAN)
                    })
                } else {
                    sessions.preview_cleanup(active, now)
                }
            })
        } else {
            sessions.handle_resource(method, params)
        }
    }
    #[cfg(target_os = "macos")]
    fn runtime_storage(
        &self,
        method: &str,
        params: &serde_json::Map<String, serde_json::Value>,
    ) -> Result<serde_json::Value, WireError> {
        let failed = |code: &str, message: &str| WireError {
            code: code.into(),
            message: message.into(),
            details: Some(serde_json::Map::from_iter([
                ("phase".into(), serde_json::json!("runtimeStorageOwner")),
                ("newDispatchCount".into(), serde_json::json!(0)),
            ])),
        };
        let (sessions, artifacts) = self
            .storage
            .as_deref()
            .ok_or_else(|| failed("rejected", "Runtime storage owners are not configured"))?;
        let artifact = artifacts
            .status()
            .map_err(|_| failed("recordUnreadable", "Artifact inventory is unreadable"))?;
        let session = sessions.handle(method, params)?;
        Ok(
            serde_json::json!({"schemaVersion":"arkdeck.runtime-storage/1", "sessionDomain":session, "artifactDomain":artifact}),
        )
    }
    #[cfg(target_os = "macos")]
    fn workspace_project(
        &self,
        method: &str,
        params: &serde_json::Map<String, serde_json::Value>,
    ) -> Result<serde_json::Value, WireError> {
        #[cfg(target_os = "macos")]
        if let Some(owner) = &self.workspace_projects {
            use arkdeck_hoststore::WorkspaceReference;
            // A project or preset mutation is refused while an active or
            // uncertain workspace Job names it; without the Job owner nothing
            // proves that none does.
            let census = |reference: WorkspaceReference<'_>| match (&self.jobs, reference) {
                (Some(jobs), WorkspaceReference::Project(project)) => {
                    jobs.require_no_active_workspace_project_reference(project)
                }
                (Some(jobs), WorkspaceReference::Preset(preset)) => {
                    jobs.require_no_active_workspace_preset_reference(preset)
                }
                (None, _) => Err(WireError {
                    code: "recordUnreadable".into(),
                    message: "workspace Job references cannot be verified".into(),
                    details: Some(serde_json::Map::from_iter([
                        ("phase".into(), serde_json::json!("workspaceProjectOwner")),
                        ("newDispatchCount".into(), serde_json::json!(0)),
                    ])),
                }),
            };
            return owner.handle(
                method,
                params,
                &|| arkdeck_hoststore::runtime_now().unwrap_or_default(),
                &census,
            );
        }
        let _ = params;
        // Swift answers a preset method without its owner under the preset
        // owner's phase.
        let phase = if method.starts_with("workspace.preset.") {
            "workspacePresetOwner"
        } else {
            "workspaceProjectOwner"
        };
        Err(WireError {
            code: "operationUnavailable".into(),
            message: "workspace project owner is unavailable".into(),
            details: Some(serde_json::Map::from_iter([
                ("phase".into(), serde_json::json!(phase)),
                ("newDispatchCount".into(), serde_json::json!(0)),
            ])),
        })
    }
    #[cfg(target_os = "macos")]
    fn history_filter(
        &self,
        method: &str,
        params: &serde_json::Map<String, serde_json::Value>,
    ) -> Result<serde_json::Value, WireError> {
        let store = self.history.as_ref().ok_or_else(|| WireError {
            code: "rejected".into(),
            message: "History filter owner is not configured".into(),
            details: None,
        })?;
        store.handle(method, params, &utc_now())
    }
    #[cfg(target_os = "macos")]
    fn debug_read(
        &self,
        target_id: &str,
        template_id: Option<&str>,
    ) -> Result<serde_json::Value, WireError> {
        self.hdc()
            .ok_or_else(|| WireError {
                code: "internalError".into(),
                message: "Debug Runtime probing is not configured".into(),
                details: None,
            })?
            .debug_read(target_id, template_id)
    }
    /// Swift's daemon answers from the observer its HDC host gives it, and
    /// `unconfigured()` without one: this composition has a host only when
    /// the isolated owner started a managed server.
    #[cfg(target_os = "macos")]
    fn runtime_hdc_status(&self) -> Result<serde_json::Value, WireError> {
        Ok(match self.managed_hdc() {
            Some(managed) => managed.status(&utc_now),
            None => arkdeck_provider_hdc::unconfigured_status(None),
        })
    }
    #[cfg(target_os = "macos")]
    fn managed_hdc_tool(&self) -> Option<arkdeck_control::ManagedToolFacts> {
        self.managed_hdc()
            .map(crate::managed_hdc::ManagedHdc::tool_facts)
    }

    fn observed_at(&self) -> String {
        utc_now()
    }
    /// Swift `doctorReport`'s owner inputs, read from this composition's
    /// owners as they are now.
    fn doctor_facts(&self, deep: bool) -> arkdeck_control::DoctorFacts {
        #[cfg(target_os = "macos")]
        {
            use arkdeck_control::{ArtifactStoreFacts, TargetStoreFacts};
            // Swift `totalBytesUsed()` and `quotaTotalBytes`, read in deep mode.
            let artifacts = match &self.storage {
                None => ArtifactStoreFacts::NotConfigured,
                Some(_) if !deep => ArtifactStoreFacts::NotChecked,
                Some(storage) => storage
                    .1
                    .quota()
                    .ok()
                    .and_then(|quota| {
                        Some(ArtifactStoreFacts::Quota {
                            total: quota["totalBytes"].as_u64()?,
                            used: quota["usedBytes"].as_u64()?,
                        })
                    })
                    .unwrap_or(ArtifactStoreFacts::Unreadable),
            };
            // Swift `targetStore.listActive()`, read in both modes.
            let targets = match &self.targets {
                None => TargetStoreFacts::NotConfigured,
                Some(targets) => targets
                    .handle("target.list", &serde_json::Map::new(), &utc_now())
                    .ok()
                    .and_then(|rows| rows.as_array().map(Vec::len))
                    .map_or(TargetStoreFacts::Unreadable, |count| {
                        TargetStoreFacts::Adopted(count as u64)
                    }),
            };
            // Swift `engine.listCleanupDebt()`: the Job cleanup ledger beside
            // the Artifacts, unreadable without its owners.
            let cleanup_debt = match (deep, &self.jobs, &self.artifacts) {
                (true, Some(jobs), Some(artifacts)) => {
                    arkdeck_hoststore::JobResultReader { jobs, artifacts }
                        .outstanding_cleanup_debt()
                        .ok()
                        .map(|debts| debts.len() as u64)
                }
                _ => None,
            };
            arkdeck_control::DoctorFacts {
                artifacts,
                targets,
                // Swift's `DeviceBootstrapMachine`: what answers device
                // discovery here — the Target observation owner's sources, or
                // the registered read-only provider.
                discovery: (self.hdc.is_some() && self.targets.is_some())
                    || self.provider.is_some(),
                cleanup_debt,
                quarantined: self.quarantined.get().cloned().unwrap_or_default(),
                // Swift reads the whole ledger only for a deep report, and
                // names at most sixteen of what it finds.
                unreadable_records: match (&self.jobs, deep) {
                    (Some(jobs), true) => jobs.unreadable_records(16).ok(),
                    _ => None,
                },
            }
        }
        #[cfg(not(target_os = "macos"))]
        {
            let _ = deep;
            arkdeck_control::DoctorFacts {
                discovery: self.provider.is_some(),
                ..arkdeck_control::DoctorFacts::default()
            }
        }
    }
    fn hdc_status(&self, deep: bool) -> HdcStatus {
        // Swift's status observer exists exactly when its HDC host started:
        // here, when the isolated owner started its managed server.
        #[cfg(target_os = "macos")]
        if let Some(managed) = self.managed_hdc() {
            if !deep {
                return HdcStatus {
                    configured: true,
                    checked: false,
                    availability: "notChecked".into(),
                    ownership: "unknown".into(),
                    server_health: "unknown".into(),
                    reason_code: "doctor.deepNotRequested".into(),
                };
            }
            let snapshot = managed.status(&utc_now);
            let member =
                |key: &str, missing: &str| snapshot[key].as_str().unwrap_or(missing).to_owned();
            return HdcStatus {
                configured: true,
                checked: true,
                availability: member("availability", "unknown"),
                ownership: member("ownership", "unknown"),
                server_health: member("serverHealth", "unknown"),
                reason_code: member("reasonCode", "hdc.statusIncomplete"),
            };
        }
        let Some(provider) = &self.provider else {
            return HdcStatus::unavailable(deep, self.unavailable);
        };
        // No lifecycle operation is available here. A deep observation is the
        // same registered, identity-bracketed read used by device candidates.
        let (availability, reason) = if !deep {
            ("notChecked", "doctor.deepNotRequested")
        } else if provider.list_candidates().is_ok() {
            ("available", "hdc.observationReady")
        } else {
            ("unavailable", "hdc.identityUnavailable")
        };
        HdcStatus {
            configured: true,
            checked: deep,
            availability: availability.into(),
            ownership: "external".into(),
            server_health: "unknown".into(),
            reason_code: reason.into(),
        }
    }
    #[cfg(target_os = "macos")]
    fn observations_following(
        &self,
        reference: &serde_json::Value,
    ) -> Result<DeviceObservationsResult, WireError> {
        let empty = serde_json::Map::new();
        let fields = reference.as_object().unwrap_or(&empty);
        match self.observe(|sources| {
            let reference = arkdeck_hoststore::parse_reference(fields)?;
            self.target_observations
                .snapshot(sources, Some(&reference))
                .and_then(|snapshot| snapshot.answer(sources.targets))
        }) {
            Some(answer) => typed_observations(answer),
            None => Err(arkdeck_control::observation_refusal(
                "resourceConflict",
                "the referenced observation is not retained by this Runtime",
                Some(reference),
            )),
        }
    }
    #[cfg(target_os = "macos")]
    fn target_adopt(
        &self,
        params: &serde_json::Map<String, serde_json::Value>,
    ) -> Result<serde_json::Value, WireError> {
        match self.observe(|sources| {
            let reference = arkdeck_hoststore::parse_reference(params)?;
            self.target_observations
                .adopt(sources, &reference)
                .map(|adopted| arkdeck_hoststore::adoption_answer(&adopted, &reference))
        }) {
            Some(answer) => answer.map_err(|error| error.wire()),
            None => Err(WireError {
                code: "rejected".into(),
                message: "this method is unavailable in the read-only Rust foundation".into(),
                details: None,
            }),
        }
    }
    fn observations(&self) -> Result<DeviceObservationsResult, WireError> {
        let fail = |message: &str| WireError {
            code: "rejected".into(),
            message: message.into(),
            details: None,
        };
        // With the development HDC, the Target observation owner observes.
        #[cfg(target_os = "macos")]
        if let Some(answer) = self.observe(|sources| {
            self.target_observations
                .snapshot(sources, None)
                .and_then(|snapshot| snapshot.answer(sources.targets))
        }) {
            return typed_observations(answer);
        }
        let Some(provider) = &self.provider else {
            return Err(fail(self.unavailable));
        };
        // Serialize refreshes, so generations order the actual completed reads.
        let mut state = self
            .observations
            .lock()
            .map_err(|_| fail("the observation generation is unavailable"))?;
        state.snapshot = None;
        #[cfg(target_os = "macos")]
        if let Some(targets) = &self.targets {
            targets.expire_candidates()?;
        }
        let mut candidates = provider
            .list_candidates()
            .map_err(|error| fail(&format!("{}: {error}", error.classification())))?;
        let next = state
            .generation
            .checked_add(1)
            .filter(|n| *n <= i64::MAX as u64)
            .ok_or_else(|| fail("the observation generation is exhausted"))?;
        candidates.sort_by(|a, b| {
            a.connect_key
                .cmp(&b.connect_key)
                .then_with(|| a.state.cmp(&b.state))
        });
        #[cfg(target_os = "macos")]
        let presentations = self
            .targets
            .as_ref()
            .map(|targets| {
                targets.candidate_presentations(
                    &candidates
                        .iter()
                        .map(|c| c.connect_key.clone())
                        .collect::<Vec<_>>(),
                )
            })
            .transpose()?;
        let mut observations = Vec::with_capacity(candidates.len());
        for candidate in candidates {
            #[cfg(target_os = "macos")]
            let presentation = presentations
                .as_ref()
                .and_then(|rows| rows.get(&candidate.connect_key));
            observations.push(DeviceObservationsResultObservationsItem {
                candidate_key: candidate.connect_key,
                authorization_state: candidate.state,
                observation_id: format!(
                    "obs-{}",
                    fresh_id().map_err(|_| fail("observation identity entropy is unavailable"))?
                ),
                observation_continuity: "generationScoped".into(),
                #[cfg(target_os = "macos")]
                display_name_generation: presentation
                    .and_then(|v| v["displayNameGeneration"].as_str())
                    .map_or_else(|| next.to_string(), str::to_owned),
                #[cfg(not(target_os = "macos"))]
                display_name_generation: next.to_string(),
                #[cfg(target_os = "macos")]
                adopted_target_id: presentation
                    .and_then(|v| v["targetId"].as_str())
                    .map(str::to_owned),
                #[cfg(not(target_os = "macos"))]
                adopted_target_id: None,
                #[cfg(target_os = "macos")]
                binding_revision: presentation.and_then(|v| v["bindingRevision"].as_i64()),
                #[cfg(not(target_os = "macos"))]
                binding_revision: None,
                #[cfg(target_os = "macos")]
                display_name: presentation
                    .and_then(|v| v["displayName"].as_str())
                    .map(str::to_owned),
                #[cfg(not(target_os = "macos"))]
                display_name: None,
                device_information: None,
                observed_facts: (),
            });
        }
        state.generation = next;
        let snapshot = DeviceObservationsResult {
            schema_version: "arkdeck.device-observations/1".into(),
            snapshot_generation: next.to_string(),
            observed_at_utc: utc_now(),
            health: "current".into(),
            observations,
        };
        state.snapshot = Some(snapshot.clone());
        Ok(snapshot)
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
/// keeps the registry's code and message, as Swift rethrows it.
#[cfg(target_os = "macos")]
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

pub(crate) fn utc_now() -> String {
    timestamp(
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs(),
    )
}

// Proleptic Gregorian conversion; the output uses the existing UTC seconds
// spelling. Monotonic generation ordering does not depend on this wall clock.
fn timestamp(seconds: u64) -> String {
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

#[cfg(test)]
mod tests {
    use super::*;
    /// The development authority moves the root a device mutation proves its
    /// state continuity against, and changes nothing else about that proof.
    #[cfg(target_os = "macos")]
    #[test]
    fn the_development_mutation_root_is_the_root_the_isolated_owner_proves() {
        use std::{fs, os::unix::fs::DirBuilderExt};
        let path = std::env::temp_dir()
            .canonicalize()
            .unwrap()
            .join(format!("development-mutation-host-{}", fresh_id().unwrap()));
        let jobs = path.join("jobs-state");
        fs::DirBuilder::new()
            .mode(0o700)
            .recursive(true)
            .create(&jobs)
            .unwrap();
        let store = arkdeck_hoststore::JobStore::open_owner(&jobs).unwrap();
        let host = Host::from_environment().with_capabilities(
            arkdeck_hoststore::CapabilityStore::open(&jobs.join("capabilities")).unwrap(),
        );
        // The installed Runtime's root, which an isolated owner is not: its
        // mutation state can never be proved continuous with it.
        let installed = host.authority().unwrap();
        assert_ne!(installed.default_root, jobs);
        assert_eq!(
            installed.require_state(&store).unwrap_err().code,
            "recordUnreadable"
        );
        // Taken, the proof is anchored at this owner's own Job state.
        let host = host.with_development_mutation_root(jobs.clone());
        assert_eq!(host.authority().unwrap().default_root, jobs);
        host.authority().unwrap().require_state(&store).unwrap();
        // Everything else the proof refuses, it still refuses there: recorded
        // authorization usage beside the root, and a Session root that is a
        // link out of it.
        fs::write(path.join("AuthorizationUsage"), b"").unwrap();
        assert_eq!(
            host.authority()
                .unwrap()
                .require_state(&store)
                .unwrap_err()
                .code,
            "recordUnreadable"
        );
        fs::remove_file(path.join("AuthorizationUsage")).unwrap();
        std::os::unix::fs::symlink(&path, path.join("Sessions")).unwrap();
        assert_eq!(
            host.authority()
                .unwrap()
                .require_state(&store)
                .unwrap_err()
                .code,
            "recordUnreadable"
        );
        fs::remove_file(path.join("Sessions")).unwrap();
        host.authority().unwrap().require_state(&store).unwrap();
        fs::remove_dir_all(&path).unwrap();
    }
    #[cfg(target_os = "macos")]
    #[test]
    fn candidate_name_owner_uses_only_runtime_snapshot_and_advances_cas() {
        use serde_json::json;
        use std::{fs, os::unix::fs::DirBuilderExt};
        let path = std::env::temp_dir()
            .canonicalize()
            .unwrap()
            .join(format!("candidate-host-{}", fresh_id().unwrap()));
        fs::DirBuilder::new().mode(0o700).create(&path).unwrap();
        let mut host = Host::from_environment()
            .with_targets(arkdeck_hoststore::TargetStore::open(&path).unwrap());
        host.provider = None; // Explicitly simulated in-memory snapshot; no transport is reachable.
        let params = json!({"candidate":"fixture-serial","observationId":"obs-fixture","observationGeneration":"1","name":"Bench"});
        assert_eq!(
            host.candidate_display_name("device.display-name.set", params.as_object().unwrap())
                .unwrap_err()
                .code,
            "resourceConflict"
        );
        let snapshot:DeviceObservationsResult=serde_json::from_value(json!({"schemaVersion":"arkdeck.device-observations/1","snapshotGeneration":"1","observedAtUtc":"2026-09-12T00:00:00Z","health":"current","observations":[{"candidateKey":"fixture-serial","authorizationState":"Connected","observationId":"obs-fixture","observationContinuity":"generationScoped","displayNameGeneration":"1","adoptedTargetId":null,"bindingRevision":null,"displayName":null,"deviceInformation":null,"observedFacts":null}]})).unwrap();
        *host.observations.lock().unwrap() = ObservationState {
            generation: 1,
            snapshot: Some(snapshot),
        };
        let reply = host
            .candidate_display_name("device.display-name.set", params.as_object().unwrap())
            .unwrap();
        assert_eq!(reply["generation"], "2");
        assert_eq!(
            host.observations
                .lock()
                .unwrap()
                .snapshot
                .as_ref()
                .unwrap()
                .observations[0]
                .display_name
                .as_deref(),
            Some("Bench")
        );
        assert_eq!(
            host.candidate_display_name("device.display-name.set", params.as_object().unwrap())
                .unwrap_err()
                .code,
            "resourceConflict"
        );
        let mut forged = params.clone();
        forged["observationGeneration"] = json!("2");
        forged["freshFacts"] = json!({"connected":true});
        assert_eq!(
            host.candidate_display_name("device.display-name.set", forged.as_object().unwrap())
                .unwrap_err()
                .code,
            "invalidParams"
        );
        let clear = json!({"candidate":"fixture-serial","observationId":"obs-fixture","observationGeneration":"2"});
        assert_eq!(
            host.candidate_display_name("device.display-name.clear", clear.as_object().unwrap())
                .unwrap()["generation"],
            "3"
        );
        drop(host);
        let restarted = Host::from_environment()
            .with_targets(arkdeck_hoststore::TargetStore::open(&path).unwrap());
        assert_eq!(
            restarted
                .candidate_display_name("device.display-name.clear", clear.as_object().unwrap())
                .unwrap_err()
                .code,
            "resourceConflict"
        );
        drop(restarted);
        fs::remove_dir_all(path).unwrap();
    }
    #[test]
    fn utc_spelling_and_leap_day() {
        assert_eq!(timestamp(0), "1970-01-01T00:00:00Z");
        assert_eq!(timestamp(1_709_251_199), "2024-02-29T23:59:59Z");
        assert_eq!(timestamp(1_709_251_200), "2024-03-01T00:00:00Z");
    }
}

#[cfg(all(test, target_os = "macos"))]
mod session_activity_tests {
    use super::*;
    use std::{fs, os::unix::fs::DirBuilderExt};
    struct Fixture(std::path::PathBuf);
    impl Fixture {
        fn new() -> Self {
            let root = std::env::temp_dir()
                .canonicalize()
                .unwrap()
                .join(format!("host-cleanup-{}", fresh_id().unwrap()));
            for name in ["state", "sessions", "artifacts", "jobs"] {
                fs::DirBuilder::new()
                    .recursive(true)
                    .mode(0o700)
                    .create(root.join(name))
                    .unwrap();
            }
            Self(root)
        }
        fn host(&self) -> Host {
            Host::from_environment().with_storage(
                arkdeck_hoststore::SessionStore::open(
                    &self.0.join("state"),
                    &self.0.join("sessions"),
                )
                .unwrap(),
                arkdeck_hoststore::ArtifactUsage::open(&self.0.join("artifacts"), 1024).unwrap(),
            )
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
    #[test]
    fn cleanup_requires_activity_owner_and_propagates_unreadable_job_inventory() {
        let fixture = Fixture::new();
        let params = serde_json::Map::new();
        assert_eq!(
            fixture
                .host()
                .session_resource("session.cleanup.preview", &params)
                .unwrap_err()
                .code,
            "operationUnavailable"
        );
        assert!(!fixture.0.join("state/session-cleanup-previews").exists());
        let unavailable = fixture
            .host()
            .with_jobs(arkdeck_hoststore::JobStore::open(&fixture.0.join("jobs")).unwrap());
        fs::rename(
            fixture.0.join("jobs/runtime-jobs.sqlite3"),
            fixture.0.join("jobs/replaced.sqlite3"),
        )
        .unwrap();
        assert_eq!(
            unavailable
                .session_resource("session.cleanup.preview", &params)
                .unwrap_err()
                .code,
            "recordUnreadable"
        );
        assert!(!fixture.0.join("state/session-cleanup-previews").exists());
    }
    #[test]
    fn preview_and_apply_use_the_actual_job_owner_and_refuse_when_it_is_missing() {
        let fixture = Fixture::new();
        let host = fixture
            .host()
            .with_jobs(arkdeck_hoststore::JobStore::open(&fixture.0.join("jobs")).unwrap());
        let preview = host
            .session_resource("session.cleanup.preview", &serde_json::Map::new())
            .unwrap();
        let params = serde_json::json!({"previewId":preview["previewId"], "previewDigest":preview["previewDigest"]});
        let result = host
            .session_resource("session.cleanup.apply", params.as_object().unwrap())
            .unwrap();
        assert_eq!(result["removedSessionIds"], serde_json::json!([]));
        let absent = fixture.host();
        assert_eq!(
            absent
                .session_resource("session.cleanup.apply", params.as_object().unwrap())
                .unwrap_err()
                .code,
            "operationUnavailable"
        );
    }
}

#[cfg(all(test, target_os = "macos"))]
mod cancellation_tests {
    use super::*;
    use std::sync::Arc;
    use std::time::{Duration, Instant};
    use std::{fs, os::unix::fs::DirBuilderExt};

    /// A composition whose Job owner is empty, so every request that reaches
    /// the owner answers for an absent Job.
    struct Fixture(std::path::PathBuf);
    impl Fixture {
        fn new() -> Self {
            let root = std::env::temp_dir()
                .canonicalize()
                .unwrap()
                .join(format!("host-cancel-{}", fresh_id().unwrap()));
            for name in ["jobs", "artifacts"] {
                fs::DirBuilder::new()
                    .recursive(true)
                    .mode(0o700)
                    .create(root.join(name))
                    .unwrap();
            }
            Self(root)
        }
        fn host(&self) -> Host {
            Host::from_environment()
                .with_jobs(arkdeck_hoststore::JobStore::open_owner(&self.0.join("jobs")).unwrap())
                .with_artifacts(
                    arkdeck_hoststore::ArtifactReadStore::open(&self.0.join("artifacts")).unwrap(),
                )
                .with_planning(&self.0, None)
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    fn job(id: &str) -> serde_json::Map<String, serde_json::Value> {
        serde_json::Map::from_iter([("jobId".into(), serde_json::json!(id))])
    }

    /// Holds `id` as a run or a cancellation of this owner would.
    fn hold(host: &Host, id: &str, cancelling: bool) -> Arc<RunSlot> {
        let slot = Arc::new(RunSlot {
            cancelling,
            ..RunSlot::default()
        });
        host.running
            .lock()
            .unwrap()
            .insert(id.to_owned(), slot.clone());
        slot
    }

    #[test]
    fn a_request_waits_in_the_run_and_falls_back_to_the_record_when_it_ends() {
        let fixture = Fixture::new();
        let host = fixture.host();
        let slot = hold(&host, "job-a", false);
        std::thread::scope(|scope| {
            let cancel = scope.spawn(|| host.job_cancel(&job("job-a")));
            // The run alone writes the Job's Journal, so the request waits in
            // it rather than in this owner.
            let deadline = Instant::now() + Duration::from_secs(30);
            while !slot.cancellation.pending() {
                assert!(
                    Instant::now() < deadline,
                    "the request never reached the run"
                );
                std::thread::sleep(Duration::from_millis(1));
            }
            assert!(!cancel.is_finished());
            // The run returns without acting on it, as job_run lets a run go.
            slot.cancellation.end();
            slot.finish(&Ok(serde_json::json!({})));
            host.running.lock().unwrap().remove("job-a");
            // The Job's record then decides; this owner holds no such Job.
            let absent = cancel.join().unwrap().unwrap_err();
            assert_eq!(
                (
                    absent.code.as_str(),
                    absent.message.as_str(),
                    &absent.details
                ),
                ("notFound", "unknown job job-a", &None)
            );
        });
        assert!(host.running.lock().unwrap().is_empty());
    }

    #[test]
    fn a_cancellation_is_joined_and_a_run_waits_it_out() {
        let fixture = Fixture::new();
        let host = fixture.host();
        let slot = hold(&host, "job-b", true);
        std::thread::scope(|scope| {
            let cancel = scope.spawn(|| host.job_cancel(&job("job-b")));
            let run = scope.spawn(|| host.job_run(&job("job-b")));
            // Both callers hold the slot: the map, this test and the two.
            let deadline = Instant::now() + Duration::from_secs(30);
            while Arc::strong_count(&slot) < 4 {
                assert!(Instant::now() < deadline, "the callers never met the slot");
                std::thread::sleep(Duration::from_millis(1));
            }
            assert!(!cancel.is_finished() && !run.is_finished());
            host.running.lock().unwrap().remove("job-b");
            slot.finish(&Ok(serde_json::json!({"cancelRequested": true})));
            // The concurrent cancellation answers what the first one did; the
            // run starts its own and meets the Job as the cancellation left it.
            assert_eq!(
                cancel.join().unwrap().unwrap(),
                serde_json::json!({"cancelRequested": true})
            );
            assert_eq!(run.join().unwrap().unwrap_err().code, "resourceNotFound");
        });
        assert!(host.running.lock().unwrap().is_empty());
    }
}
