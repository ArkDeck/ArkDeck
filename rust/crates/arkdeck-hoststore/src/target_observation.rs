//! Swift's `TargetObservationCoordinator`: the Runtime's own device
//! observation, stamped with observation identities and fact generations, and
//! the adoption of a device from one exact observation.
//!
//! Every device list is bracketed by two reads of the USB relations the
//! Runtime observes on its own (`arkdeck_provider_hdc::Reading`). An
//! observation keeps its identity only while an unchanged proved relation
//! carries it; the fact generation advances only when the facts change; and a
//! device is adopted only from the current generation's exact observation,
//! whose relation must still hold through the adoption's tool and identity
//! readback. The snapshot, the generations and the adoption receipts live in
//! memory, as in Swift: nothing here survives a restart (design §L.1 item 13).
//!
//! One difference from Swift: a reading is taken under the owner's lock, so
//! concurrent callers take successive readings rather than joining one in
//! flight.
use crate::target_owner::{ObservationReference, TargetStore};
use arkdeck_contract::WireError;
use arkdeck_provider_hdc::{
    BootstrapFailure, DeviceCandidate, Expected, HdcDispatch, Reading, UsbRelation, UsbRelations,
    adoption_holds, observe_device_identity, observe_tool_version,
    stable_identity_sha256_for_serial,
};
use serde_json::{Map, Value, json};
use std::collections::BTreeMap;
use std::sync::Mutex;

/// Swift `TargetObservationCoordinator.adopt`'s receipt bound.
const MAXIMUM_RECEIPTS: usize = 1000;

/// Swift `TargetDeviceObservation`: one candidate of a snapshot, the
/// identity it carries, the generation that identity was first observed in,
/// and the relation that proved it, if any.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Observation {
    pub candidate: DeviceCandidate,
    pub observation_id: String,
    first_generation: u64,
    pub relation: Option<UsbRelation>,
}

impl Observation {
    /// Swift `continuity`.
    pub fn continuity(&self) -> &'static str {
        if self.relation.is_some() {
            "relationProven"
        } else {
            "generationScoped"
        }
    }

    fn reference(&self, generation: u64) -> ObservationReference {
        ObservationReference {
            candidate: self.candidate.connect_key.clone(),
            observation_id: self.observation_id.clone(),
            generation,
        }
    }
}

/// Swift `TargetObservationSnapshot`, with each observation's candidate
/// display name and its generation.
#[derive(Clone, Debug)]
pub struct Snapshot {
    pub generation: u64,
    pub observed_at: String,
    pub observations: Vec<Observation>,
    pub names: BTreeMap<String, (Option<String>, u64)>,
}

/// The Target an adoption answers with.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Adopted {
    pub target_id: String,
    pub binding_revision: u64,
}

/// Why an observation or an adoption did not answer: Swift's
/// `TargetObservationFailure`, which the daemon refuses before admission
/// with the reference it names, or any other failure, which it answers as
/// `internalError` with its reason.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ObservationError {
    Refused {
        code: String,
        message: String,
        reference: Option<ObservationReference>,
    },
    Failed(String),
}

impl ObservationError {
    fn refused(code: &str, message: &str, reference: Option<&ObservationReference>) -> Self {
        Self::Refused {
            code: code.into(),
            message: message.into(),
            reference: reference.cloned(),
        }
    }

    /// The daemon's answer: a refusal carries `phase: preAdmission`, no new
    /// dispatch and the reference it names.
    pub fn wire(&self) -> WireError {
        match self {
            Self::Refused {
                code,
                message,
                reference,
            } => {
                let mut details = Map::from_iter([
                    ("phase".into(), json!("preAdmission")),
                    ("newDispatchCount".into(), json!(0)),
                ]);
                if let Some(reference) = reference {
                    details.insert("candidate".into(), json!(reference.candidate));
                    details.insert("observationId".into(), json!(reference.observation_id));
                    details.insert(
                        "observationGeneration".into(),
                        json!(reference.generation.to_string()),
                    );
                }
                WireError {
                    code: code.clone(),
                    message: message.clone(),
                    details: Some(details),
                }
            }
            Self::Failed(message) => WireError {
                code: "internalError".into(),
                message: message.clone(),
                details: None,
            },
        }
    }
}

impl From<BootstrapFailure> for ObservationError {
    /// Swift answers `BootstrapError.observationFailed` with its reason.
    fn from(failure: BootstrapFailure) -> Self {
        Self::Failed(failure.0)
    }
}

fn store_failure(error: WireError) -> ObservationError {
    ObservationError::Failed(error.message)
}

fn conflict(reference: &ObservationReference) -> ObservationError {
    ObservationError::refused(
        "resourceConflict",
        "the exact observation no longer belongs to the current snapshot",
        Some(reference),
    )
}

/// Swift's trust refusal: a candidate waiting for the person is
/// `targetTrustPending`, any other `admissionDenied`.
fn trust_or_denied(observation: &Observation) -> &'static str {
    if observation.candidate.state == "Unauthorized" {
        "targetTrustPending"
    } else {
        "admissionDenied"
    }
}

/// A fresh observation identity, `obs-` and a lowercase version-4 UUID.
fn fresh_observation_id() -> Result<String, ObservationError> {
    let mut bytes = arkdeck_platform::random_bytes::<16>().map_err(|_| {
        ObservationError::Failed("observation identity entropy is unavailable".into())
    })?;
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    let hex: String = bytes.iter().map(|byte| format!("{byte:02x}")).collect();
    Ok(format!(
        "obs-{}-{}-{}-{}-{}",
        &hex[..8],
        &hex[8..12],
        &hex[12..16],
        &hex[16..20],
        &hex[20..]
    ))
}

/// What an observation reads through: the HDC dispatch, the USB relations,
/// the Target store and the owner's clock.
pub struct Sources<'a> {
    pub dispatch: &'a dyn HdcDispatch,
    pub relations: &'a dyn UsbRelations,
    pub targets: &'a TargetStore,
    pub now: &'a dyn Fn() -> String,
}

#[derive(Default)]
struct State {
    latest: Option<Snapshot>,
    last_generation: u64,
    receipts: Vec<(ObservationReference, Adopted)>,
}

/// The Runtime's Target observation owner.
#[derive(Default)]
pub struct TargetObservations {
    state: Mutex<State>,
}

impl TargetObservations {
    /// Swift `snapshot(following:)`: a new reading, stamped; a reference
    /// followed must belong to the snapshot before and after it.
    pub fn snapshot(
        &self,
        sources: &Sources<'_>,
        following: Option<&ObservationReference>,
    ) -> Result<Snapshot, ObservationError> {
        let mut state = self.lock()?;
        Self::observe(&mut state, sources, following)
    }

    /// Swift `adopt`: the device of one exact observation of the current
    /// generation, adopted only if its relation still holds through the tool
    /// and identity readback, as one Target.
    pub fn adopt(
        &self,
        sources: &Sources<'_>,
        reference: &ObservationReference,
    ) -> Result<Adopted, ObservationError> {
        self.adopt_guarded(sources, reference, || Ok(()))
    }

    /// The agent's original budget must still hold before each identity
    /// readback and before the synchronous Target commit, as Swift checks it.
    pub(crate) fn adopt_guarded(
        &self,
        sources: &Sources<'_>,
        reference: &ObservationReference,
        mut before_commit: impl FnMut() -> Result<(), ObservationError>,
    ) -> Result<Adopted, ObservationError> {
        let mut state = self.lock()?;
        if let Some(adopted) = state
            .receipts
            .iter()
            .find(|(held, _)| held == reference)
            .map(|(_, adopted)| adopted.clone())
        {
            // A retry answers the receipt only while the original physical
            // observation can still be proved.
            Self::observe(&mut state, sources, Some(reference))?;
            return Ok(adopted);
        }
        before_commit()?;
        let initial = Self::current(&state, reference, false)?.clone();
        if initial.relation.is_none() {
            return Err(ObservationError::refused(
                trust_or_denied(&initial),
                "this observation has no independently proved physical relation",
                Some(reference),
            ));
        }
        Self::observe(&mut state, sources, None)?;
        let selected = Self::current(&state, reference, false)?.clone();
        if selected.candidate.state != "Connected" {
            return Err(ObservationError::refused(
                trust_or_denied(&selected),
                "the exact observed candidate is not authorized and connected",
                Some(reference),
            ));
        }
        let Some(relation) = selected.relation else {
            return Err(ObservationError::refused(
                "admissionDenied",
                "the Runtime cannot prove this candidate's physical identity",
                Some(reference),
            ));
        };
        let reads = (|| {
            let tool_version = observe_tool_version(sources.dispatch)?;
            before_commit()?;
            let readback = observe_device_identity(
                sources.dispatch,
                &reference.candidate,
                Expected::default(),
            )?;
            let live = sources.relations.relations().map_err(BootstrapFailure)?;
            Ok::<_, ObservationError>((tool_version, readback, live))
        })();
        let (tool_version, readback, live) = match reads {
            Ok(reads) => reads,
            Err(failure) => {
                state.latest = None;
                return Err(failure);
            }
        };
        let last = Self::current(&state, reference, false)?;
        if last.relation.as_ref() != Some(&relation) || !adoption_holds(&relation, &live, &readback)
        {
            return Err(ObservationError::refused(
                "factsDrifted",
                "physical identity changed during adoption readback",
                Some(reference),
            ));
        }
        before_commit()?;
        let Some(latest) = state.latest.clone() else {
            return Err(ObservationError::refused(
                "resourceConflict",
                "the exact observation no longer has a current snapshot",
                Some(reference),
            ));
        };
        let active: Vec<ObservationReference> = latest
            .observations
            .iter()
            .map(|observation| observation.reference(latest.generation))
            .collect();
        let next = latest
            .generation
            .checked_add(1)
            .filter(|next| *next <= i64::MAX as u64)
            .ok_or_else(|| {
                ObservationError::refused(
                    "resourceConflict",
                    "observation generation is exhausted",
                    Some(reference),
                )
            })?;
        let adopted = sources
            .targets
            .adopt_observed_candidate(
                &stable_identity_sha256_for_serial(&relation.serial),
                &reference.candidate,
                &tool_version,
                &(sources.now)(),
                reference,
                &active,
                next,
            )
            .map_err(store_failure)?;
        let names = Self::names(sources.targets, &latest.observations, next)?;
        state.latest = Some(Snapshot {
            generation: next,
            observed_at: latest.observed_at,
            observations: latest.observations,
            names,
        });
        state.last_generation = next;
        if state.receipts.len() >= MAXIMUM_RECEIPTS {
            state.receipts.clear();
        }
        state.receipts.push((reference.clone(), adopted.clone()));
        Ok(adopted)
    }

    fn lock(&self) -> Result<std::sync::MutexGuard<'_, State>, ObservationError> {
        self.state
            .lock()
            .map_err(|_| ObservationError::Failed("the observation state is unavailable".into()))
    }

    /// A reading stamped into the latest snapshot, a followed reference
    /// checked on both sides of it. A failed reading breaks continuity: the
    /// next one mints new identities.
    fn observe(
        state: &mut State,
        sources: &Sources<'_>,
        following: Option<&ObservationReference>,
    ) -> Result<Snapshot, ObservationError> {
        if let Some(reference) = following {
            Self::current(state, reference, true)?;
        }
        if let Err(error) = Self::stamp(state, sources) {
            state.latest = None;
            return Err(error);
        }
        if let Some(reference) = following {
            Self::current(state, reference, true)?;
        }
        state
            .latest
            .clone()
            .ok_or_else(|| ObservationError::Failed("no completed observation snapshot".into()))
    }

    /// Swift `stamp`.
    fn stamp(state: &mut State, sources: &Sources<'_>) -> Result<(), ObservationError> {
        let reading = Reading::take(sources.dispatch, sources.relations)?;
        reading.validate().map_err(|_| {
            ObservationError::refused(
                "operationUnavailable",
                "device snapshot exceeds its bounds",
                None,
            )
        })?;
        let next = state
            .last_generation
            .checked_add(1)
            .filter(|next| *next <= i64::MAX as u64)
            .ok_or_else(|| {
                ObservationError::refused(
                    "recordUnreadable",
                    "observation generation exhausted",
                    None,
                )
            })?;
        let mut observations = Vec::new();
        for row in reading.rows() {
            let previous = state.latest.as_ref().and_then(|latest| {
                latest.observations.iter().find(|held| {
                    row.relation.is_some()
                        && held.relation == row.relation
                        && held.candidate.connect_key == row.candidate.connect_key
                })
            });
            let (observation_id, first_generation) = match previous {
                Some(held) => (held.observation_id.clone(), held.first_generation),
                None => (fresh_observation_id()?, next),
            };
            observations.push(Observation {
                candidate: row.candidate,
                observation_id,
                first_generation,
                relation: row.relation,
            });
        }
        // Unchanged, independently proved facts keep their generation; any
        // change is a new one and expires the candidates' names.
        let changed = state
            .latest
            .as_ref()
            .is_none_or(|latest| latest.observations != observations);
        let generation = match &state.latest {
            Some(latest) if !changed => latest.generation,
            _ => next,
        };
        if changed {
            sources.targets.expire_candidates().map_err(store_failure)?;
        }
        state.last_generation = generation;
        let names = Self::names(sources.targets, &observations, generation)?;
        // Swift's coordinator publishes every completed reading for live
        // route selection (`recordLiveHDCCandidates`).
        let candidates: Vec<_> = observations
            .iter()
            .map(|observation| observation.candidate.clone())
            .collect();
        state.latest = Some(Snapshot {
            generation,
            observed_at: (sources.now)(),
            observations,
            names,
        });
        sources.targets.record_live_candidates(&candidates);
        Ok(())
    }

    fn names(
        targets: &TargetStore,
        observations: &[Observation],
        generation: u64,
    ) -> Result<BTreeMap<String, (Option<String>, u64)>, ObservationError> {
        let references: Vec<ObservationReference> = observations
            .iter()
            .map(|observation| observation.reference(generation))
            .collect();
        targets
            .candidate_display_names(&references)
            .map_err(store_failure)
    }

    /// Swift `current(_:allowNewer:)`.
    fn current<'s>(
        state: &'s State,
        reference: &ObservationReference,
        allow_newer: bool,
    ) -> Result<&'s Observation, ObservationError> {
        let latest = state.latest.as_ref().ok_or_else(|| conflict(reference))?;
        let generation_holds = if allow_newer {
            latest.generation >= reference.generation
        } else {
            latest.generation == reference.generation
        };
        let row = latest
            .observations
            .iter()
            .find(|row| {
                row.observation_id == reference.observation_id
                    && row.candidate.connect_key == reference.candidate
            })
            .filter(|row| {
                reference.generation > 0
                    && generation_holds
                    && row.first_generation <= reference.generation
                    && (!allow_newer
                        || row.relation.is_some()
                        || latest.generation == reference.generation)
            })
            .ok_or_else(|| conflict(reference))?;
        Ok(row)
    }
}

impl Snapshot {
    /// The daemon's `device.observations` answer. A proved row names the
    /// Target its connect key is bound to; a candidate's display name is its
    /// own, never its Target's.
    pub fn answer(&self, targets: &TargetStore) -> Result<Value, ObservationError> {
        let proved: Vec<String> = self
            .observations
            .iter()
            .filter(|observation| observation.relation.is_some())
            .map(|observation| observation.candidate.connect_key.clone())
            .collect();
        let bound = targets
            .candidate_presentations(&proved)
            .map_err(store_failure)?;
        let mut rows = Vec::with_capacity(self.observations.len());
        for observation in &self.observations {
            let Some((name, generation)) = self.names.get(&observation.observation_id) else {
                return Err(ObservationError::refused(
                    "recordUnreadable",
                    "candidate display-name projection is incomplete",
                    None,
                ));
            };
            let target = observation
                .relation
                .as_ref()
                .and_then(|_| bound.get(&observation.candidate.connect_key));
            rows.push(json!({
                "observationId": observation.observation_id,
                "candidateKey": observation.candidate.connect_key,
                "authorizationState": observation.candidate.state,
                "observationContinuity": observation.continuity(),
                "adoptedTargetId": target.map_or(Value::Null, |target| target["targetId"].clone()),
                "bindingRevision": target.map_or(Value::Null, |target| target["bindingRevision"].clone()),
                "displayName": name,
                "displayNameGeneration": generation.to_string(),
                "deviceInformation": null,
                "observedFacts": null,
            }));
        }
        Ok(json!({
            "schemaVersion": "arkdeck.device-observations/1",
            "snapshotGeneration": self.generation.to_string(),
            "observedAtUtc": self.observed_at,
            "health": "current",
            "observations": rows,
        }))
    }
}

/// The daemon's `target.adopt` answer: the Target, and the reference it was
/// adopted from as the request named it.
pub fn adoption_answer(adopted: &Adopted, reference: &ObservationReference) -> Value {
    json!({
        "outcome": "adopted",
        "targetId": adopted.target_id,
        "bindingRevision": adopted.binding_revision,
        "observationId": reference.observation_id,
        "snapshotGeneration": reference.generation.to_string(),
    })
}

/// Swift `targetObservationReference`: exactly `candidate` (1 to 1024
/// bytes), `observationId` (1 to 128 bytes) and a canonical positive
/// `observationGeneration` no greater than `Int64.max`.
pub fn parse_reference(
    params: &Map<String, Value>,
) -> Result<ObservationReference, ObservationError> {
    let invalid = || {
        ObservationError::refused(
            "invalidInput",
            "candidate, observationId and canonical positive observationGeneration are required",
            None,
        )
    };
    let text = |key: &str| params.get(key).and_then(Value::as_str);
    if params.len() != 3 {
        return Err(invalid());
    }
    let (Some(candidate), Some(observation_id), Some(generation)) = (
        text("candidate"),
        text("observationId"),
        text("observationGeneration"),
    ) else {
        return Err(invalid());
    };
    if !(1..=1024).contains(&candidate.len())
        || !(1..=128).contains(&observation_id.len())
        || generation.starts_with('0')
        || !generation.bytes().all(|byte| byte.is_ascii_digit())
    {
        return Err(invalid());
    }
    let generation = generation
        .parse::<u64>()
        .ok()
        .filter(|generation| (1..=i64::MAX as u64).contains(generation))
        .ok_or_else(invalid)?;
    Ok(ObservationReference {
        candidate: candidate.into(),
        observation_id: observation_id.into(),
        generation,
    })
}
