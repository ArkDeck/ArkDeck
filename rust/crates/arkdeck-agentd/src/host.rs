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

pub struct Host {
    #[cfg(target_os = "macos")]
    imports: Option<arkdeck_hoststore::ImportUploadStore>,
    #[cfg(target_os = "macos")]
    targets: Option<arkdeck_hoststore::TargetStore>,
    #[cfg(target_os = "macos")]
    artifacts: Option<arkdeck_hoststore::ArtifactReadStore>,
    #[cfg(target_os = "macos")]
    jobs: Option<arkdeck_hoststore::JobStore>,
    #[cfg(target_os = "macos")]
    bootstrap: Option<crate::bootstrap_readers::BootstrapReaders>,
    provider: Option<HdcReadOnlyProvider>,
    #[cfg(target_os = "macos")]
    history: Option<arkdeck_hoststore::HistoryStore>,
    #[cfg(target_os = "macos")]
    trace_cache: Option<arkdeck_hoststore::TraceCacheStore>,
    #[cfg(target_os = "macos")]
    storage: Option<(
        arkdeck_hoststore::SessionStore,
        arkdeck_hoststore::ArtifactUsage,
    )>,
    unavailable: &'static str,
    observations: Mutex<ObservationState>,
}

impl Host {
    #[cfg(target_os = "macos")]
    pub fn with_imports(mut self, imports: arkdeck_hoststore::ImportUploadStore) -> Self {
        self.imports = Some(imports);
        self
    }

    #[cfg(target_os = "macos")]
    pub fn with_targets(mut self, targets: arkdeck_hoststore::TargetStore) -> Self {
        self.targets = Some(targets);
        self
    }
    #[cfg(target_os = "macos")]
    pub fn with_jobs(mut self, jobs: arkdeck_hoststore::JobStore) -> Self {
        self.jobs = Some(jobs);
        self
    }
    #[cfg(target_os = "macos")]
    pub fn with_artifacts(mut self, artifacts: arkdeck_hoststore::ArtifactReadStore) -> Self {
        self.artifacts = Some(artifacts);
        self
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
        self.storage = Some((sessions, artifacts));
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
        }
    }
}

impl HostServices for Host {
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
        // Local control clients never inherit the App's trusted transport provenance.
        self.imports
            .as_ref()
            .ok_or_else(unavailable)?
            .handle_resource(method, params, &utc_now(), false, |_| Err(unavailable()))
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
        artifacts.handle_resource(method, params, |job| self.require_artifact_job(job))
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
        let (sessions, _) = self.storage.as_ref().ok_or_else(|| WireError {
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
        if method == "session.cleanup.preview" {
            if !params.is_empty() {
                return Err(WireError {
                    code: "invalidParams".into(),
                    message: "Session cleanup preview accepts no parameters".into(),
                    details: None,
                });
            }
            // A retained nonterminal/unknown Job protects its Session even in
            // the read-only development Runtime. Missing activity is a refusal.
            let now = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map_err(|_| WireError {
                    code: "operationUnavailable".into(),
                    message: "Runtime clock is unavailable".into(),
                    details: None,
                })?
                .as_secs_f64()
                - 978307200.0;
            return self
                .jobs
                .as_ref()
                .ok_or_else(|| WireError {
                    code: "operationUnavailable".into(),
                    message: "Job activity owner is not configured".into(),
                    details: None,
                })?
                .with_active_sessions(|active| sessions.preview_cleanup(active, now));
        }
        sessions.handle_resource(method, params)
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
            .as_ref()
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
    fn observations(&self) -> Result<DeviceObservationsResult, WireError> {
        let fail = |message: &str| WireError {
            code: "rejected".into(),
            message: message.into(),
            details: None,
        };
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

fn utc_now() -> String {
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
