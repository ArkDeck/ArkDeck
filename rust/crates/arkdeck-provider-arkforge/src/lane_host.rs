//! Swift `ArkForgeLaneHost`: split preparation and execution of one correlated
//! daemon Job. Preparation cannot sign; only `perform` drives an existing Job.
//! Runtime remains responsible for durable correlation and capability use.

use crate::authority::{ApprovedPlan, AuthorityBinding, ExecutionAuthority, PERMIT_LIFETIME_MS};
use crate::authority_support::Configuration;
use crate::flash_session::{self, ControlPerformer, FlashSession, SessionDaemon, SessionOutcome};
use crate::lane_plan::{self, AssessmentSource, PlanSource, digest_bytes};
use crate::{
    ActionReceipt, DeviceBinding, Execution, FlashLane, LaneArtifact, LaneFailure, PrewarmReceipt,
    Terminal,
};
use arkforge_authority_api::ControllerPairingSecret;
use arkforge_ipc::messages::ActionReceiptSummary;
use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};
use std::time::{Instant, SystemTime, UNIX_EPOCH};

/// The existing controller session plus its typed start call. No start call
/// is exposed through passive terminal observation.
pub trait ExecutionClient: SessionDaemon {
    fn start(
        &mut self,
        plan_id: &str,
        digest: &str,
        purpose: &str,
        session: &str,
    ) -> Result<String, String>;
}

impl ExecutionClient for arkforge_client::ControllerClient {
    fn start(
        &mut self,
        plan_id: &str,
        digest: &str,
        purpose: &str,
        session: &str,
    ) -> Result<String, String> {
        self.start_execution(plan_id, digest, purpose, session)
            .map_err(|error| flash_session::client_error(&error))
    }
}

/// Inspection and materialization over the one owned daemon generation.
/// Tests replace these external ports; production uses the pinned SDK.
pub trait PlanConnections: Send + Sync {
    fn controller(&self) -> Result<Box<dyn PlanSource>, String>;
    fn public(&self) -> Result<Box<dyn AssessmentSource>, String>;
}

/// Execution ports are absent from the read-only preview owner.
pub trait LaneConnections: PlanConnections {
    fn execution(&self) -> Result<Box<dyn ExecutionClient>, String>;
    fn performer(&self, job_id: &str, binding: &DeviceBinding) -> Box<dyn ControlPerformer>;
}

#[derive(Default)]
struct JobState {
    prewarm: Option<PrewarmReceipt>,
    execution: Option<Execution>,
    purpose: Option<String>,
    failure: Option<LaneFailure>,
    receipts: BTreeMap<String, ActionReceipt>,
    completed: Option<ActionReceipt>,
}

/// One lane per owned daemon generation. Its pairing secret stays in memory
/// and belongs to that generation. Per-Job locks prevent duplicate starts and
/// drives without blocking unrelated archive prewarms behind a long flash.
pub struct LaneHost {
    connections: Box<dyn LaneConnections>,
    toolchain_sha256: String,
    support: Configuration,
    secret: ControllerPairingSecret,
    jobs: Mutex<BTreeMap<String, Arc<Mutex<JobState>>>>,
}

const CONTROLLER_SESSION: &str = "arkdeck-agentd";

impl LaneHost {
    pub fn new(
        connections: Box<dyn LaneConnections>,
        toolchain_sha256: String,
        support: Configuration,
        secret: ControllerPairingSecret,
    ) -> Self {
        Self {
            connections,
            toolchain_sha256,
            support,
            secret,
            jobs: Mutex::new(BTreeMap::new()),
        }
    }

    fn job(&self, job_id: &str) -> Result<Arc<Mutex<JobState>>, LaneFailure> {
        let mut jobs = self
            .jobs
            .lock()
            .map_err(|_| unknown("lane state lock was poisoned"))?;
        Ok(Arc::clone(jobs.entry(job_id.to_owned()).or_default()))
    }

    fn validate_identity(&self, execution: &Execution) -> Result<(), LaneFailure> {
        if execution.arkdeck_job_id.is_empty()
            || execution.daemon_job_id.is_empty()
            || execution.plan_id.is_empty()
            || execution.observation_mode.is_empty()
            || digest_bytes(&execution.plan_sha256).is_none()
            || digest_bytes(&execution.artifact_sha256).is_none()
            || digest_bytes(&execution.stable_identity_sha256).is_none()
        {
            return Err(LaneFailure::Other(
                "persisted ArkForge execution correlation is malformed".into(),
            ));
        }
        if execution.toolchain_sha256 != self.toolchain_sha256 {
            return Err(LaneFailure::Other(
                "persisted ArkForge execution is bound to another toolchain".into(),
            ));
        }
        Ok(())
    }

    fn validate(
        &self,
        execution: &Execution,
        job_id: &str,
        artifact: &LaneArtifact,
        binding: &DeviceBinding,
        purpose: &str,
    ) -> Result<(), LaneFailure> {
        self.validate_identity(execution)?;
        if execution.arkdeck_job_id != job_id
            || execution.execution_purpose != purpose
            || execution.artifact_sha256 != artifact.sha256.to_lowercase()
            || execution.artifact_profile_id != artifact.profile_id
            || execution.target_id != binding.target_id
            || execution.binding_revision != binding.binding_revision
            || execution.stable_identity_sha256 != binding.stable_identity_sha256.to_lowercase()
            || execution.usb_topology != binding.usb_topology
        {
            return Err(LaneFailure::Other(
                "persisted ArkForge execution correlation does not match this Runtime attempt"
                    .into(),
            ));
        }
        Ok(())
    }

    fn prepare_once(
        &self,
        state: &mut JobState,
        job_id: &str,
        artifact: &LaneArtifact,
        binding: &DeviceBinding,
        purpose: &str,
    ) -> Result<Execution, LaneFailure> {
        // No permit exists in this boundary. Even a lost start reply can only
        // leave an orphan daemon Job waiting for a permit, with no effect.
        let before_start = || -> Result<_, String> {
            let client = self.connections.execution()?;
            let mut controller = self.connections.controller()?;
            if let Some(prewarm) = &state.prewarm {
                if prewarm.artifact_sha256 != artifact.sha256
                    || prewarm.profile_id != artifact.profile_id
                {
                    return Err("artifact identity changed after lane prewarm".into());
                }
            } else {
                lane_plan::ensure_artifact(&mut *controller, artifact)?;
            }
            let mut public = self.connections.public()?;
            let materialized = lane_plan::materialize(
                &mut *controller,
                &mut *public,
                artifact,
                binding,
                purpose,
                &self.support,
            )
            .map_err(|error| error.detail)?;
            Ok((client, materialized))
        };
        let (mut client, (plan, observed_mode)) = before_start().map_err(|error| {
            LaneFailure::ConfirmedNotExecuted(format!("arkforged refused before startExecution; nothing was dispatched and the device was not touched: {error}"))
        })?;
        state.prewarm = None;
        if plan.execution_purpose != purpose
            || digest_bytes(&plan.plan_sha256).is_none()
            || plan.plan_id.is_empty()
        {
            return Err(LaneFailure::ConfirmedNotExecuted(
                "arkforged returned a malformed or differently purposed plan before startExecution"
                    .into(),
            ));
        }
        state.purpose = Some(purpose.to_owned());
        let daemon_job_id = client.start(&plan.plan_id, &plan.plan_sha256, purpose, CONTROLLER_SESSION)
            .map_err(|error| LaneFailure::ConfirmedNotExecuted(format!("arkforged startExecution did not return a durable job identity; no permit was signed and the device was not touched: {error}")))?;
        if daemon_job_id.is_empty() {
            return Err(LaneFailure::ConfirmedNotExecuted("arkforged startExecution returned no job identity; no permit was signed and the device was not touched".into()));
        }
        Ok(Execution {
            arkdeck_job_id: job_id.to_owned(),
            daemon_job_id,
            plan_id: plan.plan_id,
            plan_sha256: plan.plan_sha256.to_lowercase(),
            execution_purpose: purpose.to_owned(),
            artifact_sha256: artifact.sha256.to_lowercase(),
            artifact_profile_id: artifact.profile_id.clone(),
            target_id: binding.target_id.clone(),
            binding_revision: binding.binding_revision,
            stable_identity_sha256: binding.stable_identity_sha256.to_lowercase(),
            usb_topology: binding.usb_topology.clone(),
            observation_mode: observed_mode,
            toolchain_sha256: self.toolchain_sha256.clone(),
        })
    }

    fn drive(
        &self,
        execution: &Execution,
        binding: &DeviceBinding,
    ) -> Result<SessionOutcome, LaneFailure> {
        let mut client = self.connections.execution().map_err(|error| {
            unknown(&format!(
                "cannot reconnect to correlated arkforged job {}: {error}",
                execution.daemon_job_id
            ))
        })?;
        let identity = digest_bytes(&binding.stable_identity_sha256)
            .ok_or_else(|| unknown("bound identity digest is malformed"))?;
        let mut authority = ExecutionAuthority::new(
            ApprovedPlan {
                job_id: execution.arkdeck_job_id.clone(),
                plan_id: execution.plan_id.clone(),
                plan_sha256: digest_bytes(&execution.plan_sha256)
                    .ok_or_else(|| unknown("plan digest is malformed"))?,
                admitted_device_facts_sha256: identity.clone(),
                usb_topology: Some(binding.usb_topology.clone()),
                binding: AuthorityBinding {
                    authority_namespace: "arkdeck".into(),
                    binding_id: binding.target_id.clone(),
                    binding_revision: binding.binding_revision.max(0) as u64,
                    stable_identity_digest: identity,
                },
                controller_session_id: CONTROLLER_SESSION.into(),
                permit_lifetime_ms: PERMIT_LIFETIME_MS,
            },
            self.secret.clone(),
            || {
                SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .map_or(0, |time| time.as_millis().min(u64::MAX as u128) as u64)
            },
        );
        authority.record_materialized_observation_mode(&execution.observation_mode);
        let mut performer = self
            .connections
            .performer(&execution.arkdeck_job_id, binding);
        FlashSession::new(&mut *client, &mut authority, &mut *performer)
            .run_existing(&execution.daemon_job_id)
            .map_err(|error| {
                unknown(&format!(
                    "lost control of correlated arkforged job {}: {error}",
                    execution.daemon_job_id
                ))
            })
    }
}

impl FlashLane for LaneHost {
    fn toolchain_sha256(&self) -> &str {
        &self.toolchain_sha256
    }

    fn prewarm(
        &self,
        job_id: &str,
        artifact: &LaneArtifact,
    ) -> Result<PrewarmReceipt, LaneFailure> {
        let job = self.job(job_id)?;
        let mut state = job
            .lock()
            .map_err(|_| unknown("lane Job lock was poisoned"))?;
        if let Some(prewarm) = &state.prewarm {
            if prewarm.artifact_sha256 != artifact.sha256
                || prewarm.profile_id != artifact.profile_id
            {
                return Err(LaneFailure::Other(
                    "artifact identity changed after lane prewarm".into(),
                ));
            }
            return Ok(prewarm.clone());
        }
        let started = Instant::now();
        let mut controller = self.connections.controller().map_err(LaneFailure::Other)?;
        let imported =
            lane_plan::ensure_artifact(&mut *controller, artifact).map_err(LaneFailure::Other)?;
        let receipt = PrewarmReceipt {
            artifact_sha256: artifact.sha256.clone(),
            profile_id: artifact.profile_id.clone(),
            imported,
            duration_milliseconds: started.elapsed().as_millis().min(u64::MAX as u128) as u64,
        };
        state.prewarm = Some(receipt.clone());
        Ok(receipt)
    }

    fn finish_prewarm(&self, job_id: &str) {
        let job = self
            .jobs
            .lock()
            .ok()
            .and_then(|jobs| jobs.get(job_id).cloned());
        if let Some(job) = job
            && let Ok(mut state) = job.lock()
        {
            state.prewarm = None;
        }
    }

    fn prepare(
        &self,
        job_id: &str,
        artifact: &LaneArtifact,
        binding: &DeviceBinding,
        purpose: &str,
    ) -> Result<Execution, LaneFailure> {
        let job = self.job(job_id)?;
        let mut state = job
            .lock()
            .map_err(|_| unknown("lane Job lock was poisoned"))?;
        if let Some(execution) = &state.execution {
            self.validate(execution, job_id, artifact, binding, purpose)?;
            return Ok(execution.clone());
        }
        if state
            .purpose
            .as_deref()
            .is_some_and(|bound| bound != purpose)
        {
            return Err(LaneFailure::Other(
                "the ArkDeck Job is already bound to another execution purpose".into(),
            ));
        }
        if let Some(failure) = &state.failure {
            return Err(failure.clone());
        }
        match self.prepare_once(&mut state, job_id, artifact, binding, purpose) {
            Ok(execution) => {
                state.execution = Some(execution.clone());
                Ok(execution)
            }
            Err(failure) => {
                state.failure = Some(failure.clone());
                Err(failure)
            }
        }
    }

    fn perform(
        &self,
        step_id: &str,
        execution: &Execution,
        artifact: &LaneArtifact,
        binding: &DeviceBinding,
    ) -> Result<ActionReceipt, LaneFailure> {
        self.validate(
            execution,
            &execution.arkdeck_job_id,
            artifact,
            binding,
            &execution.execution_purpose,
        )?;
        let job = self.job(&execution.arkdeck_job_id)?;
        let mut state = job
            .lock()
            .map_err(|_| unknown("lane Job lock was poisoned"))?;
        if let Some(failure) = &state.failure {
            return Err(failure.clone());
        }
        if state
            .execution
            .as_ref()
            .is_some_and(|existing| existing != execution)
        {
            return Err(unknown(
                "another daemon execution is already correlated with this Job",
            ));
        }
        if state.completed.is_some() {
            return projected(&state, step_id);
        }
        state.execution = Some(execution.clone());
        state.purpose = Some(execution.execution_purpose.clone());
        let result = self.drive(execution, binding);
        let (receipts, failure) = match result {
            Ok(SessionOutcome::Completed(receipts)) => (receipts, None),
            Ok(SessionOutcome::ConfirmedFailed { reason, receipts }) => (receipts, Some(LaneFailure::Failed(reason))),
            Ok(SessionOutcome::CancelledSafe(receipts)) => (receipts, Some(LaneFailure::ConfirmedNotExecuted("arkforged cancelled the plan before any external effect; no completion receipt exists".into()))),
            Ok(SessionOutcome::OutcomeUnknown { reason, receipts }) => (receipts, Some(unknown(&reason))),
            Err(failure) => (Vec::new(), Some(failure)),
        };
        for receipt in &receipts {
            state
                .receipts
                .entry(receipt.step_id.clone())
                .or_insert_with(|| action_receipt(receipt));
        }
        if let Some(failure) = failure {
            state.failure = Some(failure.clone());
            return Err(failure);
        }
        let Some(last) = receipts.last() else {
            let failure = unknown("arkforged completed without an action receipt");
            state.failure = Some(failure.clone());
            return Err(failure);
        };
        state.completed = Some(action_receipt(last));
        projected(&state, step_id)
    }

    fn observe_terminal(&self, execution: &Execution) -> Result<Option<Terminal>, String> {
        self.validate_identity(execution)
            .map_err(|error| format!("{error:?}"))?;
        let mut client = self.connections.execution()?;
        Ok(
            flash_session::observe_terminal(&mut *client, &execution.daemon_job_id)?.map(
                |outcome| match outcome {
                    SessionOutcome::Completed(receipts) => {
                        Terminal::Completed(receipts.iter().map(action_receipt).collect())
                    }
                    SessionOutcome::ConfirmedFailed { reason, .. } => {
                        Terminal::ConfirmedFailed(reason)
                    }
                    SessionOutcome::CancelledSafe(_) => Terminal::CancelledSafe,
                    SessionOutcome::OutcomeUnknown { reason, .. } => {
                        Terminal::OutcomeUnknown(reason)
                    }
                },
            ),
        )
    }

    fn completed_plan_receipt(&self, job_id: &str) -> Option<ActionReceipt> {
        let job = self.jobs.lock().ok()?.get(job_id)?.clone();
        job.lock().ok()?.completed.clone()
    }

    fn hardware_acceptance_campaign(&self) -> Option<String> {
        (!self.support.hardware_campaign.is_empty()).then(|| self.support.hardware_campaign.clone())
    }
}

fn projected(state: &JobState, step_id: &str) -> Result<ActionReceipt, LaneFailure> {
    state
        .receipts
        .get(step_id)
        .cloned()
        .or_else(|| {
            matches!(step_id, "flash-partitions" | "verify-flash-readback")
                .then(|| state.completed.clone())
                .flatten()
        })
        .ok_or_else(|| {
            LaneFailure::Other(format!("arkforged returned no receipt for step {step_id}"))
        })
}

fn unknown(reason: &str) -> LaneFailure {
    LaneFailure::OutcomeUnknown(reason.to_owned())
}

fn action_receipt(receipt: &ActionReceiptSummary) -> ActionReceipt {
    ActionReceipt {
        job_id: receipt.job_id.clone(),
        plan_id: receipt.plan_id.clone(),
        step_id: receipt.step_id.clone(),
        action_id: receipt.action_id.clone(),
        attempt_id: receipt.attempt_id.clone(),
        permit_id: receipt.permit_id.clone(),
        disposition: receipt.disposition.clone(),
        evidence_sha256: receipt.evidence_sha256.clone(),
        verification_outcome: receipt.verification_outcome.clone(),
        verification_strength: receipt.verification_strength.clone(),
        verified_range_start: receipt.verified_range_start,
        verified_range_length: receipt.verified_range_length,
        typed_skip_reason: receipt.typed_skip_reason.clone(),
        failure_classification: receipt.failure_classification.clone(),
        facts: receipt
            .facts
            .iter()
            .map(|fact| (fact.key.clone(), fact.value.clone()))
            .collect(),
    }
}

#[cfg(test)]
mod tests;
