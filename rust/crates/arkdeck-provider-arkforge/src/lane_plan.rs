//! Swift `ArkForgeLaneHost.materializeStoredArtifact`: two non-executable
//! assessments must agree before the independent authority seal is supplied.
//! This is the lane's materialization policy, not a second IPC codec.

use crate::authority_support::{self, Configuration, Seal};
use crate::{DeviceBinding, LaneArtifact, LanePreview, select};
use arkforge_client::{DeviceObservationView, MaterializeInput};
use arkforge_ipc::messages::{Assessment, ExecutablePlan, MaterializePlanResponse};
use std::collections::BTreeMap;

/// Keep execution's existing refusal text while exposing Swift's structured
/// preview state. Both callers run the same materialization gates.
pub(crate) struct MaterializationFailure {
    pub(crate) detail: String,
    pub(crate) preview: LanePreview,
}
impl From<String> for MaterializationFailure {
    fn from(detail: String) -> Self {
        Self {
            preview: LanePreview::PreviewFailed(detail.clone()),
            detail,
        }
    }
}
fn unusable(
    reason: &str,
    unknowns: impl IntoIterator<Item = (&'static str, String)>,
) -> MaterializationFailure {
    refused(
        "unusable",
        reason,
        unknowns.into_iter().map(|(k, v)| (k.into(), v)).collect(),
        reason.to_owned(),
    )
}
fn refused(
    availability: &str,
    reason: &str,
    unknowns: BTreeMap<String, String>,
    detail: String,
) -> MaterializationFailure {
    MaterializationFailure {
        detail,
        preview: LanePreview::PlanNotExecutable {
            availability: availability.into(),
            reason: reason.into(),
            unknowns,
        },
    }
}
fn observation_failure(error: crate::SelectionFailure) -> MaterializationFailure {
    let detail = error.to_string();
    MaterializationFailure {
        preview: LanePreview::DeviceNotObserved(detail.clone()),
        detail,
    }
}

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

/// The SDK rejects executable public replies before exposing their body.
/// Preserve that typed boundary failure so preview reports Swift's refusal.
#[derive(Debug)]
pub enum AssessmentFailure {
    ExecutableReply(String),
    Client(String),
}
impl From<AssessmentFailure> for MaterializationFailure {
    fn from(error: AssessmentFailure) -> Self {
        match error {
            AssessmentFailure::ExecutableReply(detail) => {
                let mut failure = unusable(
                    "the public ArkForge endpoint returned an executable plan",
                    [("publicPlan", "assessment-only boundary was bypassed".into())],
                );
                failure.detail = detail;
                failure
            }
            AssessmentFailure::Client(detail) => detail.into(),
        }
    }
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
    ) -> Result<MaterializePlanResponse, AssessmentFailure>;
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
) -> Result<(ExecutablePlan, String), MaterializationFailure> {
    let identity = digest_bytes(&binding.stable_identity_sha256).ok_or_else(|| {
        unusable(
            "the ArkDeck binding has no exact 32-byte stable identity digest",
            [("stableIdentitySHA256", "malformed or absent".into())],
        )
    })?;
    public.inspect(&artifact.sha256)?;
    let observations = public.discover()?;
    let public_observation =
        select(&observations, &binding.usb_topology).map_err(observation_failure)?;
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
        return Err(unusable(
            "the public ArkForge endpoint returned an executable plan",
            [("publicPlan", "assessment-only boundary was bypassed".into())],
        ));
    };
    if digest_bytes(&public_assessment.mechanics_maturity_key_sha256).is_none() {
        return Err(unusable(
            "the public assessment carries no usable mechanics maturity key",
            [(
                "mechanicsMaturityKeySHA256",
                public_assessment.mechanics_maturity_key_sha256.clone(),
            )],
        ));
    }

    let observations = controller.discover()?;
    let controller_observation =
        select(&observations, &binding.usb_topology).map_err(observation_failure)?;
    if !same_observation(public_observation, controller_observation) {
        return Err(unusable(
            "public and controller sessions did not observe the same bound device facts",
            [
                (
                    "publicObservation",
                    public_observation.observation_id.clone(),
                ),
                (
                    "controllerObservation",
                    controller_observation.observation_id.clone(),
                ),
            ],
        ));
    }
    let pending_key = authority_support::pending_key_sha256();
    let pending = controller.materialize(&input(
        &controller_observation.observation_id,
        &pending_key,
        "hardwareGated",
        authority_support::PENDING_DETAIL,
    ))?;
    let MaterializePlanResponse::Assessment(mechanics) = pending else {
        return Err(unusable(
            "ArkForge returned an executable plan for a hardware-gated authority binding",
            [(
                "authorityGate",
                "pending assessment became executable".into(),
            )],
        ));
    };
    let pending_hex: String = pending_key.iter().map(|b| format!("{b:02x}")).collect();
    if mechanics.authority_support_key_sha256 != pending_hex
        || mechanics.authority_support_state != "hardwareGated"
    {
        return Err(unusable(
            "ArkForge did not echo the pending authority-support seal",
            [
                (
                    "authoritySupportKeySHA256",
                    mechanics.authority_support_key_sha256.clone(),
                ),
                (
                    "authoritySupportState",
                    mechanics.authority_support_state.clone(),
                ),
            ],
        ));
    }
    if mechanics.mechanics_maturity_key_sha256 != public_assessment.mechanics_maturity_key_sha256 {
        return Err(unusable(
            "public and controller materialization disagree on the mechanics maturity key",
            [
                (
                    "publicMechanicsKey",
                    public_assessment.mechanics_maturity_key_sha256.clone(),
                ),
                (
                    "controllerMechanicsKey",
                    mechanics.mechanics_maturity_key_sha256.clone(),
                ),
            ],
        ));
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
        let reason = format!(
            "authority support is {} for the exact ArkDeck authority key; mechanics maturity does not bypass this independent gate",
            seal.state
        );
        let mut unknowns: BTreeMap<String, String> = mechanics
            .unknowns
            .iter()
            .map(|pair| (pair.key.clone(), pair.value.clone()))
            .collect();
        unknowns.insert("RK-A01".into(), seal.detail.clone());
        return Err(refused(
            "unavailable",
            &reason,
            unknowns,
            format!("{reason}: {}", seal.detail),
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
) -> Result<(), MaterializationFailure> {
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
        return Err(unusable(
            "ArkForge did not seal the exact mechanics and authority-support evidence supplied",
            [
                (
                    "mechanicsMaturityKeySHA256",
                    plan.mechanics_maturity_key_sha256.clone(),
                ),
                (
                    "mechanicsMaturityState",
                    plan.mechanics_maturity_state.clone(),
                ),
                (
                    "mechanicsMaturityCampaign",
                    plan.mechanics_maturity_campaign.clone(),
                ),
                (
                    "authoritySupportKeySHA256",
                    plan.authority_support_key_sha256.clone(),
                ),
                (
                    "authoritySupportState",
                    plan.authority_support_state.clone(),
                ),
                (
                    "authoritySupportCampaign",
                    plan.authority_support_campaign.clone(),
                ),
            ],
        ));
    }
    Ok(())
}

fn assessment_refusal(assessment: &Assessment) -> MaterializationFailure {
    refused(
        &assessment.availability,
        &assessment.unavailable_reason,
        assessment
            .unknowns
            .iter()
            .map(|pair| (pair.key.clone(), pair.value.clone()))
            .collect(),
        format!(
            "ArkForge plan is {}: {}",
            assessment.availability, assessment.unavailable_reason
        ),
    )
}
