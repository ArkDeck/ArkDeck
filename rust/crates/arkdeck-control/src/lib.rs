//! Transport-free handlers for the current control contract.

use arkdeck_contract::{
    CATALOG_CANONICAL_JSON, CATALOG_DIGEST, CONTRACT_IDENTITY, ContractError,
    DeviceObservationsResult, MAX_REQUEST_BYTES, MAX_RESPONSE_BYTES, METHODS, PROTOCOL_VERSION,
    Response, WireError, decode_request, encode_frame, sha256_hex, strict_json,
    validate_method_value,
};
use serde_json::{Value, json};
mod operation_description;
mod target_availability;

/// The composition root supplies local resources and device observations.
/// This interface provides no device mutation or authority administration.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BootstrapRegistryKind {
    Tool,
    Bundle,
}

pub trait HostServices: Send + Sync {
    /// Fresh host-scoped provider/dispatcher/Artifact availability. None means
    /// no provider is registered; an empty reason list means available on this
    /// host, never target admission. Implementations must not dispatch.
    fn operation_availability(
        &self,
        _reference: &str,
        _provider: &str,
    ) -> Option<Vec<(&'static str, String)>> {
        None
    }

    fn import_resource(
        &self,
        _method: &str,
        _params: &serde_json::Map<String, Value>,
    ) -> Result<Value, WireError> {
        Err(WireError {
            code: "operationUnavailable".into(),
            message: "Import owner services are unavailable".into(),
            details: Some(serde_json::Map::from_iter([
                ("phase".into(), json!("importOwner")),
                ("newDispatchCount".into(), json!(0)),
            ])),
        })
    }
    /// The Import methods of a frame the authenticated App transport accepted
    /// (`Control::handle_app_frame`), never of a local control client: an
    /// Import the App begins is App-owned, and it can operate on no other.
    /// A host without that owner refuses with zero dispatch.
    fn app_import_resource(
        &self,
        _method: &str,
        _params: &serde_json::Map<String, Value>,
    ) -> Result<Value, WireError> {
        Err(WireError {
            code: "operationUnavailable".into(),
            message: "App Import owner services are unavailable".into(),
            details: Some(serde_json::Map::from_iter([
                ("phase".into(), json!("importOwner")),
                ("newDispatchCount".into(), json!(0)),
            ])),
        })
    }

    fn target_resource(
        &self,
        _method: &str,
        _params: &serde_json::Map<String, Value>,
    ) -> Result<Value, WireError> {
        Err(WireError {
            code: "internalError".into(),
            message: "Target owner is not configured".into(),
            details: None,
        })
    }
    fn candidate_display_name(
        &self,
        _method: &str,
        _params: &serde_json::Map<String, Value>,
    ) -> Result<Value, WireError> {
        Err(WireError {
            code: "internalError".into(),
            message: "Target observation owner is not configured".into(),
            details: None,
        })
    }

    fn artifact_resource(
        &self,
        _method: &str,
        _params: &serde_json::Map<String, Value>,
    ) -> Result<Value, WireError> {
        Err(WireError {
            code: "operationUnavailable".into(),
            message: "Artifact owner is not configured".into(),
            details: Some(serde_json::Map::from_iter([
                ("phase".into(), json!("artifactOwner")),
                ("newDispatchCount".into(), json!(0)),
            ])),
        })
    }

    fn job_resource(
        &self,
        _method: &str,
        _params: &serde_json::Map<String, Value>,
    ) -> Result<Value, WireError> {
        Err(WireError {
            code: "rejected".into(),
            message: "The Job owner is not configured".into(),
            details: None,
        })
    }
    /// `job.plan` materializes without admitting. A host without a Job
    /// planner answers as the read-only foundation always has.
    fn job_plan(&self, _params: &serde_json::Map<String, Value>) -> Result<Value, WireError> {
        Err(WireError {
            code: "rejected".into(),
            message: "this method is unavailable in the read-only Rust foundation".into(),
            details: None,
        })
    }
    /// `job.submit` admits a Job. A host without a Job owner that admits
    /// answers as the read-only foundation always has.
    fn job_submit(&self, _params: &serde_json::Map<String, Value>) -> Result<Value, WireError> {
        Err(WireError {
            code: "rejected".into(),
            message: "this method is unavailable in the read-only Rust foundation".into(),
            details: None,
        })
    }
    /// `job.result` and `job.evidence` read a Job's verified result. A host
    /// without Job and Artifact owners answers as the foundation always has.
    fn job_result_resource(
        &self,
        _method: &str,
        _params: &serde_json::Map<String, Value>,
    ) -> Result<Value, WireError> {
        Err(WireError {
            code: "rejected".into(),
            message: "this method is unavailable in the read-only Rust foundation".into(),
            details: None,
        })
    }
    /// `job.run` runs an admitted Job. A host without a Job owner that runs
    /// answers as the read-only foundation always has.
    fn job_run(&self, _params: &serde_json::Map<String, Value>) -> Result<Value, WireError> {
        Err(WireError {
            code: "rejected".into(),
            message: "this method is unavailable in the read-only Rust foundation".into(),
            details: None,
        })
    }
    /// `job.cancel` asks the Runtime to cancel a Job. A host without a Job
    /// owner answers as the read-only foundation always has.
    fn job_cancel(&self, _params: &serde_json::Map<String, Value>) -> Result<Value, WireError> {
        Err(WireError {
            code: "rejected".into(),
            message: "this method is unavailable in the read-only Rust foundation".into(),
            details: None,
        })
    }
    /// `job.reconcile` reconciles a Job whose outcome is unknown against its
    /// durable intent. A host without a Job owner that reconciles answers as
    /// the read-only foundation always has.
    fn job_reconcile(&self, _params: &serde_json::Map<String, Value>) -> Result<Value, WireError> {
        Err(WireError {
            code: "rejected".into(),
            message: "this method is unavailable in the read-only Rust foundation".into(),
            details: None,
        })
    }
    /// `agent.run`, `agent.status`, `agent.list` and `agent.abandon` advance,
    /// read, list and abandon agent executions. A host without an agent
    /// execution owner answers as the read-only foundation always has.
    fn agent_execution(
        &self,
        _method: &str,
        _params: &serde_json::Map<String, Value>,
    ) -> Result<Value, WireError> {
        Err(WireError {
            code: "rejected".into(),
            message: "this method is unavailable in the read-only Rust foundation".into(),
            details: None,
        })
    }
    /// Invoked only with foreground-console evidence supplied by the local
    /// transport. Frame parameters can never opt into this origin.
    fn interactive_human_action_resume(
        &self,
        params: &serde_json::Map<String, Value>,
    ) -> Result<Value, WireError> {
        self.agent_execution("human-action.resume", params)
    }
    /// `human-action.list` and `human-action.show` read the physical
    /// assistance agent executions ask for and the impact approvals control
    /// actions request. A host without the human-action owner answers as the
    /// read-only foundation always has.
    fn human_action(
        &self,
        _method: &str,
        _params: &serde_json::Map<String, Value>,
    ) -> Result<Value, WireError> {
        Err(WireError {
            code: "rejected".into(),
            message: "this method is unavailable in the read-only Rust foundation".into(),
            details: None,
        })
    }
    /// `artifact.quota` reads the Artifact store's used bytes against its
    /// quota. A host without an Artifact owner answers as the read-only
    /// foundation always has.
    fn artifact_quota(&self) -> Result<Value, WireError> {
        Err(WireError {
            code: "rejected".into(),
            message: "this method is unavailable in the read-only Rust foundation".into(),
            details: None,
        })
    }
    /// `capability.list` and `capability.inspect` read the Runtime capability
    /// store. A host without one answers as the read-only foundation always
    /// has.
    fn capability_resource(
        &self,
        _method: &str,
        _params: &serde_json::Map<String, Value>,
    ) -> Result<Value, WireError> {
        Err(WireError {
            code: "rejected".into(),
            message: "this method is unavailable in the read-only Rust foundation".into(),
            details: None,
        })
    }
    /// `cleanupDebt.list` reads the Job cleanup debt ledger beside the
    /// Artifacts, and `cleanupDebt.continue` continues one of its debts. A
    /// host without the Artifact and Job owners answers as the read-only
    /// foundation always has.
    fn cleanup_debt(
        &self,
        _method: &str,
        _params: &serde_json::Map<String, Value>,
    ) -> Result<Value, WireError> {
        Err(WireError {
            code: "rejected".into(),
            message: "this method is unavailable in the read-only Rust foundation".into(),
            details: None,
        })
    }
    fn bootstrap_register_bundle(&self, _file: &str) -> Result<Value, WireError> {
        Err(WireError {
            code: "operationUnavailable".into(),
            message: "Bundle registration owner is not configured".into(),
            details: Some(serde_json::Map::from_iter([
                ("phase".into(), json!("bootstrapRegistryOwner")),
                ("newDispatchCount".into(), json!(0)),
            ])),
        })
    }
    fn bootstrap_register_deveco(&self, _root: &str) -> Result<Value, WireError> {
        Err(WireError {
            code: "operationUnavailable".into(),
            message: "DevEco registration owner is not configured".into(),
            details: Some(serde_json::Map::from_iter([
                ("phase".into(), json!("bootstrapRegistryOwner")),
                ("newDispatchCount".into(), json!(0)),
            ])),
        })
    }
    fn bootstrap_register_hdc(&self, _file: &str) -> Result<Value, WireError> {
        Err(WireError {
            code: "operationUnavailable".into(),
            message: "HDC registration owner is not configured".into(),
            details: Some(serde_json::Map::from_iter([
                ("phase".into(), json!("bootstrapRegistryOwner")),
                ("newDispatchCount".into(), json!(0)),
            ])),
        })
    }
    fn trace_cache_purge(&self) -> Result<Value, WireError> {
        Err(WireError {
            code: "rejected".into(),
            message: "Trace cache owner is not configured".into(),
            details: None,
        })
    }
    fn trace_cache_status(&self) -> Result<Value, WireError> {
        Err(WireError {
            code: "rejected".into(),
            message: "Trace cache owner is not configured".into(),
            details: None,
        })
    }
    fn bootstrap_bundle_list(
        &self,
        _page_size: usize,
        _cursor: Option<&str>,
    ) -> Result<Value, WireError> {
        Err(WireError {
            code: "operationUnavailable".into(),
            message: "Bootstrap bundle list owner is not configured".into(),
            details: Some(serde_json::Map::from_iter([
                ("phase".into(), json!("bootstrapRegistryOwner")),
                ("newDispatchCount".into(), json!(0)),
            ])),
        })
    }
    fn bootstrap_inspect(
        &self,
        _kind: BootstrapRegistryKind,
        _reference: &str,
    ) -> Result<Value, WireError> {
        Err(WireError {
            code: "operationUnavailable".into(),
            message: "Bootstrap read owner is not configured".into(),
            details: Some(serde_json::Map::from_iter([
                ("phase".into(), json!("bootstrapRegistryOwner")),
                ("newDispatchCount".into(), json!(0)),
            ])),
        })
    }

    fn session_resource(
        &self,
        _method: &str,
        _params: &serde_json::Map<String, Value>,
    ) -> Result<Value, WireError> {
        Err(WireError {
            code: "rejected".into(),
            message: "Session owner is not configured".into(),
            details: None,
        })
    }
    fn runtime_storage(
        &self,
        _method: &str,
        _params: &serde_json::Map<String, Value>,
    ) -> Result<Value, WireError> {
        Err(WireError {
            code: "rejected".into(),
            message: "Runtime storage owners are not configured".into(),
            details: None,
        })
    }
    /// The startup facts of the HDC server the Runtime manages, which
    /// `target.availability` reports as its tool leg; none without one.
    fn managed_hdc_tool(&self) -> Option<ManagedToolFacts> {
        None
    }
    /// Fixed Debug reads. The router validates caller fields before reaching an owner.
    fn debug_read(&self, _target_id: &str, _template_id: Option<&str>) -> Result<Value, WireError> {
        Err(WireError {
            code: "internalError".into(),
            message: "Debug Runtime probing is not configured".into(),
            details: None,
        })
    }
    /// `trace.probe`: the fixed Trace Runtime probe of an adopted Target. The
    /// router reads its `targetId` before reaching an owner; a host without
    /// one answers as Swift's daemon without its probe does.
    fn trace_probe(&self, _target_id: &str) -> Result<Value, WireError> {
        Err(WireError {
            code: "internalError".into(),
            message: "Trace Runtime probing is not configured".into(),
            details: None,
        })
    }
    /// `flash.reconcile-alias` once its two parameters were read: the
    /// Target's post-flash alias reconciled against the one attached board. A
    /// host without the reconciler answers as Swift's daemon without it does.
    fn flash_reconcile_alias(
        &self,
        _target_id: &str,
        _expected_binding_revision: i64,
    ) -> Result<Value, WireError> {
        Err(WireError {
            code: "internalError".into(),
            message: "Rockchip post-flash alias reconciliation is not configured".into(),
            details: None,
        })
    }
    /// `flash.prerequisites` once its target and a supported profile were
    /// read. A host without the prerequisite observer answers as Swift's
    /// daemon without it does.
    fn flash_prerequisites(
        &self,
        _target_id: &str,
        _profile_reference: &str,
    ) -> Result<Value, WireError> {
        Err(WireError {
            code: "internalError".into(),
            message: "Flash prerequisite observation is not configured".into(),
            details: None,
        })
    }
    /// `flash.bootloader-status`, which reads no parameter. A host without
    /// the bootloader status observer answers as Swift's daemon without it.
    fn flash_bootloader_status(&self) -> Result<Value, WireError> {
        Err(WireError {
            code: "internalError".into(),
            message: "Rockchip bootloader status observation is not configured".into(),
            details: None,
        })
    }
    /// `flash.device-access`, which takes no parameter: the Rockchip flashing
    /// modes the ArkForge lane's daemon sees attached. A host without the
    /// observer answers as Swift's daemon without it.
    fn flash_device_access(&self) -> Result<Value, WireError> {
        Err(WireError {
            code: "internalError".into(),
            message: "Rockchip device access observation is not configured".into(),
            details: None,
        })
    }
    /// `debug.status` and `recovery.flash-invocation.list`: the reads of the
    /// Runtime Flash invocation owner, which checks their parameters itself
    /// once it is composed, as Swift's handler does. A host without the owner
    /// answers as Swift's daemon without it does, whatever the parameters.
    fn flash_invocation(
        &self,
        method: &str,
        _params: &serde_json::Map<String, Value>,
    ) -> Result<Value, WireError> {
        Err(WireError {
            code: "internalError".into(),
            message: if method == "debug.status" {
                "Runtime debug invocation is not configured"
            } else {
                "Runtime Flash invocation owner is not configured"
            }
            .into(),
            details: None,
        })
    }
    /// `runtime.hdc.status`: the live HDC status the Runtime answers. A host
    /// without it keeps the foundation's refusal.
    fn runtime_hdc_status(&self) -> Result<Value, WireError> {
        Err(WireError {
            code: "rejected".into(),
            message: "this method is unavailable in the read-only Rust foundation".into(),
            details: None,
        })
    }
    /// `runtime.hdc.impact-preview`, `runtime.hdc.restart`,
    /// `runtime.tool.select` and `control-action.list`, `.show` and
    /// `.reconcile`: Swift's `hdcControlActionRequest`, parameters and all. A
    /// host without its control-action owners keeps the foundation's refusal.
    fn control_action(
        &self,
        _method: &str,
        _params: &serde_json::Map<String, Value>,
    ) -> Result<Value, WireError> {
        Err(WireError {
            code: "rejected".into(),
            message: "this method is unavailable in the read-only Rust foundation".into(),
            details: None,
        })
    }
    fn workspace_project(
        &self,
        method: &str,
        _params: &serde_json::Map<String, Value>,
    ) -> Result<Value, WireError> {
        let phase = if method.starts_with("workspace.preset.") {
            "workspacePresetOwner"
        } else {
            "workspaceProjectOwner"
        };
        Err(WireError {
            code: "operationUnavailable".into(),
            message: "workspace project owner is unavailable".into(),
            details: Some(serde_json::Map::from_iter([
                ("phase".into(), json!(phase)),
                ("newDispatchCount".into(), json!(0)),
            ])),
        })
    }
    fn history_filter(
        &self,
        _method: &str,
        _params: &serde_json::Map<String, Value>,
    ) -> Result<Value, WireError> {
        Err(WireError {
            code: "rejected".into(),
            message: "History filter owner is not configured".into(),
            details: None,
        })
    }
    fn bootstrap_bundle_remove(
        &self,
        _reference: &str,
        _generation: &str,
    ) -> Result<Value, WireError> {
        Err(WireError {
            code: "operationUnavailable".into(),
            message: "Bundle retirement owner is not configured".into(),
            details: Some(serde_json::Map::from_iter([
                ("phase".into(), json!("bootstrapRegistryOwner")),
                ("newDispatchCount".into(), json!(0)),
            ])),
        })
    }
    fn bootstrap_tool_remove(
        &self,
        _reference: &str,
        _generation: &str,
    ) -> Result<Value, WireError> {
        Err(WireError {
            code: "operationUnavailable".into(),
            message: "Tool retirement owner is not configured".into(),
            details: Some(serde_json::Map::from_iter([
                ("phase".into(), json!("bootstrapRegistryOwner")),
                ("newDispatchCount".into(), json!(0)),
            ])),
        })
    }
    fn bootstrap_tool_list(
        &self,
        _page_size: usize,
        _cursor: Option<&str>,
    ) -> Result<Value, WireError> {
        Err(WireError {
            code: "operationUnavailable".into(),
            message: "Bootstrap bundle list owner is not configured".into(),
            details: Some(serde_json::Map::from_iter([
                ("phase".into(), json!("bootstrapRegistryOwner")),
                ("newDispatchCount".into(), json!(0)),
            ])),
        })
    }
    /// `device.observations` following an observation reference. A host
    /// without a retained snapshot answers that this Runtime does not retain
    /// it.
    fn observations_following(
        &self,
        reference: &Value,
    ) -> Result<DeviceObservationsResult, WireError> {
        Err(observation_refusal(
            "resourceConflict",
            "the referenced observation is not retained by this Runtime",
            Some(reference),
        ))
    }
    /// `target.adopt`: the device of one exact observation adopted as a
    /// Target. A host without the Target observation owner keeps the
    /// foundation's refusal.
    fn target_adopt(&self, _params: &serde_json::Map<String, Value>) -> Result<Value, WireError> {
        Err(WireError {
            code: "rejected".into(),
            message: "this method is unavailable in the read-only Rust foundation".into(),
            details: None,
        })
    }
    /// What `doctor` reads from the host's owners beyond the Catalog and the
    /// HDC status. The default is a host with none of them.
    fn doctor_facts(&self, _deep: bool) -> DoctorFacts {
        DoctorFacts::default()
    }
    fn observed_at(&self) -> String;
    fn hdc_status(&self, deep: bool) -> HdcStatus;
    fn observations(&self) -> Result<DeviceObservationsResult, WireError>;
}

/// Swift `doctorReport`'s owner inputs: the Runtime Artifact store's quota
/// (read in deep mode), the durable Target store's active Targets (read in
/// both modes), whether device discovery is composed (Swift's
/// `DeviceBootstrapMachine`), and the outstanding cleanup debt (read in deep
/// mode; `None` when it cannot be read, as for an engine without an Artifact
/// store).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct DoctorFacts {
    pub artifacts: ArtifactStoreFacts,
    pub targets: TargetStoreFacts,
    pub discovery: bool,
    pub cleanup_debt: Option<u64>,
    /// The Jobs start-up recovery set aside, in its order, each with the
    /// reason it gave (Swift `engine.quarantinedJobRecords`).
    pub quarantined: Vec<(String, String)>,
    /// Every durable Job record in the store this build cannot decode, and a
    /// bounded sample of their identities in the index's order (Swift
    /// `engine.unreadableDurableRecords()`, whose sample stops at 16). Read
    /// only for a deep report, so absent otherwise.
    pub unreadable_records: Option<(u64, Vec<String>)>,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum ArtifactStoreFacts {
    #[default]
    NotConfigured,
    /// Configured; its quota is read only in deep mode.
    NotChecked,
    Quota {
        total: u64,
        used: u64,
    },
    Unreadable,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum TargetStoreFacts {
    #[default]
    NotConfigured,
    /// Readable, with this many active Targets.
    Adopted(u64),
    Unreadable,
}

/// Swift `HDCManagedRuntimeDiagnostics` as `target.availability`'s tool leg
/// reports them: the verified tool's digest, the client and server versions
/// the startup `checkserver` answered, and how the endpoint was selected.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ManagedToolFacts {
    pub tool_sha256: String,
    pub client_version: String,
    pub server_version: String,
    pub endpoint_source: String,
}

#[derive(Debug, Clone)]
pub struct HdcStatus {
    pub configured: bool,
    pub checked: bool,
    pub availability: String,
    pub ownership: String,
    pub server_health: String,
    pub reason_code: String,
}

impl HdcStatus {
    pub fn unavailable(deep: bool, reason_code: &str) -> Self {
        Self {
            configured: false,
            checked: deep,
            availability: "unavailable".into(),
            ownership: "unknown".into(),
            server_health: "unknown".into(),
            reason_code: reason_code.into(),
        }
    }
}

pub struct Control<H> {
    host: H,
    operations: Value,
    providers: Vec<String>,
}

/// The transport that accepted a frame, as that transport authenticated its
/// connection. A frame can name neither.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Origin {
    /// The local control socket, with or without a foreground console.
    Local { foreground_console: bool },
    /// The authenticated App transport.
    App,
}

impl<H: HostServices> Control<H> {
    pub fn new(host: H) -> Result<Self, ContractError> {
        if sha256_hex(CATALOG_CANONICAL_JSON.as_bytes()) != CATALOG_DIGEST {
            return Err(ContractError::ContractMismatch);
        }
        let catalog: Vec<Value> =
            serde_json::from_str(CATALOG_CANONICAL_JSON).map_err(|_| ContractError::Malformed)?;
        // Cache only Catalog metadata and the unregistered fallback. Fresh
        // host availability replaces that fallback at each discovery request;
        // publishing a descriptor alone never registers its provider.
        let operations = Value::Array(catalog.iter().map(|d| {
            let reference = match d["version"].as_u64() {
                Some(version) => format!("{}@{version}", d["id"].as_str().expect("Catalog id")),
                None => d["id"].as_str().expect("Catalog id").to_owned(),
            };
            json!({"reference":reference,"canonicalReference":reference,"aliasFor":d.get("aliasFor").unwrap_or(&Value::Null),
                "minimumEffect":d["effect"]["minimum"],"binding":d["binding"],"profiles":d["profiles"],
                "availability":"unavailable","reasonCodes":["provider_not_registered"],"reasonOrigins":["product_build"],
                "reasons":[format!("provider {} is not registered",d["provider"].as_str().expect("Catalog provider"))]})
        }).collect());
        validate_method_value("operation.list", "result", &operations)?;
        let providers = catalog
            .iter()
            .map(|d| d["provider"].as_str().expect("Catalog provider").to_owned())
            .collect();
        Ok(Self {
            host,
            operations,
            providers,
        })
    }

    /// The same fresh projection feeds discovery and descriptor views. Keep
    /// metadata cached, but never cache provider or executable availability.
    pub fn operation_availability(&self) -> Value {
        let items: Vec<_> = self
            .operations
            .as_array()
            .expect("Catalog operations")
            .iter()
            .zip(&self.providers)
            .map(|(base, provider)| {
                let mut item = base.clone();
                if let Some(reasons) = self.host.operation_availability(
                    base["reference"].as_str().expect("Catalog reference"),
                    provider,
                ) {
                    item["availability"] = json!(if reasons.is_empty() {
                        "available"
                    } else {
                        "unavailable"
                    });
                    item["reasons"] =
                        json!(reasons.iter().map(|(_, reason)| reason).collect::<Vec<_>>());
                    item["reasonCodes"] =
                        json!(reasons.iter().map(|(code, _)| code).collect::<Vec<_>>());
                    item["reasonOrigins"] = json!(
                        reasons
                            .iter()
                            .map(|(code, _)| match *code {
                                "provider_not_registered"
                                | "operation_not_supported"
                                | "workspace_preset_not_offered" => "product_build",
                                _ => "host_configuration",
                            })
                            .collect::<Vec<_>>()
                    );
                }
                item
            })
            .collect();
        Value::Array(items)
    }

    /// Payload excludes its LF delimiter. Every path returns one bounded frame.
    pub fn handle_frame(&self, bytes: &[u8]) -> Vec<u8> {
        self.handle_frame_with_console(bytes, false)
    }

    /// `foreground_console` comes from the kernel-authenticated connection,
    /// never from the request or the App transport.
    pub fn handle_frame_with_console(&self, bytes: &[u8], foreground_console: bool) -> Vec<u8> {
        self.handle_frame_from(bytes, Origin::Local { foreground_console })
    }

    /// A frame the authenticated App transport accepted. That transport, not
    /// the frame, supplies this origin, and it never holds a foreground
    /// console. Only its Import methods answer differently from a local
    /// client's: they reach `HostServices::app_import_resource`.
    pub fn handle_app_frame(&self, bytes: &[u8]) -> Vec<u8> {
        self.handle_frame_from(bytes, Origin::App)
    }

    fn handle_frame_from(&self, bytes: &[u8], origin: Origin) -> Vec<u8> {
        let foreground_console = origin
            == Origin::Local {
                foreground_console: true,
            };
        let request = match decode_request(bytes) {
            Ok(request) => request,
            Err(error) => {
                let (code, message) = match error {
                    ContractError::UnsupportedVersion => (
                        "unsupportedProtocolVersion",
                        "this Runtime requires exactly 1.0.0",
                    ),
                    ContractError::ContractMismatch => (
                        "unsupportedProtocolVersion",
                        "client and Runtime must use the same current control contract",
                    ),
                    ContractError::UnknownMethod => {
                        ("unknownMethod", "method is not published by this Runtime")
                    }
                    _ => ("malformedFrame", "undecodable current request frame"),
                };
                let id = if matches!(
                    error,
                    ContractError::UnsupportedVersion
                        | ContractError::ContractMismatch
                        | ContractError::UnknownMethod
                ) {
                    frame_id(bytes)
                } else {
                    "-".into()
                };
                return response_bytes(Response::failure(id, code, message));
            }
        };
        let params = request.params.unwrap_or_default();
        let response = match request.method.as_str() {
            "health" if params.is_empty() => Response::success(
                &request.id,
                json!({
                "status":"ok","protocolVersion":PROTOCOL_VERSION,"contractIdentity":CONTRACT_IDENTITY,
                "catalogDigest":CATALOG_DIGEST,"providers":[],"publishedMethods":METHODS}),
            ),
            "health" => {
                Response::failure(&request.id, "invalidParams", "health accepts no parameters")
            }
            "operation.list" if params.is_empty() => {
                Response::success(&request.id, self.operation_availability())
            }
            "operation.list" => Response::failure(
                &request.id,
                "invalidParams",
                "operation.list accepts no parameters",
            ),
            "operation.describe" => {
                if params.len() != 1 || !params.get("reference").is_some_and(Value::is_string) {
                    Response::failure(
                        &request.id,
                        "invalidParams",
                        "an exact operation reference is required",
                    )
                } else {
                    let reference = params["reference"].as_str().expect("checked reference");
                    let operations = self.operation_availability();
                    match operations
                        .as_array()
                        .expect("Catalog operations")
                        .iter()
                        .find(|v| v["reference"] == reference)
                    {
                        None => Response::failure(
                            &request.id,
                            "notFound",
                            "operation reference does not exist",
                        ),
                        Some(availability) => {
                            match operation_description::describe(reference, availability) {
                                Ok(Some(result)) => Response::success(&request.id, result),
                                _ => Response::failure(
                                    &request.id,
                                    "internalError",
                                    "Catalog descriptor could not be projected",
                                ),
                            }
                        }
                    }
                }
            }
            "doctor" => {
                if params.keys().any(|k| k != "deep") {
                    Response::failure(
                        &request.id,
                        "invalidParams",
                        "doctor accepts only the deep boolean",
                    )
                } else if params.get("deep").is_some_and(|v| !v.is_boolean()) {
                    Response::failure(
                        &request.id,
                        "invalidParams",
                        "doctor deep must be a boolean",
                    )
                } else {
                    Response::success(
                        &request.id,
                        self.doctor(params.get("deep").and_then(Value::as_bool).unwrap_or(false)),
                    )
                }
            }
            "target.availability" => Response {
                id: request.id.clone(),
                outcome: self.target_availability(&params),
            },
            "target.list"
            | "target.show"
            | "target.display-name.set"
            | "target.display-name.clear" => Response {
                id: request.id.clone(),
                outcome: self.host.target_resource(&request.method, &params),
            },
            "device.display-name.set" | "device.display-name.clear" => Response {
                id: request.id.clone(),
                outcome: self.host.candidate_display_name(&request.method, &params),
            },
            "device.observations" => {
                if params.keys().any(|k| k != "following") {
                    observation_failure(
                        &request.id,
                        "invalidInput",
                        "device observations accepts only following",
                        None,
                    )
                } else if let Some(reference) = params.get("following") {
                    // Only the host's own snapshot can retain an observation;
                    // a caller's reference never becomes identity.
                    if valid_observation_reference(reference) {
                        Response {
                            id: request.id.clone(),
                            outcome: self
                                .host
                                .observations_following(reference)
                                .and_then(encode_observations),
                        }
                    } else {
                        observation_failure(
                            &request.id,
                            "invalidInput",
                            "candidate, observationId and canonical positive observationGeneration are required",
                            None,
                        )
                    }
                } else {
                    Response {
                        id: request.id.clone(),
                        outcome: self.host.observations().and_then(encode_observations),
                    }
                }
            }
            "target.adopt" => Response {
                id: request.id.clone(),
                outcome: self.host.target_adopt(&params),
            },
            "trace.cache.purge" if params.is_empty() => Response {
                id: request.id.clone(),
                outcome: self.host.trace_cache_purge(),
            },
            "trace.cache.purge" => Response::failure(
                &request.id,
                "invalidParams",
                "Trace cache purge accepts no parameters",
            ),
            "trace.cache.status" if params.is_empty() => Response {
                id: request.id.clone(),
                outcome: self.host.trace_cache_status(),
            },
            "trace.cache.status" => Response::failure(
                &request.id,
                "invalidParams",
                "Trace cache status accepts no parameters",
            ),
            "runtime.bundle.register" => {
                let file = params.get("file").and_then(Value::as_str);
                if params.len() != 2
                    || params.get("kind") != Some(&json!("daemon-bundle"))
                    || !file.is_some_and(|path| {
                        path.starts_with('/')
                            && path.len() <= 16_384
                            && !path.contains('\0')
                            && !path.split('/').any(|part| matches!(part, "." | ".."))
                    })
                {
                    Response { id: request.id.clone(), outcome: Err(WireError {
                        code: "invalidParams".into(), message: "Bundle registration requires kind daemon-bundle and an absolute local file".into(),
                        details: Some(serde_json::Map::from_iter([("phase".into(), json!("bootstrapRegistryOwner")), ("newDispatchCount".into(), json!(0))])),
                    }) }
                } else {
                    return bootstrap_mutation_response_bytes(
                        "runtime.bundle.register",
                        Response {
                            id: request.id.clone(),
                            outcome: self
                                .host
                                .bootstrap_register_bundle(file.expect("validated file")),
                        },
                    );
                }
            }
            "runtime.tool.register" => {
                let kind = params.get("kind").and_then(Value::as_str);
                let key = match kind {
                    Some("hdc") => "file",
                    _ => "root",
                };
                let root = params.get(key).and_then(Value::as_str);
                if params.len() != 2
                    || !matches!(kind, Some("deveco" | "hdc"))
                    || !root.is_some_and(|path| {
                        path.starts_with('/')
                            && !path.as_bytes().contains(&0)
                            && !path.split('/').any(|part| matches!(part, "." | ".."))
                    })
                {
                    Response {
                        id: request.id.clone(),
                        outcome: Err(WireError {
                            code: "invalidParams".into(),
                            message: "Tool registration requires kind and its absolute local path"
                                .into(),
                            details: Some(serde_json::Map::from_iter([
                                ("phase".into(), json!("bootstrapRegistryOwner")),
                                ("newDispatchCount".into(), json!(0)),
                            ])),
                        }),
                    }
                } else {
                    return bootstrap_mutation_response_bytes(
                        "runtime.tool.register",
                        Response {
                            id: request.id.clone(),
                            outcome: if kind == Some("hdc") {
                                self.host
                                    .bootstrap_register_hdc(root.expect("validated file"))
                            } else {
                                self.host
                                    .bootstrap_register_deveco(root.expect("validated root"))
                            },
                        },
                    );
                }
            }
            "runtime.tool.list" => {
                let size = match params.get("pageSize") {
                    None => Some(100),
                    Some(value) => value.as_i64(),
                };
                let cursor = params.get("cursor");
                let valid = params
                    .keys()
                    .all(|key| matches!(key.as_str(), "pageSize" | "cursor"))
                    && size.is_some()
                    && cursor.is_none_or(Value::is_string);
                if !valid {
                    Response {
                        id: request.id.clone(),
                        outcome: Err(WireError {
                            code: "invalidParams".into(),
                            message: "tool list accepts only integer pageSize and string cursor"
                                .into(),
                            details: Some(serde_json::Map::from_iter([
                                ("phase".into(), json!("bootstrapRegistryOwner")),
                                ("newDispatchCount".into(), json!(0)),
                            ])),
                        }),
                    }
                } else {
                    Response {
                        id: request.id.clone(),
                        outcome: self.host.bootstrap_tool_list(
                            usize::try_from(size.expect("checked integer")).unwrap_or(0),
                            cursor.and_then(Value::as_str),
                        ),
                    }
                }
            }
            "runtime.bundle.list" => {
                let size = match params.get("pageSize") {
                    None => Some(100),
                    Some(value) => value.as_i64(),
                };
                let cursor = params.get("cursor");
                let valid = params
                    .keys()
                    .all(|key| matches!(key.as_str(), "pageSize" | "cursor"))
                    && size.is_some()
                    && cursor.is_none_or(Value::is_string);
                if !valid {
                    Response {
                        id: request.id.clone(),
                        outcome: Err(WireError {
                            code: "invalidParams".into(),
                            message: "bundle list accepts only integer pageSize and string cursor"
                                .into(),
                            details: Some(serde_json::Map::from_iter([
                                ("phase".into(), json!("bootstrapRegistryOwner")),
                                ("newDispatchCount".into(), json!(0)),
                            ])),
                        }),
                    }
                } else {
                    Response {
                        id: request.id.clone(),
                        outcome: self.host.bootstrap_bundle_list(
                            usize::try_from(size.expect("checked integer")).unwrap_or(0),
                            cursor.and_then(Value::as_str),
                        ),
                    }
                }
            }
            "runtime.bundle.remove" => {
                let reference = params.get("bundle").and_then(Value::as_str);
                let generation = params.get("expectedGeneration").and_then(Value::as_str);
                let outcome = if let (2, Some(reference), Some(generation)) =
                    (params.len(), reference, generation)
                {
                    self.host.bootstrap_bundle_remove(reference, generation)
                } else {
                    Err(WireError {
                        code: "invalidParams".into(),
                        message:
                            "bundle retirement requires typed bundle and expectedGeneration strings"
                                .into(),
                        details: Some(serde_json::Map::from_iter([
                            ("phase".into(), json!("bootstrapRegistryOwner")),
                            ("newDispatchCount".into(), json!(0)),
                        ])),
                    })
                };
                Response {
                    id: request.id.clone(),
                    outcome,
                }
            }
            "runtime.tool.remove" => {
                let reference = params.get("tool").and_then(Value::as_str);
                let generation = params.get("expectedGeneration").and_then(Value::as_str);
                let outcome = if let (2, Some(reference), Some(generation)) =
                    (params.len(), reference, generation)
                {
                    self.host.bootstrap_tool_remove(reference, generation)
                } else {
                    Err(WireError {
                        code: "invalidParams".into(),
                        message:
                            "tool retirement requires typed tool and expectedGeneration strings"
                                .into(),
                        details: Some(serde_json::Map::from_iter([
                            ("phase".into(), json!("bootstrapRegistryOwner")),
                            ("newDispatchCount".into(), json!(0)),
                        ])),
                    })
                };
                Response {
                    id: request.id.clone(),
                    outcome,
                }
            }
            "runtime.tool.inspect" | "runtime.bundle.inspect" => {
                let (key, kind, prefixes): (&str, BootstrapRegistryKind, &[&str]) =
                    if request.method == "runtime.tool.inspect" {
                        (
                            "tool",
                            BootstrapRegistryKind::Tool,
                            &["tool:sha256:", "toolchain:sha256:"],
                        )
                    } else {
                        ("bundle", BootstrapRegistryKind::Bundle, &["bundle:sha256:"])
                    };
                let reference = params.get(key).and_then(Value::as_str);
                if params.len() != 1
                    || !reference.is_some_and(|reference| {
                        prefixes.iter().any(|prefix| {
                            reference.strip_prefix(prefix).is_some_and(|digest| {
                                digest.len() == 64
                                    && digest.bytes().all(|byte| {
                                        byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte)
                                    })
                            })
                        })
                    })
                {
                    Response {
                        id: request.id.clone(),
                        outcome: Err(WireError {
                            code: "invalidParams".into(),
                            message: "one exact bootstrap resource reference is required".into(),
                            details: Some(serde_json::Map::from_iter([
                                ("phase".into(), json!("bootstrapRegistryOwner")),
                                ("newDispatchCount".into(), json!(0)),
                            ])),
                        }),
                    }
                } else {
                    Response {
                        id: request.id.clone(),
                        outcome: self
                            .host
                            .bootstrap_inspect(kind, reference.expect("checked reference")),
                    }
                }
            }
            "history.filter.list" | "history.filter.save" | "history.filter.delete" => Response {
                id: request.id.clone(),
                outcome: self.host.history_filter(&request.method, &params),
            },
            "job.list" | "job.status" | "job.show" | "job.timeline" | "job.events" => Response {
                id: request.id.clone(),
                outcome: self.host.job_resource(&request.method, &params),
            },
            "job.plan" => Response {
                id: request.id.clone(),
                outcome: self.host.job_plan(&params),
            },
            "job.submit" => Response {
                id: request.id.clone(),
                outcome: self.host.job_submit(&params),
            },
            "job.run" => Response {
                id: request.id.clone(),
                outcome: self.host.job_run(&params),
            },
            "job.cancel" => Response {
                id: request.id.clone(),
                outcome: self.host.job_cancel(&params),
            },
            "job.reconcile" => Response {
                id: request.id.clone(),
                outcome: self.host.job_reconcile(&params),
            },
            "job.result" | "job.evidence" => Response {
                id: request.id.clone(),
                outcome: self.host.job_result_resource(&request.method, &params),
            },
            "capability.list" | "capability.inspect" => Response {
                id: request.id.clone(),
                outcome: self.host.capability_resource(&request.method, &params),
            },
            "cleanupDebt.list" | "cleanupDebt.continue" => Response {
                id: request.id.clone(),
                outcome: self.host.cleanup_debt(&request.method, &params),
            },
            "artifact.list" | "artifact.inspect" | "artifact.read" | "artifact.export" => {
                Response {
                    id: request.id.clone(),
                    outcome: self.host.artifact_resource(&request.method, &params),
                }
            }
            "agent.run"
            | "agent.status"
            | "agent.list"
            | "agent.abandon"
            | "agent.resume"
            | "human-action.resume" => Response {
                id: request.id.clone(),
                outcome: if request.method == "human-action.resume" && foreground_console {
                    self.host.interactive_human_action_resume(&params)
                } else {
                    self.host.agent_execution(&request.method, &params)
                },
            },
            "human-action.list" | "human-action.show" => Response {
                id: request.id.clone(),
                outcome: self.host.human_action(&request.method, &params),
            },
            // Swift reads no parameter of a quota request.
            "artifact.quota" => Response {
                id: request.id.clone(),
                outcome: self.host.artifact_quota(),
            },
            "artifact.import.begin"
            | "artifact.import.append"
            | "artifact.import.abort"
            | "artifact.import.inspect"
            | "artifact.import.inspection"
            | "artifact.import.list"
            | "artifact.import.commit"
            | "artifact.import.release" => Response {
                id: request.id.clone(),
                outcome: match origin {
                    Origin::App => self.host.app_import_resource(&request.method, &params),
                    Origin::Local { .. } => self.host.import_resource(&request.method, &params),
                },
            },
            "session.list"
            | "session.show"
            | "session.pin"
            | "session.unpin"
            | "session.cleanup.preview"
            | "session.cleanup.apply"
            | "session.export.preview"
            | "session.export.apply" => Response {
                id: request.id.clone(),
                outcome: self.host.session_resource(&request.method, &params),
            },
            "runtime.storage.status" | "runtime.storage.policy" | "runtime.storage.root" => {
                Response {
                    id: request.id.clone(),
                    outcome: self.host.runtime_storage(&request.method, &params),
                }
            }
            "workspace.project.register" | "workspace.project.list" | "workspace.project.show" => {
                let valid = match request.method.as_str() {
                    "workspace.project.register" => {
                        params.len() == 3
                            && ["registrationRequestId", "kind", "root"]
                                .iter()
                                .all(|key| params.get(*key).is_some_and(Value::is_string))
                    }
                    "workspace.project.show" => {
                        params.len() == 1
                            && params
                                .get("projectRef")
                                .and_then(Value::as_str)
                                .is_some_and(|reference| !reference.is_empty())
                    }
                    _ => params.is_empty(),
                };
                if !valid {
                    Response::failure(
                        &request.id,
                        "invalidParams",
                        "workspace project parameters are invalid",
                    )
                } else {
                    Response {
                        id: request.id.clone(),
                        outcome: self.host.workspace_project(&request.method, &params),
                    }
                }
            }
            // As Swift's handler, check for check and message for message:
            // exact keys and a canonical generation for a mutation, one closed
            // typed definition for a preset registration or update, a project
            // for every preset read.
            "workspace.project.update"
            | "workspace.project.remove"
            | "workspace.preset.list"
            | "workspace.preset.show"
            | "workspace.preset.register"
            | "workspace.preset.update"
            | "workspace.preset.remove" => match workspace_params_refusal(&request.method, &params)
            {
                Some(message) => Response::failure(&request.id, "invalidParams", message),
                None => Response {
                    id: request.id.clone(),
                    outcome: self.host.workspace_project(&request.method, &params),
                },
            },
            "debug.probe" | "debug.template.run" => {
                let target = params.get("targetId").and_then(Value::as_str);
                let template = params.get("templateId").and_then(Value::as_str);
                let error = if request.method == "debug.probe" {
                    if params.len() != 1 || !params.contains_key("targetId") {
                        Some("Debug Runtime probe accepts only targetId")
                    } else if target.is_none() {
                        Some("targetId is required")
                    } else if target.is_some_and(|id| id.is_empty() || id.len() > 128) {
                        Some("targetId must be a bounded durable target identity")
                    } else {
                        None
                    }
                } else if target.is_none()
                    || !matches!(
                        template,
                        Some(
                            "device.packageInventory"
                                | "device.debugParameterRead"
                                | "device.windowInventory"
                                | "device.uptime"
                        )
                    )
                {
                    Some("targetId and a closed templateId are required")
                } else {
                    None
                };
                match error {
                    Some(message) => Response::failure(&request.id, "invalidParams", message),
                    None => Response {
                        id: request.id.clone(),
                        outcome: self.host.debug_read(target.unwrap(), template),
                    },
                }
            }
            // As Swift's handler: a string `targetId` is required, and it is
            // all the handler reads; the probe's commands are fixed.
            "trace.probe" => match params.get("targetId").and_then(Value::as_str) {
                Some(target) => Response {
                    id: request.id.clone(),
                    outcome: self.host.trace_probe(target),
                },
                None => Response::failure(&request.id, "invalidParams", "targetId is required"),
            },
            // As Swift's handler: its two parameters, a string and a positive
            // integer (Foundation's reading of a JSON number), before its owner.
            "flash.reconcile-alias" => match (
                params.get("targetId").and_then(Value::as_str),
                params
                    .get("expectedBindingRevision")
                    .and_then(foundation_integer),
            ) {
                (Some(target), Some(revision)) if revision > 0 => Response {
                    id: request.id.clone(),
                    outcome: self.host.flash_reconcile_alias(target, revision),
                },
                _ => Response::failure(
                    &request.id,
                    "invalidParams",
                    "targetId and expectedBindingRevision are required",
                ),
            },
            // As Swift's handler: a string target and a supported profile
            // (`RockchipFlashProfile.board(reference:)` knows only `dayu200`)
            // before its owners.
            "flash.prerequisites" => match (
                params.get("targetId").and_then(Value::as_str),
                params.get("profileReference").and_then(Value::as_str),
            ) {
                (Some(target), Some(profile @ "dayu200")) => Response {
                    id: request.id.clone(),
                    outcome: self.host.flash_prerequisites(target, profile),
                },
                _ => Response::failure(
                    &request.id,
                    "invalidParams",
                    "a supported targetId and profileReference are required",
                ),
            },
            // As Swift's handler: no parameter is read.
            "flash.bootloader-status" => Response {
                id: request.id.clone(),
                outcome: self.host.flash_bootloader_status(),
            },
            // As Swift's handler: any parameter is refused, before the
            // observer; absent and empty parameters are the same request.
            "flash.device-access" if !params.is_empty() => Response::failure(
                &request.id,
                "invalidParams",
                "Device access discovery does not accept parameters",
            ),
            "flash.device-access" => Response {
                id: request.id.clone(),
                outcome: self.host.flash_device_access(),
            },
            // As Swift's handler: the owner before the parameters, which the
            // owner checks itself.
            "debug.status" | "recovery.flash-invocation.list" => Response {
                id: request.id.clone(),
                outcome: self.host.flash_invocation(&request.method, &params),
            },
            // As Swift's handler: a caller's facts are refused before any observation.
            "runtime.hdc.status" if params.is_empty() => Response {
                id: request.id.clone(),
                outcome: self.host.runtime_hdc_status(),
            },
            "runtime.hdc.status" => Response::failure(
                &request.id,
                "invalidParams",
                "live HDC status does not accept caller facts or paths",
            ),
            // Swift's handler checks each of these against its owners itself:
            // the lifecycle and selection methods before any parameter, the
            // others after.
            "runtime.hdc.impact-preview"
            | "runtime.hdc.restart"
            | "runtime.tool.select"
            | "control-action.list"
            | "control-action.show"
            | "control-action.reconcile" => Response {
                id: request.id.clone(),
                outcome: self.host.control_action(&request.method, &params),
            },
            _ => Response::failure(
                &request.id,
                "rejected",
                "this method is unavailable in the read-only Rust foundation",
            ),
        };
        if request.method == "runtime.tool.remove" {
            return bootstrap_mutation_response_bytes(&request.method, response);
        }
        let conforms = match &response.outcome {
            Ok(result) => validate_method_value(&request.method, "result", result).is_ok(),
            Err(error) => {
                validate_method_value(&request.method, "errorCode", &json!(error.code)).is_ok()
                    && error.details.as_ref().is_none_or(|details| {
                        validate_method_value(&request.method, "errorDetails", &json!(details))
                            .is_ok()
                    })
            }
        };
        if !conforms {
            return response_bytes(Response::failure(
                request.id,
                "internalError",
                "the result does not conform to the current contract",
            ));
        }
        response_bytes(response)
    }

    /// Swift `RuntimeControlPlaneHandler.doctorReport(deep:)`: every finding
    /// from the host's owners as they are now. Two Swift findings come from
    /// start-up recovery and are never emitted yet: `runtime.jobRecordUnreadable`
    /// (the recovery quarantine, which the isolated daemon reports on its
    /// standard error at its start) and `runtime.durableRecordsUnreadable`
    /// (the deep census of undecodable Job records).
    fn doctor(&self, deep: bool) -> Value {
        let hdc = self.host.hdc_status(deep);
        let facts = self.host.doctor_facts(deep);
        let mut findings = Vec::new();
        let (mut blockers, mut warnings) = (0_usize, 0_usize);
        let mut add =
            |code: &str, severity: &str, scope: &str, summary: &str, details: Option<Value>| {
                match severity {
                    "blocker" => blockers += 1,
                    "warning" => warnings += 1,
                    _ => {}
                }
                let mut row =
                    json!({"code":code,"severity":severity,"scope":scope,"summary":summary});
                if let Some(details) = details {
                    row["details"] = details;
                }
                findings.push(row);
            };
        add(
            "runtime.controlReady",
            "info",
            "runtime",
            "the target control protocol is serving bounded diagnostic requests",
            None,
        );

        // Swift: the Jobs whose durable record this build cannot decode. They
        // are why the daemon may be serving with part of its own store
        // unreadable, so each is a blocker naming the Job and the reason
        // recovery gave. Recovery already answered; nothing is read again.
        for (job, reason) in &facts.quarantined {
            add(
                "runtime.jobRecordUnreadable",
                "blocker",
                "runtime",
                &format!(
                    "a Job record in this store was written in a shape this build cannot read: {job} — {reason}. The Job is not live, its record was not modified, and it still counts as active"
                ),
                None,
            );
        }
        // Recovery's query excludes terminal states, so the findings above
        // name only still-active Jobs. A deep report counts the whole ledger
        // and names a bounded sample, as one finding rather than one per row.
        if let Some((total, sample)) = &facts.unreadable_records
            && *total > 0
        {
            let named = sample.join(", ");
            add(
                "runtime.durableRecordsUnreadable",
                "blocker",
                "runtime",
                &format!(
                    "{total} durable Job records in this store were written in a shape this build cannot read{}. No byte of these records is modified; every History page that would include one is refused, and every mutation face they could affect stays refused",
                    if named.is_empty() {
                        String::new()
                    } else {
                        format!(", among them {named}")
                    }
                ),
                None,
            );
        }

        // Swift `engine.operationAvailability()` and `providerIDs`: an
        // operation is available when the host answers it with no reason, and
        // a provider is registered when the host answers any of its
        // operations at all (otherwise `provider_not_registered`).
        let mut available = 0_usize;
        let mut registered = std::collections::BTreeSet::new();
        let operations = self.operations.as_array().expect("Catalog operations");
        for (base, provider) in operations.iter().zip(&self.providers) {
            if let Some(reasons) = self.host.operation_availability(
                base["reference"].as_str().expect("Catalog reference"),
                provider,
            ) {
                registered.insert(provider.clone());
                available += usize::from(reasons.is_empty());
            }
        }
        let unavailable = operations.len() - available;
        if available == 0 {
            add(
                "catalog.noAvailableOperations",
                "blocker",
                "catalog",
                "the published Catalog has no operation available on this Runtime",
                None,
            );
        } else {
            add(
                "catalog.availableOperations",
                "info",
                "catalog",
                "the Runtime can materialize at least one published operation",
                Some(json!({ "availableOperationCount": available })),
            );
        }
        if unavailable > 0 {
            add(
                "catalog.unavailableOperations",
                "warning",
                "catalog",
                "some published operations are unavailable with the current host configuration",
                Some(json!({ "unavailableOperationCount": unavailable })),
            );
        }
        if registered.is_empty() {
            add(
                "provider.noneRegistered",
                "blocker",
                "provider",
                "the Runtime has no registered provider",
                None,
            );
        } else {
            add(
                "provider.registered",
                "info",
                "provider",
                "the Runtime has registered providers",
                Some(json!({ "providerCount": registered.len() })),
            );
        }

        let mut hdc_check = json!({
            "checked": deep, "configured": hdc.configured,
            "availability": if deep { "unknown" } else { "notChecked" },
            "ownership": "unknown", "serverHealth": "unknown",
            "reasonCode": if deep { "hdc.statusUnavailable" } else { "doctor.deepNotRequested" },
        });
        if !hdc.configured {
            add(
                "hdc.notConfigured",
                "blocker",
                "hdc",
                "the Runtime has no bounded HDC status observer",
                None,
            );
            hdc_check["availability"] = json!("unavailable");
            hdc_check["reasonCode"] = json!("hdc.notConfigured");
        } else if deep {
            hdc_check["availability"] = json!(hdc.availability);
            hdc_check["ownership"] = json!(hdc.ownership);
            hdc_check["serverHealth"] = json!(hdc.server_health);
            hdc_check["reasonCode"] = json!(hdc.reason_code);
            if hdc.availability == "available" && hdc.ownership == "arkDeckManaged" {
                add(
                    "hdc.identityReady",
                    "info",
                    "hdc",
                    "the selected HDC server has a live Runtime-managed identity",
                    None,
                );
            } else {
                let reason = if hdc.reason_code.is_empty() {
                    String::new()
                } else {
                    format!(": {}", hdc.reason_code)
                };
                add(
                    "hdc.identityUnavailable",
                    "blocker",
                    "hdc",
                    &format!(
                        "the selected HDC server identity is unavailable or not Runtime-managed{reason}"
                    ),
                    None,
                );
            }
        } else {
            add(
                "hdc.deepCheckSkipped",
                "info",
                "hdc",
                "live HDC identity was not requested; use doctor --deep to check it",
                None,
            );
        }

        let mut runtime_artifacts = json!({
            "checked": deep,
            "configured": facts.artifacts != ArtifactStoreFacts::NotConfigured,
            "totalBytes": null, "usedBytes": null, "remainingBytes": null,
        });
        match facts.artifacts {
            ArtifactStoreFacts::NotConfigured => add(
                "storage.artifactStoreNotConfigured",
                "blocker",
                "storage",
                "the Runtime Artifact store is not configured",
                None,
            ),
            _ if !deep => add(
                "storage.deepCheckSkipped",
                "info",
                "storage",
                "Artifact quota accounting was not requested; use doctor --deep to check it",
                None,
            ),
            ArtifactStoreFacts::Quota { total, used } => {
                let remaining = total.saturating_sub(used);
                runtime_artifacts["totalBytes"] = json!(total);
                runtime_artifacts["usedBytes"] = json!(used);
                runtime_artifacts["remainingBytes"] = json!(remaining);
                if remaining == 0 {
                    add(
                        "storage.quotaExhausted",
                        "blocker",
                        "storage",
                        "the Runtime Artifact store has no remaining quota",
                        None,
                    );
                } else {
                    add(
                        "storage.artifactStoreReady",
                        "info",
                        "storage",
                        "the Runtime Artifact store is readable and has remaining quota",
                        None,
                    );
                }
            }
            ArtifactStoreFacts::NotChecked | ArtifactStoreFacts::Unreadable => add(
                "storage.artifactStoreUnreadable",
                "blocker",
                "storage",
                "the Runtime Artifact store could not produce bounded quota facts",
                None,
            ),
        }
        // The App-owned Session output root and the Runtime Artifact root are
        // separate stores; until a Runtime owner for Session output is
        // published, the gap is reported and never combined into one number.
        add(
            "storage.sessionOutputOwnerUnavailable",
            "warning",
            "storage",
            "Session output storage has no published Runtime owner",
            None,
        );

        let mut target_check = json!({
            "configured": facts.targets != TargetStoreFacts::NotConfigured,
            "bootstrapConfigured": facts.discovery,
            "adoptedTargetCount": null,
        });
        match facts.targets {
            TargetStoreFacts::Adopted(count) => {
                target_check["adoptedTargetCount"] = json!(count);
                let (code, summary) = if count == 0 {
                    (
                        "target.noneAdopted",
                        "the target store is readable and has no adopted target",
                    )
                } else {
                    ("target.storeReady", "the target store is readable")
                };
                add(
                    code,
                    "info",
                    "target",
                    summary,
                    Some(json!({ "adoptedTargetCount": count })),
                );
            }
            TargetStoreFacts::Unreadable => add(
                "target.storeUnreadable",
                "blocker",
                "target",
                "the durable target store could not be read",
                None,
            ),
            TargetStoreFacts::NotConfigured => add(
                "target.storeNotConfigured",
                "blocker",
                "target",
                "the durable target store is not configured",
                None,
            ),
        }
        if !facts.discovery {
            add(
                "target.discoveryNotConfigured",
                "blocker",
                "target",
                "device discovery is not configured",
                None,
            );
        }

        let mut recovery_check = json!({"checked": deep, "outstandingCleanupCount": null});
        if deep {
            match facts.cleanup_debt {
                Some(count) => {
                    recovery_check["outstandingCleanupCount"] = json!(count);
                    let (code, severity, summary) = if count == 0 {
                        (
                            "recovery.noCleanupDebt",
                            "info",
                            "the Runtime has no outstanding cleanup debt",
                        )
                    } else {
                        (
                            "recovery.cleanupDebtOutstanding",
                            "blocker",
                            "the Runtime has outstanding cleanup debt",
                        )
                    };
                    add(
                        code,
                        severity,
                        "recovery",
                        summary,
                        Some(json!({ "outstandingCleanupCount": count })),
                    );
                }
                None => add(
                    "recovery.cleanupDebtUnreadable",
                    "blocker",
                    "recovery",
                    "the Runtime could not inspect outstanding cleanup debt",
                    None,
                ),
            }
        } else {
            add(
                "recovery.deepCheckSkipped",
                "info",
                "recovery",
                "cleanup debt was not requested; use doctor --deep to check it",
                None,
            );
        }

        let overall = if blockers > 0 {
            "blocked"
        } else if warnings > 0 {
            "degraded"
        } else {
            "healthy"
        };
        let info = findings.len().saturating_sub(blockers + warnings);
        json!({"schemaVersion":"arkdeck.doctor-report/1","mode":if deep {"deep"} else {"standard"},
        "observedAt":self.host.observed_at(),"overall":overall,"ready":blockers == 0,
        "findingCounts":{"blocker":blockers,"warning":warnings,"info":info},"findings":findings,
        "checks":{
            "runtime":{"protocolVersion":PROTOCOL_VERSION,"runtimeRequestSchemaVersion":"1.0.0"},
            "catalog":{"digest":CATALOG_DIGEST,"operationCount":operations.len(),"availableOperationCount":available,"unavailableOperationCount":unavailable},
            "providers":{"registered":registered},
            "hdc":hdc_check,
            "storage":{"runtimeArtifacts":runtime_artifacts,
                "sessionOutput":{"availability":"unavailable","checked":false,"reasonCode":"storage.sessionOutputOwnerNotPublished"}},
            "target":target_check,
            "recovery":recovery_check
        }})
    }
}

fn valid_observation_reference(value: &Value) -> bool {
    let Some(fields) = value.as_object() else {
        return false;
    };
    fields.len() == 3
        && fields
            .get("candidate")
            .and_then(Value::as_str)
            .is_some_and(|s| (1..=1024).contains(&s.len()))
        && fields
            .get("observationId")
            .and_then(Value::as_str)
            .is_some_and(|s| (1..=128).contains(&s.len()))
        && fields
            .get("observationGeneration")
            .and_then(Value::as_str)
            .is_some_and(|s| {
                !s.starts_with('0')
                    && s.bytes().all(|b| b.is_ascii_digit())
                    && s.parse::<i64>().is_ok_and(|n| n > 0)
            })
}

/// A device observation refused before admission: no new dispatch, and the
/// observation reference the request named, if any.
pub fn observation_refusal(code: &str, message: &str, reference: Option<&Value>) -> WireError {
    let mut details = serde_json::Map::from_iter([
        ("phase".into(), json!("preAdmission")),
        ("newDispatchCount".into(), json!(0)),
    ]);
    if let Some(reference) = reference {
        for key in ["candidate", "observationId", "observationGeneration"] {
            details.insert(key.into(), reference[key].clone());
        }
    }
    WireError {
        code: code.into(),
        message: message.into(),
        details: Some(details),
    }
}

fn observation_failure(id: &str, code: &str, message: &str, reference: Option<&Value>) -> Response {
    // All callers are before the host entry; this proof is local, not inferred
    // from a timeout, lost reply or external observation failure.
    Response {
        id: id.into(),
        outcome: Err(observation_refusal(code, message, reference)),
    }
}

fn encode_observations(snapshot: DeviceObservationsResult) -> Result<Value, WireError> {
    serde_json::to_value(snapshot).map_err(|_| WireError {
        code: "internalError".into(),
        message: "observation encoding failed".into(),
        details: None,
    })
}

fn frame_id(bytes: &[u8]) -> String {
    if bytes.len() >= MAX_REQUEST_BYTES {
        return "-".into();
    }
    strict_json(bytes)
        .ok()
        .and_then(|v| v["id"].as_str().map(str::to_owned))
        .filter(|id| !id.is_empty() && id.len() <= 128 && id.chars().all(|c| c >= '\u{20}'))
        .unwrap_or_else(|| "-".into())
}

// The Bootstrap owner may already have published host metadata. Losing its
// classified receipt must preserve uncertainty, including schema/encoding failure.
fn bootstrap_mutation_response_bytes(method: &str, response: Response) -> Vec<u8> {
    let conforms = match &response.outcome {
        Ok(value) => validate_method_value(method, "result", value).is_ok(),
        Err(error) => {
            validate_method_value(method, "errorCode", &json!(error.code)).is_ok()
                && error.details.as_ref().is_none_or(|details| {
                    validate_method_value(method, "errorDetails", &json!(details)).is_ok()
                })
        }
    };
    if conforms && let Ok(bytes) = encode_frame(&response.value(), MAX_RESPONSE_BYTES) {
        return bytes;
    }
    response_bytes(Response {
        id: response.id,
        outcome: Err(WireError {
            code: "outcomeUnknown".into(),
            message: "Bootstrap mutation did not return a bounded classified receipt".into(),
            details: Some(serde_json::Map::from_iter([
                ("phase".into(), json!("bootstrapRegistryOwner")),
                ("newDispatchCount".into(), json!(0)),
            ])),
        }),
    })
}

fn response_bytes(response: Response) -> Vec<u8> {
    encode_frame(&response.value(), MAX_RESPONSE_BYTES).unwrap_or_else(|_| {
        encode_frame(
            &Response::failure(
                response.id,
                "internalError",
                "response exceeds the current frame limit",
            )
            .value(),
            MAX_RESPONSE_BYTES,
        )
        .expect("bounded error response")
    })
}

/// Swift `canonicalPositiveUInt64`: canonical decimal text in 1...Int64.max.
fn canonical_positive(value: Option<&Value>) -> bool {
    value.and_then(Value::as_str).is_some_and(|text| {
        text.parse::<u64>()
            .is_ok_and(|n| n > 0 && n <= i64::MAX as u64 && n.to_string() == text)
    })
}

/// Swift `decodeWorkspacePresetDefinition`: the mutation keys and the
/// definition's required keys present, nothing else but its optional keys,
/// every value typed.
fn preset_definition(params: &serde_json::Map<String, Value>, mutation_keys: &[&str]) -> bool {
    const OPTIONAL: [&str; 7] = [
        "toolchainRef",
        "toolchainGeneration",
        "credentialRef",
        "module",
        "product",
        "buildMode",
        "relativeSourceMap",
    ];
    let required: Vec<&str> = mutation_keys
        .iter()
        .copied()
        .chain(["kind", "templateRef", "timeoutSeconds"])
        .collect();
    required.iter().all(|key| params.contains_key(*key))
        && params
            .keys()
            .all(|key| required.contains(&key.as_str()) || OPTIONAL.contains(&key.as_str()))
        && params.get("kind").is_some_and(Value::is_string)
        && params.get("templateRef").is_some_and(Value::is_string)
        && canonical_positive(params.get("timeoutSeconds"))
        && OPTIONAL
            .iter()
            .filter(|key| **key != "toolchainGeneration")
            .all(|key| params.get(*key).is_none_or(Value::is_string))
        && params
            .get("toolchainGeneration")
            .is_none_or(|value| canonical_positive(Some(value)))
}

/// The `invalidParams` message Swift's handler answers for a malformed
/// workspace mutation or preset read, or `None` when it would proceed.
fn workspace_params_refusal(
    method: &str,
    params: &serde_json::Map<String, Value>,
) -> Option<&'static str> {
    let text = |key: &str| params.get(key).and_then(Value::as_str);
    let nonempty = |key: &str| text(key).is_some_and(|value| !value.is_empty());
    let exact =
        |keys: &[&str]| params.len() == keys.len() && keys.iter().all(|key| text(key).is_some());
    let generation = || canonical_positive(params.get("expectedGeneration"));
    match method {
        "workspace.project.update" => {
            (!(exact(&["projectRef", "expectedGeneration", "kind", "root"]) && generation()))
                .then_some(
                    "workspace project update requires exact project, generation, kind and root",
                )
        }
        "workspace.project.remove" => (!(exact(&["projectRef", "expectedGeneration"])
            && generation()))
        .then_some("workspace project remove requires exact project and generation"),
        "workspace.preset.list" => {
            if !nonempty("projectRef") {
                Some("projectRef is required")
            } else if params
                .keys()
                .any(|key| key != "projectRef" && key != "kind")
            {
                Some("workspace preset list accepts only projectRef and kind")
            } else if params.get("kind").is_some_and(|kind| !kind.is_string()) {
                Some("kind must be text")
            } else {
                None
            }
        }
        "workspace.preset.show" => {
            if !nonempty("projectRef") || !nonempty("presetRef") {
                Some("projectRef and presetRef are required")
            } else if params.len() != 2 {
                Some("workspace preset show requires exact projectRef and presetRef")
            } else {
                None
            }
        }
        "workspace.preset.register" => {
            (!(preset_definition(params, &["registrationRequestId", "projectRef"])
                && text("registrationRequestId").is_some()
                && text("projectRef").is_some()))
            .then_some("workspace preset register requires one closed typed definition")
        }
        "workspace.preset.update" => (!(preset_definition(
            params,
            &[
                "mutationRequestId",
                "projectRef",
                "presetRef",
                "expectedGeneration",
            ],
        ) && ["mutationRequestId", "projectRef", "presetRef"]
            .iter()
            .all(|key| text(key).is_some())
            && generation()))
        .then_some("workspace preset update requires identity, exact generation and definition"),
        _ => (!(exact(&[
            "mutationRequestId",
            "projectRef",
            "presetRef",
            "expectedGeneration",
        ]) && generation()))
        .then_some("workspace preset remove requires identity and exact generation"),
    }
}

/// Foundation's `Int64` of a JSON number, as Swift's `JSONValue.integer`
/// holds a request parameter: an integer, or a number with no fraction
/// inside the range.
fn foundation_integer(value: &Value) -> Option<i64> {
    value.as_i64().or_else(|| {
        value
            .as_f64()
            .filter(|float| {
                float.fract() == 0.0 && *float >= i64::MIN as f64 && *float < i64::MAX as f64
            })
            .map(|float| float as i64)
    })
}
