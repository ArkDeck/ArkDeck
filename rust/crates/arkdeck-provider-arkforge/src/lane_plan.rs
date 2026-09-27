//! Swift `ArkForgeLaneHost.materializeStoredArtifact`: two non-executable
//! assessments must agree before the independent authority seal is supplied.
//! This is the lane's materialization policy, not a second IPC codec.

use crate::authority_support::{self, Configuration, Seal};
use crate::{DeviceBinding, LaneArtifact, select};
use arkforge_client::{DeviceObservationView, MaterializeInput};
use arkforge_ipc::messages::{Assessment, ExecutablePlan, MaterializePlanResponse};

/// The controller's typed calls used by materialization.
pub trait PlanSource {
    fn inspect(&mut self, artifact_sha256: &str) -> Result<(), String>;
    fn import(&mut self, artifact: &LaneArtifact) -> Result<(), String>;
    fn discover(&mut self) -> Result<Vec<DeviceObservationView>, String>;
    fn materialize(
        &mut self,
        input: &MaterializeInput<'_>,
    ) -> Result<MaterializePlanResponse, String>;
}

/// Public assessment carries no controller binding or authority fields and
/// exposes neither import nor execution. An unexpected executable reply is
/// still checked by the materializer before any controller plan is requested.
pub trait AssessmentSource {
    fn inspect(&mut self, artifact_sha256: &str) -> Result<(), String>;
    fn discover(&mut self) -> Result<Vec<DeviceObservationView>, String>;
    fn assess(
        &mut self,
        artifact_id: &str,
        profile_id: &str,
        observation_id: &str,
    ) -> Result<MaterializePlanResponse, String>;
}

pub(crate) fn digest_bytes(hex: &str) -> Option<Vec<u8>> {
    if hex.len() != 64 || !hex.bytes().all(|b| b.is_ascii_hexdigit()) {
        return None;
    }
    hex.as_bytes()
        .as_chunks::<2>()
        .0
        .iter()
        .map(|pair| u8::from_str_radix(std::str::from_utf8(pair).ok()?, 16).ok())
        .collect()
}

/// An import is host-only and is followed by inspection of that exact digest.
pub(crate) fn ensure_artifact(
    source: &mut dyn PlanSource,
    artifact: &LaneArtifact,
) -> Result<bool, String> {
    if source.inspect(&artifact.sha256).is_ok() {
        return Ok(false);
    }
    source.import(artifact)?;
    source.inspect(&artifact.sha256)?;
    Ok(true)
}

pub(crate) fn materialize(
    controller: &mut dyn PlanSource,
    public: &mut dyn AssessmentSource,
    artifact: &LaneArtifact,
    binding: &DeviceBinding,
    purpose: &str,
    support: &Configuration,
) -> Result<(ExecutablePlan, String), String> {
    let identity = digest_bytes(&binding.stable_identity_sha256)
        .ok_or("the ArkDeck binding has no exact 32-byte stable identity digest")?;
    public.inspect(&artifact.sha256)?;
    let observations = public.discover()?;
    let public_observation =
        select(&observations, &binding.usb_topology).map_err(|error| error.to_string())?;
    let input = |observation_id, key, state, detail| MaterializeInput {
        artifact_id: &artifact.sha256,
        profile_id: &artifact.profile_id,
        device_id: observation_id,
        toolchain_id: "arkforged-native-rockusb",
        authority_namespace: authority_support::NAMESPACE,
        binding_id: &binding.target_id,
        binding_revision: binding.binding_revision.max(1) as u64,
        stable_identity_sha256: &identity,
        execution_purpose: purpose,
        authority_support_key_sha256: key,
        authority_support_state: state,
        authority_support_detail: detail,
    };
    let public_answer = public.assess(
        &artifact.sha256,
        &artifact.profile_id,
        &public_observation.observation_id,
    )?;
    let MaterializePlanResponse::Assessment(public_assessment) = public_answer else {
        return Err("the public ArkForge endpoint returned an executable plan".into());
    };
    if digest_bytes(&public_assessment.mechanics_maturity_key_sha256).is_none() {
        return Err("the public assessment carries no usable mechanics maturity key".into());
    }

    let observations = controller.discover()?;
    let controller_observation =
        select(&observations, &binding.usb_topology).map_err(|error| error.to_string())?;
    if !same_observation(public_observation, controller_observation) {
        return Err(
            "public and controller sessions did not observe the same bound device facts".into(),
        );
    }
    let pending_key = authority_support::pending_key_sha256();
    let pending = controller.materialize(&input(
        &controller_observation.observation_id,
        &pending_key,
        "hardwareGated",
        authority_support::PENDING_DETAIL,
    ))?;
    let MaterializePlanResponse::Assessment(mechanics) = pending else {
        return Err(
            "ArkForge returned an executable plan for a hardware-gated authority binding".into(),
        );
    };
    let pending_hex: String = pending_key.iter().map(|b| format!("{b:02x}")).collect();
    if mechanics.authority_support_key_sha256 != pending_hex
        || mechanics.authority_support_state != "hardwareGated"
    {
        return Err("ArkForge did not echo the pending authority-support seal".into());
    }
    if mechanics.mechanics_maturity_key_sha256 != public_assessment.mechanics_maturity_key_sha256 {
        return Err(
            "public and controller materialization disagree on the mechanics maturity key".into(),
        );
    }
    if !matches!(
        mechanics.mechanics_maturity_state.as_str(),
        "productionVerified" | "hardwareCampaign"
    ) {
        return Err(assessment_refusal(&mechanics));
    }
    let seal = support
        .seal(&mechanics.mechanics_maturity_key_sha256)
        .map_err(|error| error.to_string())?;
    if !seal.permits_execution() {
        return Err(format!(
            "authority support is {} for the exact ArkDeck authority key; mechanics maturity does not bypass this independent gate: {}",
            seal.state, seal.detail
        ));
    }
    match controller.materialize(&input(
        &controller_observation.observation_id,
        &seal.key_sha256,
        &seal.state,
        &seal.detail,
    ))? {
        MaterializePlanResponse::Plan(plan) => {
            require_seals(&plan, &mechanics, &seal, &support.hardware_campaign)?;
            Ok((plan, controller_observation.mode.clone()))
        }
        MaterializePlanResponse::Assessment(answer) => Err(assessment_refusal(&answer)),
    }
}

fn same_observation(left: &DeviceObservationView, right: &DeviceObservationView) -> bool {
    left.observation_id == right.observation_id
        && left.mode == right.mode
        && left.topology_sha256 == right.topology_sha256
        && left.descriptor_sha256 == right.descriptor_sha256
        && left.identity_strength == right.identity_strength
        && left.malformed_descriptor == right.malformed_descriptor
        && left.protocol_identity == right.protocol_identity
}

fn require_seals(
    plan: &ExecutablePlan,
    mechanics: &Assessment,
    support: &Seal,
    campaign: &str,
) -> Result<(), String> {
    let mechanics_campaign = if mechanics.mechanics_maturity_state == "hardwareCampaign" {
        campaign
    } else {
        ""
    };
    if plan.mechanics_maturity_key_sha256 != mechanics.mechanics_maturity_key_sha256
        || plan.mechanics_maturity_state != mechanics.mechanics_maturity_state
        || plan.mechanics_maturity_campaign != mechanics_campaign
        || plan.authority_support_key_sha256 != support.key_hex()
        || plan.authority_support_state != support.state
        || plan.authority_support_campaign != support.campaign()
    {
        return Err(
            "ArkForge did not seal the exact mechanics and authority-support evidence supplied"
                .into(),
        );
    }
    Ok(())
}

fn assessment_refusal(assessment: &Assessment) -> String {
    format!(
        "ArkForge plan is {}: {}",
        assessment.availability, assessment.unavailable_reason
    )
}
