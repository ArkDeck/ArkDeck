//! Trusted maintenance data and result projection. No frontend supplies these records.
pub use arkforge_arkdeck_adapter::maintenance::*;
pub use arkforge_ipc::messages::{
    ActionReceiptSummary, Effect, ExecutablePlan, JobSummary, KeyValue, PublicStep,
};
use serde_json::{Value, json};
use std::path::Path;

#[derive(Clone, Debug)]
pub struct SourceRecords {
    pub plan: ExecutablePlan,
    pub job: JobSummary,
    pub receipts: Vec<ActionReceiptSummary>,
    pub active_jobs: u64,
}

pub fn verification_document(result: &VerificationResult) -> Value {
    json!({
        "schema": "arkforge.flash-verification/v1",
        "source_job_id": result.source_job_id,
        "source_plan_id": result.source_plan_id,
        "source_plan_sha256": result.source_plan_sha256,
        "exit_code": result.exit_code(), "outcome": result.outcome(),
        "verified": result.verified(), "skipped": result.skipped(), "failed": result.failed(),
        "targets": result.targets.iter().map(|target| json!({
            "target": target.effect.target, "range_start": target.effect.range_start,
            "range_length": target.effect.range_length, "expected_sha256": target.effect.content_sha256,
            "observed_sha256": target.observed_sha256, "outcome": target.outcome,
            "verification_strength": target.verification_strength, "reason": target.reason,
        })).collect::<Vec<_>>()
    })
}

pub fn restoration_document(result: &RestorationResult) -> Value {
    match result {
        RestorationResult::Verified {
            restoration_job,
            verification,
        } => json!({
            "schema": "arkforge.boot-loop-restoration/v1", "outcome": "verified", "exit_code": 0,
            "restoration_job_id": restoration_job, "verification": verification_document(verification),
        }),
        RestorationResult::Stopped { reason } => json!({
            "schema": "arkforge.boot-loop-restoration/v1", "outcome": "stopped", "exit_code": 1,
            "reason": reason,
        }),
    }
}

#[cfg(any(target_os = "macos", windows))]
fn plans(runtime: &Path) -> Result<arkdeck_platform::HostDirectory, String> {
    arkdeck_platform::HostDirectory::open(runtime)
        .and_then(|root| root.private_child("maintenance-plans"))
        .map_err(|_| "sealed maintenance plan store is unavailable".into())
}

pub(crate) fn retain_plan(runtime: &Path, plan: &ExecutablePlan) -> Result<(), String> {
    #[cfg(any(target_os = "macos", windows))]
    {
        arkforge_core::Sha256Digest::parse_hex(&plan.plan_sha256).map_err(|e| e.to_string())?;
        let root = plans(runtime)?;
        let _lock = root
            .lock_document(".plans.lock")
            .map_err(|e| e.to_string())?;
        let name = format!("{}.bin", plan.plan_sha256);
        let bytes = plan.encode();
        match root
            .read_owner_only(&name, 4 * 1024 * 1024)
            .map_err(|e| e.to_string())?
        {
            Some(old) if old != bytes => {
                return Err("sealed plan record conflicts with existing history".into());
            }
            Some(_) => return Ok(()),
            None => (),
        }
        root.publish_document(&name, &bytes, 4 * 1024 * 1024)
            .map_err(|_| "sealed plan could not become durable".to_owned())?;
        Ok(())
    }
    #[cfg(not(any(target_os = "macos", windows)))]
    {
        let _ = (runtime, plan);
        Err("maintenance is supported on macOS and Windows".into())
    }
}

pub(crate) fn read_source(
    runtime: &Path,
    execution: &crate::Execution,
) -> Result<SourceRecords, String> {
    #[cfg(any(target_os = "macos", windows))]
    {
        arkforge_core::Sha256Digest::parse_hex(&execution.plan_sha256)
            .map_err(|e| e.to_string())?;
        let bytes = plans(runtime)?
            .read_owner_only(&format!("{}.bin", execution.plan_sha256), 4 * 1024 * 1024)
            .map_err(|e| e.to_string())?
            .ok_or("source predates retained maintenance plans")?;
        let plan = ExecutablePlan::decode(&bytes).map_err(|e| e.to_string())?;
        if plan.encode() != bytes
            || plan.plan_sha256 != execution.plan_sha256
            || plan.plan_id != execution.plan_id
        {
            return Err("sealed source plan does not match its durable Job correlation".into());
        }
        let mut client = arkforge_client::PublicClient::connect_with_read_timeout(
            runtime,
            std::time::Duration::from_secs(10),
        )
        .map_err(|e| crate::flash_session::client_error(&e))?;
        let job = client
            .job_show(&execution.daemon_job_id)
            .map_err(|e| crate::flash_session::client_error(&e))?;
        let events = client
            .job_events(&execution.daemon_job_id, 0)
            .map_err(|e| crate::flash_session::client_error(&e))?;
        let jobs = client
            .job_list()
            .map_err(|e| crate::flash_session::client_error(&e))?;
        let receipts = events.into_iter().filter_map(|e| e.receipt).collect();
        Ok(SourceRecords {
            plan,
            job,
            receipts,
            active_jobs: jobs.iter().filter(|job| !job.terminal).count() as u64,
        })
    }
    #[cfg(not(any(target_os = "macos", windows)))]
    {
        let _ = (runtime, execution);
        Err("maintenance is supported on macOS and Windows".into())
    }
}
