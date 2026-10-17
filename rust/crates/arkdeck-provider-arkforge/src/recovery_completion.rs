//! Complete-overwrite proof from the Provider's sealed plan and durable receipts.
//! A successful postflight or a typed skip is not proof of full partition readback.
use crate::maintenance::SourceRecords;
use crate::{Execution, validate_completion};
use arkforge_core::Sha256Digest;
use std::collections::BTreeSet;

const TARGETS: [&str; 9] = [
    "uboot",
    "resource",
    "boot_linux",
    "ramdisk",
    "system",
    "vendor",
    "updater",
    "chip_ckm",
    "userdata",
];

pub(crate) fn validate(execution: &Execution, source: &SourceRecords) -> Result<(), String> {
    let refused = || {
        "flash.recoveryFullReadbackMissing: sealed plan and all partition receipts must prove complete write/readback/reboot/postflight".to_owned()
    };
    let plan = &source.plan;
    let job = &source.job;
    let digest = Sha256Digest::parse_hex(&execution.plan_sha256).map_err(|_| refused())?;
    if execution.execution_purpose != "supersedingRecovery"
        || execution.artifact_profile_id != "org.openharmony.dayu200@1.0.0"
        || plan.execution_purpose != execution.execution_purpose
        || plan.plan_id != execution.plan_id
        || plan.plan_sha256 != execution.plan_sha256
        || job.job_id != execution.daemon_job_id
        || job.plan_id != plan.plan_id
        || job.plan_sha256 != digest.as_bytes()
        || job.state != "succeeded"
        || !job.terminal
        || job.completed_steps != job.total_steps
        || job.total_steps != plan.public_steps.len() as u64
        || source.receipts.len() != plan.public_steps.len()
        || plan.public_steps.len() < 2
        || plan.public_steps[plan.public_steps.len() - 2].kind != "reboot"
        || plan
            .public_steps
            .last()
            .is_none_or(|step| step.kind != "postflightProbe")
    {
        return Err(refused());
    }
    let mut steps = BTreeSet::new();
    for step in &plan.public_steps {
        if !steps.insert(&step.step_id) {
            return Err(refused());
        }
        let receipts: Vec<_> = source
            .receipts
            .iter()
            .filter(|receipt| receipt.step_id == step.step_id)
            .collect();
        let [receipt] = receipts.as_slice() else {
            return Err(refused());
        };
        if receipt.job_id != job.job_id
            || receipt.plan_id != plan.plan_id
            || receipt.disposition != "semanticSuccess"
            || !receipt.failure_classification.is_empty()
            || !receipt.typed_skip_reason.is_empty()
            || !matches!(receipt.verification_outcome.as_str(), "" | "verified")
            || receipt.receipt_digest().is_err()
        {
            return Err(refused());
        }
        if step.kind == "postflightProbe"
            && !validate_completion(&crate::lane_host::action_receipt(receipt), Some(execution))
        {
            return Err(refused());
        }
    }
    let mut targets = BTreeSet::new();
    for effect in &plan.persistent_effects {
        let expected = Sha256Digest::parse_hex(&effect.content_sha256).map_err(|_| refused())?;
        if effect.kind != "writePartition"
            || !TARGETS.contains(&effect.target.as_str())
            || !targets.insert(effect.target.as_str())
            || effect.range_length == 0
            || !effect.range_start.is_multiple_of(512)
            || effect
                .range_start
                .checked_add(effect.range_length)
                .is_none()
        {
            return Err(refused());
        }
        for kind in ["writeTarget", "verifyTarget"] {
            let matching: Vec<_> = plan
                .public_steps
                .iter()
                .filter(|step| {
                    step.kind == kind
                        && step.semantic_target == format!("partition:{}", effect.target)
                        && step.content_sha256 == effect.content_sha256
                })
                .collect();
            let [step] = matching.as_slice() else {
                return Err(refused());
            };
            if kind == "verifyTarget" {
                let receipt = source
                    .receipts
                    .iter()
                    .find(|receipt| receipt.step_id == step.step_id)
                    .ok_or_else(refused)?;
                if receipt.verification_outcome != "verified"
                    || receipt.verification_strength != "fullHash"
                    || receipt.verified_range_start != effect.range_start
                    || receipt.verified_range_length != effect.range_length
                    || receipt.evidence_sha256 != expected.as_bytes()
                {
                    return Err(refused());
                }
            }
        }
    }
    if targets != TARGETS.into_iter().collect()
        || ["writeTarget", "verifyTarget"].iter().any(|kind| {
            plan.public_steps
                .iter()
                .filter(|step| step.kind == *kind)
                .count()
                != TARGETS.len()
        })
    {
        return Err(refused());
    }
    Ok(())
}
