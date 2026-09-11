use arkdeck_contract::{
    DeviceObservationsResult, DeviceObservationsResultObservationsItem, WireError,
};
use arkdeck_control::{HdcStatus, HostServices};
use arkdeck_platform::{VerifiedTool, random_bytes};
use arkdeck_provider_hdc::HdcReadOnlyProvider;
use std::io;
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

pub struct Host {
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
    generation: Mutex<u64>,
}

impl Host {
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
            bootstrap: None,
            provider,
            #[cfg(target_os = "macos")]
            history: None,
            #[cfg(target_os = "macos")]
            trace_cache: None,
            #[cfg(target_os = "macos")]
            storage: None,
            unavailable,
            generation: Mutex::new(0),
        }
    }
}

impl HostServices for Host {
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
            // Stores are configured only by the isolated development composition
            // root, whose daemon has no Job dispatch. Installed activation must
            // supply the actual Job owner's active-session inventory.
            let now = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map_err(|_| WireError {
                    code: "operationUnavailable".into(),
                    message: "Runtime clock is unavailable".into(),
                    details: None,
                })?
                .as_secs_f64()
                - 978307200.0;
            return sessions.preview_cleanup(&std::collections::BTreeSet::new(), now);
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
        let mut generation = self
            .generation
            .lock()
            .map_err(|_| fail("the observation generation is unavailable"))?;
        let mut candidates = provider
            .list_candidates()
            .map_err(|error| fail(&format!("{}: {error}", error.classification())))?;
        let next = generation
            .checked_add(1)
            .ok_or_else(|| fail("the observation generation is exhausted"))?;
        candidates.sort_by(|a, b| {
            a.connect_key
                .cmp(&b.connect_key)
                .then_with(|| a.state.cmp(&b.state))
        });
        let mut observations = Vec::with_capacity(candidates.len());
        for candidate in candidates {
            observations.push(DeviceObservationsResultObservationsItem {
                candidate_key: candidate.connect_key,
                authorization_state: candidate.state,
                observation_id: format!(
                    "obs-{}",
                    fresh_id().map_err(|_| fail("observation identity entropy is unavailable"))?
                ),
                observation_continuity: "generationScoped".into(),
                display_name_generation: next.to_string(),
                adopted_target_id: None,
                binding_revision: None,
                display_name: None,
                device_information: None,
                observed_facts: (),
            });
        }
        *generation = next;
        Ok(DeviceObservationsResult {
            schema_version: "arkdeck.device-observations/1".into(),
            snapshot_generation: next.to_string(),
            observed_at_utc: utc_now(),
            health: "current".into(),
            observations,
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
    #[test]
    fn utc_spelling_and_leap_day() {
        assert_eq!(timestamp(0), "1970-01-01T00:00:00Z");
        assert_eq!(timestamp(1_709_251_199), "2024-02-29T23:59:59Z");
        assert_eq!(timestamp(1_709_251_200), "2024-03-01T00:00:00Z");
    }
}
