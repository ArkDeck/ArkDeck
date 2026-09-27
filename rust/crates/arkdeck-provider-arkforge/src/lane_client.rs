//! Production ports for `LaneHost`, using ArkForge's typed client and codec.
//! Each materialization gets independent connections, so an archive import
//! cannot occupy the controller connection carrying execution events.

use crate::flash_session::{ControlPerformer, client_error};
use crate::{
    AssessmentSource, DeviceBinding, ExecutionClient, LaneArtifact, LaneConnections, PlanSource,
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

impl LaneConnections for NativeLaneConnections {
    fn controller(&self) -> Result<Box<dyn PlanSource>, String> {
        ControllerClient::connect_with_read_timeout(
            &self.runtime_directory,
            ControllerClient::MATERIALIZATION_READ_TIMEOUT,
        )
        .map(|client| Box::new(client) as Box<dyn PlanSource>)
        .map_err(|error| client_error(&error))
    }

    fn public(&self) -> Result<Box<dyn AssessmentSource>, String> {
        PublicClient::connect_with_read_timeout(
            &self.runtime_directory,
            ControllerClient::MATERIALIZATION_READ_TIMEOUT,
        )
        .map(|client| Box::new(client) as Box<dyn AssessmentSource>)
        .map_err(|error| client_error(&error))
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
    ) -> Result<MaterializePlanResponse, String> {
        // The public API omits every controller/authority field and itself
        // refuses a Plan reply. The lane checks that boundary again.
        self.flash_assess(artifact_id, profile_id, observation_id)
            .map(MaterializePlanResponse::Assessment)
            .map_err(|error| client_error(&error))
    }
}
