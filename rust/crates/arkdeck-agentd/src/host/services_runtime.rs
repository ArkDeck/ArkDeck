macro_rules! host_services_runtime_methods {
    () => {
    /// `job.cancel` cancels an admitted Job in the owner that admitted it. A
    /// Job this owner is running is cancelled by its run, which alone writes
    /// the Job's Journal. A run of a Job no run holds waits the cancellation
    /// out, and a concurrent cancellation joins it.
    #[cfg(any(target_os = "macos", windows))]
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
                now: clock_now,
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
        // admission reserved it in. A debug HAP's failure finalization runs
        // through the runner its runs use, over the same owners.
        let hdc = self.hdc();
        let runner =
            self.planning
                .as_ref()
                .map(|(state_root, analyzer)| arkdeck_hoststore::JobRunner {
                    imports: self.imports.as_deref(),
                    mutation: self.authority().map(|authority| {
                        arkdeck_hoststore::MutationExecution {
                            authority,
                            state_root,
                        }
                    }),
                    jobs,
                    artifacts,
                    analyzer: Some(analyzer),
                    quota: self.artifact_limit(),
                    home: &self.home,
                    now: clock_now,
                    precise_now: clock_precise_now,
                    sessions: publisher.as_ref(),
                    cancellation: None,
                    after_commit: None,
                    hdc: hdc.as_ref(),
                    workspace: self.workspace.as_deref(),
                });
        let reconciler = arkdeck_hoststore::JobReconciler {
            jobs,
            artifacts,
            imports: self.imports.as_deref(),
            now: clock_now,
            sessions: publisher.as_ref(),
            hdc: hdc.as_ref(),
            capabilities: self.capabilities.as_deref(),
            runner: runner.as_ref(),
        };
        let flash_reconciler = arkdeck_hoststore::FlashReconciler {
            reconciler,
            lane: self.flash_runtime.as_ref().map(|runtime| &*runtime.lane),
        };
        self.reconcile_once(params, &|| flash_reconciler.handle(params), &|| {
            flash_reconciler.reconciler.status(params)
        })
    }
    /// `job.reconcile` on Windows: the macOS reconciler over this
    /// composition's owners, with the Session publication writer and the
    /// runner its runs use, the HDC composition where one is composed, and
    /// the Flash lane where one is installed. A Job a run of this owner holds
    /// is decided by that run alone, and a concurrent reconcile joins the one
    /// under way.
    #[cfg(windows)]
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
        let hdc = self.hdc();
        let runner = self.planning.as_ref().map(|planning| {
            windows_runner(
                planning,
                jobs,
                artifacts,
                self.artifact_limit(),
                self.imports.as_deref(),
                self.authority(),
                &self.home,
                publisher.as_ref(),
                None,
                self.workspace.as_deref(),
                hdc.as_ref(),
            )
        });
        let reconciler = arkdeck_hoststore::JobReconciler {
            jobs,
            artifacts,
            imports: self.imports.as_deref(),
            now: clock_now,
            sessions: publisher.as_ref(),
            hdc: hdc.as_ref(),
            capabilities: self.capabilities.as_deref(),
            runner: runner.as_ref(),
        };
        // A delegated Flash's receipt is read through the executable lane,
        // where one is installed (TASK-XPA-010).
        let flash_reconciler = arkdeck_hoststore::FlashReconciler {
            reconciler,
            lane: self.flash_runtime.as_ref().map(|runtime| &*runtime.lane),
        };
        self.reconcile_once(params, &|| flash_reconciler.handle(params), &|| {
            flash_reconciler.reconciler.status(params)
        })
    }
    #[cfg(any(target_os = "macos", windows))]
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
    #[cfg(any(target_os = "macos", windows))]
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
    #[cfg(any(target_os = "macos", windows))]
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
    /// On macOS and Windows: the Trace cache owner purges inactive derived
    /// databases while the Job owner holds its active-Session census and the
    /// Artifact owner its Trace retention census.
    #[cfg(any(target_os = "macos", windows))]
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
        // Without the retention owners nothing proves the entries inactive:
        // refused before admission, so a client reads a refusal rather than
        // an unknown outcome.
        let unavailable = arkdeck_hoststore::TraceCacheStore::purge_unavailable;
        let jobs = self.jobs.as_ref().ok_or_else(unavailable)?;
        let artifacts = self.artifacts.as_ref().ok_or_else(unavailable)?;
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
    #[cfg(any(target_os = "macos", windows))]
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
    #[cfg(any(target_os = "macos", windows))]
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
    #[cfg(any(target_os = "macos", windows))]
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
    #[cfg(any(target_os = "macos", windows))]
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
    #[cfg(any(target_os = "macos", windows))]
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
    #[cfg(any(target_os = "macos", windows))]
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

    #[cfg(any(target_os = "macos", windows))]
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
            // The storage lock first, as Swift's cleanup waits for it, and
            // the Job owner's activity guard only under it
            // (`SessionStore::preview_cleanup`).
            let jobs: &arkdeck_hoststore::JobStore = jobs;
            if let Some((id, digest)) = tuple {
                sessions.apply_cleanup(id, digest, jobs, || {
                    SystemTime::now()
                        .duration_since(UNIX_EPOCH)
                        .map(|value| value.as_secs_f64() - 978307200.0)
                        .unwrap_or(f64::NAN)
                })
            } else {
                let now = SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .map(|value| value.as_secs_f64() - 978307200.0)
                    .unwrap_or(f64::NAN);
                sessions.preview_cleanup(jobs, now)
            }
        } else {
            sessions.handle_resource(method, params)
        }
    }
    #[cfg(any(target_os = "macos", windows))]
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
    #[cfg(any(target_os = "macos", windows))]
    fn workspace_project(
        &self,
        method: &str,
        params: &serde_json::Map<String, serde_json::Value>,
    ) -> Result<serde_json::Value, WireError> {
        if let Some(owner) = &self.workspace_projects {
            use arkdeck_hoststore::WorkspaceReference;
            // A project or preset mutation is refused while an active or
            // uncertain workspace Job names it; without the Job owner nothing
            // proves that none does.
            let unverified = || WireError {
                code: "recordUnreadable".into(),
                message: "workspace Job references cannot be verified".into(),
                details: Some(serde_json::Map::from_iter([
                    ("phase".into(), serde_json::json!("workspaceProjectOwner")),
                    ("newDispatchCount".into(), serde_json::json!(0)),
                ])),
            };
            // A Runtime-owned copy's reference maps to the project it was
            // copied from through the workspace provider.
            let registration = |reference: &str| {
                self.workspace
                    .as_ref()
                    .and_then(|workspace| workspace.census_registration(reference))
            };
            let census = |reference: WorkspaceReference<'_>| match (&self.jobs, reference) {
                (Some(jobs), WorkspaceReference::Project(project)) => {
                    jobs.require_no_active_workspace_project_reference(project, &registration)
                }
                (Some(jobs), WorkspaceReference::Preset(preset)) => {
                    jobs.require_no_active_workspace_preset_reference(preset)
                }
                (None, _) => Err(unverified()),
            };
            #[cfg(target_os = "macos")]
            let now = || clock_now().unwrap_or_default();
            // The same whole-second UTC spelling.
            #[cfg(windows)]
            let now = utc_now;
            return owner.handle(method, params, &now, &census);
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
    #[cfg(any(target_os = "macos", windows))]
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
    /// `debug.probe` and `debug.template.run` over this host's HDC
    /// composition (on Windows, the registered tuple's managed server, or a
    /// test build's fake), as Swift's daemon composes its Debug probe
    /// (TASK-XPA-008).
    #[cfg(any(target_os = "macos", windows))]
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
    /// Swift's daemon composes its Trace Runtime probe beside the Debug one,
    /// over the same selected HDC executable and Target owner (on Windows,
    /// the registered tuple's managed server, or a test build's fake, as the
    /// Debug probe's; TASK-XPA-005).
    #[cfg(any(target_os = "macos", windows))]
    fn trace_probe(&self, target_id: &str) -> Result<serde_json::Value, WireError> {
        self.hdc()
            .ok_or_else(|| WireError {
                code: "internalError".into(),
                message: "Trace Runtime probing is not configured".into(),
                details: None,
            })?
            .trace_probe(target_id)
    }

    #[cfg(windows)]
    fn trace_inspection(
        &self,
        params: &serde_json::Map<String, serde_json::Value>,
    ) -> Result<serde_json::Value, WireError> {
        use arkdeck_hoststore::AnalyzerComposition;
        let configured = self.jobs.as_deref().zip(self.artifacts.as_deref()).zip(
            self.planning
                .as_ref()
                .and_then(|(_, profiles)| profiles.profile("trace-summary@1")),
        );
        let Some(((jobs, artifacts), profile)) = configured else {
            return Err(arkdeck_hoststore::trace_inspection_unavailable());
        };
        arkdeck_hoststore::inspect_trace_artifact(jobs, artifacts, profile, params)
    }
    /// Swift composes the reconciler over its Target store; a host without
    /// either answers as Swift's daemon without the reconciler does.
    #[cfg(any(target_os = "macos", windows))]
    fn flash_reconcile_alias(
        &self,
        target_id: &str,
        expected_binding_revision: i64,
    ) -> Result<serde_json::Value, WireError> {
        match (&self.flash_alias, &self.targets) {
            (Some(reconciler), Some(targets)) => {
                reconciler.reconcile(targets, target_id, expected_binding_revision)
            }
            _ => Err(WireError {
                code: "internalError".into(),
                message: "Rockchip post-flash alias reconciliation is not configured".into(),
                details: None,
            }),
        }
    }
    /// Swift composes the prerequisite observer with the Target store, and
    /// its probe only with an HDC (none on Windows yet).
    #[cfg(any(target_os = "macos", windows))]
    fn flash_prerequisites(
        &self,
        target_id: &str,
        profile_reference: &str,
    ) -> Result<serde_json::Value, WireError> {
        match (&self.flash_facts, &self.targets) {
            (Some(facts), Some(targets)) => {
                facts.prerequisites(targets, self.flash_hdc(), target_id, profile_reference)
            }
            _ => Err(WireError {
                code: "internalError".into(),
                message: "Flash prerequisite observation is not configured".into(),
                details: None,
            }),
        }
    }
    /// Swift's handler over its coordinator, with this host's Jobs consulted
    /// first for an enter-Loader transition awaiting the binding.
    #[cfg(any(target_os = "macos", windows))]
    fn flash_bind_current_loader(
        &self,
        target_id: &str,
        expected_binding_revision: i64,
    ) -> Result<serde_json::Value, WireError> {
        let (Some(binding), Some(targets)) = (&self.loader_binding, &self.targets) else {
            return Err(WireError {
                code: "internalError".into(),
                message: "Rockchip Loader binding is not configured".into(),
                details: None,
            });
        };
        binding.bind(
            targets,
            self.jobs.as_deref(),
            target_id,
            expected_binding_revision,
        )
    }
    #[cfg(any(target_os = "macos", windows))]
    fn flash_adopt_current_loader(&self) -> Result<serde_json::Value, WireError> {
        let (Some(binding), Some(targets), Some(jobs)) =
            (&self.loader_binding, &self.targets, &self.jobs)
        else {
            return Err(WireError {
                code: "internalError".into(),
                message: "Rockchip Loader adoption and Job census are not configured".into(),
                details: None,
            });
        };
        binding.adopt_current_loader(targets, jobs)
    }
    #[cfg(any(target_os = "macos", windows))]
    fn flash_bootloader_status(&self) -> Result<serde_json::Value, WireError> {
        match (&self.flash_facts, &self.targets) {
            (Some(facts), Some(targets)) => facts.bootloader_status(targets),
            _ => Err(WireError {
                code: "internalError".into(),
                message: "Rockchip bootloader status observation is not configured".into(),
                details: None,
            }),
        }
    }
    /// Swift's handler over its Target store and, with a lane, its composed
    /// previewer: the Target's facts through the ArkForge provider's port —
    /// this host's, measured over its HDC — or, with no facts composed, the
    /// provider's refusal to resolve any.
    #[cfg(any(target_os = "macos", windows))]
    fn flash_lane_plan_preview(
        &self,
        target_id: &str,
        _profile: &str,
        archive_sha256: &str,
    ) -> Result<serde_json::Value, WireError> {
        let Some(targets) = &self.targets else {
            return Err(WireError {
                code: "internalError".into(),
                message: "lane plan preview is not configured".into(),
                details: None,
            });
        };
        let hdc = self.flash_hdc();
        let previewer = self.lane_plan_preview.as_ref().map(|lane| {
            move |target: &str| {
                arkdeck_hoststore::preview_before_lane(
                    match &self.flash_facts {
                        Some(facts) => facts.current_facts(targets, hdc, target),
                        None => {
                            Err("production ArkForge target facts are not registered".to_owned())
                        }
                    },
                    target,
                    &|topology| lane.preview(archive_sha256, topology),
                )
            }
        });
        arkdeck_hoststore::lane_plan_preview(
            targets,
            target_id,
            previewer
                .as_ref()
                .map(|preview| preview as &dyn Fn(&str) -> arkdeck_hoststore::LanePreview),
        )
    }

    #[cfg(any(target_os = "macos", windows))]
    fn flash_device_access(&self) -> Result<serde_json::Value, WireError> {
        let Some(observer) = &self.device_access else {
            return Err(WireError {
                code: "internalError".into(),
                message: "Rockchip device access observation is not configured".into(),
                details: None,
            });
        };
        match observer.observe() {
            Ok(modes) => Ok(serde_json::json!({
                "observationCount": modes.len(),
                "observedModes": modes.iter().map(|mode| mode.as_str()).collect::<Vec<_>>(),
            })),
            // A refused Hello is a compatibility error, not missing hardware.
            // The SDK closes the connection before any request is sent.
            Err(arkdeck_provider_arkforge::DeviceAccessFailure::Client { code, message })
                if code == "PROTOCOL_REFUSED" =>
            {
                Err(WireError {
                    code: "unsupportedProtocolVersion".into(),
                    message: format!("ArkForge {code}: {message}"),
                    details: None,
                })
            }
            // Other transport failures may contain socket paths or USB identities.
            Err(_) => Err(WireError {
                code: "rejected".into(),
                message: "Rockchip device access observation failed".into(),
                details: None,
            }),
        }
    }
    #[cfg(any(target_os = "macos", windows))]
    fn flash_invocation(
        &self,
        method: &str,
        params: &serde_json::Map<String, serde_json::Value>,
    ) -> Result<serde_json::Value, WireError> {
        let unconfigured = || WireError {
            code: "internalError".into(),
            message: if method.starts_with("debug.") {
                "Runtime debug invocation is not configured"
            } else {
                "Runtime Flash invocation owner is not configured"
            }
            .into(),
            details: None,
        };
        let Some(owner) = &self.flash_invocations else {
            return Err(unconfigured());
        };
        if !matches!(method, "debug.start" | "debug.evaluate") {
            return owner.handle(method, params);
        }
        // Swift's broker over its engine's `planOnly`: this host's planner,
        // Flash composition and facts, the Runtime clock and a fresh identity;
        // an attempt is admitted and run through this host's own Job path.
        self.with_flash_planner(|planner| {
            owner.broker(
                method,
                params,
                &arkdeck_hoststore::InvocationBroker {
                    plan: &|request| planner.plan(request),
                    now: &clock_now,
                    mint: &|| fresh_id().ok().map(|id| format!("debug-{id}")),
                    execute: &|request| self.debug_attempt(request),
                },
            )
        })
        .unwrap_or_else(|| Err(unconfigured()))
    }

    /// Swift's daemon answers from the observer its HDC host gives it, and
    /// `unconfigured()` without one: this composition has a host only when
    /// the isolated owner started a managed server (on Windows, only behind
    /// a registered HDC tuple).
    #[cfg(any(target_os = "macos", windows))]
    fn runtime_hdc_status(&self) -> Result<serde_json::Value, WireError> {
        Ok(match self.managed_hdc() {
            Some(managed) => managed.status(&utc_now),
            None => arkdeck_provider_hdc::unconfigured_status(None),
        })
    }
    #[cfg(any(target_os = "macos", windows))]
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
        #[cfg(any(target_os = "macos", windows))]
        {
            use arkdeck_control::ArtifactStoreFacts;
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
            let targets = self.target_store_facts();
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
                staged_sessions_kept: self.staged_kept.get().cloned().unwrap_or_default(),
                // Swift reads the whole ledger only for a deep report, and
                // names at most sixteen of what it finds.
                unreadable_records: match (&self.jobs, deep) {
                    (Some(jobs), true) => Some(jobs.unreadable_records(16)),
                    _ => None,
                },
            }
        }
        #[cfg(not(any(target_os = "macos", windows)))]
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
        #[cfg(any(target_os = "macos", windows))]
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
    #[cfg(any(target_os = "macos", windows))]
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
    #[cfg(any(target_os = "macos", windows))]
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
            // The Target owner without a registered HDC to observe through
            // (no `ARKDECK_HDC_PATH` on macOS; no registered Windows HDC
            // tuple). A reference it would refuse as malformed is refused so
            // first; any other is refused as Swift's owner refuses a snapshot
            // it cannot take (`operationUnavailable`, `preAdmission`, no new
            // dispatch), which proves that nothing was observed, dispatched or
            // written: a client reads a refusal, not an unknown outcome.
            None if self.targets.is_some() => {
                arkdeck_hoststore::parse_reference(params).map_err(|error| error.wire())?;
                Err(arkdeck_hoststore::ObservationError::Refused {
                    code: "operationUnavailable".into(),
                    message: NO_REGISTERED_HDC.into(),
                    reference: None,
                }
                .wire())
            }
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
        #[cfg(any(target_os = "macos", windows))]
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
        #[cfg(any(target_os = "macos", windows))]
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
        #[cfg(any(target_os = "macos", windows))]
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
            #[cfg(any(target_os = "macos", windows))]
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
                #[cfg(any(target_os = "macos", windows))]
                display_name_generation: presentation
                    .and_then(|v| v["displayNameGeneration"].as_str())
                    .map_or_else(|| next.to_string(), str::to_owned),
                #[cfg(not(any(target_os = "macos", windows)))]
                display_name_generation: next.to_string(),
                #[cfg(any(target_os = "macos", windows))]
                adopted_target_id: presentation
                    .and_then(|v| v["targetId"].as_str())
                    .map(str::to_owned),
                #[cfg(not(any(target_os = "macos", windows)))]
                adopted_target_id: None,
                #[cfg(any(target_os = "macos", windows))]
                binding_revision: presentation.and_then(|v| v["bindingRevision"].as_i64()),
                #[cfg(not(any(target_os = "macos", windows)))]
                binding_revision: None,
                #[cfg(any(target_os = "macos", windows))]
                display_name: presentation
                    .and_then(|v| v["displayName"].as_str())
                    .map(str::to_owned),
                #[cfg(not(any(target_os = "macos", windows)))]
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
    };
}
