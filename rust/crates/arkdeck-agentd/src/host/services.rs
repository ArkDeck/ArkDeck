include!("services_runtime.rs");

impl HostServices for Host {
    fn registered_provider_ids(&self) -> Vec<&'static str> {
        let mut providers = Vec::new();
        let hdc = self.provider.is_some();
        #[cfg(any(target_os = "macos", windows))]
        let hdc = hdc || self.hdc.is_some();
        #[cfg(all(windows, test))]
        let hdc = hdc || self.test_hdc.is_some();
        if hdc {
            providers.push("hdc");
        }
        #[cfg(any(target_os = "macos", windows))]
        {
            if self.planning.is_some() {
                providers.push("analyzer");
            }
            if self.workspace.is_some() {
                providers.push("workspace");
            }
            if self.flash_planning.is_some() {
                providers.push("arkforge");
            }
        }
        providers
    }

    /// `operation.list`: the availability of each operation over this
    /// composition's owners, its HDC included (on Windows only a registered
    /// tuple's managed server).
    #[cfg(any(target_os = "macos", windows))]
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
                    .map(|(_, analyzer)| analyzer as &dyn arkdeck_hoststore::AnalyzerComposition),
                hdc_registered: self.job_hdc().is_some() && self.targets.is_some(),
                mutation_owner: self
                    .authority()
                    .zip(self.jobs.as_deref())
                    .is_some_and(|(authority, jobs)| authority.state_proven_now(jobs)),
                code_sign_helper: self.code_sign_helper.is_some(),
                // Asked only of an operation this executor runs: every other
                // one is unsupported whatever the tool measures.
                hdc_tool_current: if provider == "hdc"
                    && arkdeck_hoststore::hdc_operation_runs(reference)
                {
                    self.hdc_tool_current()
                } else {
                    false
                },
                workspace: self.workspace.as_deref(),
                flash_planning: self.flash_planning.as_deref(),
                flash_execution: self.flash_runtime.is_some()
                    && self.flash_facts.is_some()
                    && self.targets.is_some(),
            },
        )
    }

    #[cfg(any(target_os = "macos", windows))]
    fn import_resource(
        &self,
        method: &str,
        params: &serde_json::Map<String, serde_json::Value>,
    ) -> Result<serde_json::Value, WireError> {
        // Local control clients never inherit the App's trusted transport provenance.
        self.imports_for(method, params, false)
    }
    /// Swift's `RuntimeImportControlGateway` for the App transport: the
    /// owner records an Import the App begins as App-owned, atomically with
    /// it, so a restart keeps that ownership; it refuses to append to, abort
    /// or commit any other before it writes anything. Discovery, inspection
    /// and release stay local.
    #[cfg(any(target_os = "macos", windows))]
    fn app_import_resource(
        &self,
        method: &str,
        params: &serde_json::Map<String, serde_json::Value>,
    ) -> Result<serde_json::Value, WireError> {
        if ![
            "artifact.import.begin",
            "artifact.import.append",
            "artifact.import.abort",
            "artifact.import.commit",
        ]
        .contains(&method)
        {
            return Err(WireError {
                code: "rejected".into(),
                message: "Import discovery, inspection and release are not available to the App"
                    .into(),
                details: None,
            });
        }
        // Swift's App gateway without its Artifact owner refuses the App's
        // follow-up uploads before the Runtime; a begin reaches the handler,
        // which refuses it for its missing owners.
        if method != "artifact.import.begin" && (self.imports.is_none() || self.artifacts.is_none())
        {
            return Err(WireError {
                code: "admissionDenied".into(),
                message: "Import is outside this App upload scope".into(),
                details: Some(serde_json::Map::from_iter([
                    ("phase".into(), serde_json::json!("preAdmission")),
                    ("newDispatchCount".into(), serde_json::json!(0)),
                ])),
            });
        }
        self.imports_for(method, params, true)
    }

    #[cfg(any(target_os = "macos", windows))]
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
    #[cfg(any(target_os = "macos", windows))]
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
        // With the development HDC (on Windows, the registered tuple), the
        // Target observation owner observes, so its current snapshot is the
        // one a candidate is named in.
        if let Some(named) = self.observe(|sources| {
            self.target_observations.name_candidate(
                sources.targets,
                &reference,
                params.get("name").and_then(serde_json::Value::as_str),
                &utc_now(),
            )
        }) {
            return named.unwrap_or_else(|| {
                Err(fail(
                    "resourceConflict",
                    "No current observation snapshot exists",
                ))
            });
        }
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

    #[cfg(any(target_os = "macos", windows))]
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
            let import_owner_unavailable = || WireError {
                code: "operationUnavailable".into(),
                message: "Import owner is unavailable".into(),
                details: None,
            };
            let imports = self.imports.as_ref().ok_or_else(import_owner_unavailable)?;
            return imports.artifact_resource(artifacts, method, params);
        }
        if method == "artifact.list" {
            // The pages are kept where Swift keeps them, below the Artifact
            // root's Import namespace, apart from the Job list's.
            return artifacts.handle_list(params, |job| self.require_artifact_job(job));
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
                analyzer: Some(analyzer),
                state_root,
                hdc: hdc.as_ref(),
                workspace: self.workspace.as_deref(),
            },
            jobs,
            now: clock_now,
            authority: self.authority(),
        };
        // An execution's request is admitted as `job.submit` admits it: a
        // Flash operation over the Flash composition (Swift `submitOwned`).
        let answer = self
            .with_flash_admitter(admitter, |admitter| {
                let engine = arkdeck_hoststore::AgentEngine {
                    targets,
                    jobs,
                    admitter,
                    now: clock_precise_now,
                    observations: self.observing(),
                };
                agents.advance(method, params, &engine)
            })
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

    /// `agent.run`, `agent.status`, `agent.list`, `agent.abandon`,
    /// `agent.resume` and `human-action.resume` on Windows: the agent
    /// execution owner over the Target, Job and Artifact owners, admitting an
    /// execution's request as `job.submit` admits it here, observing Targets
    /// over the composed HDC; a resume reference names an execution's action,
    /// or a control action's impact approval.
    #[cfg(windows)]
    fn agent_execution(
        &self,
        method: &str,
        params: &serde_json::Map<String, serde_json::Value>,
    ) -> Result<serde_json::Value, WireError> {
        // As on macOS, the resume reference is looked up in the combined
        // human-action owner first: a control action's impact approval is
        // answered there, never by the agent execution owner.
        if matches!(method, "agent.resume" | "human-action.resume")
            && let (Some(agents), Some(resources), Some(controls)) =
                (&self.agents, &self.human_actions, &self.control_actions)
            && let Some(answer) = resources.resume_control_action(method, params, agents, controls)
        {
            return answer;
        }
        let (Some(agents), Some((state_root, _)), Some(jobs), Some(artifacts), Some(targets)) = (
            &self.agents,
            &self.planning,
            &self.jobs,
            &self.artifacts,
            &self.targets,
        ) else {
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
            planner: self.planner(state_root, hdc.as_ref()),
            jobs,
            now: clock_now,
            authority: self.authority(),
        };
        // An execution's request is admitted as `job.submit` admits it: a
        // Flash operation over the Flash composition (Swift `submitOwned`),
        // as on macOS (TASK-XPA-010).
        let answer = self
            .with_flash_admitter(admitter, |admitter| {
                let engine = arkdeck_hoststore::AgentEngine {
                    targets,
                    jobs,
                    admitter,
                    now: clock_precise_now,
                    observations: self.observing(),
                };
                agents.advance(method, params, &engine)
            })
            .map_err(|mut error| {
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

    #[cfg(any(target_os = "macos", windows))]
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
                        let drivers = (
                            driver as &dyn arkdeck_hoststore::HdcLifecycleDriver,
                            Some(driver as &dyn arkdeck_hoststore::ToolSelectionDriver),
                        );
                        controls
                            .consume_with_drivers(id, reference, response, jobs, source, drivers)
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
    /// executions and the union control-action owner (none on Windows).
    #[cfg(any(target_os = "macos", windows))]
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
    /// Production also composes the registered tool-selection owner, and so
    /// does the Windows account daemon beside the managed server it starts
    /// from its Bootstrap selection (`windows_lifecycle`); on Windows the HDC
    /// control-action owner is composed only beside a registered tuple's
    /// managed server.
    #[cfg(any(target_os = "macos", windows))]
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

    #[cfg(any(target_os = "macos", windows))]
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
    fn app_job_recovery_allowed(&self, job_id: &str, resume: bool) -> bool {
        let Some(jobs) = &self.jobs else {
            return false;
        };
        let Ok(record) = jobs.read_snapshot(job_id) else {
            return false;
        };
        let Ok(value) = record.value() else {
            return false;
        };
        let eligible = if resume {
            record.state == "resumeAtConfirmedSafeBoundary" && value["outcomeUnknown"] == false
        } else {
            record.state == "waitingForRecovery"
        };
        // Admission may materialize the working request. The immutable
        // original submission retains the App's closed caller vocabulary.
        let request = value
            .get("originalSubmissionRequest")
            .filter(|value| value.is_object())
            .unwrap_or(&record.request);
        eligible
            && serde_json::to_string(request)
                .ok()
                .and_then(|request| crate::app_ingress::jobs::kind(&request))
                .is_some()
    }

    #[cfg(target_os = "macos")]
    fn app_job_archive_allowed(&self, job_id: &str) -> bool {
        let Some(jobs) = &self.jobs else {
            return false;
        };
        let Ok(record) = jobs.read_snapshot(job_id) else {
            return false;
        };
        let Ok(value) = record.value() else {
            return false;
        };
        let request = value
            .get("originalSubmissionRequest")
            .filter(|v| v.is_object())
            .unwrap_or(&record.request);
        matches!(
            record.state.as_str(),
            "waitingForRecovery" | "userAbandonRequested" | "interrupted"
        ) && serde_json::to_string(request)
            .ok()
            .and_then(|r| crate::app_ingress::jobs::kind(&r))
            .is_some()
    }
    #[cfg(any(target_os = "macos", windows))]
    fn job_archive(
        &self,
        method: &str,
        params: &serde_json::Map<String, serde_json::Value>,
    ) -> Result<serde_json::Value, WireError> {
        let jobs = self.jobs.as_ref().ok_or_else(|| WireError {
            code: "rejected".into(),
            message: "Job owner is unavailable".into(),
            details: None,
        })?;
        let probe = arkdeck_hoststore::SystemStorageProbe;
        let publisher =
            self.storage
                .as_deref()
                .map(|(sessions, _)| arkdeck_hoststore::SessionPublisher {
                    sessions,
                    claims: &self.claims,
                    probe: &probe,
                });
        let archiver = arkdeck_hoststore::JobArchiver {
            jobs,
            now: clock_now,
            sessions: publisher.as_ref(),
        };
        if method == "job.archive.preview" {
            archiver.preview(params)
        } else {
            archiver.archive(params)
        }
    }

    #[cfg(target_os = "macos")]
    fn job_plan(
        &self,
        params: &serde_json::Map<String, serde_json::Value>,
    ) -> Result<serde_json::Value, WireError> {
        self.with_flash_planner(|planner| planner.handle(params))
            .ok_or_else(|| WireError {
                code: "rejected".into(),
                message: "this method is unavailable in the read-only Rust foundation".into(),
                details: None,
            })?
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
    /// `job.plan` on Windows: the Job planner with the Flash planning and
    /// facts (TASK-XPA-010), so a Flash plan is materialized as on macOS and
    /// a device plan is refused before admission with zero dispatch, as on
    /// macOS without an HDC provider.
    #[cfg(windows)]
    fn job_plan(
        &self,
        params: &serde_json::Map<String, serde_json::Value>,
    ) -> Result<serde_json::Value, WireError> {
        self.with_flash_planner(|planner| planner.handle(params))
            .ok_or_else(|| WireError {
                code: "rejected".into(),
                message: "this method is unavailable in the read-only Rust foundation".into(),
                details: None,
            })?
            .map_err(|refusal| WireError {
                code: refusal.code.into(),
                message: refusal.message,
                details: Some(serde_json::Map::from_iter([
                    ("phase".into(), serde_json::json!("preAdmission")),
                    ("newDispatchCount".into(), serde_json::json!(0)),
                ])),
            })
    }
    /// `job.submit` on Windows: the Job admitter over the Job store, its
    /// idempotency lookup and admission interlock included, with the
    /// planner above and the capability authority, under the Flash admission.
    #[cfg(windows)]
    fn job_submit(
        &self,
        params: &serde_json::Map<String, serde_json::Value>,
    ) -> Result<serde_json::Value, WireError> {
        let (Some((state_root, _)), Some(jobs)) = (&self.planning, &self.jobs) else {
            return Err(WireError {
                code: "rejected".into(),
                message: "this method is unavailable in the read-only Rust foundation".into(),
                details: None,
            });
        };
        let hdc = self.hdc();
        let admitter = arkdeck_hoststore::JobAdmitter {
            planner: self.planner(state_root, hdc.as_ref()),
            jobs,
            now: clock_now,
            authority: self.authority(),
        };
        // A Flash is judged through the Flash admission (TASK-XPA-010).
        self.with_flash_admitter(admitter, |admitter| admitter.handle(params))
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
    /// `job.submit` admits into the Job owner the planner materializes for,
    /// the ArkForge Flash operations over the Flash composition and facts.
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
        let admitter = arkdeck_hoststore::JobAdmitter {
            planner: arkdeck_hoststore::JobPlanner {
                imports: self.imports.as_deref(),
                artifacts: self.artifacts.as_deref(),
                analyzer: Some(analyzer),
                state_root,
                hdc: hdc.as_ref(),
                workspace: self.workspace.as_deref(),
            },
            jobs,
            now: clock_now,
            authority: self.authority(),
        };
        self.with_flash_admitter(admitter, |admitter| admitter.handle(params))
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
    #[cfg(any(target_os = "macos", windows))]
    fn diagnostic_session_control(
        &self,
        method: &str,
        params: &serde_json::Map<String, serde_json::Value>,
    ) -> Result<serde_json::Value, WireError> {
        let jobs = self.jobs.as_ref().ok_or_else(|| WireError {
            code: "rejected".into(),
            message: "Diagnostic Session owner is unavailable".into(),
            details: None,
        })?;
        jobs.diagnostic_session_control(method, params)
    }

    /// `job.result` and `job.evidence` read from the Job and Artifact owners
    /// the isolated composition opened.
    #[cfg(any(target_os = "macos", windows))]
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
    /// `job.run` on Windows: the macOS run over this composition's owners —
    /// the Job and Artifact owners, the Session publication writer, the
    /// analyzers, the workspace provider, the Flash lane where one is
    /// installed and the HDC composition where one is composed. Without an
    /// HDC a device Job is refused before its run with zero dispatch, and
    /// every concurrent caller for one Job joins its one run, as on macOS.
    #[cfg(windows)]
    fn job_run(
        &self,
        params: &serde_json::Map<String, serde_json::Value>,
    ) -> Result<serde_json::Value, WireError> {
        let (Some(planning), Some(jobs), Some(artifacts)) =
            (&self.planning, &self.jobs, &self.artifacts)
        else {
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
        let facts = self.flash_facts_port();
        let hdc = self.hdc();
        let run = |cancellation: Option<&arkdeck_hoststore::RunCancellation>| {
            // A Flash runs through the executable lane where one is installed
            // (TASK-XPA-010); without it the runner refuses it before its run.
            let flash = facts.as_ref().and_then(|facts| self.flash_execution(facts));
            arkdeck_hoststore::FlashRunner {
                runner: windows_runner(
                    planning,
                    jobs,
                    artifacts,
                    self.artifact_limit(),
                    self.imports.as_deref(),
                    self.authority(),
                    &self.home,
                    publisher.as_ref(),
                    cancellation,
                    self.workspace.as_deref(),
                    hdc.as_ref(),
                ),
                flash,
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
            match self.claim_run(job).ok_or_else(uncertain)? {
                RunClaim::Own(slot) => break slot,
                RunClaim::Reconciling(reconcile) => {
                    if reconcile.wait().is_none() {
                        return Err(uncertain());
                    }
                }
                RunClaim::Held(slot) => {
                    let outcome = slot.wait();
                    if !slot.cancelling {
                        return outcome.unwrap_or_else(|| Err(uncertain()));
                    }
                }
            }
        };
        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            run(Some(&slot.cancellation))
        }))
        .unwrap_or_else(|_| Err(uncertain()));
        slot.cancellation.end();
        slot.finish(&result);
        if let Ok(mut running) = self.running.lock() {
            running.remove(job);
        }
        result
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
        let facts = self.flash_facts_port();
        let flash = facts.as_ref().and_then(|facts| self.flash_execution(facts));
        let run = |cancellation: Option<&arkdeck_hoststore::RunCancellation>| {
            let runner = arkdeck_hoststore::JobRunner {
                imports: self.imports.as_deref(),
                mutation: self.authority().zip(self.planning.as_ref()).map(
                    |(authority, (state_root, _))| arkdeck_hoststore::MutationExecution {
                        authority,
                        state_root,
                    },
                ),
                jobs,
                artifacts,
                analyzer: Some(analyzer),
                quota: self.artifact_limit(),
                home: &self.home,
                now: clock_now,
                precise_now: clock_precise_now,
                sessions: publisher.as_ref(),
                cancellation,
                after_commit: None,
                hdc: hdc.as_ref(),
                workspace: self.workspace.as_deref(),
            };
            arkdeck_hoststore::FlashRunner { runner, flash }
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
            match self.claim_run(job).ok_or_else(uncertain)? {
                RunClaim::Own(slot) => break slot,
                // A run waits out a reconcile of its Job under way, then
                // meets what the reconcile left: now that a run resumes a
                // Job a reconcile concludes, the two never drive one Job at
                // once (Swift's run joins a failure finalization under way).
                RunClaim::Reconciling(reconcile) => {
                    if reconcile.wait().is_none() {
                        return Err(uncertain());
                    }
                }
                RunClaim::Held(slot) => {
                    let outcome = slot.wait();
                    // A run waits out a cancellation of its Job, then meets
                    // what the cancellation left.
                    if !slot.cancelling {
                        return outcome.unwrap_or_else(|| Err(uncertain()));
                    }
                }
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
    #[cfg(any(target_os = "macos", windows))]
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
    #[cfg(any(target_os = "macos", windows))]
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
                .map(|(_, analyzer)| analyzer as &dyn arkdeck_hoststore::AnalyzerComposition),
            quota: self.artifact_limit(),
            home: &self.home,
            now: clock_now,
            precise_now: clock_precise_now,
            // A continuation publishes no Session and cancels nothing.
            sessions: None,
            cancellation: None,
            after_commit: None,
            hdc: hdc.as_ref(),
            workspace: self.workspace.as_deref(),
        }
        .continue_cleanup_debt(params)
    }
    /// `cleanupDebt.list` and `cleanupDebt.continue` on Windows: the macOS
    /// answers over this composition's Artifact and Job owners, through the
    /// runner `job.run` uses here. Without an HDC composition a continuation
    /// of a debt the ledger owes is refused (`rejected`, the provider
    /// unavailable) after the ledger and the Job are read and before any
    /// readback or retry is sent; nothing is written to the ledger.
    #[cfg(windows)]
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
        let (Some(state_root), Some(jobs)) = (&self.planning, &self.jobs) else {
            return Err(foundation());
        };
        // A continuation publishes no Session and cancels nothing.
        let hdc = self.hdc();
        windows_runner(
            state_root,
            jobs,
            artifacts,
            self.artifact_limit(),
            self.imports.as_deref(),
            self.authority(),
            &self.home,
            None,
            None,
            self.workspace.as_deref(),
            hdc.as_ref(),
        )
        .continue_cleanup_debt(params)
    }
    host_services_runtime_methods!();
}
