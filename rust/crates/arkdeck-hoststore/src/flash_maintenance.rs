//! Authority-owned maintenance over the same Job, binding and capability stores.
use crate::job_owner::arkforge_job_state::ArkForgeJobState;
use crate::job_plan::{FlashPlanner, FlashPlanning, Materialized, PlanRefusal};
use crate::operation_catalog::CatalogOperation;
use crate::operation_request::OperationRequest;
use crate::{FlashHostFacts, JobStore, TargetStore};
use arkdeck_contract::sha256_hex;
use arkdeck_provider_arkforge::{
    DeviceBinding, Execution, FlashLane, LaneArtifact, maintenance as m,
};
use arkdeck_provider_hdc::{DispatchFailure, HdcDispatch, ProcessPlan, Receipt};
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

pub(crate) fn is_maintenance(reference: &str) -> bool {
    matches!(reference, "flash.verify@1" | "flash.restore-boot-loop@1")
}

pub trait MaintenanceReads: Send + Sync {
    fn recommission_facts(
        &self,
        _target: &str,
        _deadline: Instant,
    ) -> Result<crate::flash_facts::RockchipFacts, String> {
        Err("controlled retry identity reads are unavailable".into())
    }
    fn recommission_read(
        &self,
        _key: &str,
        _effect: &m::Effect,
        _nonce: Option<&str>,
        _deadline: Instant,
    ) -> Result<(String, Option<arkdeck_provider_hdc::PrebootHash>), String> {
        Err("controlled retry full readback is unavailable".into())
    }
    fn observe(
        &self,
        execution: &Execution,
        deadline: Instant,
    ) -> Result<(m::Identity, DeviceBinding), String>;
    fn read(
        &self,
        execution: &Execution,
        target: &m::Effect,
        deadline: Instant,
    ) -> Result<m::ReadOutcome, String>;
}

pub struct NativeMaintenanceReads {
    facts: Arc<FlashHostFacts>,
    targets: Arc<TargetStore>,
    hdc: Box<crate::HdcResolver>,
}
impl NativeMaintenanceReads {
    pub fn new(
        facts: Arc<FlashHostFacts>,
        targets: Arc<TargetStore>,
        hdc: Box<crate::HdcResolver>,
    ) -> Self {
        Self {
            facts,
            targets,
            hdc,
        }
    }
}
struct BoundedHdc<'a> {
    hdc: &'a dyn HdcDispatch,
    deadline: Instant,
}
impl HdcDispatch for BoundedHdc<'_> {
    fn mutation_identity_current(&self) -> bool {
        self.hdc.mutation_identity_current()
    }
    fn registered_windows_tuple(&self) -> Option<&'static arkdeck_provider_hdc::WindowsHdcTuple> {
        self.hdc.registered_windows_tuple()
    }
    fn observe_server(&self) -> Result<arkdeck_provider_hdc::ServerObservation, DispatchFailure> {
        self.hdc.observe_server()
    }
    fn dispatch(&self, plan: &ProcessPlan) -> Result<Receipt, DispatchFailure> {
        let remaining = self
            .deadline
            .checked_duration_since(Instant::now())
            .filter(|d| !d.is_zero())
            .ok_or_else(|| DispatchFailure::Refused("maintenance budget exhausted".into()))?;
        self.hdc.dispatch(&ProcessPlan {
            arguments: plan.arguments.clone(),
            timeout: plan.timeout.min(remaining),
            capture_bytes: plan.capture_bytes,
        })
    }
}
impl MaintenanceReads for NativeMaintenanceReads {
    fn recommission_facts(
        &self,
        target: &str,
        deadline: Instant,
    ) -> Result<crate::flash_facts::RockchipFacts, String> {
        let hdc = (self.hdc)()?;
        let bounded = BoundedHdc {
            hdc: &*hdc,
            deadline,
        };
        self.facts
            .operation_facts(&self.targets, Some(&bounded), target, true)
    }
    fn recommission_read(
        &self,
        key: &str,
        effect: &m::Effect,
        nonce: Option<&str>,
        deadline: Instant,
    ) -> Result<(String, Option<arkdeck_provider_hdc::PrebootHash>), String> {
        let hdc = (self.hdc)()?;
        if let Some(nonce) = nonce {
            if effect.target != "userdata"
                || effect.range_start != arkdeck_provider_arkforge::preboot::USERDATA_START
                || effect.range_length != arkdeck_provider_arkforge::preboot::USERDATA_BYTES
            {
                return Err("preboot range differs from sealed userdata effect".into());
            }
            let proof = arkdeck_provider_hdc::read_preboot_hash(&*hdc, key, nonce, deadline)
                .map_err(str::to_owned)?;
            return Ok((proof.digest.clone(), Some(proof)));
        }
        match arkdeck_provider_hdc::read_flash_partition(
            &*hdc,
            key,
            &arkdeck_provider_hdc::PartitionRange {
                target: effect.target.clone(),
                range_start: effect.range_start,
                range_length: effect.range_length,
            },
            deadline,
        )
        .map_err(str::to_owned)?
        {
            arkdeck_provider_hdc::PartitionHash::Full(hash) => Ok((hash, None)),
            arkdeck_provider_hdc::PartitionHash::MountedWritable => {
                Err("controlled retry cannot count a writable mounted partition as verified".into())
            }
        }
    }
    fn observe(
        &self,
        execution: &Execution,
        deadline: Instant,
    ) -> Result<(m::Identity, DeviceBinding), String> {
        let hdc = (self.hdc)()?;
        let bounded = BoundedHdc {
            hdc: &*hdc,
            deadline,
        };
        let identity = self
            .facts
            .maintenance_identity(&self.targets, &bounded, execution)?;
        let facts =
            self.facts
                .current_facts(&self.targets, Some(&bounded), &execution.target_id)?;
        if Instant::now() >= deadline
            || facts.binding_revision != execution.binding_revision
            || facts.identity_sha256 != execution.stable_identity_sha256
            || facts.tool_sha256 != execution.toolchain_sha256
        {
            return Err("maintenance identity or budget changed".into());
        }
        Ok((
            identity,
            DeviceBinding {
                target_id: execution.target_id.clone(),
                binding_revision: execution.binding_revision,
                stable_identity_sha256: execution.stable_identity_sha256.clone(),
                connect_key: facts.execution_connect_key,
                usb_topology: execution.usb_topology.clone(),
                loader_first_connector_sha256: None,
                recommission: None,
            },
        ))
    }
    fn read(
        &self,
        execution: &Execution,
        target: &m::Effect,
        deadline: Instant,
    ) -> Result<m::ReadOutcome, String> {
        let (_, binding) = self.observe(execution, deadline)?;
        let hdc = (self.hdc)()?;
        let result = arkdeck_provider_hdc::read_flash_partition(
            &*hdc,
            &binding.connect_key,
            &arkdeck_provider_hdc::PartitionRange {
                target: target.target.clone(),
                range_start: target.range_start,
                range_length: target.range_length,
            },
            deadline,
        )
        .map_err(str::to_owned)?;
        Ok(match result {
            arkdeck_provider_hdc::PartitionHash::Full(hash) => m::ReadOutcome::FullHash(hash),
            arkdeck_provider_hdc::PartitionHash::MountedWritable => m::ReadOutcome::MountedWritable,
        })
    }
}

pub struct MaintenanceContext {
    pub(crate) jobs: Arc<JobStore>,
    pub(crate) lane: Arc<dyn FlashLane>,
    pub(crate) reads: Arc<dyn MaintenanceReads>,
    plans: Mutex<BTreeMap<String, m::ExecutablePlan>>,
}

pub(crate) struct Prepared {
    pub source: m::Source,
    pub execution: Execution,
    pub binding: DeviceBinding,
    pub restoration: Option<m::ExecutablePlan>,
    pub artifact: Option<LaneArtifact>,
    pub artifact_facts: BTreeMap<String, String>,
    pub digest: String,
}
impl MaintenanceContext {
    pub fn new(
        jobs: Arc<JobStore>,
        lane: Arc<dyn FlashLane>,
        reads: Arc<dyn MaintenanceReads>,
    ) -> Self {
        Self {
            jobs,
            lane,
            reads,
            plans: Mutex::new(BTreeMap::new()),
        }
    }
    pub(crate) fn prepare(
        &self,
        request: &OperationRequest,
        planner: &crate::JobPlanner<'_>,
    ) -> Result<Prepared, String> {
        let source_id = request
            .inputs
            .get("sourceJobId")
            .and_then(Value::as_str)
            .filter(|id| crate::job_repository::identifier(id))
            .ok_or("invalid maintenance source Job")?;
        if !self.jobs.maintenance_source_is_latest(
            source_id,
            &request.target_id,
            &request.idempotency_key,
        )? {
            return Err("maintenance requires the latest durable Flash Job on this target".into());
        }
        let record = self.jobs.read_snapshot(source_id).map_err(|e| e.message)?;
        if record.outcome_unknown() || record.request["target"]["targetId"] != request.target_id {
            return Err("source outcome or target is not confirmed".into());
        }
        let ArkForgeJobState {
            execution: Some(execution),
            ..
        } = self
            .jobs
            .arkforge_state(source_id)
            .map_err(|e| e.to_string())?
        else {
            return Err("source has no durable ArkForge Job correlation".into());
        };
        if request.expected_binding_revision != Some(execution.binding_revision) {
            return Err("maintenance source binding revision differs".into());
        }
        let (identity, binding) = self
            .reads
            .observe(&execution, Instant::now() + Duration::from_secs(30))?;
        let records = self.lane.maintenance_source(&execution)?;
        let source = m::Source {
            authority_namespace: "arkdeck".into(),
            profile: execution.artifact_profile_id.clone(),
            campaign: records.plan.authority_support_campaign.clone(),
            latest_job: records.job.job_id.clone(),
            job: records.job,
            plan: records.plan,
            receipts: records.receipts,
            identity,
            active_jobs: records.active_jobs,
        };
        let mut artifact = None;
        let mut artifact_facts = BTreeMap::new();
        let mut restoration = None;
        if request.reference() == "flash.restore-boot-loop@1" {
            let lease = request
                .inputs
                .get("artifactLease")
                .and_then(Value::as_str)
                .ok_or("restoration requires an Artifact lease")?;
            let owner = planner.artifacts.ok_or("Artifact store unavailable")?;
            let leased = planner.resolve_bound_lease(
                owner,
                lease,
                request,
                &crate::device_facts::DeviceFacts {
                    target_id: execution.target_id.clone(),
                    binding_revision: execution.binding_revision,
                    tool_version: "arkforged native RockUSB".into(),
                    tool_sha256: execution.toolchain_sha256.clone(),
                    connect_key: binding.connect_key.clone(),
                    identity: execution.stable_identity_sha256.clone(),
                },
            )?;
            if !owner.payload_matches(&leased) {
                return Err("restoration Artifact digest changed".into());
            }
            let sha256 = leased.row["sha256"]
                .as_str()
                .ok_or("Artifact digest missing")?
                .to_owned();
            artifact_facts = BTreeMap::from([
                ("artifactId".into(), leased.artifact_id),
                ("artifactSha256".into(), sha256.clone()),
                (
                    "artifactByteCount".into(),
                    leased.row["byteCount"]
                        .as_u64()
                        .ok_or("Artifact length missing")?
                        .to_string(),
                ),
            ]);
            let input = LaneArtifact {
                path: leased.path,
                sha256,
                profile_id: source.profile.clone(),
            };
            let key = sha256_hex(&serde_json::to_vec(&json!({"requestId":request.request_id,"idempotencyKey":request.idempotency_key,"inputs":request.inputs,"target":request.target_id,"sourcePlan":source.plan.plan_sha256,"identity":execution.stable_identity_sha256})).map_err(|e| e.to_string())?);
            let mut plans = self
                .plans
                .lock()
                .map_err(|_| "maintenance plan lock unavailable")?;
            if !plans.contains_key(&key) {
                if plans.len() >= 1024 {
                    return Err("maintenance plan capacity reached".into());
                }
                plans.insert(key.clone(), self.lane.restoration_plan(&input, &binding)?);
            }
            let plan = plans[&key].clone();
            let now = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map_err(|_| "runtime clock unavailable")?
                .as_millis();
            if u128::from(plan.expires_at_epoch_ms) <= now {
                return Err("restoration plan expired; no dispatch".into());
            }
            restoration = Some(plan);
            artifact = Some(input);
        }
        let document = json!({
            "operation": request.reference(), "catalogDigest": arkdeck_contract::CATALOG_DIGEST,
            "inputs": request.inputs, "target": request.target_id, "bindingRevision": execution.binding_revision,
            "identity": execution.stable_identity_sha256, "toolchain": execution.toolchain_sha256,
            "sourceJob": source_id, "sourcePlan": source.plan.plan_sha256, "artifactFacts": artifact_facts,
            "restorationPlan": restoration.as_ref().map(m::ExecutablePlan::encode),
        });
        let digest =
            sha256_hex(&crate::session_json::encode(&document).map_err(|e| format!("{e:?}"))?);
        Ok(Prepared {
            source,
            execution,
            binding,
            restoration,
            artifact,
            artifact_facts,
            digest,
        })
    }
}

pub(crate) fn context(planning: &FlashPlanning) -> Result<Arc<MaintenanceContext>, String> {
    planning
        .maintenance
        .lock()
        .map_err(|_| "maintenance context unavailable")?
        .clone()
        .ok_or_else(|| "maintenance Runtime ports are unavailable".into())
}
pub(crate) fn materialize<'a>(
    planner: &FlashPlanner<'_>,
    flash: &FlashPlanning,
    request: &OperationRequest,
    _descriptor: &CatalogOperation,
) -> Result<(Materialized<'a>, Option<String>), PlanRefusal> {
    let prepared = context(flash)
        .and_then(|c| c.prepare(request, &planner.planner))
        .map_err(|message| PlanRefusal {
            code: "invalidInput",
            message,
            swift: None,
        })?;
    Ok((
        Materialized {
            _import_use: None,
            _workspace_use: None,
            digest: prepared.digest,
            artifact_facts: prepared.artifact_facts,
            identity: Some(prepared.execution.stable_identity_sha256),
            binding_revision: Some(prepared.execution.binding_revision),
            recommission: None,
            recommission_retry_program_sha256: None,
        },
        None,
    ))
}
