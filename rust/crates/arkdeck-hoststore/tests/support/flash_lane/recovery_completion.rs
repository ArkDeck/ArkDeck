//! Synthetic sealed-plan receipts for the Runtime recovery tests. No device I/O.
use super::*;
use arkdeck_provider_arkforge::maintenance::{
    ActionReceiptSummary, Effect, ExecutablePlan, JobSummary, KeyValue, PublicStep, SourceRecords,
};

pub(super) fn source(execution: &Execution, fault: &str) -> Result<SourceRecords, String> {
    if fault == "readbackUnavailable" {
        return Err("fixture sealed completion proof unavailable".into());
    }
    let targets = [
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
    let mut plan = ExecutablePlan {
        plan_id: execution.plan_id.clone(),
        plan_sha256: execution.plan_sha256.clone(),
        execution_purpose: execution.execution_purpose.clone(),
        ..ExecutablePlan::default()
    };
    let mut receipts = Vec::new();
    for (index, target) in targets.into_iter().enumerate() {
        let effect = Effect {
            kind: "writePartition".into(),
            target: target.into(),
            range_start: (index as u64 + 1) * 4096,
            range_length: 512,
            content_sha256: "ab".repeat(32),
        };
        for kind in ["writeTarget", "verifyTarget"] {
            let step_id = format!("STEP-{}", plan.public_steps.len() + 1);
            plan.public_steps.push(PublicStep {
                step_id: step_id.clone(),
                kind: kind.into(),
                semantic_target: format!("partition:{target}"),
                content_sha256: effect.content_sha256.clone(),
                ..PublicStep::default()
            });
            let mut receipt = ActionReceiptSummary {
                job_id: execution.daemon_job_id.clone(),
                plan_id: execution.plan_id.clone(),
                step_id,
                attempt_id: "ATTEMPT-1".into(),
                permit_id: "PERMIT-1".into(),
                disposition: "semanticSuccess".into(),
                evidence_sha256: vec![0xab; 32],
                ..ActionReceiptSummary::default()
            };
            if kind == "verifyTarget" {
                receipt.verification_outcome = "verified".into();
                receipt.verification_strength = "fullHash".into();
                receipt.verified_range_start = effect.range_start;
                receipt.verified_range_length = effect.range_length;
                if index >= 2 && fault == "readbackSkip" {
                    receipt.verification_outcome = "typedSkip".into();
                    receipt.verification_strength.clear();
                    receipt.typed_skip_reason = "skipped-lba-read-window".into();
                }
                if index == 8 && fault == "readbackShort" {
                    receipt.verified_range_length -= 1;
                }
                if index == 8 && fault == "readbackHash" {
                    receipt.evidence_sha256 = vec![0xcd; 32];
                }
                if index == 8 && fault == "readbackWeak" {
                    receipt.verification_strength = "sampledRanges".into();
                }
                if index == 8 && fault == "readbackRange" {
                    receipt.verified_range_start += 512;
                }
            }
            receipts.push(receipt);
        }
        plan.persistent_effects.push(effect);
    }
    for kind in ["reboot", "postflightProbe"] {
        let step_id = format!("STEP-{}", plan.public_steps.len() + 1);
        plan.public_steps.push(PublicStep {
            step_id: step_id.clone(),
            kind: kind.into(),
            ..PublicStep::default()
        });
        receipts.push(ActionReceiptSummary {
            job_id: execution.daemon_job_id.clone(),
            plan_id: execution.plan_id.clone(),
            step_id,
            attempt_id: "ATTEMPT-1".into(),
            permit_id: "PERMIT-1".into(),
            disposition: "semanticSuccess".into(),
            evidence_sha256: vec![1; 32],
            ..ActionReceiptSummary::default()
        });
    }
    let postflight = super::receipt(execution, true);
    let last = receipts.last_mut().unwrap();
    last.step_id = postflight.step_id.clone();
    plan.public_steps.last_mut().unwrap().step_id = postflight.step_id;
    last.evidence_sha256 = postflight.evidence_sha256;
    last.facts = postflight
        .facts
        .into_iter()
        .map(|(key, value)| KeyValue { key, value })
        .collect();
    if fault == "readbackMissing" {
        receipts.remove(17);
    }
    if fault == "readbackDuplicate" {
        receipts[17] = receipts[15].clone();
    }
    if fault == "readbackOtherJob" {
        receipts[17].job_id = "JOB-OTHER".into();
    }
    if fault == "readbackMissingEffect" {
        plan.persistent_effects.pop();
    }
    if fault == "readbackWriteFailed" {
        receipts[0].disposition = "confirmedPartialEffect".into();
    }
    let job = JobSummary {
        job_id: execution.daemon_job_id.clone(),
        plan_id: execution.plan_id.clone(),
        plan_sha256: (0..32)
            .map(|index| {
                u8::from_str_radix(&execution.plan_sha256[index * 2..index * 2 + 2], 16).unwrap()
            })
            .collect(),
        state: "succeeded".into(),
        terminal: true,
        total_steps: plan.public_steps.len() as u64,
        completed_steps: plan.public_steps.len() as u64,
        ..JobSummary::default()
    };
    Ok(SourceRecords {
        plan,
        job,
        receipts,
        active_jobs: 0,
    })
}
