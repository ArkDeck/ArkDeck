//! Swift's `RuntimeCapabilityStore` (ArkDeckStorage): its reads, for
//! `capability.list` and `capability.inspect`, and its writes, which install a
//! capability and reserve and settle its uses.
//!
//! A store is a directory: the checkpoint `runtime-capabilities.json`, the
//! events appended to `runtime-capabilities.ledger` since the checkpoint was
//! last written, and `.runtime-capabilities.lock`, which every call holds with
//! a blocking exclusive `flock`. A read here is Swift's `loadDocument` under
//! that lock: the checkpoint and the ledger refused when either is a symbolic
//! link, a ledger without its checkpoint refused, the checkpoint checked for
//! duplicate and malformed JSON and decoded into the current shape alone
//! (each capability's model invariants and field shape included), every
//! appended event decoded and replayed over it with a torn final append
//! dropped, and the whole validated as Swift validates it: use accounting,
//! lineage order, and the receipt and outcome digests. A refusal is Swift's
//! error rendered as the daemon renders it. A read writes nothing but the lock
//! file, which Swift's reads create too.
//!
//! A write loads the document the same way under the same lock, then writes
//! as Swift writes. An install appends the capability with its whole budget
//! and writes the checkpoint (Swift's `canonicalPretty`: sorted keys, two-space
//! indentation, no escaped solidus, no trailing newline) atomically, then
//! empties an existing ledger, only once the checkpoint holding its events is
//! durable. A use is reserved (`consume`) and settled (`recordOutcome`) by
//! appending one event, compact canonical JSON and a newline, fully
//! synchronized; once 128 events have been appended since the checkpoint, the
//! next is folded into a new checkpoint instead. Each receipt and outcome is
//! digested into one hash-linked lineage per capability. Settling an unknown
//! outcome is recovery, which ADR-0009 has not placed yet (decisions 2 and 4),
//! so this owner refuses it as Swift refuses every other change to a recorded
//! outcome.
//!
//! Numbers follow Foundation, as the oracle records it: a field Swift decodes
//! as `Int` takes a number with no fraction however it is spelled (`2.0` is
//! 2), and any other number fails the whole decode; a number inside
//! `exactInputs` is an integer when it has no fraction, as Swift's
//! `JSONValue` holds it. The refusal of a fraction quotes serde's spelling of
//! the number where Foundation quotes the document's.

use std::collections::{BTreeMap, BTreeSet, HashSet};
use std::io;
use std::os::unix::fs::DirBuilderExt;
use std::path::{Path, PathBuf};

use arkdeck_platform::{DocumentPublishError, HostDirectory};
use serde_json::{Map, Value, json};

use crate::strict_json::{self, swift_quoted};
use crate::swift_decoding::{
    Decoding, Keyed, Step, characters, same_text, string, swift_integer, swift_value, text_key,
};

const CHECKPOINT: &str = "runtime-capabilities.json";
const LEDGER: &str = "runtime-capabilities.ledger";
const LOCK: &str = ".runtime-capabilities.lock";
const SCHEMA_VERSION: &str = "1.0.0";
/// Swift `checkpointEveryEvents`: how many events the ledger takes before the
/// next change is written out as a whole checkpoint instead.
const CHECKPOINT_EVERY_EVENTS: usize = 128;
/// Swift `CurrentDurableJSON`'s refusal of a record outside the current shape.
const DURABLE_SHAPE: &str = "record does not match the current durable field shape";

/// Swift `RuntimeCapabilityStoreError`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum CapabilityStoreError {
    /// `ioFailure`
    Io(String),
    /// `storeCorrupted`
    Corrupted(String),
    /// `capabilityNotFound`
    NotFound(String),
    /// `capabilityAlreadyInstalled`
    AlreadyInstalled(String),
    /// `reservationConflict`
    ReservationConflict(String),
    /// `lineageBlocked`
    LineageBlocked(String),
    /// `outcomeConflict`
    OutcomeConflict(String),
    /// `denied`
    Denied(CapabilityDenial),
}

impl CapabilityStoreError {
    /// Swift's interpolation of the error, which the daemon answers with. A
    /// denial is spelled as Swift reflects its value; no oracle records one.
    pub fn swift(&self) -> String {
        match self {
            Self::Io(detail) => case_text("ioFailure", detail),
            Self::Corrupted(detail) => case_text("storeCorrupted", detail),
            Self::NotFound(id) => case_text("capabilityNotFound", id),
            Self::AlreadyInstalled(id) => case_text("capabilityAlreadyInstalled", id),
            Self::ReservationConflict(detail) => case_text("reservationConflict", detail),
            Self::LineageBlocked(detail) => case_text("lineageBlocked", detail),
            Self::OutcomeConflict(detail) => case_text("outcomeConflict", detail),
            Self::Denied(denial) => format!(
                "denied(ArkDeckCore.RuntimeCapabilityDenial(reason: \
                 ArkDeckCore.RuntimeCapabilityDenialReason.{}, detail: {}))",
                denial.reason,
                swift_quoted(&denial.detail)
            ),
        }
    }
}

/// Swift `RuntimeCapabilityDenial`: why a capability does not authorize a
/// query (the reason's case name), and Swift's detail.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CapabilityDenial {
    pub reason: &'static str,
    pub detail: String,
}

fn denial(reason: &'static str, detail: impl Into<String>) -> CapabilityDenial {
    CapabilityDenial {
        reason,
        detail: detail.into(),
    }
}

/// Swift `RuntimeCapabilityAuthorizationQuery`, as far as the store reads it:
/// may an operation run at an effect against a subject, with these typed
/// inputs, these Runtime-resolved Artifact facts and this materialized plan?
#[derive(Clone, Debug, PartialEq)]
pub struct CapabilityQuery {
    pub operation_id: String,
    pub operation_version: Option<i64>,
    pub effect: Effect,
    pub target_stable_identity_sha256: Option<String>,
    pub target_binding_revision: Option<i64>,
    pub plan_digest: Option<String>,
    pub inputs: Map<String, Value>,
    pub artifact_facts: BTreeMap<String, String>,
    pub workspace_identity_sha256: Option<String>,
    pub workspace_revision: Option<String>,
    pub workspace_file_scopes_digest: Option<String>,
}

impl CapabilityQuery {
    /// Swift `operationReference`.
    pub fn operation_reference(&self) -> String {
        match self.operation_version {
            Some(version) => format!("{}@{version}", self.operation_id),
            None => self.operation_id.clone(),
        }
    }
}

/// Swift `RuntimeCapabilityConsumptionReceipt`: the use a `consume` reserved.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ConsumptionReceipt {
    pub capability_id: String,
    pub ordinal: i64,
    pub reservation_id: String,
    pub job_id: String,
    pub consumed_at_utc: String,
    pub operation_reference: String,
    pub query_fingerprint_sha256: String,
    pub remaining_uses_after: i64,
    pub previous_lineage_sha256: Option<String>,
    pub receipt_sha256: String,
}

/// What automatic issuance reads of an installed generation.
pub(crate) struct Generation {
    pub(crate) remaining_uses: i64,
    pub(crate) expires_at: String,
    pub(crate) revoked: bool,
    pub(crate) issued_at: String,
    /// Swift `lineageAllowsNewExecution`: no use of it is unsettled and a use
    /// remains.
    pub(crate) lineage_allows_new_execution: bool,
    /// The last outcome recorded for its last use, with the terminal state it
    /// was recorded for (Swift `lineage.last?.outcomeHistory.last`).
    pub(crate) last_outcome: Option<(UseOutcome, String)>,
}

/// A use on a Target binding left without a settled outcome.
pub(crate) struct UnresolvedUse {
    capability: String,
    ordinal: i64,
    outcome: UseOutcome,
}

impl UnresolvedUse {
    /// Swift's `lineageBlocked` for it.
    pub(crate) fn blocker(&self) -> CapabilityStoreError {
        CapabilityStoreError::LineageBlocked(format!(
            "target binding has unresolved capability {} use {} outcome {}",
            self.capability,
            self.ordinal,
            self.outcome.raw()
        ))
    }
}

/// One entry of Swift's `RuntimeCapabilityStatus.lineage`, as the lineage
/// repairs of a lost outcome and a complete-overwrite admission read it: the
/// capability and the use's ordinal, the Job and operation it was taken for,
/// its effect, Target and binding revision, and where the use stands now.
pub(crate) struct LineageUse {
    pub(crate) capability: String,
    pub(crate) ordinal: i64,
    pub(crate) job: String,
    pub(crate) operation_reference: String,
    pub(crate) effect: String,
    pub(crate) target: Option<String>,
    pub(crate) binding_revision: Option<i64>,
    pub(crate) outcome: UseOutcome,
}

/// A refused `capability.list` or `capability.inspect`: Swift's code and
/// message. Swift attaches no details to either.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CapabilityRefusal {
    pub code: &'static str,
    pub message: String,
}

fn refusal(code: &'static str, message: impl Into<String>) -> CapabilityRefusal {
    CapabilityRefusal {
        code,
        message: message.into(),
    }
}

/// One Runtime capability store, read as Swift reads it.
pub struct CapabilityStore {
    directory: PathBuf,
}

impl CapabilityStore {
    /// Swift `RuntimeCapabilityStore.init`: the directory, created private
    /// when absent. Nothing in it is read or written until a call.
    pub fn open(directory: &Path) -> io::Result<Self> {
        std::fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(directory)?;
        Ok(Self {
            directory: directory.to_path_buf(),
        })
    }

    /// The daemon's `capability.list` and `capability.inspect`. A list reads
    /// no parameter; an inspection names one capability by `capabilityId`.
    pub fn handle(
        &self,
        method: &str,
        params: &Map<String, Value>,
    ) -> Result<Value, CapabilityRefusal> {
        match method {
            "capability.list" => {
                self.read(|records| Value::Array(records.iter().map(Record::row).collect()))
            }
            "capability.inspect" => {
                let Some(Value::String(capability)) = params.get("capabilityId") else {
                    return Err(refusal("invalidParams", "capabilityId is required"));
                };
                self.read(|records| {
                    records
                        .iter()
                        .find(|record| same_text(&record.capability.id, capability))
                        .map(Record::status)
                })?
                .ok_or_else(|| refusal("notFound", "unknown capability"))
            }
            _ => Err(refusal(
                "unknownMethod",
                format!("{method} is not a capability read"),
            )),
        }
    }

    fn read<T>(&self, answer: impl FnOnce(&[Record]) -> T) -> Result<T, CapabilityRefusal> {
        self.locked(|_, document, _| Ok(answer(&document.records)))
            .map_err(|error| refusal("internalError", error.swift()))
    }

    /// Swift `install`: a new capability appended with its whole budget and
    /// the store checkpointed. The same capability again changes nothing; a
    /// different one under an installed identity is refused.
    pub fn install(&self, capability: &Capability) -> Result<(), CapabilityStoreError> {
        self.locked(|directory, mut document, _| {
            if let Some(existing) = document
                .records
                .iter()
                .find(|record| same_text(&record.capability.id, &capability.id))
            {
                if existing.capability.value() == capability.value() {
                    return Ok(());
                }
                return Err(CapabilityStoreError::AlreadyInstalled(
                    capability.id.clone(),
                ));
            }
            document.records.push(Record {
                capability: capability.clone(),
                remaining_uses: capability.maximum_uses,
                consumptions: Vec::new(),
            });
            self.persist(directory, &document)
        })
    }

    /// Swift `validateNewExecution`: an execution checked against the
    /// installed envelope and its durable lineage, reserving nothing.
    pub fn validate_new_execution(
        &self,
        capability_id: &str,
        query: &CapabilityQuery,
        now_utc: &str,
    ) -> Result<(), CapabilityStoreError> {
        self.locked(|_, document, _| {
            let record = document
                .records
                .iter()
                .find(|record| same_text(&record.capability.id, capability_id))
                .ok_or_else(|| CapabilityStoreError::NotFound(capability_id.to_owned()))?;
            validate_new_execution(record, query, now_utc)
        })
    }

    /// Swift `validateContinuation`: a Job continuing under the use it
    /// already reserved, which must be exactly its own (the reservation and
    /// the Job), for this very query, and not yet settled; the capability must
    /// still authorize the query with that one use added back, as it did when
    /// the use was charged. Nothing is reserved, replenished or written.
    pub(crate) fn validate_continuation(
        &self,
        capability_id: &str,
        reservation_id: &str,
        job_id: &str,
        query: &CapabilityQuery,
        now_utc: &str,
    ) -> Result<ConsumptionReceipt, CapabilityStoreError> {
        self.locked(|_, document, _| {
            let record = document
                .records
                .iter()
                .find(|record| same_text(&record.capability.id, capability_id))
                .ok_or_else(|| CapabilityStoreError::NotFound(capability_id.to_owned()))?;
            let use_ = record
                .consumptions
                .iter()
                .find(|use_| {
                    same_text(&use_.reservation, reservation_id) && same_text(&use_.job, job_id)
                })
                .filter(|use_| {
                    use_.query == fingerprint(query, true)
                        && matches!(
                            use_.current(),
                            UseOutcome::Pending | UseOutcome::OutcomeUnknown
                        )
                })
                .ok_or_else(|| {
                    CapabilityStoreError::ReservationConflict(
                        "continuation has no exact unresolved owning use".into(),
                    )
                })?;
            record
                .capability
                .authorizes(query, now_utc, use_.remaining_after + 1)
                .map_err(CapabilityStoreError::Denied)?;
            Ok(use_.to_receipt(capability_id))
        })
    }

    /// The use a resumed Job's record says it consumed, as the store holds it:
    /// the one consumed for exactly this reservation and Job, whose receipt
    /// is still unsettled (`pending` or `outcomeUnknown`). `None` when the
    /// store holds no such use. Nothing is reserved or written.
    pub(crate) fn unsettled_use(
        &self,
        capability_id: &str,
        reservation_id: &str,
        job_id: &str,
    ) -> Result<Option<ConsumptionReceipt>, CapabilityStoreError> {
        self.locked(|_, document, _| {
            Ok(document
                .records
                .iter()
                .find(|record| same_text(&record.capability.id, capability_id))
                .and_then(|record| {
                    record.consumptions.iter().find(|use_| {
                        same_text(&use_.reservation, reservation_id)
                            && same_text(&use_.job, job_id)
                            && matches!(
                                use_.current(),
                                UseOutcome::Pending | UseOutcome::OutcomeUnknown
                            )
                    })
                })
                .map(|use_| use_.to_receipt(capability_id)))
        })
    }

    /// Swift `inspect(capabilityID:)` as automatic issuance reads a
    /// generation: whether it exists and, if so, its remaining uses, its
    /// expiry and whether it was revoked.
    pub(crate) fn generation(
        &self,
        capability_id: &str,
    ) -> Result<Option<Generation>, CapabilityStoreError> {
        self.locked(|_, document, _| {
            Ok(document
                .records
                .iter()
                .find(|record| same_text(&record.capability.id, capability_id))
                .map(|record| Generation {
                    remaining_uses: record.remaining_uses,
                    expires_at: record.capability.expires_at.clone(),
                    revoked: matches!(record.capability.revocation, Revocation::Revoked { .. }),
                    issued_at: record.capability.issued_at.clone(),
                    lineage_allows_new_execution: record.remaining_uses > 0
                        && record
                            .consumptions
                            .iter()
                            .all(|use_| use_.current().settled()),
                    last_outcome: record.consumptions.last().and_then(|use_| {
                        use_.outcomes
                            .last()
                            .map(|outcome| (outcome.outcome, outcome.terminal_state.clone()))
                    }),
                }))
        })
    }

    /// Swift `validateNoUnresolvedMutationLineage` without recovery epochs:
    /// over every capability in store order, the first use on this Target
    /// binding whose outcome is neither confirmed nor safe to reflash. A
    /// pending use of `owner`'s own reservation and Job does not count.
    pub(crate) fn unresolved_use(
        &self,
        identity: &str,
        binding_revision: i64,
        owner: Option<(&str, &str)>,
    ) -> Result<Option<UnresolvedUse>, CapabilityStoreError> {
        self.unresolved_use_beyond(identity, binding_revision, owner, &BTreeSet::new())
    }

    /// As [`Self::unresolved_use`], with the Jobs a durable superseding
    /// recovery epoch or the admitted recovery covers left out, as Swift
    /// leaves them out: their uses stay unknown, and a complete overwrite
    /// has superseded them.
    pub(crate) fn unresolved_use_beyond(
        &self,
        identity: &str,
        binding_revision: i64,
        owner: Option<(&str, &str)>,
        superseded: &BTreeSet<String>,
    ) -> Result<Option<UnresolvedUse>, CapabilityStoreError> {
        self.locked(|_, document, _| {
            for record in &document.records {
                for use_ in &record.consumptions {
                    let outcome = use_.current();
                    if use_.target.as_deref() != Some(identity)
                        || use_.binding_revision != Some(binding_revision)
                        || outcome.settled()
                        || superseded.contains(&use_.job)
                    {
                        continue;
                    }
                    let owned = owner.is_some_and(|(reservation, job)| {
                        same_text(&use_.reservation, reservation) && same_text(&use_.job, job)
                    });
                    if outcome == UseOutcome::Pending && owned {
                        continue;
                    }
                    return Ok(Some(UnresolvedUse {
                        capability: record.capability.id.clone(),
                        ordinal: use_.ordinal,
                        outcome,
                    }));
                }
            }
            Ok(None)
        })
    }

    /// Swift `list()` as the lineage repairs of a lost outcome read it: every
    /// use of every capability, in store order. It writes nothing but the
    /// lock file, as every read here.
    pub(crate) fn lineage(&self) -> Result<Vec<LineageUse>, CapabilityStoreError> {
        self.locked(|_, document, _| {
            Ok(document
                .records
                .iter()
                .flat_map(|record| {
                    record.consumptions.iter().map(|use_| LineageUse {
                        capability: record.capability.id.clone(),
                        ordinal: use_.ordinal,
                        job: use_.job.clone(),
                        operation_reference: use_.operation_reference.clone(),
                        effect: use_.effect.clone(),
                        target: use_.target.clone(),
                        binding_revision: use_.binding_revision,
                        outcome: use_.current(),
                    })
                })
                .collect())
        })
    }

    /// Every use of every capability as the cutover preflight reads it: the
    /// capability, the use's ordinal, where it stands and its Job, in store
    /// order. Read without the store's lock and without creating anything:
    /// the checkpoint is replaced atomically and the ledger only appended, and
    /// a torn last event is dropped as Swift's reader drops it. Only a read
    /// while no owner runs is exact — beside a running one a fold into a new
    /// checkpoint can fall between the two reads. An absent store holds no
    /// use.
    pub(crate) fn cutover_uses(
        directory: &Path,
    ) -> Result<Vec<(String, i64, String, String)>, CapabilityStoreError> {
        if !directory.exists() {
            return Ok(Vec::new());
        }
        let store = Self {
            directory: directory.to_path_buf(),
        };
        let mut document = store.checkpoint()?;
        let events = store.ledger()?;
        for event in &events {
            apply(event, &mut document)?;
        }
        if !events.is_empty() {
            validate(&document)?;
        }
        Ok(document
            .records
            .iter()
            .flat_map(|record| {
                record.consumptions.iter().map(|use_| {
                    (
                        record.capability.id.clone(),
                        use_.ordinal,
                        use_.current().raw().to_owned(),
                        use_.job.clone(),
                    )
                })
            })
            .collect())
    }

    /// Swift `consume`: one use reserved for an exact Job execution, the Job
    /// defaulting to the reservation. Retrying a reservation answers its
    /// receipt and writes nothing; a new one must pass `validateNewExecution`
    /// and is linked to the tip of the use before it.
    pub fn consume(
        &self,
        capability_id: &str,
        reservation_id: &str,
        job_id: Option<&str>,
        query: &CapabilityQuery,
        now_utc: &str,
    ) -> Result<ConsumptionReceipt, CapabilityStoreError> {
        if reservation_id.is_empty() || characters(reservation_id) > 128 {
            return Err(CapabilityStoreError::ReservationConflict(
                "malformed reservation ID".into(),
            ));
        }
        let job = job_id.unwrap_or(reservation_id);
        if job.is_empty() || characters(job) > 160 {
            return Err(CapabilityStoreError::ReservationConflict(
                "malformed Job ID".into(),
            ));
        }
        self.locked(|directory, mut document, appended| {
            let index = document
                .records
                .iter()
                .position(|record| same_text(&record.capability.id, capability_id))
                .ok_or_else(|| CapabilityStoreError::NotFound(capability_id.to_owned()))?;
            let query_fingerprint = fingerprint(query, true);
            if let Some(existing) = document.records[index]
                .consumptions
                .iter()
                .find(|use_| same_text(&use_.reservation, reservation_id))
            {
                if existing.query != query_fingerprint || !same_text(&existing.job, job) {
                    return Err(CapabilityStoreError::ReservationConflict(format!(
                        "reservation retry fields drifted for {reservation_id}"
                    )));
                }
                return Ok(existing.to_receipt(capability_id));
            }
            let record = &document.records[index];
            validate_new_execution(record, query, now_utc)?;
            let mut use_ = Consumption {
                ordinal: record.consumptions.len() as i64 + 1,
                reservation: reservation_id.to_owned(),
                job: job.to_owned(),
                consumed_at: now_utc.to_owned(),
                operation_reference: query.operation_reference(),
                effect: query.effect.raw().to_owned(),
                target: query.target_stable_identity_sha256.clone(),
                binding_revision: query.target_binding_revision,
                plan_digest: query.plan_digest.clone(),
                authorization_scope: fingerprint(query, false),
                query: query_fingerprint,
                remaining_after: record.remaining_uses - 1,
                previous_lineage: record
                    .consumptions
                    .last()
                    .map(|last| last.lineage_tip().to_owned()),
                receipt: String::new(),
                outcomes: Vec::new(),
            };
            use_.receipt = digest(&use_.receipt_material(capability_id)).ok_or_else(unencodable)?;
            let receipt = use_.to_receipt(capability_id);
            let record = &mut document.records[index];
            record.remaining_uses = use_.remaining_after;
            record.consumptions.push(use_.clone());
            let event = Event {
                kind: "consumed".into(),
                capability: capability_id.to_owned(),
                consumption: Some(use_),
                reservation: None,
                outcome: None,
            };
            self.append(directory, &event, &document, appended)?;
            Ok(receipt)
        })
    }

    /// Swift `recordOutcome`: a pending use settled by the Job that owns it.
    /// The same outcome again changes nothing. Outcomes are appended, never
    /// replaced, and the only change one may take is Swift's `resolvesUnknown`:
    /// an `outcomeUnknown` use settled `confirmed` or `safeToReflash` by a
    /// later readback. Every other change is refused, as Swift refuses it.
    pub fn record_outcome(
        &self,
        capability_id: &str,
        reservation_id: &str,
        job_id: &str,
        outcome: UseOutcome,
        terminal_state: &str,
        at_utc: &str,
    ) -> Result<(), CapabilityStoreError> {
        let conflict = CapabilityStoreError::OutcomeConflict;
        if outcome == UseOutcome::Pending {
            return Err(conflict(
                "only confirmed, safeToReflash or outcomeUnknown may be recorded".into(),
            ));
        }
        if job_id.is_empty() || characters(job_id) > 160 {
            return Err(conflict("malformed outcome Job ID".into()));
        }
        if terminal_state.is_empty() || characters(terminal_state) > 80 {
            return Err(conflict("malformed terminal state".into()));
        }
        self.locked(|directory, mut document, appended| {
            let index = document
                .records
                .iter()
                .position(|record| same_text(&record.capability.id, capability_id))
                .ok_or_else(|| CapabilityStoreError::NotFound(capability_id.to_owned()))?;
            let Some(use_index) = document.records[index]
                .consumptions
                .iter()
                .position(|use_| same_text(&use_.reservation, reservation_id))
            else {
                return Err(conflict(format!(
                    "reservation {reservation_id} has no durable consumption"
                )));
            };
            let use_ = &document.records[index].consumptions[use_index];
            let current = use_.outcomes.last();
            if !same_text(&use_.job, job_id)
                && !current.is_some_and(|current| same_text(&current.job, job_id))
            {
                return Err(conflict(format!(
                    "outcome Job {job_id} does not own reservation {reservation_id}"
                )));
            }
            if let Some(current) = current {
                if current.outcome == outcome && same_text(&current.terminal_state, terminal_state)
                {
                    return Ok(());
                }
                // Swift `resolvesUnknown`, the one change an outcome may take
                // (ADR-0009 decision 4, ruled 2026-09-19): a readback settles an
                // unknown use as confirmed or safe to reflash, appended after it.
                let resolves_unknown = current.outcome == UseOutcome::OutcomeUnknown
                    && matches!(outcome, UseOutcome::Confirmed | UseOutcome::SafeToReflash);
                if !resolves_unknown {
                    return Err(conflict(format!(
                        "cannot change {} to {}",
                        current.outcome.raw(),
                        outcome.raw()
                    )));
                }
            }
            let mut settlement = Outcome {
                job: job_id.to_owned(),
                outcome,
                terminal_state: terminal_state.to_owned(),
                recorded_at: at_utc.to_owned(),
                previous_record: use_.lineage_tip().to_owned(),
                record: String::new(),
            };
            settlement.record =
                digest(&settlement.material(capability_id, use_)).ok_or_else(unencodable)?;
            document.records[index].consumptions[use_index]
                .outcomes
                .push(settlement.clone());
            let event = Event {
                kind: "outcome".into(),
                capability: capability_id.to_owned(),
                consumption: None,
                reservation: Some(reservation_id.to_owned()),
                outcome: Some(settlement),
            };
            self.append(directory, &event, &document, appended)
        })
    }

    /// Swift `withExclusiveLock` around `loadDocument`: the store's lock held
    /// for the whole call, over the document as it stands and the number of
    /// events appended since its checkpoint.
    fn locked<T>(
        &self,
        body: impl FnOnce(&HostDirectory, Document, usize) -> Result<T, CapabilityStoreError>,
    ) -> Result<T, CapabilityStoreError> {
        let unavailable = || CapabilityStoreError::Io("cannot open capability store lock".into());
        let directory = HostDirectory::open(&self.directory).map_err(|_| unavailable())?;
        let _lock = directory
            .wait_lock(LOCK, false)
            .map_err(|_| unavailable())?;
        let mut document = self.checkpoint()?;
        let events = self.ledger()?;
        for event in &events {
            apply(event, &mut document)?;
        }
        if !events.is_empty() {
            // Replayed state is validated as a whole, as a checkpoint is.
            validate(&document)?;
        }
        body(&directory, document, events.len())
    }

    /// Swift `persist`: the whole document written out as the checkpoint, then
    /// an existing ledger emptied, only once the checkpoint holding its events
    /// is durable. A crash between the two leaves events the checkpoint
    /// already holds, which replay refuses as a reservation taken twice.
    fn persist(
        &self,
        directory: &HostDirectory,
        document: &Document,
    ) -> Result<(), CapabilityStoreError> {
        let bytes = crate::session_json::encode_canonical_pretty(&document.value())
            .map_err(|_| CapabilityStoreError::Io("cannot encode capability store".into()))?;
        directory
            .replace_document(CHECKPOINT, &bytes, usize::MAX)
            .map_err(|error| {
                CapabilityStoreError::Io(format!(
                    "cannot durably persist capability store: {}",
                    publication_failure(error)
                ))
            })?;
        if self.directory.join(LEDGER).exists() {
            directory
                .replace_document(LEDGER, &[], usize::MAX)
                .map_err(|error| {
                    CapabilityStoreError::Io(format!(
                        "cannot reset capability ledger: {}",
                        publication_failure(error)
                    ))
                })?;
        }
        Ok(())
    }

    /// Swift `appendEvent`: one change appended to the ledger and fully
    /// synchronized before the call answers, or, once the ledger holds
    /// `CHECKPOINT_EVERY_EVENTS`, the document holding it written out as a new
    /// checkpoint instead.
    fn append(
        &self,
        directory: &HostDirectory,
        event: &Event,
        document: &Document,
        appended: usize,
    ) -> Result<(), CapabilityStoreError> {
        if appended >= CHECKPOINT_EVERY_EVENTS {
            return self.persist(directory, document);
        }
        let mut line = crate::session_json::encode(&event.value()).map_err(|_| {
            CapabilityStoreError::Io("cannot encode capability ledger event".into())
        })?;
        line.push(b'\n');
        directory
            .append_synchronized(LEDGER, &line)
            .map_err(|error| {
                CapabilityStoreError::Io(format!(
                    "cannot durably append to capability ledger: {error}"
                ))
            })
    }

    /// Swift `loadCheckpoint`.
    fn checkpoint(&self) -> Result<Document, CapabilityStoreError> {
        let checkpoint = self.directory.join(CHECKPOINT);
        let ledger = self.directory.join(LEDGER);
        for path in [&checkpoint, &ledger] {
            if std::fs::symlink_metadata(path).is_ok_and(|metadata| metadata.is_symlink()) {
                return Err(CapabilityStoreError::Io(format!(
                    "cannot read capability store: symbolicLinkRejected({})",
                    swift_quoted(&path.to_string_lossy())
                )));
            }
        }
        let bytes = match std::fs::read(&checkpoint) {
            Ok(bytes) => bytes,
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                if ledger.exists() {
                    return Err(CapabilityStoreError::Corrupted(format!(
                        "capability checkpoint is missing beside an existing ledger; original state is preserved at {}",
                        self.directory.display()
                    )));
                }
                return Ok(Document {
                    schema_version: SCHEMA_VERSION.into(),
                    records: Vec::new(),
                });
            }
            Err(error) => {
                return Err(CapabilityStoreError::Io(format!(
                    "cannot read capability store: {error}"
                )));
            }
        };
        strict_json::validate(&bytes).map_err(|error| {
            CapabilityStoreError::Corrupted(format!(
                "duplicate or malformed JSON: {}",
                error.swift()
            ))
        })?;
        let document =
            decode_durable(&bytes, Document::decode, Document::value).map_err(|error| {
                CapabilityStoreError::Corrupted(format!(
                    "undecodable current store document: {error}"
                ))
            })?;
        validate(&document)?;
        Ok(document)
    }

    /// Swift `loadLedgerEvents`: a final line without its newline is a torn
    /// append that never happened, and is dropped.
    fn ledger(&self) -> Result<Vec<Event>, CapabilityStoreError> {
        let bytes = match std::fs::read(self.directory.join(LEDGER)) {
            Ok(bytes) => bytes,
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(Vec::new()),
            Err(error) => {
                return Err(CapabilityStoreError::Io(format!(
                    "cannot read capability ledger: {error}"
                )));
            }
        };
        if bytes.is_empty() {
            return Ok(Vec::new());
        }
        let mut lines: Vec<&[u8]> = bytes.split(|byte| *byte == b'\n').collect();
        if bytes.last() != Some(&b'\n') {
            lines.pop();
        }
        lines
            .into_iter()
            .filter(|line| !line.is_empty())
            .map(|line| {
                strict_json::validate(line)
                    .map_err(|error| error.swift())
                    .and_then(|()| decode_durable(line, Event::decode, Event::value))
                    .map_err(|error| {
                        CapabilityStoreError::Corrupted(format!(
                            "undecodable capability ledger event: {error}"
                        ))
                    })
            })
            .collect()
    }
}

/// Swift `CurrentDurableJSON.decode` after its duplicate check: the typed
/// decode, then the JSON must be exactly what the typed value encodes back to.
fn decode_durable<T>(
    bytes: &[u8],
    decode: impl Fn(&Value) -> Result<T, Decoding>,
    encode: impl Fn(&T) -> Value,
) -> Result<T, String> {
    let supplied: Value = serde_json::from_slice(bytes).map_err(|error| error.to_string())?;
    let value = decode(&supplied).map_err(|error| error.describe())?;
    if swift_value(&supplied) != encode(&value) {
        return Err(format!("malformed({})", swift_quoted(DURABLE_SHAPE)));
    }
    Ok(value)
}

// MARK: - The stored model

/// Swift `StoreDocument`.
struct Document {
    schema_version: String,
    records: Vec<Record>,
}

/// Swift `StoredRecord`.
struct Record {
    capability: Capability,
    remaining_uses: i64,
    consumptions: Vec<Consumption>,
}

/// Swift `RuntimeCapability`: a durable, revocable envelope bounding which
/// operations may run at what effect, on which subject, with which inputs,
/// how many times and until when.
#[derive(Clone)]
pub struct Capability {
    id: String,
    target_scope: TargetScope,
    operation_scope: Vec<OperationScope>,
    effect_ceiling: Effect,
    input_constraints: Vec<(String, Constraint)>,
    exact_inputs: Option<Map<String, Value>>,
    exact_artifact_facts: Option<Vec<(String, String)>>,
    issued_at: String,
    expires_at: String,
    maximum_uses: i64,
    issuer_kind: IssuerKind,
    issuer_reference: String,
    exact_plan_digest: Option<String>,
    exact_binding_revision: Option<i64>,
    revocation: Revocation,
}

#[derive(Clone)]
enum TargetScope {
    AnyTarget,
    StablePhysicalIdentity(String),
    WorkspaceIdentity {
        sha256: String,
        expected_revision: String,
        allowed_scopes: String,
    },
}

#[derive(Clone)]
struct OperationScope {
    operation_id: String,
    version: Option<i64>,
}

impl OperationScope {
    fn reference(&self) -> String {
        match self.version {
            Some(version) => format!("{}@{version}", self.operation_id),
            None => self.operation_id.clone(),
        }
    }
}

#[derive(Clone)]
enum Constraint {
    ExactString(String),
    OneOfStrings(Vec<String>),
    IntegerRange(i64, i64),
}

/// Swift `WorkflowEffect`, ordered by its risk rank.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Effect {
    HostOnly,
    ReadOnly,
    DeviceMutation,
    Destructive,
}

impl Effect {
    pub fn parse(raw: &str) -> Option<Self> {
        Some(match raw {
            "hostOnly" => Self::HostOnly,
            "readOnly" => Self::ReadOnly,
            "deviceMutation" => Self::DeviceMutation,
            "destructive" => Self::Destructive,
            _ => return None,
        })
    }

    pub fn raw(self) -> &'static str {
        match self {
            Self::HostOnly => "hostOnly",
            Self::ReadOnly => "readOnly",
            Self::DeviceMutation => "deviceMutation",
            Self::Destructive => "destructive",
        }
    }

    /// Swift `WorkflowEffect.riskRank`.
    fn rank(self) -> u8 {
        match self {
            Self::HostOnly => 0,
            Self::ReadOnly => 1,
            Self::DeviceMutation => 2,
            Self::Destructive => 3,
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum IssuerKind {
    MaintainerMergedPr,
    RuntimeDefaultPolicy,
}

impl IssuerKind {
    fn parse(raw: &str) -> Option<Self> {
        match raw {
            "maintainerMergedPR" => Some(Self::MaintainerMergedPr),
            "runtimeDefaultPolicy" => Some(Self::RuntimeDefaultPolicy),
            _ => None,
        }
    }

    fn raw(self) -> &'static str {
        match self {
            Self::MaintainerMergedPr => "maintainerMergedPR",
            Self::RuntimeDefaultPolicy => "runtimeDefaultPolicy",
        }
    }
}

#[derive(Clone)]
enum Revocation {
    Active,
    Revoked { at: String, reason: String },
}

/// Swift `StoredConsumption`: one use and its outcomes.
#[derive(Clone)]
struct Consumption {
    ordinal: i64,
    reservation: String,
    job: String,
    consumed_at: String,
    operation_reference: String,
    effect: String,
    target: Option<String>,
    binding_revision: Option<i64>,
    plan_digest: Option<String>,
    authorization_scope: String,
    query: String,
    remaining_after: i64,
    previous_lineage: Option<String>,
    receipt: String,
    outcomes: Vec<Outcome>,
}

impl Consumption {
    fn current(&self) -> UseOutcome {
        self.outcomes
            .last()
            .map_or(UseOutcome::Pending, |outcome| outcome.outcome)
    }

    fn lineage_tip(&self) -> &str {
        self.outcomes
            .last()
            .map_or(self.receipt.as_str(), |outcome| outcome.record.as_str())
    }
}

/// Swift `StoredOutcomeRecord`.
#[derive(Clone)]
struct Outcome {
    job: String,
    outcome: UseOutcome,
    terminal_state: String,
    recorded_at: String,
    previous_record: String,
    record: String,
}

/// Swift `RuntimeCapabilityUseOutcome`: where one use of a capability stands.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum UseOutcome {
    /// Reserved; its Job has reached no confirmed terminal outcome.
    Pending,
    /// Its Job reached a known terminal outcome, successful or not.
    Confirmed,
    /// Complete readback proves no mutation happened.
    SafeToReflash,
    /// Dispatch may have happened, and nothing has resolved it.
    OutcomeUnknown,
}

impl UseOutcome {
    pub fn parse(raw: &str) -> Option<Self> {
        Some(match raw {
            "pending" => Self::Pending,
            "confirmed" => Self::Confirmed,
            "safeToReflash" => Self::SafeToReflash,
            "outcomeUnknown" => Self::OutcomeUnknown,
            _ => return None,
        })
    }

    pub fn raw(self) -> &'static str {
        match self {
            Self::Pending => "pending",
            Self::Confirmed => "confirmed",
            Self::SafeToReflash => "safeToReflash",
            Self::OutcomeUnknown => "outcomeUnknown",
        }
    }

    fn settled(self) -> bool {
        matches!(self, Self::Confirmed | Self::SafeToReflash)
    }
}

/// Swift `StoredLedgerEvent`.
struct Event {
    kind: String,
    capability: String,
    consumption: Option<Consumption>,
    reservation: Option<String>,
    outcome: Option<Outcome>,
}

// MARK: - Decoding, in Swift's member order

impl Document {
    fn decode(value: &Value) -> Result<Self, Decoding> {
        let keyed = Keyed::of(value, Vec::new())?;
        let schema_version = keyed.string("schemaVersion")?;
        let records = keyed
            .array("records")?
            .into_iter()
            .map(|(record, path)| Record::decode(record, path))
            .collect::<Result<_, _>>()?;
        Ok(Self {
            schema_version,
            records,
        })
    }

    fn value(&self) -> Value {
        json!({
            "schemaVersion": self.schema_version,
            "records": self.records.iter().map(Record::value).collect::<Vec<_>>(),
        })
    }
}

impl Record {
    fn decode(value: &Value, path: Vec<Step>) -> Result<Self, Decoding> {
        let keyed = Keyed::of(value, path)?;
        let capability =
            Capability::decode(keyed.present("capability")?, keyed.path("capability"))?;
        let remaining_uses = keyed.int("remainingUses")?;
        let consumptions = keyed
            .array("consumptions")?
            .into_iter()
            .map(|(use_, path)| Consumption::decode(use_, path))
            .collect::<Result<_, _>>()?;
        Ok(Self {
            capability,
            remaining_uses,
            consumptions,
        })
    }

    fn value(&self) -> Value {
        json!({
            "capability": self.capability.value(),
            "remainingUses": self.remaining_uses,
            "consumptions": self
                .consumptions
                .iter()
                .map(|use_| use_.value("outcomes"))
                .collect::<Vec<_>>(),
        })
    }

    /// Swift `status(of:)`'s blocker: the first use without a settled
    /// outcome, else an exhausted budget.
    fn blocker(&self) -> Option<String> {
        if let Some(unresolved) = self
            .consumptions
            .iter()
            .find(|use_| !use_.current().settled())
        {
            return Some(format!(
                "use {} is {}",
                unresolved.ordinal,
                unresolved.current().raw()
            ));
        }
        (self.remaining_uses == 0).then(|| "maximumUses exhausted".to_owned())
    }

    /// The daemon's `capability.list` row.
    fn row(&self) -> Value {
        let blocker = self.blocker();
        json!({
            "capabilityId": self.capability.id,
            "effectCeiling": self.capability.effect_ceiling.raw(),
            "maximumUses": self.capability.maximum_uses,
            "remainingUses": self.remaining_uses,
            "consumptionCount": self.consumptions.len(),
            "lineageAllowsNewExecution": blocker.is_none(),
            "lineageBlocker": blocker,
        })
    }

    /// Swift `RuntimeCapabilityStatus`, encoded as `capability.inspect`
    /// answers it: an absent blocker has no member.
    fn status(&self) -> Value {
        let blocker = self.blocker();
        let mut status = Map::new();
        status.insert("capability".into(), self.capability.value());
        status.insert("remainingUses".into(), json!(self.remaining_uses));
        status.insert("consumptionCount".into(), json!(self.consumptions.len()));
        status.insert("lineageAllowsNewExecution".into(), json!(blocker.is_none()));
        if let Some(blocker) = blocker {
            status.insert("lineageBlocker".into(), json!(blocker));
        }
        status.insert(
            "lineage".into(),
            Value::Array(
                self.consumptions
                    .iter()
                    .map(|use_| use_.value("outcomeHistory"))
                    .collect(),
            ),
        );
        Value::Object(status)
    }
}

impl Capability {
    /// Swift `RuntimeCapability(from:)` over a document: every member, then
    /// the model's invariants, then the exact current field shape. A refusal
    /// is Swift's `DecodingError` description.
    pub fn from_value(value: &Value) -> Result<Self, String> {
        Self::decode(value, Vec::new()).map_err(|error| error.describe())
    }

    /// Swift `capabilityID`.
    pub fn id(&self) -> &str {
        &self.id
    }

    /// Swift `RuntimeCapability.init(...)` for an envelope the Runtime issues:
    /// its members as the store encodes them, refused with Swift's
    /// `RuntimeCapabilityValidationError` when it breaks the model.
    pub(crate) fn issued(value: &Value) -> Result<Self, String> {
        let capability = Self::members(value, Vec::new()).map_err(|error| error.describe())?;
        capability.invariants()?;
        Ok(capability)
    }

    /// Swift `RuntimeCapability.init(from:)`: every member, then the model's
    /// invariants, then the exact current field shape.
    fn decode(value: &Value, path: Vec<Step>) -> Result<Self, Decoding> {
        let capability = Self::members(value, path.clone())?;
        capability
            .invariants()
            .map_err(|violation| Decoding::DataCorrupted {
                description: format!("capability violates model invariants: {violation}"),
                path: path.clone(),
            })?;
        if swift_value(value) != capability.value() {
            return Err(Decoding::DataCorrupted {
                description: "unsupported current capability field shape".into(),
                path,
            });
        }
        Ok(capability)
    }

    /// Every member, as Swift's decoder reads them.
    fn members(value: &Value, path: Vec<Step>) -> Result<Self, Decoding> {
        let keyed = Keyed::of(value, path)?;
        let id = keyed.string("capabilityID")?;
        let target_scope = TargetScope::decode(&keyed.keyed("targetScope")?)?;
        let operation_scope = keyed
            .array("operationScope")?
            .into_iter()
            .map(|(scope, path)| {
                let scope = Keyed::of(scope, path)?;
                Ok(OperationScope {
                    operation_id: scope.string("operationID")?,
                    version: scope.optional_int("version")?,
                })
            })
            .collect::<Result<_, Decoding>>()?;
        let effect_ceiling = keyed.raw("effectCeiling", "WorkflowEffect", Effect::parse)?;
        let constraints = keyed.keyed("inputConstraints")?;
        let input_constraints = constraints
            .members
            .iter()
            .map(|(name, constraint)| {
                Ok((
                    name.clone(),
                    Constraint::decode(&Keyed::of(constraint, constraints.path(name))?)?,
                ))
            })
            .collect::<Result<_, Decoding>>()?;
        let exact_inputs = keyed
            .optional("exactInputs")
            .map(|inputs| {
                Keyed::of(inputs, keyed.path("exactInputs")).map(|inputs| {
                    inputs
                        .members
                        .iter()
                        .map(|(name, input)| (name.clone(), swift_value(input)))
                        .collect()
                })
            })
            .transpose()?;
        let exact_artifact_facts = keyed
            .optional("exactArtifactFacts")
            .map(|facts| {
                let facts = Keyed::of(facts, keyed.path("exactArtifactFacts"))?;
                facts
                    .members
                    .iter()
                    .map(|(name, fact)| Ok((name.clone(), string(fact, facts.path(name))?)))
                    .collect::<Result<Vec<_>, Decoding>>()
            })
            .transpose()?;
        let issued_at = keyed.string("issuedAtUTC")?;
        let expires_at = keyed.string("expiresAtUTC")?;
        let maximum_uses = keyed.int("maximumUses")?;
        let issuer = keyed.keyed("issuer")?;
        let issuer_kind = issuer.raw("kind", "Kind", IssuerKind::parse)?;
        let issuer_reference = issuer.string("reference")?;
        let exact_plan_digest = keyed.optional_string("exactPlanDigest")?;
        let exact_binding_revision = keyed.optional_int("exactBindingRevision")?;
        let revocation = Revocation::decode(&keyed.keyed("revocation")?)?;
        Ok(Self {
            id,
            target_scope,
            operation_scope,
            effect_ceiling,
            input_constraints,
            exact_inputs,
            exact_artifact_facts,
            issued_at,
            expires_at,
            maximum_uses,
            issuer_kind,
            issuer_reference,
            exact_plan_digest,
            exact_binding_revision,
            revocation,
        })
    }

    /// The synthesized encoding: an absent optional has no member.
    pub fn value(&self) -> Value {
        let mut capability = Map::new();
        capability.insert("capabilityID".into(), json!(self.id));
        capability.insert("targetScope".into(), self.target_scope.value());
        capability.insert(
            "operationScope".into(),
            Value::Array(
                self.operation_scope
                    .iter()
                    .map(|scope| {
                        let mut value = Map::new();
                        value.insert("operationID".into(), json!(scope.operation_id));
                        if let Some(version) = scope.version {
                            value.insert("version".into(), json!(version));
                        }
                        Value::Object(value)
                    })
                    .collect(),
            ),
        );
        capability.insert("effectCeiling".into(), json!(self.effect_ceiling.raw()));
        capability.insert(
            "inputConstraints".into(),
            Value::Object(
                self.input_constraints
                    .iter()
                    .map(|(name, constraint)| (name.clone(), constraint.value()))
                    .collect(),
            ),
        );
        if let Some(inputs) = &self.exact_inputs {
            capability.insert("exactInputs".into(), Value::Object(inputs.clone()));
        }
        if let Some(facts) = &self.exact_artifact_facts {
            capability.insert(
                "exactArtifactFacts".into(),
                Value::Object(
                    facts
                        .iter()
                        .map(|(name, fact)| (name.clone(), json!(fact)))
                        .collect(),
                ),
            );
        }
        capability.insert("issuedAtUTC".into(), json!(self.issued_at));
        capability.insert("expiresAtUTC".into(), json!(self.expires_at));
        capability.insert("maximumUses".into(), json!(self.maximum_uses));
        capability.insert(
            "issuer".into(),
            json!({"kind": self.issuer_kind.raw(), "reference": self.issuer_reference}),
        );
        if let Some(digest) = &self.exact_plan_digest {
            capability.insert("exactPlanDigest".into(), json!(digest));
        }
        if let Some(revision) = self.exact_binding_revision {
            capability.insert("exactBindingRevision".into(), json!(revision));
        }
        capability.insert("revocation".into(), self.revocation.value());
        Value::Object(capability)
    }

    /// Swift `RuntimeCapability.validate()`: the first violated invariant, as
    /// Swift interpolates its `RuntimeCapabilityValidationError`.
    fn invariants(&self) -> Result<(), String> {
        let well_formed_id = self.id.strip_prefix("CAP-RT-").is_some_and(|suffix| {
            !suffix.is_empty()
                && suffix
                    .chars()
                    .all(|c| c.is_ascii_digit() || c.is_ascii_uppercase() || c == '-')
        });
        if !well_formed_id {
            return Err(case_text("malformedCapabilityID", &self.id));
        }
        if !matches!(
            self.effect_ceiling,
            Effect::DeviceMutation | Effect::Destructive
        ) {
            return Err(format!(
                "unsupportedEffectCeiling(ArkDeckCore.WorkflowEffect.{})",
                self.effect_ceiling.raw()
            ));
        }
        if self.operation_scope.is_empty() {
            return Err("emptyOperationScope".into());
        }
        for scope in &self.operation_scope {
            if scope.operation_id.is_empty()
                || scope.version.is_some_and(|version| version < 1)
                || !scope
                    .operation_id
                    .chars()
                    .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '.' || c == '-')
            {
                return Err(case_text("malformedOperationReference", &scope.reference()));
            }
        }
        if let TargetScope::StablePhysicalIdentity(sha256) = &self.target_scope
            && !hex_digest(sha256)
        {
            return Err(case_text("malformedStableIdentity", sha256));
        }
        let runtime_policy = self.issuer_kind == IssuerKind::RuntimeDefaultPolicy;
        if self.effect_ceiling == Effect::Destructive {
            if !matches!(self.target_scope, TargetScope::StablePhysicalIdentity(_)) {
                return Err("destructiveRequiresStableIdentityTarget".into());
            }
            if self.exact_plan_digest.is_none() {
                return Err("destructiveRequiresExactPlanDigest".into());
            }
            if self.maximum_uses != 1 {
                return Err("destructiveRequiresSingleUse".into());
            }
        }
        if runtime_policy && self.exact_inputs.is_none() {
            return Err("runtimePolicyRequiresExactInputs".into());
        }
        if self.effect_ceiling == Effect::Destructive
            && runtime_policy
            && self
                .exact_artifact_facts
                .as_ref()
                .is_none_or(|facts| facts.is_empty())
        {
            return Err("runtimePolicyRequiresExactArtifactFacts".into());
        }
        if self.exact_artifact_facts.as_ref().is_some_and(|facts| {
            facts.iter().any(|(name, fact)| {
                name.is_empty()
                    || fact.is_empty()
                    || characters(name) > 80
                    || characters(fact) > 256
            })
        }) {
            return Err("runtimePolicyRequiresExactArtifactFacts".into());
        }
        if let Some(digest) = &self.exact_plan_digest
            && !hex_digest(digest)
        {
            return Err(case_text("malformedPlanDigest", digest));
        }
        if let Some(revision) = self.exact_binding_revision
            && revision < 1
        {
            return Err(format!("malformedBindingRevision({revision})"));
        }
        for timestamp in [&self.issued_at, &self.expires_at] {
            if !fixed_utc(timestamp) {
                return Err(case_text("malformedTimestamp", timestamp));
            }
        }
        if self.expires_at <= self.issued_at {
            return Err("expiryNotAfterIssue".into());
        }
        if !(1..=10_000).contains(&self.maximum_uses) {
            return Err(format!("invalidMaximumUses({})", self.maximum_uses));
        }
        if self.issuer_reference.is_empty() || characters(&self.issuer_reference) > 200 {
            return Err(case_text(
                "malformedIssuerReference",
                &self.issuer_reference,
            ));
        }
        for (name, constraint) in &self.input_constraints {
            if !name.chars().next().is_some_and(char::is_lowercase)
                || !name.chars().all(|c| c.is_ascii_alphanumeric())
            {
                return Err(case_text("forbiddenInputConstraintKey", name));
            }
            let empty = match constraint {
                Constraint::OneOfStrings(values) => values.is_empty(),
                Constraint::IntegerRange(minimum, maximum) => minimum > maximum,
                Constraint::ExactString(_) => false,
            };
            if empty {
                return Err(case_text("emptyInputConstraint", name));
            }
        }
        Ok(())
    }

    /// Swift `RuntimeCapability.authorizes`: the first condition the query
    /// fails, in Swift's order, with Swift's reason and detail. `now_utc` and
    /// `remaining_uses` come from the store; the model reads no clock.
    pub fn authorizes(
        &self,
        query: &CapabilityQuery,
        now_utc: &str,
        remaining_uses: i64,
    ) -> Result<(), CapabilityDenial> {
        if let Revocation::Revoked { at, reason } = &self.revocation {
            return Err(denial("revoked", format!("revoked at {at}: {reason}")));
        }
        if !fixed_utc(now_utc) {
            return Err(denial(
                "expired",
                format!("unverifiable clock value {now_utc}"),
            ));
        }
        if now_utc < self.issued_at.as_str() {
            return Err(denial(
                "notYetValid",
                format!("issued at {}", self.issued_at),
            ));
        }
        if now_utc >= self.expires_at.as_str() {
            return Err(denial("expired", format!("expired at {}", self.expires_at)));
        }
        if remaining_uses <= 0 {
            return Err(denial(
                "exhausted",
                format!("maximumUses {} consumed", self.maximum_uses),
            ));
        }
        if query.effect.rank() > self.effect_ceiling.rank() {
            return Err(denial(
                "effectAboveCeiling",
                format!(
                    "requested {} above ceiling {}",
                    query.effect.raw(),
                    self.effect_ceiling.raw()
                ),
            ));
        }
        if !self.operation_scope.iter().any(|scope| {
            same_text(&scope.operation_id, &query.operation_id)
                && scope.version == query.operation_version
        }) {
            return Err(denial(
                "operationScopeMismatch",
                format!("{} not in scope", query.operation_reference()),
            ));
        }
        match &self.target_scope {
            TargetScope::AnyTarget => {}
            TargetScope::StablePhysicalIdentity(expected) => {
                let Some(actual) = &query.target_stable_identity_sha256 else {
                    return Err(denial(
                        "targetIdentityRequired",
                        "query carries no stable identity",
                    ));
                };
                if !same_text(actual, expected) {
                    return Err(denial(
                        "targetScopeMismatch",
                        "stable identity does not match scope",
                    ));
                }
            }
            TargetScope::WorkspaceIdentity {
                sha256,
                expected_revision,
                allowed_scopes,
            } => {
                let (Some(identity), Some(revision), Some(scopes)) = (
                    &query.workspace_identity_sha256,
                    &query.workspace_revision,
                    &query.workspace_file_scopes_digest,
                ) else {
                    return Err(denial(
                        "targetIdentityRequired",
                        "query carries no workspace identity, revision or scope digest",
                    ));
                };
                if !same_text(identity, sha256) {
                    return Err(denial(
                        "targetScopeMismatch",
                        "workspace identity does not match scope",
                    ));
                }
                // An empty expected revision is a standing grant: this tree and
                // these scopes, not this tree at this instant.
                if !expected_revision.is_empty() && !same_text(revision, expected_revision) {
                    return Err(denial(
                        "targetScopeMismatch",
                        "workspace revision moved since this capability was issued",
                    ));
                }
                if !same_text(scopes, allowed_scopes) {
                    return Err(denial(
                        "targetScopeMismatch",
                        "workspace writable scopes differ from the authorized set",
                    ));
                }
            }
        }
        if let Some(expected) = self.exact_binding_revision {
            let Some(actual) = query.target_binding_revision else {
                return Err(denial(
                    "targetScopeMismatch",
                    "query carries no target binding revision",
                ));
            };
            if actual != expected {
                return Err(denial(
                    "targetScopeMismatch",
                    "target binding revision differs",
                ));
            }
        }
        if let Some(expected) = &self.exact_plan_digest {
            let Some(actual) = &query.plan_digest else {
                return Err(denial("planDigestRequired", "query carries no plan digest"));
            };
            if !same_text(actual, expected) {
                return Err(denial("planDigestMismatch", "plan digest differs"));
            }
        }
        if let Some(exact) = &self.exact_inputs
            && swift_value(&Value::Object(query.inputs.clone())) != Value::Object(exact.clone())
        {
            return Err(denial(
                "inputConstraintViolated",
                "typed inputs differ from the runtime-issued envelope",
            ));
        }
        if let Some(facts) = &self.exact_artifact_facts
            && !same_facts(facts, &query.artifact_facts)
        {
            return Err(denial(
                "inputConstraintViolated",
                "Runtime-resolved Artifact identity or content digest differs",
            ));
        }
        for (name, constraint) in &self.input_constraints {
            let Some(value) = query.inputs.get(name) else {
                return Err(denial(
                    "inputConstraintViolated",
                    format!("constrained input {name} is absent"),
                ));
            };
            if !constraint.permits(value) {
                return Err(denial(
                    "inputConstraintViolated",
                    format!("input {name} violates constraint"),
                ));
            }
        }
        Ok(())
    }

    /// Swift `permitsWorkspaceStandingMaterialization`: a maintainer's
    /// workspace standing grant, which pins no revision, authorizes uses whose
    /// scope differs from its first use's.
    fn permits_workspace_standing_materialization(&self) -> bool {
        self.effect_ceiling == Effect::DeviceMutation
            && self.issuer_kind == IssuerKind::MaintainerMergedPr
            && matches!(
                &self.target_scope,
                TargetScope::WorkspaceIdentity { expected_revision, .. }
                    if expected_revision.is_empty()
            )
    }
}

impl TargetScope {
    fn decode(keyed: &Keyed<'_>) -> Result<Self, Decoding> {
        let kind = keyed.string("kind")?;
        match kind.as_str() {
            "anyTarget" => Ok(Self::AnyTarget),
            "stablePhysicalIdentity" => Ok(Self::StablePhysicalIdentity(keyed.string("sha256")?)),
            "workspaceIdentity" => Ok(Self::WorkspaceIdentity {
                sha256: keyed.string("sha256")?,
                expected_revision: keyed.string("expectedWorkspaceRevision")?,
                allowed_scopes: keyed.string("allowedFileScopesDigest")?,
            }),
            _ => Err(keyed.corrupted("kind", format!("unknown target scope kind {kind}"))),
        }
    }

    fn value(&self) -> Value {
        match self {
            Self::AnyTarget => json!({"kind": "anyTarget"}),
            Self::StablePhysicalIdentity(sha256) => {
                json!({"kind": "stablePhysicalIdentity", "sha256": sha256})
            }
            Self::WorkspaceIdentity {
                sha256,
                expected_revision,
                allowed_scopes,
            } => json!({
                "kind": "workspaceIdentity",
                "sha256": sha256,
                "expectedWorkspaceRevision": expected_revision,
                "allowedFileScopesDigest": allowed_scopes,
            }),
        }
    }
}

impl Constraint {
    /// Swift `RuntimeCapabilityInputConstraint.permits`: the string a string
    /// constraint names, or for a range an integer, or a number with no
    /// fraction, inside it.
    fn permits(&self, value: &Value) -> bool {
        match (self, value) {
            (Self::ExactString(expected), Value::String(actual)) => same_text(expected, actual),
            (Self::OneOfStrings(allowed), Value::String(actual)) => {
                allowed.iter().any(|allowed| same_text(allowed, actual))
            }
            (Self::IntegerRange(minimum, maximum), Value::Number(number)) => {
                swift_integer(number).is_some_and(|value| (*minimum..=*maximum).contains(&value))
            }
            _ => false,
        }
    }

    fn decode(keyed: &Keyed<'_>) -> Result<Self, Decoding> {
        let kind = keyed.string("kind")?;
        match kind.as_str() {
            "exactString" => Ok(Self::ExactString(keyed.string("value")?)),
            "oneOfStrings" => Ok(Self::OneOfStrings(
                keyed
                    .array("values")?
                    .into_iter()
                    .map(|(value, path)| string(value, path))
                    .collect::<Result<_, _>>()?,
            )),
            "integerRange" => Ok(Self::IntegerRange(
                keyed.int("minimum")?,
                keyed.int("maximum")?,
            )),
            _ => Err(keyed.corrupted("kind", format!("unknown constraint kind {kind}"))),
        }
    }

    fn value(&self) -> Value {
        match self {
            Self::ExactString(value) => json!({"kind": "exactString", "value": value}),
            Self::OneOfStrings(values) => json!({"kind": "oneOfStrings", "values": values}),
            Self::IntegerRange(minimum, maximum) => {
                json!({"kind": "integerRange", "minimum": minimum, "maximum": maximum})
            }
        }
    }
}

impl Revocation {
    fn decode(keyed: &Keyed<'_>) -> Result<Self, Decoding> {
        let state = keyed.string("state")?;
        match state.as_str() {
            "active" => Ok(Self::Active),
            "revoked" => Ok(Self::Revoked {
                at: keyed.string("atUTC")?,
                reason: keyed.string("reason")?,
            }),
            _ => Err(keyed.corrupted("state", format!("unknown revocation state {state}"))),
        }
    }

    fn value(&self) -> Value {
        match self {
            Self::Active => json!({"state": "active"}),
            Self::Revoked { at, reason } => {
                json!({"state": "revoked", "atUTC": at, "reason": reason})
            }
        }
    }
}

impl Consumption {
    fn decode(value: &Value, path: Vec<Step>) -> Result<Self, Decoding> {
        let keyed = Keyed::of(value, path)?;
        Ok(Self {
            ordinal: keyed.int("ordinal")?,
            reservation: keyed.string("reservationID")?,
            job: keyed.string("jobID")?,
            consumed_at: keyed.string("consumedAtUTC")?,
            operation_reference: keyed.string("operationReference")?,
            effect: keyed.string("effect")?,
            target: keyed.optional_string("targetStableIdentitySHA256")?,
            binding_revision: keyed.optional_int("bindingRevision")?,
            plan_digest: keyed.optional_string("materializedPlanDigest")?,
            authorization_scope: keyed.string("authorizationScopeFingerprintSHA256")?,
            query: keyed.string("queryFingerprintSHA256")?,
            remaining_after: keyed.int("remainingUsesAfter")?,
            previous_lineage: keyed.optional_string("previousLineageSHA256")?,
            receipt: keyed.string("receiptSHA256")?,
            outcomes: keyed
                .array("outcomes")?
                .into_iter()
                .map(|(outcome, path)| Outcome::decode(outcome, path))
                .collect::<Result<_, _>>()?,
        })
    }

    /// The use as the store holds it (`outcomes`) or as a status's lineage
    /// entry shows it (`outcomeHistory`).
    fn value(&self, outcomes: &str) -> Value {
        let mut use_ = self.material_members();
        use_.insert("receiptSHA256".into(), json!(self.receipt));
        use_.insert(
            outcomes.into(),
            Value::Array(self.outcomes.iter().map(Outcome::value).collect()),
        );
        Value::Object(use_)
    }

    /// Every member but the receipt and outcomes: what the receipt digests,
    /// apart from the capability's identity.
    fn material_members(&self) -> Map<String, Value> {
        let mut members = Map::new();
        members.insert("ordinal".into(), json!(self.ordinal));
        members.insert("reservationID".into(), json!(self.reservation));
        members.insert("jobID".into(), json!(self.job));
        members.insert("consumedAtUTC".into(), json!(self.consumed_at));
        members.insert("operationReference".into(), json!(self.operation_reference));
        members.insert("effect".into(), json!(self.effect));
        if let Some(target) = &self.target {
            members.insert("targetStableIdentitySHA256".into(), json!(target));
        }
        if let Some(revision) = self.binding_revision {
            members.insert("bindingRevision".into(), json!(revision));
        }
        if let Some(plan) = &self.plan_digest {
            members.insert("materializedPlanDigest".into(), json!(plan));
        }
        members.insert(
            "authorizationScopeFingerprintSHA256".into(),
            json!(self.authorization_scope),
        );
        members.insert("queryFingerprintSHA256".into(), json!(self.query));
        members.insert("remainingUsesAfter".into(), json!(self.remaining_after));
        if let Some(previous) = &self.previous_lineage {
            members.insert("previousLineageSHA256".into(), json!(previous));
        }
        members
    }

    /// Swift `receipt(capabilityID:consumption:)`.
    fn to_receipt(&self, capability: &str) -> ConsumptionReceipt {
        ConsumptionReceipt {
            capability_id: capability.to_owned(),
            ordinal: self.ordinal,
            reservation_id: self.reservation.clone(),
            job_id: self.job.clone(),
            consumed_at_utc: self.consumed_at.clone(),
            operation_reference: self.operation_reference.clone(),
            query_fingerprint_sha256: self.query.clone(),
            remaining_uses_after: self.remaining_after,
            previous_lineage_sha256: self.previous_lineage.clone(),
            receipt_sha256: self.receipt.clone(),
        }
    }

    /// Swift `ReceiptMaterial`.
    fn receipt_material(&self, capability: &str) -> Value {
        let mut material = self.material_members();
        material.insert("capabilityID".into(), json!(capability));
        Value::Object(material)
    }
}

impl Outcome {
    fn decode(value: &Value, path: Vec<Step>) -> Result<Self, Decoding> {
        let keyed = Keyed::of(value, path)?;
        Ok(Self {
            job: keyed.string("jobID")?,
            outcome: keyed.raw("outcome", "RuntimeCapabilityUseOutcome", UseOutcome::parse)?,
            terminal_state: keyed.string("terminalState")?,
            recorded_at: keyed.string("recordedAtUTC")?,
            previous_record: keyed.string("previousRecordSHA256")?,
            record: keyed.string("recordSHA256")?,
        })
    }

    fn value(&self) -> Value {
        json!({
            "jobID": self.job,
            "outcome": self.outcome.raw(),
            "terminalState": self.terminal_state,
            "recordedAtUTC": self.recorded_at,
            "previousRecordSHA256": self.previous_record,
            "recordSHA256": self.record,
        })
    }

    /// Swift `OutcomeMaterial`.
    fn material(&self, capability: &str, use_: &Consumption) -> Value {
        json!({
            "capabilityID": capability,
            "ordinal": use_.ordinal,
            "reservationID": use_.reservation,
            "jobID": self.job,
            "outcome": self.outcome.raw(),
            "terminalState": self.terminal_state,
            "recordedAtUTC": self.recorded_at,
            "previousRecordSHA256": self.previous_record,
        })
    }
}

impl Event {
    fn decode(value: &Value) -> Result<Self, Decoding> {
        let keyed = Keyed::of(value, Vec::new())?;
        Ok(Self {
            kind: keyed.string("kind")?,
            capability: keyed.string("capabilityID")?,
            consumption: keyed
                .optional("consumption")
                .map(|use_| Consumption::decode(use_, keyed.path("consumption")))
                .transpose()?,
            reservation: keyed.optional_string("reservationID")?,
            outcome: keyed
                .optional("outcome")
                .map(|outcome| Outcome::decode(outcome, keyed.path("outcome")))
                .transpose()?,
        })
    }

    fn value(&self) -> Value {
        let mut event = Map::new();
        event.insert("kind".into(), json!(self.kind));
        event.insert("capabilityID".into(), json!(self.capability));
        if let Some(use_) = &self.consumption {
            event.insert("consumption".into(), use_.value("outcomes"));
        }
        if let Some(reservation) = &self.reservation {
            event.insert("reservationID".into(), json!(reservation));
        }
        if let Some(outcome) = &self.outcome {
            event.insert("outcome".into(), outcome.value());
        }
        Value::Object(event)
    }
}

// MARK: - Replay and validation

/// Swift `apply(_:to:)`: one appended event over the replayed document.
fn apply(event: &Event, document: &mut Document) -> Result<(), CapabilityStoreError> {
    let corrupted = |detail: String| CapabilityStoreError::Corrupted(detail);
    let Some(record) = document
        .records
        .iter_mut()
        .find(|record| same_text(&record.capability.id, &event.capability))
    else {
        return Err(corrupted(format!(
            "ledger names capability {}, which the store does not hold",
            event.capability
        )));
    };
    match event.kind.as_str() {
        "consumed" => {
            let (Some(use_), None, None) = (&event.consumption, &event.reservation, &event.outcome)
            else {
                return Err(corrupted("ledger consume carries no use".into()));
            };
            if record
                .consumptions
                .iter()
                .any(|taken| same_text(&taken.reservation, &use_.reservation))
            {
                return Err(corrupted(format!(
                    "ledger replays reservation {} twice",
                    use_.reservation
                )));
            }
            record.consumptions.push(use_.clone());
            record.remaining_uses = use_.remaining_after;
        }
        "outcome" => {
            let (Some(reservation), Some(outcome), None) =
                (&event.reservation, &event.outcome, &event.consumption)
            else {
                return Err(corrupted("ledger outcome carries no record".into()));
            };
            let Some(use_) = record
                .consumptions
                .iter_mut()
                .find(|taken| same_text(&taken.reservation, reservation))
            else {
                return Err(corrupted(format!(
                    "ledger settles reservation {reservation}, which was never taken"
                )));
            };
            use_.outcomes.push(outcome.clone());
        }
        other => {
            return Err(corrupted(format!(
                "ledger holds an unknown event kind {other}"
            )));
        }
    }
    Ok(())
}

/// Swift `validate(_:)`: the schema, unique identities, use accounting,
/// lineage order, and each receipt and outcome as its digest binds it.
fn validate(document: &Document) -> Result<(), CapabilityStoreError> {
    let corrupted = |detail: String| Err(CapabilityStoreError::Corrupted(detail));
    if document.schema_version != SCHEMA_VERSION {
        return corrupted(format!(
            "unsupported schema version {}",
            document.schema_version
        ));
    }
    let mut identities = HashSet::new();
    if !document
        .records
        .iter()
        .all(|record| identities.insert(text_key(&record.capability.id)))
    {
        return corrupted("duplicate capability identity".into());
    }
    for record in &document.records {
        let id = &record.capability.id;
        let maximum = record.capability.maximum_uses;
        if record.remaining_uses < 0
            || record.remaining_uses > maximum
            || maximum - record.remaining_uses != record.consumptions.len() as i64
        {
            return corrupted(format!("inconsistent use accounting for {id}"));
        }
        let mut expected_previous: Option<&str> = None;
        let mut reservations = HashSet::new();
        for (offset, use_) in record.consumptions.iter().enumerate() {
            let expected_ordinal = offset as i64 + 1;
            if !lowercase_sha256(&use_.authorization_scope)
                || !lowercase_sha256(&use_.query)
                || use_.ordinal != expected_ordinal
                || use_.remaining_after != maximum - expected_ordinal
                || use_.previous_lineage.as_deref() != expected_previous
                || !reservations.insert(text_key(&use_.reservation))
            {
                return corrupted(format!("invalid lineage ordering for {id}"));
            }
            if digest(&use_.receipt_material(id)).as_deref() != Some(use_.receipt.as_str()) {
                return corrupted(format!(
                    "invalid receipt digest for {id} use {}",
                    use_.ordinal
                ));
            }
            let mut expected_outcome_previous = use_.receipt.as_str();
            let mut prior = UseOutcome::Pending;
            for outcome in &use_.outcomes {
                let allowed = prior == UseOutcome::Pending
                    || (prior == UseOutcome::OutcomeUnknown && outcome.outcome.settled());
                if !allowed
                    || outcome.outcome == UseOutcome::Pending
                    || outcome.job.is_empty()
                    || characters(&outcome.job) > 160
                    || outcome.previous_record != expected_outcome_previous
                {
                    return corrupted(format!(
                        "invalid outcome transition for {id} use {}",
                        use_.ordinal
                    ));
                }
                if digest(&outcome.material(id, use_)).as_deref() != Some(outcome.record.as_str()) {
                    return corrupted(format!(
                        "invalid outcome digest for {id} use {}",
                        use_.ordinal
                    ));
                }
                prior = outcome.outcome;
                expected_outcome_previous = &outcome.record;
            }
            expected_previous = Some(use_.lineage_tip());
        }
    }
    Ok(())
}

// MARK: - Admission of a new execution

/// Swift `validateNewExecution(record:query:nowUTC:)`: a subject the ledger
/// can name, a complete plan, no earlier use left unsettled, the scope of the
/// lineage's first use, then the envelope's own authorization.
fn validate_new_execution(
    record: &Record,
    query: &CapabilityQuery,
    now_utc: &str,
) -> Result<(), CapabilityStoreError> {
    let device = query
        .target_stable_identity_sha256
        .as_deref()
        .is_some_and(lowercase_sha256)
        && query.target_binding_revision.unwrap_or(0) > 0;
    let workspace = [
        &query.workspace_identity_sha256,
        &query.workspace_revision,
        &query.workspace_file_scopes_digest,
    ]
    .into_iter()
    .all(|value| value.as_deref().is_some_and(lowercase_sha256));
    if !device && !workspace {
        return Err(CapabilityStoreError::Denied(denial(
            "targetIdentityRequired",
            "a device (stable identity + binding revision) or workspace \
             (identity + revision + scope digest) subject is required",
        )));
    }
    if !query.plan_digest.as_deref().is_some_and(lowercase_sha256) {
        return Err(CapabilityStoreError::Denied(denial(
            "planDigestRequired",
            "a complete materialized plan digest is required",
        )));
    }
    if let Some(unresolved) = record
        .consumptions
        .iter()
        .find(|use_| !use_.current().settled())
    {
        return Err(CapabilityStoreError::LineageBlocked(format!(
            "previous use {} is {}; new mutation dispatch is forbidden",
            unresolved.ordinal,
            unresolved.current().raw()
        )));
    }
    if let Some(first) = record.consumptions.first()
        && !record
            .capability
            .permits_workspace_standing_materialization()
        && first.authorization_scope != fingerprint(query, false)
    {
        return Err(CapabilityStoreError::LineageBlocked(
            "operation, effect, target, binding or typed inputs drifted from authorization \
             lineage use 1"
                .into(),
        ));
    }
    record
        .capability
        .authorizes(query, now_utc, record.remaining_uses)
        .map_err(CapabilityStoreError::Denied)
}

/// Swift `fingerprint(of:includePlan:)`: the lowercase SHA-256 of the query's
/// scope, one `name=value` line each, with the plan digest for the query
/// fingerprint and without it for the authorization scope. The workspace
/// revision is deliberately absent: it moves with every legitimate mutation.
fn fingerprint(query: &CapabilityQuery, include_plan: bool) -> String {
    let or_dash = |value: &Option<String>| value.clone().unwrap_or_else(|| "-".into());
    let mut lines = vec![
        format!("operation={}", query.operation_reference()),
        format!("effect={}", query.effect.raw()),
        format!("target={}", or_dash(&query.target_stable_identity_sha256)),
        format!(
            "bindingRevision={}",
            query
                .target_binding_revision
                .map_or_else(|| "-".into(), |revision| revision.to_string())
        ),
        format!("workspace={}", or_dash(&query.workspace_identity_sha256)),
        format!(
            "workspaceScopes={}",
            or_dash(&query.workspace_file_scopes_digest)
        ),
    ];
    if include_plan {
        lines.push(format!("plan={}", or_dash(&query.plan_digest)));
    }
    // Swift encodes the inputs as `JSONValue`s, whose numbers with no fraction
    // are integers.
    lines.push(
        match crate::session_json::encode(&swift_value(&Value::Object(query.inputs.clone()))) {
            Ok(bytes) => format!("inputs={}", String::from_utf8_lossy(&bytes)),
            Err(_) => "inputs=unencodable".into(),
        },
    );
    arkdeck_contract::sha256_hex(lines.join("\n").as_bytes())
}

/// Swift's `[String: String]` equality, of a capability's Artifact facts and
/// a query's.
fn same_facts(facts: &[(String, String)], query: &BTreeMap<String, String>) -> bool {
    facts.len() == query.len()
        && facts
            .iter()
            .all(|(name, fact)| query.get(name).is_some_and(|value| same_text(value, fact)))
}

/// Lineage material always encodes (Swift's precondition); this answers the
/// impossible case without a panic.
fn unencodable() -> CapabilityStoreError {
    CapabilityStoreError::Io("cannot encode capability lineage material".into())
}

fn publication_failure(error: DocumentPublishError) -> io::Error {
    match error {
        DocumentPublishError::BeforePublication(error)
        | DocumentPublishError::OutcomeUnknown(error) => error,
    }
}

// MARK: - Helpers

/// Swift's digest of lineage material: SHA-256 of its canonical encoding
/// (`[.sortedKeys, .withoutEscapingSlashes]`).
fn digest(material: &Value) -> Option<String> {
    crate::session_json::encode(material)
        .ok()
        .map(|bytes| arkdeck_contract::sha256_hex(&bytes))
}

fn case_text(case: &str, payload: &str) -> String {
    format!("{case}({})", swift_quoted(payload))
}

/// `SHA256Hex.isLowercaseSHA256`.
fn lowercase_sha256(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f'))
}

/// `RuntimeCapability.isHexDigest`.
fn hex_digest(value: &str) -> bool {
    lowercase_sha256(value)
}

/// `RuntimeCapability.isFixedFormatUTC`: exactly `YYYY-MM-DDTHH:MM:SSZ`.
fn fixed_utc(value: &str) -> bool {
    value.len() == 20
        && value.bytes().enumerate().all(|(index, byte)| match index {
            4 | 7 => byte == b'-',
            10 => byte == b'T',
            13 | 16 => byte == b':',
            19 => byte == b'Z',
            _ => byte.is_ascii_digit(),
        })
}
