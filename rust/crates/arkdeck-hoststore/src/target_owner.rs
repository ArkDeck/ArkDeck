//! Local Target presentation owner. Binding/alias documents are read-only.
//! Runtime supplies active observation references internally, never through RPC.
use crate::{
    decode_display_names,
    display_names::{Candidate, Document, Record, target_identifier, valid_name},
    target_document::TargetDocument,
};
use arkdeck_contract::WireError;
use arkdeck_platform::{DocumentPublishError, HostDirectory};
use serde_json::{Map, Value, json};
use std::{
    collections::BTreeMap,
    io,
    path::{Path, PathBuf},
};
const NAMES: &str = "target-display-names.json";
const LOCK: &str = ".target-display-names.lock";
const MAX: usize = 512 * 1024;
const TARGETS: &str = "targets.json";
const TARGETS_MAX: usize = 4 * 1024 * 1024;

/// A document an owner transaction publishes, in its order.
enum Publication {
    Names(Document),
    Targets(Vec<u8>),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ObservationReference {
    pub candidate: String,
    pub observation_id: String,
    pub generation: u64,
}
fn same_text(a: &str, b: &str) -> bool {
    matches!((crate::canonical_host_text(a),crate::canonical_host_text(b)),(Ok(a),Ok(b)) if a==b)
}
impl ObservationReference {
    fn same_reference(&self, other: &Self) -> bool {
        self.generation == other.generation
            && same_text(&self.candidate, &other.candidate)
            && same_text(&self.observation_id, &other.observation_id)
    }
}
/// Swift `liveHDCCandidateObservation`: the last provider-verified candidate
/// list, each key and state, and when it was read.
type LiveCandidates = Option<(Vec<(String, String)>, std::time::Instant)>;
pub struct TargetStore {
    path: PathBuf,
    root: HostDirectory,
    live: std::sync::Mutex<LiveCandidates>,
    /// Swift's engine `mutationLane`: each Target's device mutation lane,
    /// which every run, finalization and cleanup retry through a composition
    /// over this owner shares (`device_lane.rs`).
    lanes: crate::device_lane::DeviceMutationLanes,
}
/// The Target a binding lineage advance left, and whether it moved.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct AdvancedTarget {
    pub(crate) target_id: String,
    pub(crate) identity_sha256: String,
    pub(crate) binding_revision: u64,
    pub(crate) updated: bool,
}
/// Swift `routeObservationFreshnessSeconds`.
const ROUTE_OBSERVATION_FRESHNESS: std::time::Duration = std::time::Duration::from_secs(5);
/// Swift `RuntimeTargetHDCRoute`: where an adopted Target's HDC commands go.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct HdcRoute {
    pub(crate) target_id: String,
    pub(crate) binding_revision: u64,
    pub(crate) tool_version: String,
    pub(crate) connect_key: String,
}
pub(super) fn failure(code: &str, message: &str, phase: &str) -> WireError {
    WireError {
        code: code.into(),
        message: message.into(),
        details: (!phase.is_empty()).then(|| {
            Map::from_iter([
                ("phase".into(), json!(phase)),
                ("newDispatchCount".into(), json!(0)),
            ])
        }),
    }
}
fn unreadable(phase: &str) -> WireError {
    failure(
        "recordUnreadable",
        "Target presentation storage is unreadable or unsafe",
        phase,
    )
}
fn positive(text: &str) -> Option<u64> {
    text.parse::<u64>()
        .ok()
        .filter(|n| (1..=i64::MAX as u64).contains(n) && n.to_string() == text)
}
fn empty_names() -> Document {
    Document {
        schema_version: "arkdeck.target-display-names/1".into(),
        records: Vec::new(),
        candidates: None,
    }
}
/// Swift `stageCandidateAdoption`: the adopted observation's exact
/// candidate name handed to its Target before the binding becomes visible,
/// unless the Target already has a name; repeating the exact stage changes
/// nothing. Whether the names changed.
fn stage_candidate_adoption(
    names: &mut Document,
    reference: &ObservationReference,
    target_id: &str,
    now: &str,
) -> Result<bool, WireError> {
    let Some(index) = names
        .candidates
        .as_deref()
        .unwrap_or_default()
        .iter()
        .position(|record| {
            record.candidate == reference.candidate
                && record.observation_id == reference.observation_id
        })
    else {
        return Ok(false);
    };
    let candidate = names.candidates.as_deref().unwrap_or_default()[index].clone();
    if candidate.generation != reference.generation {
        return Err(failure(
            "resourceConflict",
            "candidate display-name generation changed",
            "",
        ));
    }
    if let (Some(staged), Some(generation)) = (
        candidate.staged_target_id.as_deref(),
        candidate.staged_target_generation,
    ) {
        let consistent = staged == target_id
            && names.records.iter().any(|record| {
                record.target_id == target_id
                    && record.generation == generation
                    && record.name.as_deref() == Some(candidate.name.as_str())
            });
        if !consistent {
            return Err(failure(
                "recordUnreadable",
                "candidate display-name migration stage is inconsistent",
                "",
            ));
        }
        return Ok(false);
    }
    // A durable Target name outranks an observation-scoped one.
    if names
        .records
        .iter()
        .any(|record| record.target_id == target_id && record.name.is_some())
    {
        return Ok(false);
    }
    let current = names
        .records
        .iter()
        .find(|record| record.target_id == target_id)
        .map_or(1, |record| record.generation);
    let next = current
        .checked_add(1)
        .filter(|next| *next <= i64::MAX as u64)
        .ok_or_else(|| {
            failure(
                "resourceConflict",
                "target display-name generation is exhausted",
                "",
            )
        })?;
    if !crate::format_time::valid_format_timestamp(now) {
        return Err(unreadable(""));
    }
    let record = Record {
        target_id: target_id.into(),
        generation: next,
        name: Some(candidate.name.clone()),
        updated_at: now.into(),
    };
    if let Some(held) = names
        .records
        .iter_mut()
        .find(|held| held.target_id == target_id)
    {
        *held = record;
    } else {
        if names.records.len() >= 4096 {
            return Err(failure(
                "quotaExceeded",
                "target display-name resource count exceeds its bound",
                "",
            ));
        }
        names.records.push(record);
    }
    if let Some(candidates) = names.candidates.as_mut() {
        candidates[index].staged_target_id = Some(target_id.into());
        candidates[index].staged_target_generation = Some(next);
    }
    Ok(true)
}
/// Swift `finishCandidateAdoption`: the adopted observation's name and
/// every inactive one dropped, the others carried into the next generation
/// with any stage cleared.
fn finish_candidate_adoption(
    names: &mut Document,
    reference: &ObservationReference,
    active: &[ObservationReference],
    next_generation: u64,
) -> Result<(), WireError> {
    let records = names.candidates.take().unwrap_or_default();
    let is_active = |record: &Candidate| {
        active.iter().any(|held| {
            same_text(&held.candidate, &record.candidate)
                && same_text(&held.observation_id, &record.observation_id)
        })
    };
    if records
        .iter()
        .any(|record| is_active(record) && record.generation != reference.generation)
    {
        return Err(failure(
            "resourceConflict",
            "candidate display-name generation changed",
            "",
        ));
    }
    names.candidates = Some(
        records
            .into_iter()
            .filter(|record| {
                is_active(record)
                    && !(record.candidate == reference.candidate
                        && record.observation_id == reference.observation_id)
            })
            .map(|mut record| {
                record.generation = next_generation;
                record.staged_target_id = None;
                record.staged_target_generation = None;
                record
            })
            .collect(),
    );
    Ok(())
}
fn target_name(doc: &Document, id: &str) -> Value {
    doc.records.iter().find(|r| r.target_id == id).map_or_else(|| json!({"schemaVersion":"arkdeck.target-display-name/1","targetId":id,"generation":"1","name":null,"updatedAtUtc":null}), |r| json!({"schemaVersion":"arkdeck.target-display-name/1","targetId":id,"generation":r.generation.to_string(),"name":r.name,"updatedAtUtc":r.updated_at}))
}
impl TargetStore {
    pub fn open(path: &Path) -> io::Result<Self> {
        let owner = Self {
            path: path.to_owned(),
            root: HostDirectory::open(path)?,
            live: std::sync::Mutex::new(None),
            lanes: Default::default(),
        };
        owner
            .transaction("targetDisplayNameOwner", |targets, names| {
                let active = targets.active_ids();
                let before = serde_json::to_value(&*names)
                    .map_err(|_| unreadable("targetDisplayNameOwner"))?;
                names.records.retain(|r| active.contains(&r.target_id));
                names.candidates = Some(Vec::new());
                let changed = before
                    != serde_json::to_value(&*names)
                        .map_err(|_| unreadable("targetDisplayNameOwner"))?;
                Ok((Value::Null, changed))
            })
            .map_err(|e| io::Error::other(e.message))?;
        Ok(owner)
    }
    fn transaction(
        &self,
        phase: &str,
        action: impl FnOnce(&TargetDocument, &mut Document) -> Result<(Value, bool), WireError>,
    ) -> Result<Value, WireError> {
        self.publishing(phase, |targets, names| {
            let (value, write) = action(targets, names)?;
            let publications = if write {
                vec![Publication::Names(names.clone())]
            } else {
                Vec::new()
            };
            Ok((value, publications))
        })
    }
    /// Both documents read under both locks, `action` run over them, then
    /// each publication it names made in its order, the namespace checked
    /// before and after each. Each lock is waited for, as Swift's `persist`
    /// and display-name owner block in `flock(LOCK_EX)`: another thread's
    /// transaction, or another owner's of this directory, delays this one
    /// rather than refusing it. So `action` never starts another transaction
    /// here; it would wait for itself.
    fn publishing(
        &self,
        phase: &str,
        action: impl FnOnce(
            &mut TargetDocument,
            &mut Document,
        ) -> Result<(Value, Vec<Publication>), WireError>,
    ) -> Result<Value, WireError> {
        self.root
            .validate_path(&self.path)
            .map_err(|_| unreadable(phase))?;
        let target_lock = self
            .root
            .wait_lock(".targets.lock", false)
            .map_err(|_| unreadable(phase))?;
        let names_lock = self
            .root
            .wait_lock(LOCK, false)
            .map_err(|_| unreadable(phase))?;
        let mut targets = match self.root.read(TARGETS, TARGETS_MAX) {
            Ok(bytes) => TargetDocument::decode(&bytes).map_err(|_| unreadable(phase))?,
            Err(e) if e.kind() == io::ErrorKind::NotFound => TargetDocument::empty(),
            Err(_) => return Err(unreadable(phase)),
        };
        let mut names = match self.root.read(NAMES, MAX) {
            Ok(bytes) => {
                let decoded = decode_display_names(&bytes).map_err(|_| unreadable(phase))?;
                serde_json::from_slice(&decoded.document).map_err(|_| unreadable(phase))?
            }
            Err(e) if e.kind() == io::ErrorKind::NotFound => empty_names(),
            Err(_) => return Err(unreadable(phase)),
        };
        let (value, publications) = action(&mut targets, &mut names)?;
        self.root
            .validate_path(&self.path)
            .map_err(|_| unreadable(phase))?;
        target_lock
            .validate_link(&self.root, ".targets.lock")
            .map_err(|_| unreadable(phase))?;
        names_lock
            .validate_link(&self.root, LOCK)
            .map_err(|_| unreadable(phase))?;
        for publication in publications {
            match publication {
                Publication::Names(mut names) => {
                    names.records.sort_by(|a, b| a.target_id.cmp(&b.target_id));
                    if let Some(candidates) = names.candidates.as_mut() {
                        candidates.sort_by(|a, b| {
                            if same_text(&a.candidate, &b.candidate) {
                                a.observation_id.cmp(&b.observation_id)
                            } else {
                                a.candidate.cmp(&b.candidate)
                            }
                        });
                    }
                    let bytes = serde_json::to_vec(&names).map_err(|_| unreadable(phase))?;
                    if bytes.len() >= MAX {
                        return Err(failure(
                            "quotaExceeded",
                            "Display-name storage exceeds its bound",
                            phase,
                        ));
                    }
                    let validated = decode_display_names(&bytes).map_err(|_| unreadable(phase))?;
                    self.root.publish_document(NAMES, &validated.document, MAX).map_err(|e| match e {
                        DocumentPublishError::BeforePublication(_) => failure("ioFailure", "Display-name update could not be written", phase),
                        DocumentPublishError::OutcomeUnknown(_) => failure("outcomeUnknown", "Display-name publication is unconfirmed; read current state before another update", phase),
                    })?;
                }
                Publication::Targets(bytes) => {
                    self.root.publish_document(TARGETS, &bytes, TARGETS_MAX).map_err(|e| match e {
                        DocumentPublishError::BeforePublication(_) => failure("ioFailure", "Target binding update could not be written", phase),
                        DocumentPublishError::OutcomeUnknown(_) => failure("outcomeUnknown", "Target binding publication is unconfirmed; read current state before another update", phase),
                    })?;
                }
            }
            if self.root.validate_path(&self.path).is_err()
                || names_lock.validate_link(&self.root, LOCK).is_err()
                || target_lock
                    .validate_link(&self.root, ".targets.lock")
                    .is_err()
            {
                return Err(failure(
                    "outcomeUnknown",
                    "Target namespace changed during publication",
                    phase,
                ));
            }
        }
        Ok(value)
    }
    /// Swift `candidateDisplayNames(references:)`: each observation's
    /// candidate name, which counts only in the generation it was named in;
    /// otherwise none, in the reference's generation.
    pub(crate) fn candidate_display_names(
        &self,
        references: &[ObservationReference],
    ) -> Result<BTreeMap<String, (Option<String>, u64)>, WireError> {
        let mut resolved = BTreeMap::new();
        self.transaction("", |_, names| {
            let records = names.candidates.as_deref().unwrap_or_default();
            for reference in references {
                let name = records
                    .iter()
                    .find(|record| {
                        record.candidate == reference.candidate
                            && record.observation_id == reference.observation_id
                            && record.generation == reference.generation
                    })
                    .map(|record| record.name.clone());
                resolved.insert(
                    reference.observation_id.clone(),
                    (name, reference.generation),
                );
            }
            Ok((Value::Null, false))
        })?;
        Ok(resolved)
    }
    /// Swift `RuntimeTargetStore.adoptObservedCandidate`: the adopted
    /// identity's Target, materialized in the binding document; the adopted
    /// observation's candidate name staged onto it, the binding published
    /// only for a new Target, then the candidate names finished into the
    /// next observation generation — in Swift's order, under both locks.
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn adopt_observed_candidate(
        &self,
        identity: &str,
        connect_key: &str,
        tool_version: &str,
        now: &str,
        reference: &ObservationReference,
        active: &[ObservationReference],
        next_generation: u64,
    ) -> Result<crate::target_observation::Adopted, WireError> {
        let mut adopted = None;
        self.publishing("", |targets, names| {
            let (record, created) = targets
                .materialize_adoption(identity, connect_key, tool_version, now)
                .map_err(|message| failure("internalError", &message, ""))?;
            let mut publications = Vec::new();
            if stage_candidate_adoption(names, reference, &record.target_id, now)? {
                publications.push(Publication::Names(names.clone()));
            }
            if created {
                publications.push(Publication::Targets(
                    targets.encode().map_err(|_| unreadable(""))?,
                ));
            }
            finish_candidate_adoption(names, reference, active, next_generation)?;
            publications.push(Publication::Names(names.clone()));
            adopted = Some(crate::target_observation::Adopted {
                target_id: record.target_id,
                binding_revision: record.binding_revision,
            });
            Ok((Value::Null, publications))
        })?;
        adopted.ok_or_else(|| unreadable(""))
    }
    /// Resolve only existing durable Target authority for a new Import intent.
    /// No wire input supplies a binding, route, observation or inspected fact.
    pub fn resolve_import_binding(
        &self,
        intent: &arkdeck_contract::ImportIntent,
    ) -> Result<crate::ImportBinding, WireError> {
        let phase = "importOwner";
        intent
            .validate()
            .map_err(|_| failure("invalidInput", "Invalid Import intent", phase))?;
        let live = self.fresh_live_candidates();
        let mut binding = None;
        self.transaction(phase, |document, _| {
            let target = document
                .targets
                .iter()
                .find(|target| {
                    target.target_id == intent.target_id
                        && target.binding_revision == intent.binding_revision
                })
                .ok_or_else(|| {
                    failure(
                        "resourceConflict",
                        "The exact Target binding is no longer current",
                        phase,
                    )
                })?;
            let mut resolved = crate::ImportBinding {
                target_id: target.target_id.clone(),
                binding_revision: None,
                stable_identity_sha256: None,
            };
            match intent.kind.as_str() {
                "workspace-patch" => {}
                "flash-bundle" => {
                    resolved.binding_revision = Some(target.binding_revision);
                    resolved.stable_identity_sha256 = Some(target.identity.clone());
                }
                "hap" | "native-library" => {
                    // Swift binds the Import to the Target's current proven HDC
                    // route (`hdcExecutionRoute`): the adopted key, or through a
                    // proven post-Flash alias the key a fresh observation shows
                    // Connected, else the alias's. The Import names the identity
                    // that key names (`HDCObservationProviderAdapter
                    // .stableIdentitySHA256`): the digest of the key lowercased,
                    // as the Target's device facts and a Job's plan name it.
                    // Physical identity is not this hash. A route Swift cannot
                    // resolve falls to its handler's unreadable refusal.
                    let key = match document.hdc_route(&target.target_id, live.as_deref()) {
                        Ok(Some((routed, key)))
                            if routed.binding_revision == target.binding_revision =>
                        {
                            key
                        }
                        Ok(_) => {
                            return Err(failure(
                                "resourceConflict",
                                "Import requires the target's current proven HDC route",
                                phase,
                            ));
                        }
                        Err(_) => {
                            return Err(failure(
                                "recordUnreadable",
                                "Import state or immutable content is unreadable",
                                phase,
                            ));
                        }
                    };
                    resolved.binding_revision = Some(target.binding_revision);
                    resolved.stable_identity_sha256 =
                        Some(arkdeck_provider_hdc::stable_identity_sha256(&key));
                }
                _ => return Err(failure("invalidInput", "Invalid Import kind", phase)),
            }
            binding = Some(resolved);
            Ok((Value::Null, false))
        })?;
        binding.ok_or_else(|| unreadable(phase))
    }
    /// Swift `recordLiveHDCCandidates`: one provider-verified candidate list
    /// for live route selection, memory-only and fresh for five seconds. It
    /// cannot create, rewrite or widen a Target or an alias.
    pub(crate) fn record_live_candidates(
        &self,
        candidates: &[arkdeck_provider_hdc::DeviceCandidate],
    ) {
        if let Ok(mut live) = self.live.lock() {
            *live = Some((
                candidates
                    .iter()
                    .map(|candidate| (candidate.connect_key.clone(), candidate.state.clone()))
                    .collect(),
                std::time::Instant::now(),
            ));
        }
    }

    /// The live candidate list while it is fresh.
    fn fresh_live_candidates(&self) -> Option<Vec<(String, String)>> {
        let live = self.live.lock().ok()?;
        let (candidates, observed_at) = live.as_ref()?;
        (observed_at.elapsed() <= ROUTE_OBSERVATION_FRESHNESS).then(|| candidates.clone())
    }

    /// Swift `RuntimeTargetStore.hdcExecutionRoute`: the canonical record's
    /// target, revision and tool version, and the connect key its HDC
    /// commands use (`TargetDocument::hdc_route`: the adopted key, or through
    /// a proven post-Flash alias the key a fresh observation shows Connected,
    /// else the alias's), or none for a Target never adopted.
    pub(crate) fn hdc_route(&self, target_id: &str) -> Result<Option<HdcRoute>, String> {
        let live = self.fresh_live_candidates();
        let mut route = Err("the HDC execution route could not be read".to_owned());
        self.transaction("", |document, _| {
            route = document.hdc_route(target_id, live.as_deref()).map(|found| {
                found.map(|(target, connect_key)| HdcRoute {
                    target_id: target.target_id.clone(),
                    binding_revision: target.binding_revision,
                    tool_version: target.tool_version.clone(),
                    connect_key,
                })
            });
            Ok((Value::Null, false))
        })
        .map_err(|error| error.message)?;
        route
    }

    /// The key of the mutation lane a request naming `target_id` runs in:
    /// its Target, or the canonical Target a proven post-Flash alias was
    /// merged into (`TargetDocument::mutation_lane_target`). Swift keys its
    /// lane by the name alone, so a canonical Target and its alias — one
    /// device — would not wait for each other there.
    pub fn mutation_lane_key(&self, target_id: &str) -> Result<String, String> {
        if !target_identifier(target_id) {
            return Err("the request names no Target".into());
        }
        let mut key = Err("the Target document could not be read".to_owned());
        self.transaction("", |document, _| {
            key = document.mutation_lane_target(target_id);
            Ok((Value::Null, false))
        })
        .map_err(|error| error.message)?;
        key
    }

    /// Swift `DeviceMutationLaneCoordinator.withMutationLane`'s acquisition
    /// for `holder` in the lane of the Target `target_id` names: at once, or
    /// once every earlier request has let go of it, the guard holding it
    /// until dropped. `abandon`, asked while the request waits, ends the
    /// wait without the lane (`None`). The refusal says why no lane was
    /// held or awaited: no Target, an unreadable Target document, or a
    /// holder that already holds or awaits one.
    ///
    /// Lock order: the lane's key is read in a Target transaction of its
    /// own, which has ended — both Target locks let go of — before the wait
    /// begins, so no Target lock is ever held while a lane is awaited, and no
    /// transaction's closure calls this. A holder takes Target transactions
    /// inside its lane: the lane first, the transactions after.
    pub fn enter_mutation_lane(
        &self,
        target_id: &str,
        holder: &str,
        abandon: Option<&dyn Fn() -> bool>,
    ) -> Result<Option<crate::MutationLane<'_>>, String> {
        let key = self.mutation_lane_key(target_id)?;
        self.lanes
            .enter(&key, holder, abandon)
            .map_err(|refusal| refusal.to_string())
    }

    /// Where `holder` stands in the mutation lane `key`
    /// ([`Self::mutation_lane_key`]): holding it, waiting for it, or neither.
    /// Only memory is read.
    pub fn mutation_lane_state(&self, key: &str, holder: &str) -> Option<crate::LaneState> {
        self.lanes.state(key, holder)
    }

    /// Who waits for the mutation lane `key`, first in line first. Only
    /// memory is read.
    pub fn mutation_lane_queue(&self, key: &str) -> Vec<String> {
        self.lanes.queue(key)
    }
    pub fn handle(
        &self,
        method: &str,
        params: &Map<String, Value>,
        now: &str,
    ) -> Result<Value, WireError> {
        let write = matches!(
            method,
            "target.display-name.set" | "target.display-name.clear"
        );
        let phase = if write { "targetDisplayNameOwner" } else { "" };
        let keys: &[&str] = match method {
            "target.list" => &[],
            "target.show" => &["targetId"],
            "target.display-name.set" => &["targetId", "expectedGeneration", "name"],
            "target.display-name.clear" => &["targetId", "expectedGeneration"],
            _ => {
                return Err(failure(
                    "unknownMethod",
                    "Not a Target presentation method",
                    phase,
                ));
            }
        };
        if params.len() != keys.len()
            || keys
                .iter()
                .any(|k| !params.get(*k).is_some_and(Value::is_string))
        {
            return Err(failure(
                "invalidParams",
                "Target method requires its exact typed parameters",
                phase,
            ));
        }
        let id = params.get("targetId").and_then(Value::as_str).unwrap_or("");
        if method != "target.list" && !target_identifier(id) {
            return Err(failure(
                "invalidParams",
                "Target identity must be a bounded identifier",
                phase,
            ));
        }
        let expected = if write {
            positive(params["expectedGeneration"].as_str().unwrap()).ok_or_else(|| {
                failure(
                    "invalidParams",
                    "expectedGeneration must be canonical and positive",
                    phase,
                )
            })?
        } else {
            0
        };
        let name = params.get("name").and_then(Value::as_str);
        if name.is_some_and(|n| !valid_name(n)) {
            return Err(failure(
                "invalidInput",
                "Display name must be nonblank bounded text",
                phase,
            ));
        }
        self.transaction(phase, |targets, names| {
            let active = targets.active_ids();
            if method == "target.list" {
                let rows: Vec<_> = targets.targets.iter().filter(|t| active.contains(&t.target_id)).map(|t| {
                    let name = target_name(names, &t.target_id);
                    json!({"targetId":t.target_id,"bindingRevision":t.binding_revision,"toolVersion":t.tool_version,"adoptedAtUtc":t.adopted_at,"displayName":name["name"],"displayNameGeneration":name["generation"]})
                }).collect();
                return Ok((json!(rows), false));
            }
            let target = targets.targets.iter().find(|t| t.target_id == id).ok_or_else(|| failure(if write {"resourceNotFound"} else {"notFound"}, "Durable target does not exist", phase))?;
            let current = target_name(names, id);
            if !write { return Ok((json!({"schemaVersion":"arkdeck.target/1","targetId":id,"stablePhysicalIdentitySha256":target.identity,"bindingRevision":target.binding_revision,"connectKey":target.connect_key,"toolVersion":target.tool_version,"adoptedAtUtc":target.adopted_at,"displayName":current["name"],"displayNameGeneration":current["generation"],"live":null,"observedFacts":null}), false)); }
            if !active.contains(id) { return Err(failure("resourceNotFound", "Durable target is an inactive alias", phase)); }
            let generation = positive(current["generation"].as_str().unwrap()).ok_or_else(|| unreadable(phase))?;
            if generation != expected || generation == i64::MAX as u64 { return Err(failure("resourceConflict", "Target display-name generation changed or is exhausted", phase)); }
            if !crate::format_time::valid_format_timestamp(now) { return Err(unreadable(phase)); }
            let record = Record { target_id: id.into(), generation: generation + 1, name: name.map(str::to_owned), updated_at: now.into() };
            if let Some(row) = names.records.iter_mut().find(|r| r.target_id == id) { *row = record; }
            else { if names.records.len() >= 4096 { return Err(failure("quotaExceeded", "Target display-name count exceeds its bound", phase)); } names.records.push(record); }
            Ok((target_name(names,id),true))
        })
    }
    /// Swift `RuntimeTargetStore.hasConflictingHDCAliasOwner(canonicalTargetID:
    /// connectKey:identitySHA256:establishingFlashJobID:)`: whether another
    /// adopted Target owns a verified post-flash alias's connect key or
    /// identity, refused as Swift's `storeFailure` when the query or the
    /// canonical Target is not exact.
    pub fn has_conflicting_hdc_alias_owner(
        &self,
        canonical: &str,
        connect_key: &str,
        identity: &str,
        establishing_job: &str,
    ) -> Result<bool, String> {
        let store_failure =
            |detail: &str| format!("storeFailure({})", crate::strict_json::swift_quoted(detail));
        if canonical.is_empty()
            || connect_key.is_empty()
            || !crate::target_document::sha(identity)
            || arkdeck_contract::sha256_hex(connect_key.as_bytes()) != identity
            || establishing_job.is_empty()
        {
            return Err(store_failure("invalid HDC alias ownership query"));
        }
        let mut answer = None;
        self.transaction("", |targets, _| {
            answer = targets.has_conflicting_hdc_alias_owner(canonical, connect_key, identity);
            Ok((Value::Null, false))
        })
        .map_err(|error| store_failure(&format!("undecodable target store: {}", error.message)))?;
        answer.ok_or_else(|| {
            store_failure("canonical target for HDC alias ownership is missing or ambiguous")
        })
    }
    /// Swift `RuntimeTargetStore.list()`: every durable Target record,
    /// aliases included, in stored order, as its document spells it.
    pub fn records(&self) -> Result<Vec<Value>, WireError> {
        self.transaction("", |targets, _| {
            Ok((
                serde_json::to_value(&targets.targets).map_err(|_| unreadable(""))?,
                false,
            ))
        })
        .map(|value| value.as_array().cloned().unwrap_or_default())
    }

    /// Swift `RuntimeTargetStore.advanceBindingLineage(_:)`: the adjacent
    /// lineage edge a published Loader binding drew, applied to the binding
    /// document under both locks and published only when it changed it. A
    /// refusal is Swift's rendered `storeFailure`; a document this store cannot
    /// read or publish is refused in the same case, with this store's detail.
    pub(crate) fn advance_binding_lineage(
        &self,
        advance: &crate::rockchip_binding::LineageAdvance,
    ) -> Result<AdvancedTarget, String> {
        let mut advanced = None;
        self.publishing("", |targets, _| {
            let (record, updated) =
                targets
                    .advance_binding_lineage(advance)
                    .map_err(|refusal| WireError {
                        code: "storeFailure".into(),
                        message: refusal,
                        details: None,
                    })?;
            let publications = if updated {
                vec![Publication::Targets(
                    targets.encode().map_err(|_| unreadable(""))?,
                )]
            } else {
                Vec::new()
            };
            advanced = Some(AdvancedTarget {
                target_id: record.target_id,
                identity_sha256: record.identity,
                binding_revision: record.binding_revision,
                updated,
            });
            Ok((Value::Null, publications))
        })
        .map_err(|error| match error.code.as_str() {
            "storeFailure" => error.message,
            "recordUnreadable" => format!(
                "storeFailure({})",
                crate::strict_json::swift_quoted(&format!(
                    "undecodable target store: {}",
                    error.message
                ))
            ),
            _ => format!(
                "storeFailure({})",
                crate::strict_json::swift_quoted(&format!(
                    "cannot persist target store: {}",
                    error.message
                ))
            ),
        })?;
        advanced.ok_or_else(|| "storeFailure(\"invalid target binding lineage advance\")".into())
    }

    /// The durable alias relation `ProductRockchipTargetAliasReconciler`
    /// reuses: the one whose identity-bearing members all match `draft`.
    pub(crate) fn matching_alias_resolution(
        &self,
        draft: &crate::target_document::AliasResolutionDraft,
    ) -> Result<Option<crate::target_document::AliasResolutionName>, String> {
        let mut found = None;
        self.transaction("", |targets, _| {
            found = targets.matching_alias_resolution(draft);
            Ok((Value::Null, false))
        })
        .map_err(|error| {
            format!(
                "storeFailure({})",
                crate::strict_json::swift_quoted(&format!(
                    "undecodable target store: {}",
                    error.message
                ))
            )
        })?;
        Ok(found)
    }

    /// Swift `RuntimeTargetStore.appendAliasResolution(_:)`: the proven
    /// relation appended to the binding document under both locks, published
    /// only when it was not already there. A refusal is Swift's rendered
    /// `storeFailure`.
    pub(crate) fn append_alias_resolution(
        &self,
        draft: &crate::target_document::AliasResolutionDraft,
    ) -> Result<crate::target_document::AliasResolutionName, String> {
        let mut appended = None;
        self.publishing("", |targets, _| {
            let (name, changed) =
                targets
                    .append_alias_resolution(draft)
                    .map_err(|refusal| WireError {
                        code: "storeFailure".into(),
                        message: refusal,
                        details: None,
                    })?;
            appended = Some(name);
            let publications = if changed {
                vec![Publication::Targets(
                    targets.encode().map_err(|_| unreadable(""))?,
                )]
            } else {
                Vec::new()
            };
            Ok((Value::Null, publications))
        })
        .map_err(|error| match error.code.as_str() {
            "storeFailure" => error.message,
            "recordUnreadable" => format!(
                "storeFailure({})",
                crate::strict_json::swift_quoted(&format!(
                    "undecodable target store: {}",
                    error.message
                ))
            ),
            _ => format!(
                "storeFailure({})",
                crate::strict_json::swift_quoted(&format!(
                    "cannot persist target store: {}",
                    error.message
                ))
            ),
        })?;
        appended.ok_or_else(|| {
            "storeFailure(\"target alias resolution lacks exact identity, history or postflight \
             proof\")"
                .into()
        })
    }

    /// Presentation lookup from provider-observed addresses. This does not select
    /// an execution route or establish freshness/physical continuity.
    pub fn candidate_presentations(&self, keys: &[String]) -> Result<Value, WireError> {
        if keys.len() > 1000 {
            return Err(failure(
                "recordUnreadable",
                "Candidate snapshot exceeds its bound",
                "",
            ));
        }
        self.transaction("", |targets, names| {
            let mut result=Map::new();
            for key in keys { if let Some(target)=targets.candidate_target(key) {
                let name=target_name(names,&target.target_id);
                result.insert(key.clone(),json!({"targetId":target.target_id,"bindingRevision":target.binding_revision,"displayName":name["name"],"displayNameGeneration":name["generation"]}));
            } }
            Ok((Value::Object(result),false))
        })
    }
    pub fn expire_candidates(&self) -> Result<(), WireError> {
        self.transaction("candidateDisplayNameOwner", |_, names| {
            let write = names.candidates.as_ref().is_some_and(|c| !c.is_empty());
            names.candidates = Some(Vec::new());
            Ok((Value::Null, write))
        })
        .map(|_| ())
    }
    /// Runtime-owned observation references are supplied by the in-memory coordinator.
    /// Only the requested reference and text originate from the caller.
    pub fn mutate_candidate(
        &self,
        reference: &ObservationReference,
        active: &[ObservationReference],
        name: Option<&str>,
        now: &str,
    ) -> Result<Value, WireError> {
        let phase = "candidateDisplayNameOwner";
        if !(1..=1024).contains(&reference.candidate.len())
            || !(1..=128).contains(&reference.observation_id.len())
            || reference.generation == 0
            || name.is_some_and(|n| !valid_name(n))
        {
            return Err(failure(
                "invalidInput",
                "Candidate name requires exact bounded observation and text",
                phase,
            ));
        }
        let next = reference
            .generation
            .checked_add(1)
            .filter(|n| *n <= i64::MAX as u64)
            .ok_or_else(|| {
                failure(
                    "resourceConflict",
                    "Observation generation is exhausted",
                    phase,
                )
            })?;
        if active.len() > 4096
            || !active.iter().any(|r| r.same_reference(reference))
            || active.iter().any(|r| r.generation != reference.generation)
            || active
                .iter()
                .map(|r| &r.observation_id)
                .collect::<std::collections::BTreeSet<_>>()
                .len()
                != active.len()
        {
            return Err(failure(
                "resourceConflict",
                "Candidate observation is no longer current",
                phase,
            ));
        }
        if !crate::format_time::valid_format_timestamp(now) {
            return Err(unreadable(phase));
        }
        self.transaction(phase, |targets, names| {
            if targets.candidate_target(&reference.candidate).is_some() { return Err(failure("resourceConflict", "Candidate is already adopted; use its durable target", phase)); }
            let mut rows = names.candidates.take().unwrap_or_default();
            let is_active = |r: &Candidate| active.iter().any(|a| same_text(&a.candidate,&r.candidate) && same_text(&a.observation_id,&r.observation_id));
            if rows.iter().any(|r| is_active(r) && r.generation != reference.generation) { return Err(failure("resourceConflict", "Candidate display-name generation changed", phase)); }
            rows.retain(|r| is_active(r) && !(same_text(&r.candidate,&reference.candidate) && same_text(&r.observation_id,&reference.observation_id)));
            for r in &mut rows { r.generation = next; r.staged_target_id = None; r.staged_target_generation = None; }
            if let Some(name) = name {
                if rows.len() >= 4096 { return Err(failure("quotaExceeded", "Candidate display-name count exceeds its bound", phase)); }
                rows.push(Candidate { candidate: reference.candidate.clone(), observation_id: reference.observation_id.clone(), generation: next, name: name.into(), updated_at: now.into(), staged_target_id: None, staged_target_generation: None });
            }
            names.candidates = Some(rows);
            Ok((json!({"schemaVersion":"arkdeck.candidate-display-name/1","candidateKey":reference.candidate,"observationId":reference.observation_id,"generation":next.to_string(),"name":name,"updatedAtUtc":now}),true))
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        fs,
        os::unix::fs::{DirBuilderExt, PermissionsExt, symlink},
        sync::{Arc, Barrier},
    };
    const NOW: &str = "2026-09-12T00:00:00Z";
    struct Root(PathBuf);
    impl Root {
        fn new() -> Self {
            let path = std::env::temp_dir().canonicalize().unwrap().join(format!(
                "target-owner-{:x}",
                u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap())
            ));
            fs::DirBuilder::new().mode(0o700).create(&path).unwrap();
            Self(path)
        }
        fn write(&self, name: &str, value: &Value) {
            let path = self.0.join(name);
            fs::write(&path, serde_json::to_vec(value).unwrap()).unwrap();
            fs::set_permissions(path, fs::Permissions::from_mode(0o600)).unwrap();
        }
        fn targets(&self) {
            self.write("targets.json",&json!({"schemaVersion":"1.0.0","targets":[{"targetID":"target-fixture","stablePhysicalIdentitySHA256":"a".repeat(64),"bindingRevision":1,"connectKey":"fixture-address","toolVersion":"fixture-tool","adoptedAtUTC":NOW}]}));
        }
        fn open(&self) -> TargetStore {
            TargetStore::open(&self.0).unwrap()
        }
    }
    impl Drop for Root {
        fn drop(&mut self) {
            fs::remove_dir_all(&self.0).unwrap();
        }
    }
    /// Swift's own output for a canonical Target with a proven post-Flash
    /// alias (`import-target-current/alias`): TGT-8b3d0a34cf32 at revision 2
    /// adopted as `original-hdc-address`, its alias `post-flash-hdc-address`.
    fn alias_root() -> Root {
        let root = Root::new();
        let source = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../tests/fixtures/import-target-current/alias");
        for name in ["targets.json", "target-display-names.json"] {
            let path = root.0.join(name);
            fs::copy(source.join(name), &path).unwrap();
            fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
        }
        root
    }
    const CANONICAL: &str = "TGT-8b3d0a34cf32";
    /// The alias the post-Flash resolution merged into [`CANONICAL`].
    const ALIAS: &str = "TGT-815c2c2e87c5";
    /// A Job naming a post-Flash alias waits in its canonical Target's lane:
    /// one device, whichever name a request uses (Swift keys by the name).
    #[test]
    fn a_proven_alias_shares_its_canonical_targets_mutation_lane() {
        let root = alias_root();
        let owner = root.open();
        assert_eq!(owner.mutation_lane_key(ALIAS).as_deref(), Ok(CANONICAL));
        assert_eq!(owner.mutation_lane_key(CANONICAL).as_deref(), Ok(CANONICAL));
        // A Target nobody adopted names its own lane.
        assert_eq!(
            owner.mutation_lane_key("TGT-000000000000").as_deref(),
            Ok("TGT-000000000000")
        );
        assert!(owner.mutation_lane_key("").is_err());
        let held = owner
            .enter_mutation_lane(CANONICAL, "job-canonical", None)
            .unwrap()
            .unwrap();
        std::thread::scope(|scope| {
            let waiter = scope.spawn(|| {
                owner
                    .enter_mutation_lane(ALIAS, "job-alias", None)
                    .map(|lane| lane.map(|lane| lane.key().to_owned()))
            });
            let started = std::time::Instant::now();
            while owner.mutation_lane_state(CANONICAL, "job-alias")
                != Some(crate::LaneState::Queued)
            {
                assert!(
                    started.elapsed() < std::time::Duration::from_secs(60),
                    "the alias's Job never waited for the canonical Target's lane"
                );
                std::thread::yield_now();
            }
            assert_eq!(owner.mutation_lane_queue(CANONICAL), ["job-alias"]);
            drop(held);
            assert_eq!(waiter.join().unwrap(), Ok(Some(CANONICAL.to_owned())));
        });
    }
    fn candidate(key: &str, state: &str) -> arkdeck_provider_hdc::DeviceCandidate {
        arkdeck_provider_hdc::DeviceCandidate {
            connect_key: key.into(),
            transport: "USB".into(),
            state: state.into(),
        }
    }
    #[test]
    fn the_route_follows_a_fresh_live_observation_and_falls_back_once_it_is_stale() {
        let root = alias_root();
        let owner = root.open();
        let route = |owner: &TargetStore| {
            owner
                .hdc_route(CANONICAL)
                .map(|route| route.map(|route| (route.binding_revision, route.connect_key)))
        };
        assert_eq!(
            route(&owner),
            Ok(Some((2, "post-flash-hdc-address".into())))
        );
        owner.record_live_candidates(&[candidate("original-hdc-address", "Connected")]);
        assert_eq!(route(&owner), Ok(Some((2, "original-hdc-address".into()))));
        // Past Swift's five seconds the reading no longer selects.
        let stale = std::time::Instant::now()
            .checked_sub(ROUTE_OBSERVATION_FRESHNESS + std::time::Duration::from_millis(1))
            .unwrap();
        owner.live.lock().unwrap().as_mut().unwrap().1 = stale;
        assert_eq!(
            route(&owner),
            Ok(Some((2, "post-flash-hdc-address".into())))
        );
        owner.record_live_candidates(&[
            candidate("original-hdc-address", "Offline"),
            candidate("post-flash-hdc-address", "Offline"),
        ]);
        assert!(
            route(&owner)
                .unwrap_err()
                .starts_with("observationFailed(\"fresh HDC observation found no Connected"),
        );
        // A reopened owner has no reading: the durable alias only.
        assert_eq!(
            route(&root.open()),
            Ok(Some((2, "post-flash-hdc-address".into())))
        );
    }
    #[test]
    fn hdc_imports_bind_the_identity_the_route_names() {
        let root = alias_root();
        let owner = root.open();
        let intent = |kind: &str| {
            arkdeck_contract::ImportIntent::from_wire(
                json!({"schemaVersion":"arkdeck.import-intent/1","importRequestId":format!("alias-{kind}"),
                    "kind":kind,"targetId":CANONICAL,"bindingRevision":"2","deviceProfile":null,
                    "name":match kind {"hap" => "fixture.hap", "native-library" => "libfixture.so", _ => "fixture.patch"},"byteCount":"64",
                    "sha256":arkdeck_contract::sha256_hex(&[b'a'; 64])})
                .as_object()
                .unwrap(),
            )
            .unwrap()
        };
        let bound = |owner: &TargetStore, kind: &str| {
            owner.resolve_import_binding(&intent(kind)).map(|binding| {
                (
                    binding.target_id,
                    binding.binding_revision,
                    binding.stable_identity_sha256,
                )
            })
        };
        let identity = |key: &str| Some(arkdeck_provider_hdc::stable_identity_sha256(key));
        for kind in ["hap", "native-library"] {
            assert_eq!(
                bound(&owner, kind),
                Ok((
                    CANONICAL.into(),
                    Some(2),
                    identity("post-flash-hdc-address")
                ))
            );
        }
        owner.record_live_candidates(&[candidate("original-hdc-address", "Connected")]);
        assert_eq!(
            bound(&owner, "hap"),
            Ok((CANONICAL.into(), Some(2), identity("original-hdc-address")))
        );
        owner.record_live_candidates(&[
            candidate("original-hdc-address", "Connected"),
            candidate("post-flash-hdc-address", "Connected"),
        ]);
        let refused = bound(&owner, "native-library").unwrap_err();
        assert_eq!(refused.code, "recordUnreadable");
        assert_eq!(refused.details.unwrap()["phase"], json!("importOwner"));
        // Kinds that are not HDC-routed keep their bindings.
        assert_eq!(
            bound(&owner, "workspace-patch"),
            Ok((CANONICAL.into(), None, None))
        );
    }
    fn params(generation: &str, name: Option<&str>) -> Map<String, Value> {
        let mut p = json!({"targetId":"target-fixture","expectedGeneration":generation})
            .as_object()
            .unwrap()
            .clone();
        if let Some(name) = name {
            p.insert("name".into(), json!(name));
        }
        p
    }
    #[test]
    fn target_names_survive_restart_clear_with_tombstone_and_preserve_binding_bytes() {
        let root = Root::new();
        root.targets();
        let before = fs::read(root.0.join("targets.json")).unwrap();
        let owner = root.open();
        assert_eq!(
            owner.handle("target.list", &Map::new(), NOW).unwrap()[0]["displayNameGeneration"],
            "1"
        );
        let set = owner
            .handle(
                "target.display-name.set",
                &params("1", Some("Bench e\u{301}")),
                NOW,
            )
            .unwrap();
        assert_eq!(set["generation"], "2");
        assert_eq!(
            owner
                .handle("target.display-name.clear", &params("1", None), NOW)
                .unwrap_err()
                .code,
            "resourceConflict"
        );
        let clear = root
            .open()
            .handle("target.display-name.clear", &params("2", None), NOW)
            .unwrap();
        assert_eq!(clear["generation"], "3");
        assert!(clear["name"].is_null());
        assert_eq!(
            root.open()
                .handle(
                    "target.show",
                    json!({"targetId":"target-fixture"}).as_object().unwrap(),
                    NOW
                )
                .unwrap()["displayNameGeneration"],
            "3"
        );
        assert_eq!(fs::read(root.0.join("targets.json")).unwrap(), before);
        if let Some(path) = std::env::var_os("ARKDECK_RUST_TARGET_NAMES_COPY") {
            fs::copy(root.0.join(NAMES), path).unwrap();
        }
    }
    #[test]
    fn target_names_refuse_unknown_extra_noncanonical_and_invalid_values() {
        let root = Root::new();
        root.targets();
        let owner = root.open();
        assert_eq!(
            owner
                .handle("target.display-name.set", &params("01", Some("Bench")), NOW)
                .unwrap_err()
                .code,
            "invalidParams"
        );
        assert_eq!(
            owner
                .handle(
                    "target.display-name.set",
                    &params("1", Some(" invalid")),
                    NOW
                )
                .unwrap_err()
                .code,
            "invalidInput"
        );
        let mut p = params("1", Some("Bench"));
        p.insert("freshFacts".into(), json!({}));
        assert_eq!(
            owner
                .handle("target.display-name.set", &p, NOW)
                .unwrap_err()
                .code,
            "invalidParams"
        );
        p.remove("freshFacts");
        p.insert("targetId".into(), json!("target-missing"));
        assert_eq!(
            owner
                .handle("target.display-name.set", &p, NOW)
                .unwrap_err()
                .code,
            "resourceNotFound"
        );
        assert_eq!(
            owner.handle("target.list", &Map::new(), NOW).unwrap()[0]["displayNameGeneration"],
            "1"
        );
    }
    #[test]
    fn concurrent_target_writers_have_one_cas_winner() {
        let root = Root::new();
        root.targets();
        let a = Arc::new(root.open());
        let b = Arc::new(root.open());
        let barrier = Arc::new(Barrier::new(2));
        let threads = [a, b]
            .into_iter()
            .map(|owner| {
                let barrier = barrier.clone();
                std::thread::spawn(move || {
                    barrier.wait();
                    owner.handle("target.display-name.set", &params("1", Some("Bench")), NOW)
                })
            })
            .collect::<Vec<_>>();
        let results = threads
            .into_iter()
            .map(|t| t.join().unwrap())
            .collect::<Vec<_>>();
        assert_eq!(results.iter().filter(|r| r.is_ok()).count(), 1);
        assert!(
            results
                .iter()
                .filter_map(|r| r.as_ref().err())
                .all(|e| e.code == "resourceConflict")
        );
    }
    /// Each round lets two threads go together: one reads the HDC route while
    /// the other publishes the Target's next name — over one owner, then over
    /// two owners of one directory, as another process would hold it. Each
    /// waits for the other's locks, as Swift's blocking `flock` waits, so
    /// neither is ever refused.
    #[test]
    fn overlapping_transactions_wait_for_each_other() {
        const ROUNDS: u64 = 64;
        for owners in [1, 2] {
            let root = alias_root();
            let reader = root.open();
            let other = (owners == 2).then(|| root.open());
            let writer = other.as_ref().unwrap_or(&reader);
            let barrier = Barrier::new(2);
            let (routes, names) = std::thread::scope(|scope| {
                let routes = scope.spawn(|| {
                    (0..ROUNDS)
                        .map(|_| {
                            barrier.wait();
                            reader.hdc_route(CANONICAL).map(|route| {
                                route.map(|route| (route.binding_revision, route.connect_key))
                            })
                        })
                        .collect::<Vec<_>>()
                });
                let names = scope.spawn(|| {
                    (1..=ROUNDS)
                        .map(|generation| {
                            barrier.wait();
                            let params = json!({"targetId":CANONICAL,
                                "expectedGeneration":generation.to_string(),"name":format!("Bench {generation}")});
                            writer
                                .handle("target.display-name.set", params.as_object().unwrap(), NOW)
                                .map(|name| name["generation"].clone())
                        })
                        .collect::<Vec<_>>()
                });
                (routes.join().unwrap(), names.join().unwrap())
            });
            for route in routes {
                assert_eq!(
                    route,
                    Ok(Some((2, "post-flash-hdc-address".into()))),
                    "{owners} owner(s)"
                );
            }
            for (generation, name) in (2u64..).zip(names) {
                assert_eq!(name, Ok(json!(generation.to_string())), "{owners} owner(s)");
            }
        }
    }
    #[test]
    fn candidate_names_advance_all_active_generations_and_expire_on_restart() {
        let root = Root::new();
        let owner = root.open();
        let first = ObservationReference {
            candidate: "candidate-a".into(),
            observation_id: "obs-a".into(),
            generation: 1,
        };
        let second = ObservationReference {
            candidate: "candidate-b".into(),
            observation_id: "obs-b".into(),
            generation: 1,
        };
        let result = owner
            .mutate_candidate(&first, &[first.clone(), second.clone()], Some("A"), NOW)
            .unwrap();
        assert_eq!(result["generation"], "2");
        let mut first2 = first.clone();
        first2.generation = 2;
        let mut second2 = second.clone();
        second2.generation = 2;
        owner
            .mutate_candidate(&second2, &[first2.clone(), second2.clone()], Some("B"), NOW)
            .unwrap();
        assert_eq!(
            owner
                .mutate_candidate(&first2, &[first2.clone(), second2], None, NOW)
                .unwrap_err()
                .code,
            "resourceConflict"
        );
        let decoded = decode_display_names(&fs::read(root.0.join(NAMES)).unwrap()).unwrap();
        assert_eq!(decoded.projection["candidates"][0]["generation"], "3");
        assert_eq!(decoded.projection["candidates"][1]["generation"], "3");
        root.open();
        let decoded = decode_display_names(&fs::read(root.0.join(NAMES)).unwrap()).unwrap();
        assert_eq!(decoded.projection["candidates"], json!([]));
    }
    #[test]
    fn adopted_candidate_rejects_presentation_alias_and_unknown_reference() {
        let root = Root::new();
        root.targets();
        let owner = root.open();
        let reference = ObservationReference {
            candidate: "fixture-address".into(),
            observation_id: "obs-fixture".into(),
            generation: 1,
        };
        assert_eq!(
            owner
                .mutate_candidate(
                    &reference,
                    std::slice::from_ref(&reference),
                    Some("Candidate"),
                    NOW
                )
                .unwrap_err()
                .code,
            "resourceConflict"
        );
        assert_eq!(
            owner
                .mutate_candidate(&reference, &[], Some("Candidate"), NOW)
                .unwrap_err()
                .code,
            "resourceConflict"
        );
        assert_eq!(
            owner.handle("target.list", &Map::new(), NOW).unwrap()[0]["displayNameGeneration"],
            "1"
        );
    }
    #[test]
    fn unsafe_or_duplicate_documents_fail_without_resetting_state() {
        let root = Root::new();
        root.targets();
        let owner = root.open();
        let names = fs::read(root.0.join(NAMES)).unwrap();
        fs::write(
            root.0.join("targets.json"),
            b"{\"schemaVersion\":\"1.0.0\",\"schemaVersion\":\"1.0.0\",\"targets\":[]}",
        )
        .unwrap();
        assert_eq!(
            owner
                .handle("target.list", &Map::new(), NOW)
                .unwrap_err()
                .code,
            "recordUnreadable"
        );
        assert_eq!(fs::read(root.0.join(NAMES)).unwrap(), names);
        root.targets();
        fs::remove_file(root.0.join(NAMES)).unwrap();
        symlink("targets.json", root.0.join(NAMES)).unwrap();
        assert_eq!(
            owner
                .handle("target.list", &Map::new(), NOW)
                .unwrap_err()
                .code,
            "recordUnreadable"
        );
        assert!(TargetStore::open(&root.0).is_err());
    }
    #[test]
    #[ignore = "requires an actual Swift owner export in ARKDECK_SWIFT_TARGET_STORE"]
    fn actual_swift_target_document_is_read_by_rust_without_rewriting_binding() {
        let source =
            std::env::var_os("ARKDECK_SWIFT_TARGET_STORE").expect("actual Swift owner export");
        let root = Root::new();
        let source = PathBuf::from(source);
        for name in ["targets.json", NAMES] {
            fs::copy(source.join(name), root.0.join(name)).unwrap();
            fs::set_permissions(root.0.join(name), fs::Permissions::from_mode(0o600)).unwrap();
        }
        let before = fs::read(root.0.join("targets.json")).unwrap();
        let owner = root.open();
        let listed = owner.handle("target.list", &Map::new(), NOW).unwrap();
        assert!(!listed.as_array().unwrap().is_empty());
        assert_eq!(fs::read(root.0.join("targets.json")).unwrap(), before);
    }
}
