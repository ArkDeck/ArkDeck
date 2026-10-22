impl Host {
    #[cfg(any(target_os = "macos", windows))]
    pub fn with_imports(mut self, imports: arkdeck_hoststore::ImportUploadStore) -> Self {
        self.imports = Some(std::sync::Arc::new(imports));
        self
    }

    #[cfg(any(target_os = "macos", windows))]
    pub fn with_targets(mut self, targets: arkdeck_hoststore::TargetStore) -> Self {
        self.targets = Some(std::sync::Arc::new(targets));
        self
    }
    #[cfg(any(target_os = "macos", windows))]
    pub fn with_jobs(mut self, jobs: arkdeck_hoststore::JobStore) -> Self {
        self.jobs = Some(std::sync::Arc::new(jobs));
        self
    }
    /// Swift `recoverActiveJobs()` at the daemon's start, before it serves:
    /// every active Job of this owner reopened, its unresolved intents parked
    /// and nothing dispatched, each use its capability store settles
    /// re-asserted. None without a Job owner.
    #[cfg(any(target_os = "macos", windows))]
    pub fn recover_active_jobs(
        &self,
    ) -> Result<Option<arkdeck_hoststore::RecoveredJobs>, arkdeck_hoststore::RecoveryError> {
        let Some(jobs) = &self.jobs else {
            return Ok(None);
        };
        let recovered =
            arkdeck_hoststore::recover_active_jobs(jobs, self.capabilities.as_deref(), clock_now)?;
        // Recovery answered which records it could not read; `doctor` says so
        // rather than reading them again.
        let _ = self.quarantined.set(recovered.quarantined.clone());
        Ok(Some(recovered))
    }
    /// Once Jobs are recovered and before the daemon serves: the staged
    /// Sessions a publication stopped by a crash left behind, each removed
    /// once it is proved this Runtime's and otherwise kept and named
    /// (`SessionPublisher::recover_staged`); nothing is published again. A
    /// recovery that cannot read staging keeps it all. None without a Job and
    /// a Session owner.
    #[cfg(any(target_os = "macos", windows))]
    pub fn recover_staged_sessions(&self) -> Option<arkdeck_hoststore::StagedRecovery> {
        let (Some(storage), Some(jobs)) = (self.storage.as_deref(), self.jobs.as_deref()) else {
            return None;
        };
        let probe = arkdeck_hoststore::SystemStorageProbe;
        let recovered = arkdeck_hoststore::SessionPublisher {
            sessions: &storage.0,
            claims: &self.claims,
            probe: &probe,
        }
        .recover_staged(jobs)
        .unwrap_or_else(|error| arkdeck_hoststore::StagedRecovery {
            kept: vec![(
                ".staging".into(),
                format!("staging could not be recovered: {error}"),
            )],
            ..Default::default()
        });
        let _ = self.staged_kept.set(recovered.kept.clone());
        Some(recovered)
    }
    /// Once Jobs are recovered, the line naming the enter-Loader transition
    /// that awaits the binding the start-up reconciliation carried its Target
    /// to (`RockchipStartup::awaiting_transition`); an error stops the start.
    /// None without a Job owner.
    #[cfg(target_os = "macos")]
    pub fn loader_transition_awaiting(
        &self,
        startup: &arkdeck_hoststore::RockchipStartup,
    ) -> Result<Option<String>, String> {
        match &self.jobs {
            Some(jobs) => startup.awaiting_transition(jobs),
            None => Ok(None),
        }
    }
    /// `agent.run` and `agent.status` advance and read this owner's
    /// executions, which own Jobs of the Job owner.
    #[cfg(any(target_os = "macos", windows))]
    pub fn with_agent_executions(mut self, agents: arkdeck_hoststore::AgentExecutionStore) -> Self {
        self.agents = Some(std::sync::Arc::new(agents));
        self
    }
    /// `capability.list` and `capability.inspect` read this capability store.
    #[cfg(any(target_os = "macos", windows))]
    pub fn with_capabilities(mut self, capabilities: arkdeck_hoststore::CapabilityStore) -> Self {
        self.capabilities = Some(std::sync::Arc::new(capabilities));
        self
    }
    /// `job.plan` reads the Artifact owner, the configured analyzer and the
    /// state root's Runtime debug attempt permits.
    #[cfg(any(target_os = "macos", windows))]
    pub fn with_planning(
        mut self,
        state_root: &std::path::Path,
        analyzer: Option<arkdeck_hoststore::AnalyzerProfiles>,
    ) -> Self {
        self.planning = Some((state_root.to_owned(), analyzer.unwrap_or_default()));
        self
    }
    /// The Job planner over this Windows composition's owners, as macOS
    /// builds it: the Artifact and Import owners, the analyzers, the
    /// workspace provider and the HDC composition, where one is composed.
    #[cfg(windows)]
    fn planner<'a>(
        &'a self,
        state_root: &'a std::path::Path,
        hdc: Option<&'a arkdeck_hoststore::HdcComposition<'a>>,
    ) -> arkdeck_hoststore::JobPlanner<'a> {
        arkdeck_hoststore::JobPlanner {
            imports: self.imports.as_deref(),
            artifacts: self.artifacts.as_deref(),
            analyzer: self
                .planning
                .as_ref()
                .map(|(_, analyzers)| analyzers as &dyn arkdeck_hoststore::AnalyzerComposition),
            state_root,
            hdc,
            workspace: self.workspace.as_deref(),
        }
    }
    #[cfg(any(target_os = "macos", windows))]
    pub fn with_artifacts(mut self, artifacts: arkdeck_hoststore::ArtifactReadStore) -> Self {
        self.artifacts = Some(std::sync::Arc::new(artifacts));
        self
    }
    /// Swift's daemon startup `collectGarbage`: the expired Artifacts this
    /// host's owners may reclaim, reclaimed now, or why nothing more was;
    /// `None` without a Job and an Artifact owner.
    #[cfg(any(target_os = "macos", windows))]
    pub fn collect_expired_artifacts(&self) -> Option<Result<Vec<String>, String>> {
        let (jobs, artifacts) = (self.jobs.as_ref()?, self.artifacts.as_ref()?);
        Some(match clock_now() {
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
    #[cfg(any(target_os = "macos", windows))]
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
    #[cfg(any(target_os = "macos", windows))]
    fn managed_hdc(&self) -> Option<&crate::managed_hdc::ManagedHdc> {
        self.hdc.as_ref().and_then(|hdc| hdc.managed())
    }
    /// The USB relations the Target observation owner reads: a test's, or
    /// the development source the isolated owner names
    /// (`development_usb::relation_source`).
    #[cfg(target_os = "macos")]
    pub fn with_usb_relations(
        mut self,
        usb: std::sync::Arc<dyn arkdeck_provider_hdc::UsbRelations + Send + Sync>,
    ) -> Self {
        self.usb = usb;
        self.usb_registry = false;
        self
    }
    /// The Runtime's own USB relations, which a composition reads beside the
    /// registered HDC it started as its managed server
    /// (`development_usb::relation_source`): Swift's `registeredDAYU200()`
    /// over `registry`'s census, taken afresh on every read —
    /// `UsbRegistryRelations::system()`, the host's I/O Registry, or a test's
    /// census. The owner census names it.
    #[cfg(any(target_os = "macos", windows))]
    pub fn with_usb_registry_relations<C>(
        mut self,
        registry: arkdeck_provider_hdc::UsbRegistryRelations<C>,
    ) -> Self
    where
        C: Fn() -> Result<
                Vec<arkdeck_platform::UsbHostDevice>,
                arkdeck_platform::RegistryUnavailable,
            > + Send
            + Sync
            + 'static,
    {
        self.usb = std::sync::Arc::new(registry);
        self.usb_registry = true;
        self
    }
    /// The USB relations the Target observation owner reads.
    #[cfg(all(test, target_os = "macos"))]
    pub(crate) fn usb_relations(&self) -> &dyn arkdeck_provider_hdc::UsbRelations {
        &*self.usb
    }
    /// The HDC the Target observation owner dispatches through: the
    /// development or managed HDC this composition registered. On Windows
    /// that is only a registered HDC tuple's managed server (CHG-2026-078);
    /// without one the Target observation owner observes nothing, dispatches
    /// nothing and refuses every adoption before admission (`target_adopt`).
    #[cfg(any(target_os = "macos", windows))]
    fn hdc_dispatch(&self) -> Option<&dyn arkdeck_provider_hdc::HdcDispatch> {
        self.job_hdc()
            .map(|(hdc, _)| hdc as &dyn arkdeck_provider_hdc::HdcDispatch)
    }
    /// Runs `run` over the Target observation owner's sources — the
    /// development HDC, the USB relations, the Target store and the clock —
    /// when this composition has them.
    #[cfg(any(target_os = "macos", windows))]
    fn observe<T>(&self, run: impl FnOnce(&arkdeck_hoststore::Sources<'_>) -> T) -> Option<T> {
        let (dispatch, targets) = (self.hdc_dispatch()?, self.targets.as_ref()?);
        Some(run(&arkdeck_hoststore::Sources {
            dispatch,
            relations: &*self.usb,
            targets,
            now: &utc_now,
        }))
    }
    /// The Target observation owner an execution that names no target
    /// observes through, when this composition has its sources.
    #[cfg(any(target_os = "macos", windows))]
    fn observing(&self) -> Option<arkdeck_hoststore::Observing<'_>> {
        let ((dispatch, _), targets) = (self.job_hdc()?, self.targets.as_ref()?);
        Some(arkdeck_hoststore::Observing {
            owner: &self.target_observations,
            sources: arkdeck_hoststore::Sources {
                dispatch,
                relations: &*self.usb,
                targets,
                now: &utc_now,
            },
        })
    }
    /// `human-action.list` and `human-action.show` read the physical
    /// assistance this owner's agent executions ask for and the impact
    /// approvals of the union control-action owner's actions.
    #[cfg(any(target_os = "macos", windows))]
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
    #[cfg(any(target_os = "macos", windows))]
    pub fn with_control_actions(
        mut self,
        resources: arkdeck_hoststore::ControlActionResources,
    ) -> Self {
        self.control_actions = Some(resources);
        self
    }
    #[cfg(any(target_os = "macos", windows))]
    fn with_hdc_impact<R>(
        &self,
        run: impl FnOnce(Option<&dyn arkdeck_hoststore::ImpactSource>) -> R,
    ) -> R {
        #[cfg(all(test, any(target_os = "macos", windows)))]
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
        // The process verification `runtime.hdc.status` uses: the kernel's
        // argv read on macOS, the launch's provenance on Windows.
        let verifier = managed.process_verifier();
        let source = arkdeck_hoststore::ManagedServerImpact {
            executable: managed.executable().clone(),
            endpoint: managed.endpoint().to_owned(),
            launch: &launch,
            supervisor: Some(managed),
            identity: &identity,
            signature: &arkdeck_provider_hdc::NativeSignature,
            verifier: &verifier,
            dispatch: &**hdc,
            jobs: &current_jobs,
            targets: &target_records,
            devices: &devices,
        };
        run(Some(&source))
    }

    /// The HDC composition device-bound Jobs plan, admit, run and reconcile
    /// through: this composition's development HDC over its Target store. On
    /// Windows that HDC exists only as a registered tuple's managed server
    /// (`windows_hdc_gate`, CHG-2026-078).
    #[cfg(any(target_os = "macos", windows))]
    pub(crate) fn hdc(&self) -> Option<arkdeck_hoststore::HdcComposition<'_>> {
        let ((dispatch, tool_sha256), targets) = (self.job_hdc()?, self.targets.as_ref()?);
        Some(arkdeck_hoststore::HdcComposition {
            targets,
            dispatch,
            receive_root: Some(&self.receive_root),
            tool_sha256,
            now: clock_now,
            code_sign_helper: self.code_sign_helper.as_ref(),
        })
    }

    /// Whether the HDC [`Self::job_hdc`] names still verifies, without
    /// launching anything (a test's fake always does).
    #[cfg(any(target_os = "macos", windows))]
    fn hdc_tool_current(&self) -> bool {
        #[cfg(all(windows, test))]
        if self.test_hdc.is_some() {
            return true;
        }
        self.hdc
            .as_ref()
            .is_some_and(|dispatch| dispatch.tool_identity_current())
    }

    /// The HDC this composition's Jobs and Target owners dispatch through,
    /// with the tool digest it answers as: the development or managed HDC,
    /// or, in a Windows test build, the in-process fake a test composed
    /// first (`with_test_hdc`; the production daemon has no such seam).
    #[cfg(any(target_os = "macos", windows))]
    fn job_hdc(&self) -> Option<(&(dyn arkdeck_provider_hdc::HdcDispatch + Sync), &str)> {
        #[cfg(all(windows, test))]
        if let Some((fake, tool_sha256)) = &self.test_hdc {
            return Some((&**fake, tool_sha256));
        }
        self.hdc.as_deref().map(|hdc| {
            (
                hdc as &(dyn arkdeck_provider_hdc::HdcDispatch + Sync),
                hdc.tool_sha256(),
            )
        })
    }

    /// [`Self::job_hdc`] held beyond this borrow, for a Job run in the
    /// background.
    #[cfg(windows)]
    fn owned_job_hdc(
        &self,
    ) -> Option<(
        std::sync::Arc<dyn arkdeck_provider_hdc::HdcDispatch + Send + Sync>,
        String,
    )> {
        #[cfg(test)]
        if let Some((fake, tool_sha256)) = &self.test_hdc {
            return Some((fake.clone(), tool_sha256.clone()));
        }
        self.hdc.as_ref().map(|hdc| {
            let sha256 = hdc.tool_sha256().to_owned();
            (
                hdc.clone() as std::sync::Arc<dyn arkdeck_provider_hdc::HdcDispatch + Send + Sync>,
                sha256,
            )
        })
    }

    /// Rockchip managed control uses the same descriptor-bound dispatch and
    /// managed server generation as every other operation of this owner.
    /// On Windows no descriptor-bound HDC is composed until the Windows HDC
    /// tuple is registered, so there is no resolver and no executable lane is
    /// installed (`arkforge_execution::install`).
    #[cfg(any(target_os = "macos", windows))]
    pub(crate) fn rockchip_target_store(
        &self,
    ) -> Option<std::sync::Arc<arkdeck_hoststore::TargetStore>> {
        self.targets.clone()
    }

    #[cfg(any(target_os = "macos", windows))]
    pub(crate) fn rockchip_hdc_resolver(&self) -> Option<Box<arkdeck_hoststore::HdcResolver>> {
        let dispatch = self.hdc.clone()?;
        Some(Box::new(move || {
            if !dispatch.tool_identity_current() {
                return Err("the descriptor-bound HDC executable changed".into());
            }
            Ok(dispatch.clone()
                as std::sync::Arc<dyn arkdeck_provider_hdc::HdcDispatch + Send + Sync>)
        }))
    }
    /// The bundled code-sign helper a native deployment stages, verified by
    /// the composition that found it (`code_sign_helper.rs`). With one,
    /// `deploy.native-library.app-owned@1` is available and planned; without
    /// one it stays unavailable, as Swift's composition leaves it.
    #[cfg(any(target_os = "macos", windows))]
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
    /// The installed Runtime's own state root, which a device mutation
    /// proves its continuity against: the production composition names it
    /// from the same account home as every other root it composes (on
    /// Windows, `windows_lifecycle::Authority::compose`).
    #[cfg(any(target_os = "macos", windows))]
    pub(crate) fn with_mutation_root(mut self, root: std::path::PathBuf) -> Self {
        self.default_mutation_root = Some(root);
        self
    }
    #[cfg(all(test, target_os = "macos"))]
    pub(crate) fn mutation_root(&self) -> Option<&std::path::Path> {
        self.default_mutation_root.as_deref()
    }
    /// What a device mutation is authorized from: the capability store and
    /// this daemon's device sessions. Without a store no mutation is admitted.
    #[cfg(any(target_os = "macos", windows))]
    pub(crate) fn authority(&self) -> Option<arkdeck_hoststore::MutationAuthority<'_>> {
        Some(arkdeck_hoststore::MutationAuthority {
            default_root: self.default_mutation_root.as_deref()?,
            sessions: self.storage.as_ref().map(|storage| &storage.0),
            capabilities: self.capabilities.as_ref()?,
            holds: &self.holds,
        })
    }
    /// The slot a `job.run` of `job` runs in, unless a run or cancellation
    /// already holds the Job or a reconcile of it is under way. `running` is
    /// locked before `reconciling`, as `job.reconcile` locks them, so a run
    /// and a reconcile never both begin on one Job; none if a lock is
    /// poisoned.
    #[cfg(any(target_os = "macos", windows))]
    pub(crate) fn claim_run(&self, job: &str) -> Option<RunClaim> {
        let mut running = self.running.lock().ok()?;
        if let Some(reconcile) = self.reconciling.lock().ok()?.get(job).cloned() {
            return Some(RunClaim::Reconciling(reconcile));
        }
        if let Some(slot) = running.get(job).cloned() {
            return Some(RunClaim::Held(slot));
        }
        let slot = std::sync::Arc::new(RunSlot::default());
        running.insert(job.to_owned(), slot.clone());
        Some(RunClaim::Own(slot))
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
        let quota = self.artifact_limit();
        let imports = self.imports.clone();
        let receive_root = self.receive_root.clone();
        let helper = self.code_sign_helper.clone();
        let default_mutation_root = self.default_mutation_root.clone();
        let capabilities = self.capabilities.clone();
        let holds = self.holds.clone();
        let workspace = self.workspace.clone();
        let state_root = self.planning.as_ref().map(|(root, _)| root.clone());
        let flash_runtime = self.flash_runtime.clone();
        let flash_planning = self.flash_planning.clone();
        let flash_facts = self.flash_facts.clone();
        // Swift's `startJob` runs the owned Job with the engine that admitted
        // it: the analyzer the admission materialized the plan against is the
        // one the run dispatches, or an admitted analyzer Job could never run.
        let analyzer = self
            .planning
            .as_ref()
            .map(|(_, analyzer)| analyzer.clone())
            .unwrap_or_default();
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
                    now: clock_now,
                    code_sign_helper: helper.as_ref(),
                }),
                _ => None,
            };
            let params =
                serde_json::Map::from_iter([("jobId".into(), serde_json::json!(start.job))]);
            let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                let runner = arkdeck_hoststore::JobRunner {
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
                    analyzer: Some(&analyzer),
                    quota,
                    home: &home,
                    now: clock_now,
                    precise_now: clock_precise_now,
                    sessions: publisher.as_ref(),
                    cancellation: Some(&slot.cancellation),
                    after_commit: None,
                    hdc: hdc.as_ref(),
                    workspace: workspace.as_deref(),
                };
                let facts_port = |target: &str, recommission: bool| {
                    flash_facts
                        .as_ref()
                        .ok_or("Flash facts owner is absent".to_owned())?
                        .operation_facts(
                            targets
                                .as_deref()
                                .ok_or("Target owner is absent".to_owned())?,
                            dispatch
                                .as_deref()
                                .map(|hdc| hdc as &dyn arkdeck_provider_hdc::HdcDispatch),
                            target,
                            recommission,
                        )
                };
                let flash = flash_runtime
                    .as_ref()
                    .zip(flash_planning.as_deref())
                    .zip(flash_facts.as_ref())
                    .zip(targets.as_deref())
                    .map(
                        |(((runtime, planning), _), targets)| arkdeck_hoststore::FlashExecution {
                            planning,
                            facts: &facts_port,
                            lane: &*runtime.lane,
                            profile_id: &runtime.profile_id,
                            host: &*runtime.host,
                            targets,
                        },
                    );
                arkdeck_hoststore::FlashRunner { runner, flash }
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
    /// Swift `startJob` on Windows: the owned Job runs in the background in
    /// the slot every `job.run` and `job.cancel` of it meets, through the
    /// runner `job.run` composes here (the composed analyzers, workspace
    /// provider and HDC), and its end is reported to the execution.
    #[cfg(windows)]
    fn start_agent_run(&self, start: arkdeck_hoststore::AgentStart) {
        let (Some(agents), Some(jobs), Some(artifacts), Some(planning)) = (
            self.agents.clone(),
            self.jobs.clone(),
            self.artifacts.clone(),
            self.planning.clone(),
        ) else {
            return;
        };
        let (storage, claims, running, home) = (
            self.storage.clone(),
            self.claims.clone(),
            self.running.clone(),
            self.home.clone(),
        );
        let default_mutation_root = self.default_mutation_root.clone();
        let capabilities = self.capabilities.clone();
        let holds = self.holds.clone();
        let quota = self.artifact_limit();
        let imports = self.imports.clone();
        let targets = self.targets.clone();
        let dispatch = self.owned_job_hdc();
        let receive_root = self.receive_root.clone();
        let helper = self.code_sign_helper.clone();
        let flash_runtime = self.flash_runtime.clone();
        let flash_planning = self.flash_planning.clone();
        let flash_facts = self.flash_facts.clone();
        let workspace = self.workspace.clone();
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
            let authority = capabilities
                .as_deref()
                .zip(default_mutation_root.as_deref())
                .map(
                    |(capabilities, default_root)| arkdeck_hoststore::MutationAuthority {
                        default_root,
                        sessions: storage.as_ref().map(|storage| &storage.0),
                        capabilities,
                        holds: &holds,
                    },
                );
            let hdc = match (&dispatch, &targets) {
                (Some((dispatch, tool_sha256)), Some(targets)) => {
                    Some(arkdeck_hoststore::HdcComposition {
                        targets,
                        dispatch: &**dispatch,
                        receive_root: Some(&receive_root),
                        tool_sha256,
                        now: clock_now,
                        code_sign_helper: helper.as_ref(),
                    })
                }
                _ => None,
            };
            let params =
                serde_json::Map::from_iter([("jobId".into(), serde_json::json!(start.job))]);
            let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                // The Flash lane as `job.run` runs it.
                let facts_port = |target: &str, recommission: bool| {
                    flash_facts
                        .as_ref()
                        .ok_or("Flash facts owner is absent".to_owned())?
                        .operation_facts(
                            targets
                                .as_deref()
                                .ok_or("Target owner is absent".to_owned())?,
                            dispatch
                                .as_ref()
                                .map(|(hdc, _)| &**hdc as &dyn arkdeck_provider_hdc::HdcDispatch),
                            target,
                            recommission,
                        )
                };
                let flash = flash_runtime
                    .as_ref()
                    .zip(flash_planning.as_deref())
                    .zip(flash_facts.as_ref())
                    .zip(targets.as_deref())
                    .map(
                        |(((runtime, planning), _), targets)| arkdeck_hoststore::FlashExecution {
                            planning,
                            facts: &facts_port,
                            lane: &*runtime.lane,
                            profile_id: &runtime.profile_id,
                            host: &*runtime.host,
                            targets,
                        },
                    );
                arkdeck_hoststore::FlashRunner {
                    runner: windows_runner(
                        &planning,
                        &jobs,
                        &artifacts,
                        quota,
                        imports.as_deref(),
                        authority,
                        &home,
                        publisher.as_ref(),
                        Some(&slot.cancellation),
                        workspace.as_deref(),
                        hdc.as_ref(),
                    ),
                    flash,
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
    #[cfg(any(target_os = "macos", windows))]
    fn require_artifact_job(&self, job_id: &str) -> Result<(), WireError> {
        self.jobs
            .as_ref()
            .ok_or_else(job_owner_not_configured)?
            .read_snapshot(job_id)
            .map(|_| ())
    }
    #[cfg(any(target_os = "macos", windows))]
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
    /// The Bootstrap readers on Windows, an HDC identified by the
    /// composition's own tuple table (`BootstrapReaders::open_existing_identified`).
    #[cfg(windows)]
    pub fn with_identified_bootstrap(
        mut self,
        root: &std::path::Path,
        identities: arkdeck_hoststore::PublishedIdentities,
    ) -> io::Result<Self> {
        self.bootstrap = Some(
            crate::bootstrap_readers::BootstrapReaders::open_existing_identified(root, identities)?,
        );
        Ok(self)
    }

    #[cfg(any(target_os = "macos", windows))]
    pub fn with_storage(
        mut self,
        sessions: arkdeck_hoststore::SessionStore,
        artifacts: arkdeck_hoststore::ArtifactUsage,
    ) -> Self {
        self.storage = Some(std::sync::Arc::new((sessions, artifacts)));
        self
    }
    #[cfg(any(target_os = "macos", windows))]
    fn artifact_limit(&self) -> u64 {
        self.storage
            .as_deref()
            .map_or(ARTIFACT_QUOTA, |(_, artifacts)| artifacts.limit())
    }
    #[cfg(any(target_os = "macos", windows))]
    pub fn with_workspace_projects(
        mut self,
        store: arkdeck_hoststore::WorkspaceProjectStore,
    ) -> Self {
        self.workspace_projects = Some(std::sync::Arc::new(store));
        self
    }
    /// Swift's composition root over the registered workspace projects: each
    /// resolved to its profile — its registered Hvigor presets through the
    /// DevEco registry at `bootstrap`, each preset's exact pin resolved to the
    /// toolchain it names — the Runtime-owned copies under `state_root`
    /// adopted again, the registered generations marked applied. A copy that
    /// cannot be vouched for is reported, as Swift reports it, and stays
    /// unresolvable. The source inspection reads the registered roots with
    /// the `inspector` a host configured (`ARKDECK_WORKSPACE_INSPECTOR`),
    /// pinned now; one that is not a regular executable fails the start, as
    /// Swift's composition fails it. Without the project owner nothing is
    /// composed.
    #[cfg(any(target_os = "macos", windows))]
    pub fn with_workspace_operations(
        mut self,
        state_root: &std::path::Path,
        bootstrap: &std::path::Path,
        signing: Option<arkdeck_hoststore::SigningSetup>,
        inspector: Option<&std::ffi::OsStr>,
        symbolizer: Option<&std::ffi::OsStr>,
    ) -> Result<Self, String> {
        let Some(projects) = self.workspace_projects.clone() else {
            return Ok(self);
        };
        let inspector = inspector
            .map(|path| {
                arkdeck_hoststore::WorkspaceInspector::hashing(&path.to_string_lossy())
                    .map_err(|error| format!("workspace inspector: {error}"))
            })
            .transpose()?;
        let registry = arkdeck_hoststore::DevEcoRegistryStore::open_existing(bootstrap)
            .map_err(|error| error.to_string())?;
        let resolve = |reference: &str, generation: u64, preset: &str| {
            registry
                .resolve(reference, generation, "workspacePreset", preset)
                .map_err(|error| format!("{}: {}", error.code, error.message))
        };
        let (composition, notes) = arkdeck_hoststore::WorkspaceComposition::compose(
            projects,
            state_root,
            &self.home,
            clock_now,
            &resolve,
            signing,
            symbolizer.map(|path| path.to_string_lossy()).as_deref(),
        )?;
        use std::io::Write;
        match &notes.released_credential_owners {
            Some(Ok(released)) if !released.is_empty() => {
                println!(
                    "signing credential owner released presets no store record carries: {}",
                    released.join(",")
                );
                let _ = std::io::stdout().flush();
            }
            // An unreadable owner is reported where it matters: every
            // signing preset fails its resolution with the same cause.
            Some(Err(error)) => {
                eprintln!("signing credential owner reconciliation skipped: {error}");
            }
            _ => {}
        }
        for failure in &notes.unadopted {
            println!("runtime workspace not adopted for {failure}");
        }
        if !notes.unadopted.is_empty() {
            let _ = std::io::stdout().flush();
        }
        self.workspace = Some(std::sync::Arc::new(composition.with_inspector(inspector)));
        Ok(self)
    }
    #[cfg(any(target_os = "macos", windows))]
    pub fn with_history(mut self, history: arkdeck_hoststore::HistoryStore) -> Self {
        self.history = Some(history);
        self
    }
    /// `flash.reconcile-alias` repairs the post-flash alias this reconciler
    /// keeps, against this host's Target store.
    #[cfg(any(target_os = "macos", windows))]
    pub fn with_flash_alias_reconciler(
        mut self,
        reconciler: arkdeck_hoststore::FlashAliasReconciler,
    ) -> Self {
        self.flash_alias = Some(reconciler);
        self
    }
    /// `debug.status` and `recovery.flash-invocation.list` read this owner's
    /// invocation documents.
    #[cfg(any(target_os = "macos", windows))]
    pub fn with_flash_invocations(mut self, owner: arkdeck_hoststore::FlashInvocations) -> Self {
        self.flash_invocations = Some(owner);
        self
    }
    /// `flash.bootloader-status` and `flash.prerequisites` read these facts,
    /// against this host's Target store and, for the live probe, its HDC.
    #[cfg(any(target_os = "macos", windows))]
    pub fn with_flash_host_facts(mut self, facts: arkdeck_hoststore::FlashHostFacts) -> Self {
        self.flash_facts = Some(std::sync::Arc::new(facts));
        self
    }

    /// `job.plan` materializes the ArkForge Flash operations over this
    /// composition and the Rockchip facts; without it they stay the
    /// planner's, which does not materialize them.
    #[cfg(any(target_os = "macos", windows))]
    pub fn with_flash_planning(mut self, planning: arkdeck_hoststore::FlashPlanning) -> Self {
        self.flash_planning = Some(std::sync::Arc::new(planning));
        self
    }

    /// Install the executable lane only when production composition has all
    /// its ports. Admission still checks fresh facts, exact materialization,
    /// capability, history and both existing runtime/mutation locks.
    #[cfg(any(target_os = "macos", windows))]
    pub fn with_flash_execution(
        mut self,
        lane: std::sync::Arc<dyn arkdeck_provider_arkforge::FlashLane>,
        host: std::sync::Arc<dyn arkdeck_provider_arkforge::RockchipHost>,
        profile_id: String,
    ) -> Self {
        if let Some(planning) = self
            .flash_planning
            .as_mut()
            .and_then(std::sync::Arc::get_mut)
        {
            let provider = lane.clone();
            planning
                .set_recommission_quiescence(move |source| provider.recommission_quiescent(source));
        }
        if let (Some(planning), Some(jobs), Some(facts), Some(targets), Some(hdc)) = (
            &self.flash_planning,
            &self.jobs,
            &self.flash_facts,
            self.rockchip_target_store(),
            self.rockchip_hdc_resolver(),
        ) {
            planning.install_maintenance(std::sync::Arc::new(
                arkdeck_hoststore::MaintenanceContext::new(
                    jobs.clone(),
                    lane.clone(),
                    std::sync::Arc::new(arkdeck_hoststore::NativeMaintenanceReads::new(
                        facts.clone(),
                        targets,
                        hdc,
                    )),
                ),
            ));
        }
        self.flash_runtime = Some(std::sync::Arc::new(FlashRuntime {
            lane,
            host,
            profile_id,
        }));
        self
    }

    #[cfg(any(target_os = "macos", windows))]
    fn flash_execution<'a>(
        &'a self,
        facts: arkdeck_hoststore::RockchipFactsPort<'a>,
    ) -> Option<arkdeck_hoststore::FlashExecution<'a>> {
        let runtime = self.flash_runtime.as_ref()?;
        Some(arkdeck_hoststore::FlashExecution {
            planning: self.flash_planning.as_deref()?,
            facts,
            lane: &*runtime.lane,
            profile_id: &runtime.profile_id,
            host: &*runtime.host,
            targets: self.targets.as_deref()?,
        })
    }

    /// Runs `run` with this host's `job.plan` planner: the Job planner over
    /// its owners, with the Flash composition and Swift's ArkForge facts
    /// port — the Target store's, measured over this host's HDC when it has
    /// one. None without the planning owner.
    #[cfg(target_os = "macos")]
    fn with_flash_planner<T>(
        &self,
        run: impl FnOnce(&arkdeck_hoststore::FlashPlanner<'_>) -> T,
    ) -> Option<T> {
        let (state_root, analyzer) = self.planning.as_ref()?;
        let hdc = self.hdc();
        let facts = self.flash_facts_port();
        Some(run(&arkdeck_hoststore::FlashPlanner {
            planner: arkdeck_hoststore::JobPlanner {
                imports: self.imports.as_deref(),
                artifacts: self.artifacts.as_deref(),
                analyzer: Some(analyzer),
                state_root,
                hdc: hdc.as_ref(),
                workspace: self.workspace.as_deref(),
            },
            flash: self.flash_planning.as_deref(),
            facts: facts
                .as_ref()
                .map(|port| port as arkdeck_hoststore::RockchipFactsPort<'_>),
        }))
    }

    /// Runs `run` with `admitter` under this host's Flash composition: the
    /// ArkForge Flash operations are admitted over the Flash planning, facts
    /// and campaign, and executed only where this host also runs them. Both
    /// `job.submit` and an Agent execution admit through it, as Swift's
    /// `submitOwned` serves both.
    #[cfg(target_os = "macos")]
    fn with_flash_admitter<T>(
        &self,
        admitter: arkdeck_hoststore::JobAdmitter<'_>,
        run: impl FnOnce(&arkdeck_hoststore::FlashAdmitter<'_>) -> T,
    ) -> T {
        let facts = self.flash_facts_port();
        let campaign = self
            .flash_runtime
            .as_ref()
            .and_then(|runtime| runtime.lane.hardware_acceptance_campaign());
        run(&arkdeck_hoststore::FlashAdmitter {
            admitter,
            flash: self.flash_planning.as_deref(),
            facts: facts
                .as_ref()
                .map(|port| port as arkdeck_hoststore::RockchipFactsPort<'_>),
            executes: self.flash_runtime.is_some()
                && self.flash_facts.is_some()
                && self.targets.is_some(),
            campaign: campaign.as_deref(),
        })
    }

    /// Swift `RuntimeJobEngineDebugAttemptDriver.execute`: the recovery
    /// broker's attempt admitted as `job.submit` admits it — through the Flash
    /// admission, with its DEC-016 classification and the Runtime's own
    /// destructive capability — then run as `job.run` runs it, and classified
    /// by the Job and its capability use. Once a Job exists its attempt is
    /// never reported refused: an outcome that cannot be read is unknown.
    #[cfg(any(target_os = "macos", windows))]
    fn debug_attempt(&self, request: &[u8]) -> arkdeck_hoststore::DriverResult {
        let refused = |detail: String| arkdeck_hoststore::DriverResult {
            job_id: None,
            outcome: "refused",
            detail,
        };
        let (Some((state_root, analyzer)), Some(jobs)) = (&self.planning, &self.jobs) else {
            return refused("the Job owner is not composed".into());
        };
        let hdc = self.hdc();
        #[cfg(target_os = "macos")]
        let planner = arkdeck_hoststore::JobPlanner {
            imports: self.imports.as_deref(),
            artifacts: self.artifacts.as_deref(),
            analyzer: Some(analyzer),
            state_root,
            hdc: hdc.as_ref(),
            workspace: self.workspace.as_deref(),
        };
        // The Windows Job planner over the same owners (`Self::planner`).
        #[cfg(windows)]
        let planner = {
            let _ = analyzer;
            self.planner(state_root, hdc.as_ref())
        };
        let admitter = arkdeck_hoststore::JobAdmitter {
            planner,
            jobs,
            now: clock_now,
            authority: self.authority(),
        };
        let accepted = match self.with_flash_admitter(admitter, |admitter| admitter.submit(request))
        {
            Ok(accepted) => accepted,
            Err(refusal) => return refused(format!("{}: {}", refusal.code, refusal.message)),
        };
        let Some(job) = accepted["jobId"].as_str().map(str::to_owned) else {
            return refused("the admission named no Job".into());
        };
        let classify = || {
            arkdeck_hoststore::debug_execution_outcome(jobs, self.capabilities.as_deref(), &job)
                .unwrap_or("outcomeUnknown")
        };
        let params = serde_json::Map::from_iter([("jobId".into(), serde_json::json!(job))]);
        match self.job_run(&params) {
            Ok(_) => {
                let state = jobs
                    .read_snapshot(&job)
                    .map(|record| record.state)
                    .unwrap_or_default();
                arkdeck_hoststore::DriverResult {
                    outcome: classify(),
                    detail: format!("Runtime Job terminal state {state}"),
                    job_id: Some(job),
                }
            }
            Err(error) => arkdeck_hoststore::DriverResult {
                outcome: classify(),
                detail: format!(
                    "Runtime Job failed after admission: {}: {}",
                    error.code, error.message
                ),
                job_id: Some(job),
            },
        }
    }

    /// Swift's ArkForge facts port: the Target store's facts, measured over
    /// this host's HDC when it has one. None without the facts owner or the
    /// Target store.
    #[cfg(target_os = "macos")]
    fn flash_facts_port(
        &self,
    ) -> Option<impl Fn(&str, bool) -> Result<arkdeck_hoststore::RockchipFacts, String> + '_> {
        let (Some(facts), Some(targets)) = (&self.flash_facts, &self.targets) else {
            return None;
        };
        Some(move |target_id: &str, recommission: bool| {
            facts.operation_facts(
                targets,
                self.hdc
                    .as_deref()
                    .map(|hdc| hdc as &dyn arkdeck_provider_hdc::HdcDispatch),
                target_id,
                recommission,
            )
        })
    }

    /// Swift's ArkForge facts port on Windows: the Target store's facts over
    /// the HDC the Flash facts probe (composed only for the registered
    /// Windows HDC tuple's executable, as the root's managed server).
    #[cfg(windows)]
    fn flash_facts_port(
        &self,
    ) -> Option<impl Fn(&str, bool) -> Result<arkdeck_hoststore::RockchipFacts, String> + '_> {
        let (Some(facts), Some(targets)) = (&self.flash_facts, &self.targets) else {
            return None;
        };
        Some(move |target_id: &str, recommission: bool| {
            facts.operation_facts(targets, self.flash_hdc(), target_id, recommission)
        })
    }

    /// The Windows `job.plan` planner: the Job planner with the Flash
    /// composition and the facts port above (TASK-XPA-010).
    #[cfg(windows)]
    fn with_flash_planner<T>(
        &self,
        run: impl FnOnce(&arkdeck_hoststore::FlashPlanner<'_>) -> T,
    ) -> Option<T> {
        let (state_root, _) = self.planning.as_ref()?;
        let facts = self.flash_facts_port();
        let hdc = self.hdc();
        Some(run(&arkdeck_hoststore::FlashPlanner {
            planner: self.planner(state_root, hdc.as_ref()),
            flash: self.flash_planning.as_deref(),
            facts: facts
                .as_ref()
                .map(|port| port as arkdeck_hoststore::RockchipFactsPort<'_>),
        }))
    }

    /// The Windows Flash admission: the Flash planning and facts, and the
    /// executable lane where one is installed. None is installed without a
    /// descriptor-bound HDC, so until then an admissible Flash is refused
    /// before admission as Swift refuses one this Runtime does not execute,
    /// with zero dispatch.
    #[cfg(windows)]
    fn with_flash_admitter<T>(
        &self,
        admitter: arkdeck_hoststore::JobAdmitter<'_>,
        run: impl FnOnce(&arkdeck_hoststore::FlashAdmitter<'_>) -> T,
    ) -> T {
        let facts = self.flash_facts_port();
        let campaign = self
            .flash_runtime
            .as_ref()
            .and_then(|runtime| runtime.lane.hardware_acceptance_campaign());
        run(&arkdeck_hoststore::FlashAdmitter {
            admitter,
            flash: self.flash_planning.as_deref(),
            facts: facts
                .as_ref()
                .map(|port| port as arkdeck_hoststore::RockchipFactsPort<'_>),
            executes: self.flash_runtime.is_some()
                && self.flash_facts.is_some()
                && self.targets.is_some(),
            campaign: campaign.as_deref(),
        })
    }

    /// The HDC the Flash facts probe over: this host's (on Windows only a
    /// registered tuple's managed server).
    #[cfg(any(target_os = "macos", all(windows, not(test))))]
    fn flash_hdc(&self) -> Option<&dyn arkdeck_provider_hdc::HdcDispatch> {
        self.hdc
            .as_deref()
            .map(|hdc| hdc as &dyn arkdeck_provider_hdc::HdcDispatch)
    }

    /// In a Windows test build, the fake HDC the Flash host facts replay
    /// composed (`tests/spawning`), else this host's.
    #[cfg(all(windows, test))]
    fn flash_hdc(&self) -> Option<&dyn arkdeck_provider_hdc::HdcDispatch> {
        match &self.test_hdc {
            Some((fake, _)) => Some(fake.as_ref() as &dyn arkdeck_provider_hdc::HdcDispatch),
            None => self
                .hdc
                .as_deref()
                .map(|hdc| hdc as &dyn arkdeck_provider_hdc::HdcDispatch),
        }
    }

    /// Test builds on Windows only: the fake HDC `hdc`, answering as the tool
    /// whose digest is `tool_sha256`, is this host's (see `test_hdc`). The
    /// production Windows daemon has no such seam.
    #[cfg(all(windows, test))]
    #[allow(dead_code)]
    pub fn with_test_hdc(
        mut self,
        hdc: std::sync::Arc<dyn arkdeck_provider_hdc::HdcDispatch + Send + Sync>,
        tool_sha256: &str,
    ) -> Self {
        self.test_hdc = Some((hdc, tool_sha256.to_owned()));
        self
    }

    /// Test builds on Windows only: Flash maintenance over the composed
    /// lane and Job owner, with `reads` for the device readbacks. Windows
    /// resolves a USB connector only from the host's own device tree, which
    /// no fixture has; the production daemon has no such seam and composes
    /// `NativeMaintenanceReads` over its registered HDC.
    #[cfg(all(windows, test))]
    #[allow(dead_code)]
    pub fn with_test_maintenance_reads(
        self,
        reads: std::sync::Arc<dyn arkdeck_hoststore::MaintenanceReads>,
    ) -> Self {
        if let (Some(planning), Some(jobs), Some(runtime)) =
            (&self.flash_planning, &self.jobs, &self.flash_runtime)
        {
            planning.install_maintenance(std::sync::Arc::new(
                arkdeck_hoststore::MaintenanceContext::new(
                    jobs.clone(),
                    runtime.lane.clone(),
                    reads,
                ),
            ));
        }
        self
    }

    /// Test builds on Windows only: the fake HDC and its tool digest, when a
    /// test composed one ([`Self::with_test_hdc`]).
    #[cfg(all(windows, test))]
    #[allow(dead_code)]
    pub(crate) fn test_hdc(&self) -> Option<(&dyn arkdeck_provider_hdc::HdcDispatch, &str)> {
        self.test_hdc.as_ref().map(|(hdc, sha)| {
            (
                hdc.as_ref() as &dyn arkdeck_provider_hdc::HdcDispatch,
                sha.as_str(),
            )
        })
    }

    /// `flash.bind-current-loader` binds through this owner, against this
    /// host's Target store and Jobs.
    #[cfg(any(target_os = "macos", windows))]
    pub fn with_loader_binding(mut self, binding: arkdeck_hoststore::LoaderBinding) -> Self {
        self.loader_binding = Some(binding);
        self
    }

    /// `flash.device-access` reads the flashing modes the ArkForge lane's
    /// daemon sees attached through this observer.
    #[cfg(any(target_os = "macos", windows))]
    pub fn with_device_access(
        mut self,
        observer: arkdeck_provider_arkforge::DeviceAccessObserver,
    ) -> Self {
        self.device_access = Some(observer);
        self
    }

    /// `flash.lanePlanPreview` previews through the ArkForge lane composed
    /// over this host's Target store and Rockchip facts; none
    /// without a lane, as Swift composes its previewer only with one.
    #[cfg(any(target_os = "macos", windows))]
    pub fn with_lane_plan_preview(
        mut self,
        previewer: Option<std::sync::Arc<dyn arkdeck_provider_arkforge::LanePlanPreview>>,
    ) -> Self {
        self.lane_plan_preview = previewer;
        self
    }

    /// The owners this composition holds, by name, in a fixed order: what the
    /// production composition reports at its start and its tests compare.
    #[cfg(target_os = "macos")]
    pub(crate) fn owner_census(&self) -> Vec<&'static str> {
        [
            ("jobs", self.jobs.is_some()),
            ("capabilities", self.capabilities.is_some()),
            ("mutationAuthority", self.authority().is_some()),
            ("targets", self.targets.is_some()),
            ("artifacts", self.artifacts.is_some()),
            ("imports", self.imports.is_some()),
            ("storage", self.storage.is_some()),
            ("history", self.history.is_some()),
            ("workspaceProjects", self.workspace_projects.is_some()),
            ("workspaceOperations", self.workspace.is_some()),
            ("bootstrap", self.bootstrap.is_some()),
            ("planning", self.planning.is_some()),
            (
                "analyzer",
                self.planning
                    .as_ref()
                    .is_some_and(|(_, analyzer)| !analyzer.profiles().is_empty()),
            ),
            ("agentExecutions", self.agents.is_some()),
            ("humanActions", self.human_actions.is_some()),
            ("controlActions", self.control_actions.is_some()),
            ("traceCache", self.trace_cache.is_some()),
            ("hdc", self.hdc.is_some()),
            ("managedHdc", self.managed_hdc().is_some()),
            ("usbRegistryRelations", self.usb_registry),
            ("codeSignHelper", self.code_sign_helper.is_some()),
            ("flashAliasReconciler", self.flash_alias.is_some()),
            ("flashInvocations", self.flash_invocations.is_some()),
            ("flashHostFacts", self.flash_facts.is_some()),
            ("deviceAccess", self.device_access.is_some()),
            ("lanePlanPreview", self.lane_plan_preview.is_some()),
            ("loaderBinding", self.loader_binding.is_some()),
            ("readOnlyHdcProvider", self.provider.is_some()),
        ]
        .into_iter()
        .filter_map(|(name, composed)| composed.then_some(name))
        .collect()
    }

    /// The owners a Windows composition holds, by the names the macOS
    /// census gives them, in its order: what the daemon reports at its start.
    /// This list is the one place that order is spelled on Windows; an owner
    /// ported later goes in at its position in the macOS census above.
    #[cfg(windows)]
    pub(crate) fn owner_census(&self) -> Vec<&'static str> {
        [
            ("jobs", self.jobs.is_some()),
            ("capabilities", self.capabilities.is_some()),
            ("mutationAuthority", self.authority().is_some()),
            ("targets", self.targets.is_some()),
            ("artifacts", self.artifacts.is_some()),
            ("imports", self.imports.is_some()),
            ("storage", self.storage.is_some()),
            ("history", self.history.is_some()),
            ("workspaceProjects", self.workspace_projects.is_some()),
            ("workspaceOperations", self.workspace.is_some()),
            ("bootstrap", self.bootstrap.is_some()),
            ("planning", self.planning.is_some()),
            (
                "analyzer",
                self.planning
                    .as_ref()
                    .is_some_and(|(_, analyzer)| !analyzer.profiles().is_empty()),
            ),
            ("agentExecutions", self.agents.is_some()),
            ("humanActions", self.human_actions.is_some()),
            ("controlActions", self.control_actions.is_some()),
            ("traceCache", self.trace_cache.is_some()),
            ("hdc", self.hdc.is_some()),
            ("managedHdc", self.managed_hdc().is_some()),
            ("usbRegistryRelations", self.usb_registry),
            ("codeSignHelper", self.code_sign_helper.is_some()),
            ("flashAliasReconciler", self.flash_alias.is_some()),
            ("flashInvocations", self.flash_invocations.is_some()),
            ("flashHostFacts", self.flash_facts.is_some()),
            ("deviceAccess", self.device_access.is_some()),
            ("lanePlanPreview", self.lane_plan_preview.is_some()),
            ("loaderBinding", self.loader_binding.is_some()),
            ("readOnlyHdcProvider", self.provider.is_some()),
        ]
        .into_iter()
        .filter_map(|(name, composed)| composed.then_some(name))
        .collect()
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
            #[cfg(any(target_os = "macos", windows))]
            quarantined: std::sync::OnceLock::new(),
            #[cfg(any(target_os = "macos", windows))]
            staged_kept: std::sync::OnceLock::new(),
            #[cfg(any(target_os = "macos", windows))]
            imports: None,
            #[cfg(any(target_os = "macos", windows))]
            targets: None,
            #[cfg(any(target_os = "macos", windows))]
            artifacts: None,
            #[cfg(any(target_os = "macos", windows))]
            jobs: None,
            #[cfg(any(target_os = "macos", windows))]
            capabilities: None,
            #[cfg(any(target_os = "macos", windows))]
            planning: None,
            #[cfg(any(target_os = "macos", windows))]
            bootstrap: None,
            provider,
            #[cfg(any(target_os = "macos", windows))]
            history: None,
            #[cfg(any(target_os = "macos", windows))]
            workspace_projects: None,
            #[cfg(any(target_os = "macos", windows))]
            workspace: None,
            #[cfg(any(target_os = "macos", windows))]
            trace_cache: None,
            #[cfg(any(target_os = "macos", windows))]
            storage: None,
            unavailable,
            observations: Mutex::new(ObservationState::default()),
            #[cfg(any(target_os = "macos", windows))]
            running: Default::default(),
            #[cfg(any(target_os = "macos", windows))]
            reconciling: Default::default(),
            #[cfg(any(target_os = "macos", windows))]
            home: arkdeck_platform::runtime_home().unwrap_or_default(),
            #[cfg(target_os = "macos")]
            receive_root: arkdeck_platform::foundation_temporary_directory()
                .join("arkdeck-receive"),
            #[cfg(windows)]
            receive_root: windows_receive_root(),
            #[cfg(target_os = "macos")]
            default_mutation_root: arkdeck_platform::runtime_home()
                .map(std::path::PathBuf::from)
                .filter(|home| home.is_absolute())
                .map(|home| home.join("Library/Application Support/ArkDeck/Agentd")),
            // Named by the composition over a state root
            // (`windows_lifecycle::Authority::mutation_root`).
            #[cfg(windows)]
            default_mutation_root: None,
            #[cfg(any(target_os = "macos", windows))]
            claims: Default::default(),
            #[cfg(any(target_os = "macos", windows))]
            hdc: None,
            #[cfg(any(target_os = "macos", windows))]
            agents: None,
            #[cfg(any(target_os = "macos", windows))]
            holds: Default::default(),
            #[cfg(any(target_os = "macos", windows))]
            target_observations: Default::default(),
            #[cfg(any(target_os = "macos", windows))]
            usb: std::sync::Arc::new(arkdeck_provider_hdc::NoUsbRelations),
            #[cfg(any(target_os = "macos", windows))]
            usb_registry: false,
            #[cfg(any(target_os = "macos", windows))]
            code_sign_helper: None,
            #[cfg(any(target_os = "macos", windows))]
            human_actions: None,
            #[cfg(any(target_os = "macos", windows))]
            control_actions: None,
            #[cfg(any(target_os = "macos", windows))]
            flash_alias: None,
            #[cfg(any(target_os = "macos", windows))]
            flash_invocations: None,
            #[cfg(any(target_os = "macos", windows))]
            flash_facts: None,
            #[cfg(all(windows, test))]
            test_hdc: None,
            #[cfg(any(target_os = "macos", windows))]
            flash_planning: None,
            #[cfg(any(target_os = "macos", windows))]
            flash_runtime: None,
            #[cfg(any(target_os = "macos", windows))]
            device_access: None,
            #[cfg(any(target_os = "macos", windows))]
            lane_plan_preview: None,
            #[cfg(any(target_os = "macos", windows))]
            loader_binding: None,
            #[cfg(all(test, any(target_os = "macos", windows)))]
            test_hdc_impact: None,
        }
    }
}
