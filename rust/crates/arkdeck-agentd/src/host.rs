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
    #[cfg(target_os = "macos")]
    imports: Option<arkdeck_hoststore::ImportUploadStore>,
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
    /// Swift `NSHomeDirectory()`, which Artifact redaction replaces.
    #[cfg(target_os = "macos")]
    home: String,
    #[cfg(target_os = "macos")]
    default_mutation_root: Option<std::path::PathBuf>,
    /// Swift `HostStorageCoordinator`'s claims, held by the Session
    /// publications this process makes.
    #[cfg(target_os = "macos")]
    claims: std::sync::Arc<arkdeck_hoststore::StorageClaims>,
    /// The isolated owner's development HDC: the fixture executable its
    /// device-bound Jobs dispatch to, through the process dispatch every HDC
    /// plan takes.
    #[cfg(target_os = "macos")]
    hdc: Option<std::sync::Arc<arkdeck_provider_hdc::ProcessDispatch>>,
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
    /// The combined human-action owner over the agent executions.
    #[cfg(target_os = "macos")]
    human_actions: Option<arkdeck_hoststore::HumanActionResources>,
}

impl Host {
    #[cfg(target_os = "macos")]
    pub fn with_imports(mut self, imports: arkdeck_hoststore::ImportUploadStore) -> Self {
        self.imports = Some(imports);
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
    /// Device-bound Jobs plan against the Target owner and run through this
    /// development HDC; without one no HDC provider is registered.
    #[cfg(target_os = "macos")]
    pub fn with_development_hdc(
        mut self,
        dispatch: Option<arkdeck_provider_hdc::ProcessDispatch>,
    ) -> Self {
        self.hdc = dispatch.map(std::sync::Arc::new);
        self
    }
    /// The USB relations the Target observation owner reads. Only tests
    /// compose them until a development source lands.
    #[cfg(all(test, target_os = "macos"))]
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
    /// assistance this owner's agent executions ask for.
    #[cfg(target_os = "macos")]
    pub fn with_human_actions(
        mut self,
        resources: arkdeck_hoststore::HumanActionResources,
    ) -> Self {
        self.human_actions = Some(resources);
        self
    }
    #[cfg(target_os = "macos")]
    fn hdc(&self) -> Option<arkdeck_hoststore::HdcComposition<'_>> {
        let (dispatch, targets) = (self.hdc.as_ref()?, self.targets.as_ref()?);
        Some(arkdeck_hoststore::HdcComposition {
            targets,
            dispatch: &**dispatch,
            tool_sha256: dispatch.tool_sha256(),
            now: arkdeck_hoststore::runtime_now,
        })
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
                    tool_sha256: dispatch.tool_sha256(),
                    now: arkdeck_hoststore::runtime_now,
                }),
                _ => None,
            };
            let params =
                serde_json::Map::from_iter([("jobId".into(), serde_json::json!(start.job))]);
            let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                arkdeck_hoststore::JobRunner {
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
            trace_cache: None,
            #[cfg(target_os = "macos")]
            storage: None,
            unavailable,
            observations: Mutex::new(ObservationState::default()),
            #[cfg(target_os = "macos")]
            running: Default::default(),
            #[cfg(target_os = "macos")]
            home: arkdeck_platform::runtime_home().unwrap_or_default(),
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
            human_actions: None,
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
                hdc_tool_current: if provider == "hdc"
                    && [
                        "observe.device@1",
                        "capture.diagnostics@1",
                        "input.tap@1",
                        "input.long-press@1",
                        "input.swipe@1",
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
        if method == "artifact.import.list" {
            return self.imports.as_ref().ok_or_else(unavailable)?.list(params);
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

    /// `human-action.list` and `human-action.show`, as the Swift daemon
    /// answers them with its combined human-action owner.
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
        resources.answer(method, params, agents)
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
    /// Swift's daemon answers from the observer its HDC host gives it, and
    /// `unconfigured()` without one. This composition starts no managed HDC
    /// server, so it answers as Swift's daemon without its HDC host does.
    #[cfg(target_os = "macos")]
    fn runtime_hdc_status(&self) -> Result<serde_json::Value, WireError> {
        Ok(arkdeck_provider_hdc::unconfigured_status(None))
    }

    fn observed_at(&self) -> String {
        utc_now()
    }
    fn hdc_status(&self, deep: bool) -> HdcStatus {
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
