//! The one controlled retry is one pre-materialized program: full overwrite,
//! independent complete readback, original ramdisk restoration, then postflight.
//! Runtime owns every record here; request inputs contain references only.
use crate::artifact_read_owner::LeasedArtifact;
use crate::flash_facts::RockchipFacts;
use crate::flash_maintenance::MaintenanceContext;
use crate::job_owner::arkforge_job_state::{ArkForgeJobState, execution_value};
use crate::job_owner::flash_recommission::{Allocation, IdentityChain, OPERATION};
use crate::job_plan::JobPlanner;
use crate::operation_request::OperationRequest;
use arkdeck_contract::sha256_hex;
use arkdeck_platform::HostDirectory;
use arkdeck_provider_arkforge::{DeviceBinding, LaneArtifact, maintenance as m, preboot};
use arkdeck_provider_arkforge::{
    Execution, FlashLane, FullReadback, validate_recommission_readback,
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::BTreeSet;
use std::time::{Instant, SystemTime, UNIX_EPOCH};

const LIMIT: usize = 4 * 1024 * 1024;
const PROFILE: &str = "org.openharmony.dayu200@1.0.0";
const SCHEMA: &str = "arkdeck.recommission-retry-program/v1";

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct Program {
    schema: String,
    request_sha256: String,
    identity_chain: IdentityChain,
    primary_sha256: String,
    restoration_sha256: String,
    nonce: String,
    primary_plan: Vec<u8>,
    restoration_plan: Vec<u8>,
}

pub(crate) struct Prepared {
    pub(crate) program: Program,
    pub(crate) primary: m::ExecutablePlan,
    pub(crate) restoration: m::ExecutablePlan,
    pub(crate) restoration_artifact: LaneArtifact,
    pub(crate) restoration_lease: LeasedArtifact,
}

fn request_sha(request: &OperationRequest) -> String {
    let mut request = request.clone();
    request.capability_id = None;
    request.fingerprint()
}

impl Program {
    pub(crate) fn value(&self) -> Value {
        json!(self)
    }
    pub(crate) fn sha256(&self) -> String {
        sha256_hex(&serde_json::to_vec(self).expect("closed retry program fields"))
    }
    pub(crate) fn nonce(&self) -> &str {
        &self.nonce
    }

    pub(crate) fn plans(&self) -> Result<(m::ExecutablePlan, m::ExecutablePlan), String> {
        let primary = m::ExecutablePlan::decode(&self.primary_plan).map_err(|e| e.to_string())?;
        let restoration =
            m::ExecutablePlan::decode(&self.restoration_plan).map_err(|e| e.to_string())?;
        validate_plans(&primary, &restoration)?;
        if self.schema != SCHEMA
            || self.primary_sha256 == self.restoration_sha256
            || self.nonce.len() != 32
            || !self
                .nonce
                .bytes()
                .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
            || ![
                &self.request_sha256,
                &self.primary_sha256,
                &self.restoration_sha256,
            ]
            .iter()
            .all(|digest| crate::job_record::digest(digest))
        {
            return Err("recommission.retryProgramMalformed".into());
        }
        self.identity_chain.validate()?;
        Ok((primary, restoration))
    }

    pub(crate) fn require_allocation(
        &self,
        allocation: &Allocation,
        request: &OperationRequest,
    ) -> Result<(), String> {
        if allocation
            .controlled_retry
            .as_ref()
            .is_none_or(|retry| retry.program_sha256 != self.sha256())
            || self.request_sha256 != request_sha(request)
            || self.request_sha256 != allocation.request_fingerprint_sha256
            || self.identity_chain != allocation.identity_chain
            || self.primary_sha256 != allocation.artifact_sha256
        {
            return Err("recommission.retryProgramDoesNotMatchAllocation".into());
        }
        self.plans()?;
        Ok(())
    }
}

fn validate_plans(
    primary: &m::ExecutablePlan,
    restoration: &m::ExecutablePlan,
) -> Result<(), String> {
    let invalid = || "recommission.retryPlanCoverageIncomplete".to_owned();
    if primary.execution_purpose != "supersedingRecovery"
        || restoration.execution_purpose != "primaryFlash"
        || primary.plan_id == restoration.plan_id
        || [&primary.plan_sha256, &restoration.plan_sha256]
            .iter()
            .any(|hash| !crate::job_record::digest(hash))
    {
        return Err(invalid());
    }
    let targets: BTreeSet<_> = primary
        .persistent_effects
        .iter()
        .map(|effect| effect.target.as_str())
        .collect();
    if targets != crate::job_plan::DAYU200_PARTITIONS.into_iter().collect()
        || primary.persistent_effects.len() != 9
        || restoration.persistent_effects.len() != 1
    {
        return Err(invalid());
    }
    let restored = &restoration.persistent_effects[0];
    if restored.kind != "writePartition"
        || restored.target != "ramdisk"
        || restored.range_start != 121_634_816
        || restored.range_length != preboot::MAX_IMAGE_BYTES as u64
        || restored.content_sha256 != preboot::RESTORATION_SHA256
    {
        return Err(invalid());
    }
    for plan in [primary, restoration] {
        for effect in &plan.persistent_effects {
            if effect.kind != "writePartition"
                || !crate::job_record::digest(&effect.content_sha256)
                || effect.range_length == 0
                || !effect.range_start.is_multiple_of(512)
                || effect
                    .range_start
                    .checked_add(effect.range_length)
                    .is_none()
                || ["writeTarget", "verifyTarget"].into_iter().any(|kind| {
                    plan.public_steps
                        .iter()
                        .filter(|step| {
                            step.kind == kind
                                && step.semantic_target == format!("partition:{}", effect.target)
                                && step.content_sha256 == effect.content_sha256
                        })
                        .count()
                        != 1
                })
            {
                return Err(invalid());
            }
        }
    }
    let ramdisk = primary
        .persistent_effects
        .iter()
        .find(|effect| effect.target == "ramdisk")
        .ok_or_else(invalid)?;
    let userdata = primary
        .persistent_effects
        .iter()
        .find(|effect| effect.target == "userdata")
        .ok_or_else(invalid)?;
    if ramdisk.range_start != restored.range_start
        || ramdisk.range_length != restored.range_length
        || userdata.range_start != preboot::USERDATA_START
        || userdata.range_length != preboot::USERDATA_BYTES
    {
        return Err(invalid());
    }
    Ok(())
}

fn bundle(leased: &LeasedArtifact) -> Result<crate::flash_archive::Summary, String> {
    let mut file =
        std::fs::File::open(&leased.path).map_err(|_| "recommission.retryArtifactUnavailable")?;
    let summary =
        crate::flash_archive::summarize_preboot(&mut file, &leased.path.to_string_lossy())
            .map_err(|e| e.swift())?;
    if leased.row["sha256"] != summary.archive_sha256
        || leased.row["byteCount"] != summary.archive_size
    {
        return Err("recommission.retryArtifactChanged".into());
    }
    crate::flash_archive::for_build(
        &crate::flash_archive::describe(&summary).map_err(|e| e.swift())?,
    )?;
    Ok(summary)
}

fn require_bundle_pair(
    primary: &crate::flash_archive::Summary,
    restoration: &crate::flash_archive::Summary,
) -> Result<String, String> {
    let ramdisk = primary
        .captured
        .get("ramdisk.img")
        .ok_or("recommission.prebootImageMissing")?;
    let nonce = preboot::inspect(ramdisk).map_err(str::to_owned)?;
    let restored = restoration
        .captured
        .get("ramdisk.img")
        .ok_or("recommission.originalRamdiskMissing")?;
    if restored.len() != preboot::MAX_IMAGE_BYTES
        || sha256_hex(restored) != preboot::RESTORATION_SHA256
        || primary.members.len() != restoration.members.len()
        || primary.members.iter().any(|member| {
            restoration
                .members
                .iter()
                .find(|other| member.name == other.name)
                .is_none_or(|other| {
                    member.name != "ramdisk.img"
                        && (member.sha256 != other.sha256 || member.size != other.size)
                })
        })
    {
        return Err("recommission.restorationBundleDoesNotPreserveOriginalImages".into());
    }
    Ok(nonce)
}

pub(crate) fn prepare(
    context: &MaintenanceContext,
    planner: &JobPlanner<'_>,
    request: &OperationRequest,
    facts: &RockchipFacts,
    primary_lease: &LeasedArtifact,
) -> Result<Prepared, String> {
    if request.reference() != OPERATION
        || request
            .inputs
            .get("failedRecommissionJobId")
            .and_then(Value::as_str)
            .is_none()
    {
        return Err("recommission.explicitControlledRetryRequired".into());
    }
    let chain = IdentityChain::from_facts(facts)?;
    let lease = request
        .inputs
        .get("restorationArtifactLease")
        .and_then(Value::as_str)
        .ok_or("recommission.originalRestorationLeaseRequired")?;
    let owner = planner
        .artifacts
        .ok_or("recommission.artifactStoreUnavailable")?;
    let restoration_lease = planner.resolve_bound_lease(
        owner,
        lease,
        request,
        &crate::device_facts::DeviceFacts {
            target_id: facts.target_id.clone(),
            binding_revision: facts.binding_revision,
            tool_version: "arkforged native RockUSB".into(),
            tool_sha256: facts.tool_sha256.clone(),
            connect_key: facts.execution_connect_key.clone(),
            identity: facts.identity_sha256.clone(),
        },
    )?;
    if !owner.payload_matches(primary_lease) || !owner.payload_matches(&restoration_lease) {
        return Err("recommission.immutableArtifactChanged".into());
    }
    let artifact = |leased: &LeasedArtifact| -> Result<LaneArtifact, String> {
        Ok(LaneArtifact {
            path: leased.path.clone(),
            sha256: leased.row["sha256"]
                .as_str()
                .ok_or("recommission.artifactDigestMissing")?
                .into(),
            profile_id: PROFILE.into(),
        })
    };
    let primary_artifact = artifact(primary_lease)?;
    let restoration_artifact = artifact(&restoration_lease)?;
    let key = request_sha(request);
    // The Runtime parent and Job store are distinct in production. Use the
    // same owner-held directory that completion and reconciliation read.
    let root = context.jobs.controlled_retry_program_root()?;
    let _lock = root
        .lock_document(".programs.lock")
        .map_err(|_| "recommission.retryProgramBusy")?;
    let name = format!("{key}.json");
    let program = if let Some(bytes) = root
        .read_owner_only(&name, LIMIT)
        .map_err(|_| "recommission.retryProgramUnreadable")?
    {
        serde_json::from_slice::<Program>(&bytes)
            .map_err(|_| "recommission.retryProgramMalformed")?
    } else {
        let primary = bundle(primary_lease)?;
        let original = bundle(&restoration_lease)?;
        let nonce = require_bundle_pair(&primary, &original)?;
        let binding = DeviceBinding {
            target_id: chain.target_id.clone(),
            binding_revision: chain.binding_revision,
            stable_identity_sha256: chain.loader_serial_sha256.clone(),
            connect_key: facts.execution_connect_key.clone(),
            usb_topology: chain.usb_topology.clone(),
            loader_first_connector_sha256: None,
            recommission: None,
        };
        let primary_plan = context
            .lane
            .recommission_plan(&primary_artifact, &binding)?;
        let restoration_plan = context
            .lane
            .restoration_plan(&restoration_artifact, &binding)?;
        validate_plans(&primary_plan, &restoration_plan)?;
        if primary_plan.persistent_effects.iter().any(|effect| {
            primary
                .members
                .iter()
                .find(|member| member.name == format!("{}.img", effect.target))
                .is_none_or(|member| {
                    member.sha256 != effect.content_sha256
                        || u64::try_from(member.size).ok() != Some(effect.range_length)
                })
        }) {
            return Err("recommission.sealedPlanDiffersFromImmutableBundle".into());
        }
        let program = Program {
            schema: SCHEMA.into(),
            request_sha256: key.clone(),
            identity_chain: chain.clone(),
            primary_sha256: primary_artifact.sha256.clone(),
            restoration_sha256: restoration_artifact.sha256.clone(),
            nonce,
            primary_plan: primary_plan.encode(),
            restoration_plan: restoration_plan.encode(),
        };
        let bytes =
            serde_json::to_vec(&program).map_err(|_| "recommission.retryProgramEncodingFailed")?;
        root.publish_document(&name, &bytes, LIMIT)
            .map_err(|_| "recommission.retryProgramPersistenceFailed")?;
        program
    };
    if program.request_sha256 != key
        || program.identity_chain != chain
        || program.primary_sha256 != primary_artifact.sha256
        || program.restoration_sha256 != restoration_artifact.sha256
    {
        return Err("recommission.retryProgramDrifted".into());
    }
    let (primary, restoration) = program.plans()?;
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| "recommission.clockUnavailable")?
        .as_millis();
    if [&primary, &restoration]
        .iter()
        .any(|plan| now >= u128::from(plan.expires_at_epoch_ms))
    {
        return Err("recommission.sealedRetryPlanExpired".into());
    }
    Ok(Prepared {
        program,
        primary,
        restoration,
        restoration_artifact,
        restoration_lease,
    })
}

pub(crate) fn load(
    jobs: &crate::JobStore,
    request: &OperationRequest,
    allocation: &Allocation,
) -> Result<Program, String> {
    let root = jobs.controlled_retry_program_root()?;
    let bytes = root
        .read_owner_only(&format!("{}.json", request_sha(request)), LIMIT)
        .map_err(|_| "recommission.retryProgramUnreadable")?
        .ok_or("recommission.retryProgramMissing")?;
    let program: Program =
        serde_json::from_slice(&bytes).map_err(|_| "recommission.retryProgramMalformed")?;
    program.require_allocation(allocation, request)?;
    Ok(program)
}

pub(crate) fn observe(
    context: &MaintenanceContext,
    allocation: &Allocation,
    deadline: Instant,
) -> Result<RockchipFacts, String> {
    if Instant::now() >= deadline {
        return Err("recommission.independentBudgetExpired".into());
    }
    let facts = context
        .reads
        .recommission_facts(&allocation.identity_chain.target_id, deadline)?;
    if !IdentityChain::from_facts(&facts)?.same_identity_as(&allocation.identity_chain)
        || Instant::now() >= deadline
    {
        return Err("recommission.retryIdentityOrBudgetDrifted".into());
    }
    Ok(facts)
}

pub(crate) const PROOF: &str = "recommission-full-readback.json";

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct Measurement {
    pub(crate) target: String,
    pub(crate) range_start: u64,
    pub(crate) range_length: u64,
    pub(crate) sha256: String,
}
impl Measurement {
    pub(crate) fn readback(&self) -> FullReadback {
        FullReadback {
            target: self.target.clone(),
            range_start: self.range_start,
            range_length: self.range_length,
            sha256: self.sha256.clone(),
        }
    }
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct PrebootProof {
    pub(crate) nonce: String,
    pub(crate) boot_id_sha256: String,
    pub(crate) storage_cid_sha256: String,
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct Proof {
    pub(crate) schema: String,
    pub(crate) program_sha256: String,
    pub(crate) allocation_sha256: String,
    pub(crate) primary_execution: Value,
    pub(crate) primary_reads: Vec<Measurement>,
    pub(crate) preboot: PrebootProof,
    pub(crate) restoration_state: Value,
    pub(crate) restoration_read: Measurement,
    pub(crate) completed_at_epoch_ms: u64,
}

pub(crate) fn write_once(
    jobs: &crate::JobStore,
    job: &str,
    name: &str,
    value: &Value,
) -> Result<(), String> {
    let path = jobs
        .job_directory(job)
        .map_err(|_| "recommission.retryJobUnavailable")?;
    let root = HostDirectory::open(&path).map_err(|_| "recommission.retryJobUnavailable")?;
    let _guard = root
        .lock_document(".recommission-retry.lock")
        .map_err(|_| "recommission.retryRecordBusy")?;
    if root
        .read_owner_only(name, LIMIT)
        .map_err(|_| "recommission.retryRecordUnreadable")?
        .is_some()
    {
        return Err("recommission.retryPhaseCannotReplay".into());
    }
    let bytes = serde_json::to_vec(value).map_err(|_| "recommission.retryRecordEncodingFailed")?;
    root.publish_document(name, &bytes, LIMIT)
        .map_err(|_| "recommission.retryRecordPersistenceFailed".into())
}

fn restoration_identity(
    intent: &Value,
    mut expected: Value,
    admitted: &IdentityChain,
) -> Result<IdentityChain, String> {
    admitted.validate()?;
    // Older durable intents could only use the exact admission attachment.
    // They remain readable, but cannot authorize a different restoration route.
    if intent == &expected {
        return Ok(admitted.clone());
    }
    let chain: IdentityChain = serde_json::from_value(intent["identityChain"].clone())
        .map_err(|_| "recommission.restorationIdentityMissing")?;
    let observation = intent["identityObservationSHA256"]
        .as_str()
        .filter(|value| crate::job_record::digest(value))
        .ok_or("recommission.restorationIdentityObservationMissing")?;
    expected["schema"] = json!("arkdeck.recommission-restoration-intent/v2");
    expected["identityChain"] = json!(chain);
    expected["identityObservationSHA256"] = json!(observation);
    if intent != &expected || !chain.same_identity_as(admitted) {
        return Err("recommission.restorationIdentityDrifted".into());
    }
    Ok(chain)
}

pub(crate) fn require_proof(
    jobs: &crate::JobStore,
    record: &crate::job_record::JobRecord,
    execution: &Execution,
    lane: &dyn FlashLane,
) -> Result<Value, String> {
    let allocation = record
        .admission_evidence()
        .and_then(crate::job_owner::flash_recovery::RecoveryContext::from_evidence)
        .and_then(|context| context.recommission)
        .ok_or("recommission.retryAllocationMissing")?;
    let request = OperationRequest::decode(
        &serde_json::to_vec(&record.request).map_err(|_| "recommission.retryRequestMalformed")?,
    )
    .map_err(|_| "recommission.retryRequestMalformed")?;
    let program = load(jobs, &request, &allocation)?;
    let (primary_plan, restoration_plan) = program.plans()?;
    let path = jobs
        .job_directory(&record.job_id)
        .map_err(|_| "recommission.retryJobUnavailable")?;
    let root = HostDirectory::open(&path).map_err(|_| "recommission.retryJobUnavailable")?;
    let bytes = root
        .read_owner_only(PROOF, LIMIT)
        .map_err(|_| "recommission.fullRetryReadbackMissing")?
        .ok_or("recommission.fullRetryReadbackMissing")?;
    let proof: Proof =
        serde_json::from_slice(&bytes).map_err(|_| "recommission.fullRetryReadbackMalformed")?;
    let phase = |name: &str| -> Result<Value, String> {
        let bytes = root
            .read_owner_only(name, LIMIT)
            .map_err(|_| "recommission.retryPhaseUnreadable")?
            .ok_or("recommission.retryPhaseMissing")?;
        serde_json::from_slice(&bytes).map_err(|_| "recommission.retryPhaseMalformed".into())
    };
    let restoration_chain = restoration_identity(
        &phase("recommission-restoration-intent.json")?,
        json!({
            "schema": "arkdeck.recommission-restoration-intent/v1", "childId": format!("{}-restore", record.job_id),
            "allocationSHA256": allocation.sha256(), "programSHA256": program.sha256(),
            "planSHA256": restoration_plan.plan_sha256, "artifactSHA256": program.restoration_sha256,
        }),
        &allocation.identity_chain,
    )?;
    if phase("recommission-primary-readback.json")?
        != json!({
            "schema": "arkdeck.recommission-primary-readback/v1", "programSHA256": program.sha256(),
            "execution": execution_value(execution), "measurements": proof.primary_reads, "preboot": proof.preboot,
        })
        || phase("recommission-restoration-completion.json")? != proof.restoration_state
    {
        return Err("recommission.retryPhaseDrifted".into());
    }
    if proof.schema != "arkdeck.recommission-full-readback/v1"
        || proof.program_sha256 != program.sha256()
        || proof.allocation_sha256 != allocation.sha256()
        || proof.primary_execution != execution_value(execution)
        || proof.preboot.nonce != program.nonce
        || !crate::job_record::digest(&proof.preboot.boot_id_sha256)
        || !crate::job_record::digest(&proof.preboot.storage_cid_sha256)
        || proof.completed_at_epoch_ms < allocation.reserved_at_epoch_ms
        || proof.completed_at_epoch_ms >= allocation.expires_at_epoch_ms
    {
        return Err("recommission.fullRetryReadbackDrifted".into());
    }
    let primary = lane.maintenance_source(execution)?;
    if primary.plan != primary_plan {
        return Err("recommission.primaryPlanDrifted".into());
    }
    validate_recommission_readback(
        execution,
        &primary,
        &proof
            .primary_reads
            .iter()
            .map(Measurement::readback)
            .collect::<Vec<_>>(),
        false,
    )?;
    let restored = ArkForgeJobState::from_value(&proof.restoration_state)
        .ok_or("recommission.restorationProofMalformed")?;
    let restored_execution = restored
        .execution
        .as_ref()
        .ok_or("recommission.restorationCorrelationMissing")?;
    if phase("recommission-restoration-execution.json")?
        != (ArkForgeJobState {
            execution: Some(restored_execution.clone()),
            completion: None,
        })
        .value()
    {
        return Err("recommission.restorationIntentDrifted".into());
    }
    let chain = &allocation.identity_chain;
    if restored_execution.arkdeck_job_id != format!("{}-restore", record.job_id)
        || restored_execution.artifact_sha256 != program.restoration_sha256
        || restored_execution.target_id != chain.target_id
        || restored_execution.binding_revision != chain.binding_revision
        || restored_execution.stable_identity_sha256 != chain.loader_serial_sha256
        || restored_execution.usb_topology != restoration_chain.usb_topology
        || restored_execution.toolchain_sha256 != execution.toolchain_sha256
        || restored_execution.toolchain_sha256 != lane.toolchain_sha256()
        || restored.completion.as_ref().is_none_or(|receipt| {
            !arkdeck_provider_arkforge::validate_completion(receipt, Some(restored_execution))
        })
    {
        return Err("recommission.restorationProofDrifted".into());
    }
    let restoration = lane.maintenance_source(restored_execution)?;
    if restoration.plan != restoration_plan {
        return Err("recommission.restorationPlanDrifted".into());
    }
    validate_recommission_readback(
        restored_execution,
        &restoration,
        &[proof.restoration_read.readback()],
        true,
    )?;
    Ok(json!(proof))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn restoration_keeps_legacy_routes_and_requires_full_proof_for_new_attachments() {
        let admitted = IdentityChain {
            target_id: "TGT-synthetic".into(),
            binding_revision: 1,
            normal_identity_sha256: "1".repeat(64),
            hardware_serial_sha256: "2".repeat(64),
            loader_serial_sha256: "3".repeat(64),
            connector_sha256: "4".repeat(64),
            usb_topology: "42".into(),
            provider_sha256: "5".repeat(64),
            binding_snapshot_sha256: "6".repeat(64),
        };
        let old = json!({
            "schema":"arkdeck.recommission-restoration-intent/v1", "childId":"job-synthetic-restore",
            "allocationSHA256":"a".repeat(64), "programSHA256":"b".repeat(64),
            "planSHA256":"c".repeat(64), "artifactSHA256":"d".repeat(64),
        });
        assert_eq!(
            restoration_identity(&old, old.clone(), &admitted).unwrap(),
            admitted
        );
        let mut fresh = admitted.clone();
        fresh.usb_topology = "84".into();
        let mut new = old.clone();
        new["schema"] = json!("arkdeck.recommission-restoration-intent/v2");
        new["identityChain"] = json!(fresh);
        new["identityObservationSHA256"] = json!("e".repeat(64));
        assert_eq!(
            restoration_identity(&new, old.clone(), &admitted).unwrap(),
            fresh
        );
        for field in [
            "identityChain",
            "identityObservationSHA256",
            "allocationSHA256",
            "programSHA256",
            "planSHA256",
            "artifactSHA256",
        ] {
            let mut missing = new.clone();
            missing.as_object_mut().unwrap().remove(field);
            assert!(
                restoration_identity(&missing, old.clone(), &admitted).is_err(),
                "{field}"
            );
        }
        for field in [
            "hardwareSerialSha256",
            "normalIdentitySha256",
            "loaderSerialSha256",
            "connectorSha256",
            "providerSha256",
            "bindingSnapshotSha256",
        ] {
            let mut changed = new.clone();
            changed["identityChain"][field] = json!("0".repeat(64));
            assert!(
                restoration_identity(&changed, old.clone(), &admitted).is_err(),
                "{field}"
            );
        }
        new["schema"] = old["schema"].clone();
        assert!(restoration_identity(&new, old.clone(), &admitted).is_err());
        let mut changed = old.clone();
        changed["childId"] = json!("job-other-restore");
        assert!(restoration_identity(&changed, old, &admitted).is_err());
    }
}
