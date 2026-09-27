//! Read-only plan preview over the owned daemon generation. Preview never
//! imports an artifact, opens an execution client, constructs a performer or
//! creates a permit. Execution always materializes its own plan again.
use crate::authority_support::Configuration;
use crate::{DeviceBinding, LaneArtifact, PlanConnections, lane_plan};
use std::collections::BTreeMap;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LanePreview {
    Available {
        plan_id: String,
        plan_sha256: String,
        observation_mode: String,
    },
    BundleNotInLaneStore,
    DeviceNotObserved(String),
    PlanNotExecutable {
        availability: String,
        reason: String,
        unknowns: BTreeMap<String, String>,
    },
    PreviewFailed(String),
}

pub trait LanePlanPreview: Send + Sync {
    fn preview(&self, archive_sha256: &str, usb_topology: &str) -> LanePreview;
}

pub struct LanePreviewHost {
    connections: Box<dyn PlanConnections>,
    support: Configuration,
    profile_id: String,
}

impl LanePreviewHost {
    pub fn new(
        connections: Box<dyn PlanConnections>,
        support: Configuration,
        profile_id: String,
    ) -> Self {
        Self {
            connections,
            support,
            profile_id,
        }
    }
}

impl LanePlanPreview for LanePreviewHost {
    fn preview(&self, archive_sha256: &str, usb_topology: &str) -> LanePreview {
        let mut controller = match self.connections.controller() {
            Ok(controller) => controller,
            Err(error) => return LanePreview::PreviewFailed(error),
        };
        if controller.inspect(archive_sha256).is_err() {
            return LanePreview::BundleNotInLaneStore;
        }
        let mut public = match self.connections.public() {
            Ok(public) => public,
            Err(error) => return LanePreview::PreviewFailed(error),
        };
        let artifact = LaneArtifact {
            path: Default::default(),
            sha256: archive_sha256.into(),
            profile_id: self.profile_id.clone(),
        };
        let binding = DeviceBinding {
            connect_key: String::new(),
            stable_identity_sha256: arkdeck_contract::sha256_hex(usb_topology.as_bytes()),
            target_id: format!(
                "PREVIEW-{}",
                archive_sha256.chars().take(12).collect::<String>()
            ),
            binding_revision: 1,
            usb_topology: usb_topology.into(),
        };
        match lane_plan::materialize(
            &mut *controller,
            &mut *public,
            &artifact,
            &binding,
            "primaryFlash",
            &self.support,
        ) {
            Ok((plan, observation_mode)) => LanePreview::Available {
                plan_id: plan.plan_id,
                plan_sha256: plan.plan_sha256,
                observation_mode,
            },
            Err(error) => error.preview,
        }
    }
}
