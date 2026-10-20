//! Flash maintenance through the Windows CLI (TASK-XPA-010): `flash verify`
//! and `flash restore-boot-loop`, by the real `arkdeck` CLI against a signed
//! copy of this binary serving the production control transport on a private
//! named pipe, after a `flash run` of the oracle's full restore.
//!
//! The Host is `flash_execution_control`'s Windows composition with the
//! daemon's maintenance context over the composed lane and Job owner. Its
//! device readbacks are [`FixtureReads`]: the production closed partition
//! metadata and hash reads over the in-process fake HDC, which answers from
//! the fixture board's partition table, beside a synthetic identity
//! observation, as Windows resolves a USB connector only from the host's own
//! device tree. The lane is the Swift oracle's fake ArkForge lane, with the
//! sealed source and restoration records the hoststore maintenance owner
//! tests use. No `arkforged`, device, USB host or installed Runtime is
//! reached; nothing here is device evidence.
use crate::flash_execution_control::{
    PARTITION_NAMES, Partition, Partitions, ScriptedHdc, execution_fakes,
};
use arkdeck_hoststore::{MaintenanceObservation, MaintenanceReads, RockchipFacts};
use arkdeck_provider_arkforge::{
    ActionReceipt, DeviceBinding, Execution, FlashLane, LaneArtifact, LaneFailure, PrewarmReceipt,
    Terminal, maintenance as m,
};
use serde_json::{Value, json};
use std::time::Instant;

const CAMPAIGN: &str = "synthetic-maintenance-cli";
const RESTORATION_PLAN: &str = "PLAN-MAINTENANCE-RESTORATION";

/// The original ramdisk the restoration writes, as its sealed plan names it.
fn restoration_plan() -> m::ExecutablePlan {
    let mut plan = m::ExecutablePlan {
        plan_id: RESTORATION_PLAN.into(),
        plan_sha256: "9".repeat(64),
        execution_purpose: "primaryFlash".into(),
        authority_support_campaign: CAMPAIGN.into(),
        mechanics_maturity_campaign: CAMPAIGN.into(),
        expires_at_epoch_ms: u64::MAX,
        persistent_effects: vec![m::Effect {
            kind: "writePartition".into(),
            target: "ramdisk".into(),
            range_start: m::RAMDISK_START,
            range_length: m::RAMDISK_BYTES,
            content_sha256: m::RESTORATION_SHA256.into(),
        }],
        ..Default::default()
    };
    for (index, kind) in [
        "probeDevice",
        "validateLayout",
        "writeTarget",
        "verifyTarget",
        "reboot",
        "postflightProbe",
    ]
    .into_iter()
    .enumerate()
    {
        let partition = matches!(kind, "writeTarget" | "verifyTarget");
        plan.public_steps.push(m::PublicStep {
            step_id: format!("MAINTENANCE-STEP-{index}"),
            kind: kind.into(),
            semantic_target: if partition {
                "partition:ramdisk"
            } else {
                "device"
            }
            .into(),
            content_sha256: if partition {
                m::RESTORATION_SHA256.into()
            } else {
                String::new()
            },
            ..Default::default()
        });
    }
    plan
}

/// The fake lane with the sealed maintenance records of its daemon jobs. Its
/// restoration write lays the original ramdisk on the fixture board.
pub(crate) struct MaintenanceLane {
    inner: execution_fakes::FakeLane,
    partitions: Partitions,
}

impl MaintenanceLane {
    pub(crate) fn new(fakes: &execution_fakes::Fakes, partitions: Partitions) -> Self {
        Self {
            inner: execution_fakes::FakeLane::new(fakes),
            partitions,
        }
    }
}

impl FlashLane for MaintenanceLane {
    fn toolchain_sha256(&self) -> &str {
        self.inner.toolchain_sha256()
    }
    fn prewarm(&self, job: &str, artifact: &LaneArtifact) -> Result<PrewarmReceipt, LaneFailure> {
        self.inner.prewarm(job, artifact)
    }
    fn finish_prewarm(&self, job: &str) {
        self.inner.finish_prewarm(job);
    }
    fn prepare(
        &self,
        job: &str,
        artifact: &LaneArtifact,
        binding: &DeviceBinding,
        purpose: &str,
    ) -> Result<Execution, LaneFailure> {
        self.inner.prepare(job, artifact, binding, purpose)
    }
    fn perform(
        &self,
        step: &str,
        execution: &Execution,
        artifact: &LaneArtifact,
        binding: &DeviceBinding,
    ) -> Result<ActionReceipt, LaneFailure> {
        self.inner.perform(step, execution, artifact, binding)
    }
    fn observe_terminal(&self, execution: &Execution) -> Result<Option<Terminal>, String> {
        self.inner.observe_terminal(execution)
    }
    fn completed_plan_receipt(&self, job: &str) -> Option<ActionReceipt> {
        self.inner.completed_plan_receipt(job)
    }
    fn maintenance_source(&self, execution: &Execution) -> Result<m::SourceRecords, String> {
        let mut source = self.inner.maintenance_source(execution)?;
        source.plan.authority_support_campaign = CAMPAIGN.into();
        source.plan.mechanics_maturity_campaign = CAMPAIGN.into();
        if execution.plan_id == RESTORATION_PLAN {
            source.plan = restoration_plan();
            source.receipts = source
                .plan
                .public_steps
                .iter()
                .map(|step| m::ActionReceiptSummary {
                    job_id: execution.daemon_job_id.clone(),
                    plan_id: execution.plan_id.clone(),
                    step_id: step.step_id.clone(),
                    attempt_id: "MAINTENANCE-ATTEMPT-1".into(),
                    permit_id: "MAINTENANCE-PERMIT-1".into(),
                    disposition: "semanticSuccess".into(),
                    evidence_sha256: vec![0xab; 32],
                    ..Default::default()
                })
                .collect();
            source.job.total_steps = source.plan.public_steps.len() as u64;
            source.job.completed_steps = source.job.total_steps;
        }
        Ok(source)
    }
    fn restoration_plan(
        &self,
        _artifact: &LaneArtifact,
        _binding: &DeviceBinding,
    ) -> Result<m::ExecutablePlan, String> {
        Ok(restoration_plan())
    }
    fn prepare_restoration(
        &self,
        job: &str,
        plan: &m::ExecutablePlan,
        artifact: &LaneArtifact,
        binding: &DeviceBinding,
    ) -> Result<Execution, LaneFailure> {
        self.inner.prepare_restoration(job, plan, artifact, binding)
    }
    fn perform_restoration(
        &self,
        execution: &Execution,
        artifact: &LaneArtifact,
        binding: &DeviceBinding,
        deadline: Instant,
    ) -> Result<ActionReceipt, LaneFailure> {
        let receipt = self
            .inner
            .perform_restoration(execution, artifact, binding, deadline)?;
        self.partitions.lock().unwrap().insert(
            "ramdisk".into(),
            Partition {
                start: m::RAMDISK_START,
                length: m::RAMDISK_BYTES,
                sha256: m::RESTORATION_SHA256.into(),
                writable: false,
            },
        );
        Ok(receipt)
    }
}

/// The fixture board's identity and partition readbacks: the identity the
/// source Job bound (no USB connector is resolved), its partitions through
/// the production closed reads over the fake HDC.
pub(crate) struct FixtureReads(ScriptedHdc);

impl FixtureReads {
    pub(crate) fn new(partitions: Partitions) -> Self {
        Self(ScriptedHdc::with_partitions(partitions))
    }
}

const CONNECT_KEY: &str = "150100424a544e4600";

fn identity(serial_sha256: &str, topology: &str) -> m::Identity {
    m::Identity {
        serial_sha256: serial_sha256.into(),
        topology_sha256: arkdeck_contract::sha256_hex(topology.as_bytes()),
        descriptor_sha256: "d".repeat(64),
    }
}

impl MaintenanceReads for FixtureReads {
    fn observe_flash_evidence(
        &self,
        facts: &RockchipFacts,
        _deadline: Instant,
    ) -> Result<MaintenanceObservation, String> {
        let topology = facts
            .server_facts
            .get("dayu200HDCNormalAliasUSBTopology")
            .ok_or("flash evidence has no bound Normal topology")?;
        Ok(MaintenanceObservation {
            identity: identity(&facts.identity_sha256, topology),
            binding: DeviceBinding {
                target_id: facts.target_id.clone(),
                binding_revision: facts.binding_revision,
                stable_identity_sha256: facts.identity_sha256.clone(),
                connect_key: facts.execution_connect_key.clone(),
                usb_topology: topology.clone(),
                loader_first_connector_sha256: None,
                recommission: None,
            },
            model: "DAYU200".into(),
            firmware: "OpenHarmony-7.0.0.35-20260728_180253".into(),
        })
    }
    fn observe_evidence(
        &self,
        execution: &Execution,
        deadline: Instant,
    ) -> Result<MaintenanceObservation, String> {
        let (identity, binding) = self.observe(execution, deadline)?;
        Ok(MaintenanceObservation {
            identity,
            binding,
            model: "DAYU200".into(),
            firmware: "OpenHarmony-7.0.0.35-20260728_180253".into(),
        })
    }
    fn observe(
        &self,
        execution: &Execution,
        _deadline: Instant,
    ) -> Result<(m::Identity, DeviceBinding), String> {
        Ok((
            identity(&execution.stable_identity_sha256, &execution.usb_topology),
            DeviceBinding {
                target_id: execution.target_id.clone(),
                binding_revision: execution.binding_revision,
                stable_identity_sha256: execution.stable_identity_sha256.clone(),
                connect_key: CONNECT_KEY.into(),
                usb_topology: execution.usb_topology.clone(),
                loader_first_connector_sha256: None,
                recommission: None,
            },
        ))
    }
    fn read(
        &self,
        execution: &Execution,
        effect: &m::Effect,
        deadline: Instant,
    ) -> Result<m::ReadOutcome, String> {
        let (_, binding) = self.observe(execution, deadline)?;
        let hash = arkdeck_provider_hdc::read_flash_partition(
            &self.0,
            &binding.connect_key,
            &arkdeck_provider_hdc::PartitionRange {
                target: effect.target.clone(),
                range_start: effect.range_start,
                range_length: effect.range_length,
            },
            deadline,
        )?;
        Ok(match hash {
            arkdeck_provider_hdc::PartitionHash::Full(hash) => m::ReadOutcome::FullHash(hash),
            arkdeck_provider_hdc::PartitionHash::MountedWritable => m::ReadOutcome::MountedWritable,
        })
    }
}

/// The fixture board after the fake lane's full restore: each partition of
/// its sealed source plan holds the content it wrote, and `userdata` is
/// mounted writable after boot, as on the real board.
pub(crate) fn flashed_board(partitions: &Partitions) {
    let mut table = partitions.lock().unwrap();
    for (index, name) in PARTITION_NAMES.into_iter().enumerate() {
        table.insert(
            name.into(),
            Partition {
                start: (index as u64 + 1) * 4096,
                length: 512,
                sha256: "ab".repeat(32),
                writable: name == "userdata",
            },
        );
    }
}

/// A complete typed maintenance request of `operation` over `source`, laid
/// out as the recorded full restore names its Target.
pub(crate) fn request(recorded: &Value, operation: &str, source: &str, label: &str) -> Value {
    let mut inputs = json!({"sourceJobId": source, "budgetMs": 600_000});
    if operation == "flash.restore-boot-loop" {
        inputs["artifactLease"] = recorded["inputs"]["artifactLease"].clone();
    }
    json!({
        "documentType": "runtime-operation-request",
        "schemaVersion": "1.0.0",
        "requestId": format!("maintenance-cli-{label}"),
        "idempotencyKey": format!("idem-maintenance-cli-{label}"),
        "target": recorded["target"],
        "operation": {"id": operation, "version": 1},
        "inputs": inputs,
        "requestedOutputs": ["derivedArtifacts"],
    })
}

/// The leaves this case drives, Windows `implemented` in the manifest this
/// CLI renders.
pub(crate) fn assert_measured(leaves: &[&str]) {
    let product = arkdeck_cli::machine_contracts::contract_products()
        .into_iter()
        .find(|product| product.relative_path == "cli-feature-coverage.json")
        .expect("the CLI renders its feature coverage");
    let coverage: Value = serde_json::from_slice(&product.bytes).unwrap();
    for leaf in leaves {
        let statuses: Vec<&Value> = coverage["entries"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|entry| entry["feature"] == *leaf)
            .map(|entry| &entry["implementationStatusByPlatform"]["windows"])
            .collect();
        assert!(
            !statuses.is_empty() && statuses.iter().all(|status| *status == "implemented"),
            "{leaf}: {statuses:?}"
        );
    }
}
