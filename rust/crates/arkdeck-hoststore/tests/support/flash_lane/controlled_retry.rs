//! Synthetic Provider plans and independent reads; never hardware evidence.
use super::*;
use arkdeck_hoststore::MaintenanceReads;
use arkdeck_provider_arkforge::maintenance as m;
use arkdeck_provider_hdc::PrebootHash;
use std::time::Instant;

pub const ORIGINAL_RAMDISK: &str =
    "bdd1f4eacbe545f5a553b529980bc487723d37554148058dd551c241abf86de4";

#[derive(Clone)]
pub struct Plans {
    pub primary: m::ExecutablePlan,
    pub restoration: m::ExecutablePlan,
}

/// Uses the reviewed full-recovery receipt fixture shape, with the real closed
/// ramdisk/userdata ranges but explicitly synthetic bytes for every image.
pub fn plans() -> Plans {
    let execution = Execution {
        arkdeck_job_id: "synthetic".into(),
        daemon_job_id: "JOB-FLASH-3".into(),
        plan_id: "PLAN-CONTROLLED-PRIMARY".into(),
        plan_sha256: "1".repeat(64),
        execution_purpose: "supersedingRecovery".into(),
        artifact_sha256: "a".repeat(64),
        artifact_profile_id: "org.openharmony.dayu200@1.0.0".into(),
        target_id: "synthetic".into(),
        binding_revision: 1,
        stable_identity_sha256: "b".repeat(64),
        usb_topology: "42".into(),
        observation_mode: "loader".into(),
        toolchain_sha256: TOOLCHAIN.into(),
    };
    let mut primary = recovery_completion::source(&execution, "ok").unwrap().plan;
    primary.expires_at_epoch_ms = u64::MAX;
    for effect in &mut primary.persistent_effects {
        if effect.target == "ramdisk" {
            effect.range_start = 121_634_816;
            effect.range_length = 4_194_304;
        }
        if effect.target == "userdata" {
            effect.range_start = 10_217_324_544;
            effect.range_length = 1_468_006_400;
        }
    }
    let mut restoration = primary.clone();
    restoration.plan_id = "PLAN-CONTROLLED-RESTORATION".into();
    restoration.plan_sha256 = "2".repeat(64);
    restoration.execution_purpose = "primaryFlash".into();
    restoration
        .persistent_effects
        .retain(|effect| effect.target == "ramdisk");
    restoration.persistent_effects[0].content_sha256 = ORIGINAL_RAMDISK.into();
    restoration.public_steps.retain(|step| {
        step.semantic_target == "partition:ramdisk"
            || matches!(step.kind.as_str(), "reboot" | "postflightProbe")
    });
    for step in &mut restoration.public_steps {
        if step.semantic_target == "partition:ramdisk" {
            step.content_sha256 = ORIGINAL_RAMDISK.into();
        }
    }
    Plans {
        primary,
        restoration,
    }
}

impl Fakes {
    pub fn controlled_retry(&self, plans: Plans) {
        self.shared().retry = Some(plans);
    }
}

pub(super) fn source(fakes: &Fakes, execution: &Execution) -> Result<m::SourceRecords, String> {
    let plans = fakes
        .shared()
        .retry
        .clone()
        .ok_or("synthetic retry plans missing")?;
    let mut source = recovery_completion::source(execution, "ok")?;
    let plan = if execution.plan_id == plans.primary.plan_id {
        plans.primary
    } else {
        plans.restoration
    };
    source.receipts.retain(|receipt| {
        plan.public_steps
            .iter()
            .any(|step| step.step_id == receipt.step_id)
    });
    for receipt in &mut source.receipts {
        let step = plan
            .public_steps
            .iter()
            .find(|step| step.step_id == receipt.step_id)
            .unwrap();
        if step.kind == "verifyTarget" {
            let effect = plan
                .persistent_effects
                .iter()
                .find(|effect| step.semantic_target == format!("partition:{}", effect.target))
                .unwrap();
            receipt.verified_range_start = effect.range_start;
            receipt.verified_range_length = effect.range_length;
            receipt.evidence_sha256 = (0..32)
                .map(|index| {
                    u8::from_str_radix(&effect.content_sha256[index * 2..index * 2 + 2], 16)
                        .unwrap()
                })
                .collect();
            if !matches!(effect.target.as_str(), "uboot" | "resource") {
                receipt.verification_outcome = "typedSkip".into();
                receipt.verification_strength.clear();
                receipt.typed_skip_reason = "skipped-lba-read-window".into();
            }
        }
    }
    if fakes.current().perform == "retrySourceWrite" {
        source.receipts[0].disposition = "confirmedPartialEffect".into();
    }
    source.job.total_steps = plan.public_steps.len() as u64;
    source.job.completed_steps = source.job.total_steps;
    source.plan = plan;
    Ok(source)
}

impl MaintenanceReads for Fakes {
    fn recommission_facts(
        &self,
        target: &str,
        _deadline: Instant,
    ) -> Result<RockchipFacts, String> {
        Fakes::recommission_facts(self, target)
    }

    fn recommission_read(
        &self,
        _key: &str,
        effect: &m::Effect,
        nonce: Option<&str>,
        _deadline: Instant,
    ) -> Result<(String, Option<PrebootHash>), String> {
        self.lane(format!(
            "readback {} {}",
            effect.target, effect.content_sha256
        ));
        let fault = self.current().perform;
        if fault == "retryMissingPreboot" && nonce.is_some() {
            return Err("synthetic preboot report absent".into());
        }
        if fault == "retryRestoreRead" && effect.content_sha256 == ORIGINAL_RAMDISK {
            return Err("synthetic full restoration read unavailable".into());
        }
        if fault == "retryIdentityDrift" && nonce.is_some() {
            self.shared().script.cross_mode = "cpuDrift".into();
        }
        let hash = if fault == "retryWrongHash" && nonce.is_some() {
            "0".repeat(64)
        } else {
            effect.content_sha256.clone()
        };
        Ok((
            hash.clone(),
            nonce.map(|_| PrebootHash {
                digest: hash,
                boot_id_sha256: "3".repeat(64),
                storage_cid_sha256: "4".repeat(64),
            }),
        ))
    }

    fn observe(
        &self,
        _execution: &Execution,
        _deadline: Instant,
    ) -> Result<(m::Identity, DeviceBinding), String> {
        Err("ordinary maintenance is outside this synthetic scenario".into())
    }

    fn read(
        &self,
        _execution: &Execution,
        _target: &m::Effect,
        _deadline: Instant,
    ) -> Result<m::ReadOutcome, String> {
        Err("ordinary maintenance is outside this synthetic scenario".into())
    }
}
