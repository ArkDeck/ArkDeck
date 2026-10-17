//! Production ports for `LaneHost`, using ArkForge's typed client and codec.
//! Each materialization gets independent connections, so an archive import
//! cannot occupy the controller connection carrying execution events.

use crate::flash_session::{ControlPerformer, client_error};
use crate::{
    AssessmentFailure, AssessmentSource, DeviceBinding, ExecutionClient, LaneArtifact,
    LaneConnections, PlanConnections, PlanSource,
};
use arkforge_client::{ControllerClient, DeviceObservationView, MaterializeInput, PublicClient};
use arkforge_ipc::messages::MaterializePlanResponse;
use std::path::{Path, PathBuf};
use std::time::Duration;

type PerformerFactory = dyn Fn(&str, &DeviceBinding) -> Box<dyn ControlPerformer> + Send + Sync;

pub struct NativeLaneConnections {
    runtime_directory: PathBuf,
    performer: Box<PerformerFactory>,
}

impl NativeLaneConnections {
    pub fn new(
        runtime_directory: &Path,
        performer: impl Fn(&str, &DeviceBinding) -> Box<dyn ControlPerformer> + Send + Sync + 'static,
    ) -> Self {
        Self {
            runtime_directory: runtime_directory.to_path_buf(),
            performer: Box::new(performer),
        }
    }
}

/// Inspection and assessment connections to one owned daemon generation.
pub struct NativePlanConnections(pub PathBuf);

impl PlanConnections for NativePlanConnections {
    fn controller(&self) -> Result<Box<dyn PlanSource>, String> {
        ControllerClient::connect_with_read_timeout(
            &self.0,
            ControllerClient::MATERIALIZATION_READ_TIMEOUT,
        )
        .map(|client| Box::new(client) as Box<dyn PlanSource>)
        .map_err(|error| client_error(&error))
    }

    fn public(&self) -> Result<Box<dyn AssessmentSource>, String> {
        PublicClient::connect_with_read_timeout(
            &self.0,
            ControllerClient::MATERIALIZATION_READ_TIMEOUT,
        )
        .map(|client| Box::new(client) as Box<dyn AssessmentSource>)
        .map_err(|error| client_error(&error))
    }
}

impl PlanConnections for NativeLaneConnections {
    fn retain_plan(&self, plan: &arkforge_ipc::messages::ExecutablePlan) -> Result<(), String> {
        crate::maintenance::retain_plan(&self.runtime_directory, plan)
    }
    fn maintenance_source(
        &self,
        execution: &crate::Execution,
    ) -> Result<crate::maintenance::SourceRecords, String> {
        crate::maintenance::read_source(&self.runtime_directory, execution)
    }

    fn controller(&self) -> Result<Box<dyn PlanSource>, String> {
        NativePlanConnections(self.runtime_directory.clone()).controller()
    }
    fn public(&self) -> Result<Box<dyn AssessmentSource>, String> {
        NativePlanConnections(self.runtime_directory.clone()).public()
    }
}

impl LaneConnections for NativeLaneConnections {
    fn recommission_quiescent(&self, source: &crate::Execution) -> Result<(), String> {
        // Windows HDC children are created suspended inside kill-on-close
        // Job Objects. With no resident source owner they cannot survive its
        // exit. The macOS legacy process group lacks that crash guarantee.
        if !cfg!(windows) {
            return Err("recommission.legacyHostProcessLifetimeUnproven".into());
        }
        let mut client = PublicClient::connect_with_read_timeout(
            &self.runtime_directory,
            Duration::from_secs(10),
        )
        .map_err(|error| client_error(&error))?;
        let jobs = client.job_list().map_err(|error| client_error(&error))?;
        if !census_proves_quiescence(source, &jobs) {
            return Err("recommission.providerHasUnclosedJob".into());
        }
        Ok(())
    }
    fn execution(&self) -> Result<Box<dyn ExecutionClient>, String> {
        // Swift's ordinary controller timeout. These are read-idle bounds,
        // not an absolute deadline for the entire Flash or an archive write.
        ControllerClient::connect_with_read_timeout(
            &self.runtime_directory,
            Duration::from_secs(30),
        )
        .map(|client| Box::new(client) as Box<dyn ExecutionClient>)
        .map_err(|error| client_error(&error))
    }

    fn performer(&self, job_id: &str, binding: &DeviceBinding) -> Box<dyn ControlPerformer> {
        (self.performer)(job_id, binding)
    }
}

fn census_proves_quiescence(
    source: &crate::Execution,
    jobs: &[arkforge_ipc::messages::JobSummary],
) -> bool {
    let matching: Vec<_> = jobs
        .iter()
        .filter(|job| job.job_id == source.daemon_job_id)
        .collect();
    matches!(matching.as_slice(), [job]
        if job.plan_id == source.plan_id
            && job.plan_sha256.len() == 32
            && job.plan_sha256.iter().map(|byte| format!("{byte:02x}")).collect::<String>() == source.plan_sha256)
        && jobs
            .iter()
            .all(|job| job.terminal && !job.job_id.is_empty() && job.last_sequence > 0)
}

impl PlanSource for ControllerClient {
    fn inspect(&mut self, artifact_sha256: &str) -> Result<(), String> {
        self.artifact_show(artifact_sha256)
            .map(drop)
            .map_err(|error| client_error(&error))
    }
    fn import(&mut self, artifact: &LaneArtifact) -> Result<(), String> {
        self.import_artifact(&artifact.path, &artifact.sha256)
            .map(drop)
            .map_err(|error| client_error(&error))
    }
    fn discover(&mut self) -> Result<Vec<DeviceObservationView>, String> {
        self.device_list().map_err(|error| client_error(&error))
    }
    fn materialize(
        &mut self,
        input: &MaterializeInput<'_>,
    ) -> Result<MaterializePlanResponse, String> {
        self.materialize_plan(input)
            .map_err(|error| client_error(&error))
    }
}

impl AssessmentSource for PublicClient {
    fn inspect(&mut self, artifact_sha256: &str) -> Result<(), String> {
        self.artifact_show(artifact_sha256)
            .map(drop)
            .map_err(|error| client_error(&error))
    }
    fn discover(&mut self) -> Result<Vec<DeviceObservationView>, String> {
        self.device_list().map_err(|error| client_error(&error))
    }
    fn assess(
        &mut self,
        artifact_id: &str,
        profile_id: &str,
        observation_id: &str,
    ) -> Result<MaterializePlanResponse, AssessmentFailure> {
        // The public API omits every controller/authority field and itself
        // refuses a Plan reply. The lane checks that boundary again.
        self.flash_assess(artifact_id, profile_id, observation_id)
            .map(MaterializePlanResponse::Assessment)
            .map_err(|error| {
                if error.code == "PUBLIC_ASSESSMENT_VIOLATION" {
                    AssessmentFailure::ExecutableReply(client_error(&error))
                } else {
                    AssessmentFailure::Client(client_error(&error))
                }
            })
    }
}

#[cfg(test)]
mod recommission_tests {
    use super::*;
    use arkforge_ipc::messages::JobSummary;

    #[test]
    fn only_the_exact_closed_historical_provider_job_with_no_active_writer_is_quiescent() {
        let source = crate::Execution {
            arkdeck_job_id: "job-source".into(),
            daemon_job_id: "SOURCE".into(),
            plan_id: "PLAN".into(),
            plan_sha256: "11".repeat(32),
            execution_purpose: "primaryFlash".into(),
            artifact_sha256: "22".repeat(32),
            artifact_profile_id: "dayu200".into(),
            target_id: "target".into(),
            binding_revision: 1,
            stable_identity_sha256: "33".repeat(32),
            usb_topology: "42".into(),
            observation_mode: "hdc-normal".into(),
            toolchain_sha256: "44".repeat(32),
        };
        let closed = JobSummary {
            job_id: "SOURCE".into(),
            plan_id: "PLAN".into(),
            plan_sha256: vec![0x11; 32],
            terminal: true,
            last_sequence: 8,
            state: "outcomeUnknown".into(),
            ..Default::default()
        };
        assert!(census_proves_quiescence(
            &source,
            std::slice::from_ref(&closed)
        ));
        assert!(!census_proves_quiescence(&source, &[]));
        assert!(!census_proves_quiescence(
            &source,
            &[closed.clone(), closed.clone()]
        ));
        for field in 0..5 {
            let mut wrong = closed.clone();
            match field {
                0 => wrong.job_id = "unrelated".into(),
                1 => wrong.plan_id = "other-plan".into(),
                2 => wrong.plan_sha256[0] ^= 1,
                3 => wrong.terminal = false,
                _ => wrong.last_sequence = 0,
            }
            assert!(!census_proves_quiescence(&source, &[wrong]));
        }
        let active = JobSummary {
            job_id: "another-job".into(),
            terminal: false,
            ..closed.clone()
        };
        assert!(!census_proves_quiescence(&source, &[closed, active]));
    }
}
