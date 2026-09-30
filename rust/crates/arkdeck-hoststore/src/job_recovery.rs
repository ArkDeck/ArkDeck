//! Swift `RuntimeJobEngine.recover(records:)` over
//! `RuntimeRecoveryService.replay(_:)`, and the daemon-start pass
//! `recoverActiveJobs()` over `RuntimeJobRepository.activeJobs()`: ADR-0009
//! decision 2 as the maintainer ruled on 2026-09-19 (design §L.1 item 13),
//! its carriers ported unchanged.
//!
//! Recovery reopens the given Jobs, replays each journal, parks every
//! unresolved intent or unknown outcome in `waitingForRecovery`, and completes
//! only decisions the journal already holds: a reconcile decision's
//! transition, a cancellation at its journal-confirmed safe boundary, a
//! finalization interrupted before its terminal transition, and a debug HAP's
//! declared failure compensation, which stays waiting for its explicit
//! continuation. Each Job's record then gains its recovery marker (never twice
//! in a row) and is persisted, record file first and index row after, and a
//! Job admitted under a runtime capability re-asserts its use's outcome. It
//! never dispatches, resolves a fact, publishes a Session or changes
//! authority.
//!
//! A record this build cannot read is quarantined, as Swift quarantines it:
//! never rewritten, reported, and still counted as active. An ArkForge Flash
//! whose execution lived in the lane process the restart lost is parked
//! unknown and never redispatched; a complete-overwrite recovery interrupted
//! after its superseding epoch became durable completes to `recovered`,
//! journal-only.
use crate::artifact_read_owner::swift_string;
use crate::capability_store::{CapabilityStore, UseOutcome};
use crate::job_journal_events::{self as events, Envelope};
use crate::job_journal_replay::ReplayFacts;
use crate::job_journal_writer::{JournalWriter, inspect_journal};
use crate::job_owner::JobStore;
use crate::job_record::{JobRecord, terminal};
use crate::job_repository::JobRow;
use crate::job_run::failure;
use crate::operation_catalog::CatalogOperation;
use serde_json::Value;
use std::io;

/// Swift `ArkForgeFlashOperation.containsDurableRecordReference`: the
/// canonical reference, the alias as its records spell it, and the alias's
/// retired versioned spelling.
const ARKFORGE: [&str; 3] = ["flash.full-restore@1", "flash.dayu200", "flash.dayu200@1"];
/// The states whose ArkForge execution lived in the lane process a restart
/// lost (Swift `lostArkForgeExecutionState`).
const LANE_HELD: [&str; 7] = [
    "running",
    "waitingForDevice",
    "awaitingRebindConfirmation",
    "cancelRequested",
    "cancellingAtSafeBoundary",
    "recoveringByCompleteOverwrite",
    "resumeAtConfirmedSafeBoundary",
];
/// Swift `JobStateMachine.isAllowedTransition(from:to: .waitingForRecovery,
/// mode: .execute)`.
const PARKS: [&str; 11] = [
    "preflight",
    "running",
    "waitingForDevice",
    "awaitingRebindConfirmation",
    "cancelRequested",
    "cancellingAtSafeBoundary",
    "reconciling",
    "recoveringByCompleteOverwrite",
    "resumeAtConfirmedSafeBoundary",
    "userAbandonRequested",
    "finalizing",
];
/// Swift `RuntimeDebugHAPFailureFinalization.sourceSteps`.
const HAP_SOURCE_STEPS: [&str; 3] = ["send-hap", "install-hap", "start-ability"];

/// What one recovery made of the Jobs it was given.
#[derive(Debug, Default, PartialEq)]
pub struct RecoveredJobs {
    /// Swift's `[RuntimeJobStatus]`, each as `job.status` projects it: every
    /// Job recovered, in the order given.
    pub statuses: Vec<Value>,
    /// Swift `quarantinedJobRecords`: each Job whose record this build cannot
    /// read, and why. None of its bytes was written.
    pub quarantined: Vec<(String, String)>,
    /// Each Job whose recovery needs state this Runtime does not hold, and
    /// why. None of its bytes was written. Every Job this Runtime admits is
    /// recovered as Swift recovers it, so none is refused today; the daemon
    /// still reports any.
    pub refused: Vec<(String, String)>,
}

/// Why a recovery stopped, spelled as Swift interpolates its error. As in
/// Swift, a Job recovered before the failure stays recovered.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RecoveryError(pub String);

impl std::fmt::Display for RecoveryError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}
impl std::error::Error for RecoveryError {}

/// A `RuntimeJobEngineError` case, as Swift interpolates it.
fn engine(case: &str, detail: &str) -> RecoveryError {
    RecoveryError(format!("{case}({})", swift_string(detail)))
}

fn internal(detail: impl AsRef<str>) -> RecoveryError {
    engine("internalFailure", detail.as_ref())
}

fn clock(now: fn() -> Option<String>) -> Result<String, RecoveryError> {
    now().ok_or_else(|| internal("the Runtime clock is unavailable"))
}

/// Swift `recoverActiveJobs()`: every Job the index holds in a state that is
/// not terminal (a state this build does not know included), in creation and
/// then identity order, recovered as [`recover_jobs`] recovers them. The
/// daemon runs it once at its start, before it serves.
pub fn recover_active_jobs(
    jobs: &JobStore,
    capabilities: Option<&CapabilityStore>,
    now: fn() -> Option<String>,
) -> Result<RecoveredJobs, RecoveryError> {
    let rows = jobs
        .active_rows()
        .map_err(|error| internal(format!("Runtime job repository is unreadable: {error}")))?;
    recover_rows(jobs, rows, capabilities, now)
}

/// Swift `recover(records:)` for the Jobs named, in that order, whatever
/// their state: a terminal Job too (`cleanupDebt.continue` reloads one this
/// way), whose clean journal only gains its `recovered: journal clean` marker
/// before its record is persisted again.
///
/// - Publishes no Session: as in Swift, a Job recovery closes is left for the
///   release path of `job.reconcile` to publish.
/// - Re-asserts, for every recovered Job admitted under a runtime capability,
///   its use's outcome in `capabilities`: `outcomeUnknown` with the state
///   `waitingForRecovery` for a Job whose outcome is unknown, `confirmed`
///   with its state for a terminal one (the same outcome recorded again
///   changes nothing; any other change is Swift's `outcomeConflict`).
///   `capabilities` may be `None` only when no Job named is such a Job: one
///   that is fails the whole call with an error naming it, before anything
///   is written for any Job.
/// - An unknown Job identity fails the call before anything is written.
/// - A Job whose record a failed `job.reconcile` holds resident is skipped,
///   as Swift skips a Job its engine holds.
pub fn recover_jobs(
    jobs: &JobStore,
    job_ids: &[String],
    capabilities: Option<&CapabilityStore>,
    now: fn() -> Option<String>,
) -> Result<RecoveredJobs, RecoveryError> {
    let mut rows = Vec::with_capacity(job_ids.len());
    for id in job_ids {
        match jobs.job_row(id) {
            Ok(Some(row)) => rows.push(row),
            Ok(None) => return Err(engine("jobNotFound", id)),
            Err(error) => {
                return Err(internal(format!(
                    "Runtime job history index is unreadable for {id}: {error}"
                )));
            }
        }
    }
    recover_rows(jobs, rows, capabilities, now)
}

/// Swift `RuntimeJobRecord.state(in:)`.
enum RecordState {
    Absent,
    Readable(Box<JobRecord>),
    Unreadable(String),
}

fn record_state(jobs: &JobStore, job_id: &str) -> RecordState {
    match jobs.record_bytes(job_id) {
        Err(error) if error.kind() == io::ErrorKind::NotFound => RecordState::Absent,
        Err(error) => RecordState::Unreadable(format!("job record cannot be read: {error}")),
        Ok(bytes) => match JobRecord::decode(&bytes) {
            Ok(record) => RecordState::Readable(Box::new(record)),
            Err(error) => RecordState::Unreadable(format!(
                "job record was written in a shape this build cannot read: {}",
                error.message
            )),
        },
    }
}

fn recover_rows(
    jobs: &JobStore,
    rows: Vec<JobRow>,
    capabilities: Option<&CapabilityStore>,
    now: fn() -> Option<String>,
) -> Result<RecoveredJobs, RecoveryError> {
    let mut result = RecoveredJobs::default();
    // A record this build cannot decode is set aside before anything reads
    // it: never live, never rewritten, still active so its evidence stays.
    let mut admissible = Vec::new();
    for row in rows {
        let record = match record_state(jobs, &row.id) {
            RecordState::Unreadable(reason) => {
                result.quarantined.push((row.id, reason));
                continue;
            }
            RecordState::Readable(record) => Some(*record),
            // The projection is restored from the admission's own record.
            RecordState::Absent => JobRecord::decode(&row.record).ok(),
        };
        if capabilities.is_none()
            && record
                .as_ref()
                .and_then(JobRecord::admission_evidence)
                .is_some_and(|evidence| evidence["kind"] == "runtimeCapability")
        {
            return Err(internal(format!(
                "job {} settles a runtime capability use and no capability store was given; \
                 nothing was recovered",
                row.id
            )));
        }
        admissible.push(row);
    }
    for row in &admissible {
        restore_initial_projection(jobs, row)?;
    }
    for row in &admissible {
        // Swift skips a Job its engine already holds resident.
        if jobs.holds_resident(&row.id) {
            continue;
        }
        let record = replay(jobs, row, now)?;
        jobs.persist(&record, &clock(now)?)
            .map_err(|error| internal(format!("{error:?}")))?;
        result.statuses.push(record.status());
        settle_capability(&record, capabilities, now)?;
    }
    Ok(result)
}

/// Every complete record of the Job's journal, in order (Swift
/// `DurableJournalRecovery.inspect(url:).events`).
fn journal_events(jobs: &JobStore, job_id: &str) -> Result<Vec<Value>, RecoveryError> {
    let bytes = jobs
        .journal_bytes(job_id)
        .map_err(|error| internal(format!("job {job_id} journal is unreadable: {error}")))?;
    let durable = bytes
        .iter()
        .rposition(|byte| *byte == b'\n')
        .map_or(0, |last| last + 1);
    bytes[..durable]
        .split(|byte| *byte == b'\n')
        .filter(|line| !line.is_empty())
        .map(|line| {
            serde_json::from_slice(line)
                .map_err(|_| internal(format!("job {job_id} journal cannot be replayed")))
        })
        .collect()
}

/// Swift `restoreInitialAdmissionProjectionIfNeeded`: recreates only the
/// wholly absent projection a process loss leaves between the admission
/// commit and the first journal append. A partial projection is refused,
/// never guessed at.
fn restore_initial_projection(jobs: &JobStore, row: &JobRow) -> Result<(), RecoveryError> {
    let id = row.id.as_str();
    let exists = |name: &str| {
        jobs.job_entry_exists(id, name)
            .map_err(|error| internal(format!("job {id} directory is unreadable: {error}")))
    };
    let (has_record, has_journal) = (exists("job-record.json")?, exists("journal.jsonl")?);
    if has_record && has_journal {
        return Ok(());
    }
    let record = JobRecord::decode(&row.record).map_err(|error| {
        internal(format!(
            "admitted job {id} has an invalid initial record: {}",
            error.message
        ))
    })?;
    if record.job_id != id || record.state != "preflight" {
        return Err(internal(format!(
            "admitted job {id} initial record does not match its transactional identity"
        )));
    }
    let partial = || {
        internal(format!(
            "admitted job {id} has a partial durable projection"
        ))
    };
    let directory = jobs
        .job_directory(id)
        .map_err(|error| internal(format!("{error:?}")))?;
    let publish = |record: &JobRecord| {
        jobs.publish_record_file(record)
            .map_err(|error| internal(format!("{error:?}")))
    };
    if has_journal {
        let facts = inspect_journal(&directory).map_err(|error| internal(format!("{error}")))?;
        let events = journal_events(jobs, id)?;
        if !has_record && facts.event_count == 0 {
            // The writer creates and synchronizes an empty journal before its
            // first append: still an admitted Job with no effect history.
            let mut journal = JournalWriter::open(&directory, false)
                .map_err(|error| internal(format!("{error}")))?;
            initial_admission_events(&mut journal, &record)?;
            return publish(&record);
        }
        let admitted = events.len() == 2
            && events[0]["kind"] == "jobCreated"
            && events[0]["jobId"] == id
            && events[1]["kind"] == "stateTransition"
            && events[1]["payload"]["from"] == "queued"
            && events[1]["payload"]["to"] == "preflight";
        if has_record || facts.event_count != 2 || !admitted {
            return Err(partial());
        }
        return publish(&record);
    }
    if has_record {
        return Err(partial());
    }
    let mut journal =
        JournalWriter::open(&directory, true).map_err(|error| internal(format!("{error}")))?;
    initial_admission_events(&mut journal, &record)?;
    publish(&record)
}

/// Swift `appendInitialAdmissionEvents`, at the Job's creation time.
fn initial_admission_events(
    journal: &mut JournalWriter,
    record: &JobRecord,
) -> Result<(), RecoveryError> {
    let envelope = |event_id: &str, sequence: i64| Envelope {
        event_id: event_id.into(),
        sequence,
        session_id: format!("session-{}", record.job_id),
        job_id: record.job_id.clone(),
        timestamp: record.created().into(),
    };
    for event in [
        events::job_created(
            &envelope("job-created", 0),
            "execute",
            "standardAgent",
            "CORE-2.0.0",
        ),
        events::state_transition(
            &envelope("to-preflight", 1),
            "queued",
            "preflight",
            "recovered committed admission",
            None,
        ),
    ] {
        journal
            .append(&event)
            .map_err(|error| internal(format!("{error}")))?;
    }
    Ok(())
}

/// The journal a replay appends to: only `recovery-t-<sequence>` transitions.
struct Journal {
    writer: JournalWriter,
    sequence: i64,
    job_id: String,
    now: fn() -> Option<String>,
}

impl Journal {
    /// Swift `appendTransition`: journaled and synchronized; the record takes
    /// its state from the replay afterwards.
    fn transition(
        &mut self,
        from: &str,
        to: &str,
        reason: &str,
        trigger: Option<&str>,
    ) -> Result<(), RecoveryError> {
        let envelope = Envelope {
            event_id: format!("recovery-t-{}", self.sequence),
            sequence: self.sequence,
            session_id: format!("session-{}", self.job_id),
            job_id: self.job_id.clone(),
            timestamp: clock(self.now)?,
        };
        self.writer
            .append(&events::state_transition(
                &envelope, from, to, reason, trigger,
            ))
            .map_err(|error| internal(format!("{error}")))?;
        self.sequence += 1;
        Ok(())
    }
}

/// Swift `appendRecoveryTimeline`: a parked Job is replayed on every start,
/// and an identical marker is not added twice in a row.
fn mark(record: &mut JobRecord, entry: &str) {
    if record.timeline.last().map(String::as_str) != Some(entry) {
        record.timeline.push(entry.into());
    }
}

/// Swift `outcomeUnknown = false` with the exact typed action forgotten.
fn settle_known(record: &mut JobRecord) {
    record.clear_outcome_unknown();
    record.set_recovery(None, None, None);
}

/// Swift `RuntimeRecoveryService.replay(_:)`.
fn replay(
    jobs: &JobStore,
    row: &JobRow,
    now: fn() -> Option<String>,
) -> Result<JobRecord, RecoveryError> {
    let id = row.id.as_str();
    let mut record = match record_state(jobs, id) {
        RecordState::Readable(record) => *record,
        RecordState::Absent => {
            return Err(internal(format!(
                "admitted job {id} has no durable record after recovery projection"
            )));
        }
        RecordState::Unreadable(reason) => {
            return Err(engine("jobRecordUnreadable", &format!("{id}: {reason}")));
        }
    };
    let directory = jobs
        .job_directory(id)
        .map_err(|error| internal(format!("{error:?}")))?;
    // Opening the writer cuts a torn tail back to its last complete record,
    // as Swift's `FileDurableJournal` does, or refuses.
    let writer =
        JournalWriter::open(&directory, false).map_err(|error| internal(format!("{error}")))?;
    let facts = writer.facts();
    let mut journal = Journal {
        sequence: facts.last_durable_sequence.map_or(0, |last| last + 1),
        writer,
        job_id: id.into(),
        now,
    };
    let refresh = |journal: &Journal| -> Result<(ReplayFacts, Vec<Value>), RecoveryError> {
        Ok((journal.writer.facts(), journal_events(jobs, id)?))
    };
    let (mut facts, mut events) = (facts, journal_events(jobs, id)?);

    // A crash after a reconcile decision may leave its mandatory triggered
    // transition unwritten: finish that journal-only decision first.
    if let Some(last) = events
        .last()
        .filter(|last| last["kind"] == "reconcileOutcome")
        && let Some(next) = last["payload"]["nextState"]
            .as_str()
            .filter(|next| crate::job_record::STATES.contains(next))
    {
        let (next, trigger) = (next.to_owned(), last["eventId"].as_str().map(str::to_owned));
        journal.transition(
            "reconciling",
            &next,
            "complete durable reconcile decision after restart",
            trigger.as_deref(),
        )?;
        (facts, events) = refresh(&journal)?;
    }

    let unresolved = facts.has_torn_tail
        || !facts.outstanding_intents.is_empty()
        || !facts.unknown_outcomes.is_empty()
        || facts.last_reconcile_outcome_certainty.as_deref() == Some("outcomeUnknown");
    let original = hap_original_failure(&record, &events);
    if let Some(original) = &original {
        record.set_operation_failure(Some(original.clone()));
    }
    let declared = hap_declares_finalization(&record, &events);
    if !unresolved && declared && facts.current_state.as_deref() == Some("running") {
        journal.transition(
            "running",
            "finalizing",
            "confirmed original failure has predeclared compensation; no redispatch",
            None,
        )?;
        (facts, events) = refresh(&journal)?;
    }
    // Identity may have failed before a compensation intent existed; the
    // waiting transition is durable before its record projection.
    let identity_proof_pending = declared
        && facts.outstanding_intents.is_empty()
        && facts.unknown_outcomes.is_empty()
        && matches!(
            facts.current_state.as_deref(),
            Some("waitingForRecovery" | "reconciling")
        )
        && events.iter().any(|event| {
            event["kind"] == "stateTransition"
                && event["payload"]["from"] == "finalizing"
                && event["payload"]["to"] == "waitingForRecovery"
        });
    // An ArkForge Flash's execution lives behind one delegated step: until
    // the lane's drive returns, its daemon job, receipts and completed plan
    // exist only in the lane's process. A restart can therefore find a clean
    // journal after an external execution started; resuming would materialize
    // the same destructive plan again, so the Job is parked unknown.
    let lane_lost = ARKFORGE.contains(&record.operation())
        && facts
            .current_state
            .as_deref()
            .is_some_and(|state| LANE_HELD.contains(&state));
    let park = unresolved || lane_lost || identity_proof_pending;
    if park
        && let Some(current) = facts
            .current_state
            .clone()
            .filter(|current| PARKS.contains(&current.as_str()) && current != "reconciling")
    {
        journal.transition(
            &current,
            "waitingForRecovery",
            if lane_lost {
                "durably park non-resumable ArkForge execution after restart"
            } else {
                "durably park unresolved provider intent after restart"
            },
            None,
        )?;
        (facts, events) = refresh(&journal)?;
    }

    if park {
        record.state = facts
            .current_state
            .clone()
            .unwrap_or_else(|| "waitingForRecovery".into());
        record.set_outcome_unknown();
        if record.recovery_step().is_none() {
            let step = facts
                .unknown_outcomes
                .last()
                .map(|unknown| unknown.step_id.clone())
                .or_else(|| {
                    facts
                        .outstanding_intents
                        .last()
                        .map(|intent| intent.step_id.clone())
                });
            let (intent, action) = (
                record.recovery_intent().map(str::to_owned),
                record.recovery_action().cloned(),
            );
            record.set_recovery(step.as_deref(), intent.as_deref(), action);
        }
        if identity_proof_pending {
            record.clear_finished();
            mark(
                &mut record,
                "recovered: declared compensation needs fresh identity proof; no redispatch",
            );
        } else if lane_lost {
            record.set_operation_failure(Some(failure(
                "outcomeUnknown",
                "unknownOutcome",
                "runtimeDecisionRequired",
                "awaitRuntimeReconciliation",
            )));
            if record.finished_at().is_none() {
                record.finish(&clock(now)?);
            }
            mark(
                &mut record,
                "recovered: ArkForge execution state was process-owned; parked unknown; no \
                 redispatch",
            );
        } else {
            mark(
                &mut record,
                "recovered: outstanding intents or unknown outcomes; no redispatch",
            );
        }
    } else {
        // A clean non-terminal cancellation or finalization has no resume
        // lane: complete only these already-durable decisions.
        match facts.current_state.as_deref() {
            Some(state @ ("cancelRequested" | "cancellingAtSafeBoundary" | "cancelled")) => {
                let state = state.to_owned();
                let requested = events.iter().any(|event| {
                    event["kind"] == "stateTransition"
                        && event["payload"]["to"] == "cancelRequested"
                });
                if !requested {
                    return Err(internal(
                        "terminal cancellation lacks its durable request transition",
                    ));
                }
                if state == "cancelRequested" {
                    journal.transition(
                        "cancelRequested",
                        "cancellingAtSafeBoundary",
                        "process loss with no outstanding intent is a confirmed safe boundary",
                        None,
                    )?;
                }
                if state != "cancelled" {
                    journal.transition(
                        "cancellingAtSafeBoundary",
                        "cancelled",
                        "complete durable cancellation after restart",
                        None,
                    )?;
                    (facts, events) = refresh(&journal)?;
                }
                record.set_operation_failure(Some(failure(
                    "cancelled",
                    "cancelled",
                    "notAutomatic",
                    "none",
                )));
                settle_known(&mut record);
                record.finish(&clock(now)?);
                mark(
                    &mut record,
                    "recovered: completed durable cancellation at journal-confirmed safe \
                     boundary; no redispatch",
                );
            }
            Some("finalizing") if declared => {
                record.set_operation_failure(original.clone());
                record.clear_outcome_unknown();
                record.clear_finished();
                mark(
                    &mut record,
                    "recovered: pending declared failure compensation; explicit continuation \
                     required; no redispatch",
                );
            }
            Some("finalizing") => {
                // A complete-overwrite recovery whose epoch is already
                // durable completes to `recovered`; any other interrupted
                // finalization fails.
                let established = jobs
                    .matching_recovery_epoch(&record, &events)
                    .map_err(|error| internal(format!("{error:?}")))?;
                if established.is_some() {
                    journal.transition(
                        "finalizing",
                        "recovered",
                        "complete terminal transition for durable superseding recovery epoch",
                        None,
                    )?;
                } else {
                    journal.transition(
                        "finalizing",
                        "failed",
                        "finalization was interrupted before its terminal transition",
                        None,
                    )?;
                }
                (facts, events) = refresh(&journal)?;
                record.finish(&clock(now)?);
                if facts.last_reconcile_outcome_certainty.as_deref() == Some("confirmed") {
                    settle_known(&mut record);
                }
                mark(
                    &mut record,
                    if established.is_some() {
                        "recovered: durable superseding epoch completed journal-only; no redispatch"
                    } else {
                        "recovered: finalization interrupted before terminal transition; failed \
                         without redispatch"
                    },
                );
            }
            _ => mark(&mut record, "recovered: journal clean"),
        }
        if let Some(current) = &facts.current_state {
            record.state.clone_from(current);
        }
        if facts.current_state.as_deref() == Some("resumeAtConfirmedSafeBoundary")
            && facts.last_reconcile_outcome_certainty.as_deref() == Some("confirmed")
        {
            settle_known(&mut record);
        }
    }
    if record.operation() == "debug.hap@1" {
        // The step kinds the journal's intents prove, after those the record
        // kept, in journal order.
        let mut kinds = record
            .step_kinds()
            .map(<[String]>::to_vec)
            .unwrap_or_default();
        for event in &events {
            let declared = match event["kind"].as_str() {
                Some("stepIntent") => &event["payload"]["step"],
                Some("compensationIntent") => &event["payload"]["descriptor"],
                _ => continue,
            };
            if let Some(kind) = declared["kind"].as_str()
                && !kinds.iter().any(|known| known == kind)
            {
                kinds.push(kind.into());
            }
        }
        record.set_step_kinds(kinds);
    }
    Ok(record)
}

/// Swift `RuntimeDebugHAPFailureFinalization.originalFailure(record:replay:)`:
/// the failure a debug HAP keeps through its failure finalization.
pub(crate) fn hap_original_failure(record: &JobRecord, events: &[Value]) -> Option<Value> {
    if record.operation() != "debug.hap@1" {
        return None;
    }
    if let Some(failure) = record
        .operation_failure()
        .filter(|failure| failure["code"] != "outcomeUnknown")
    {
        return Some(failure.clone());
    }
    // An optional confirmed failure is skipped on the normal path; only its
    // explicit failed reconciliation, or a required failed step, establishes
    // failure finalization when the record write was lost.
    let decided = events.iter().any(|event| {
        event["kind"] == "reconcileOutcome"
            && event["payload"]["result"] == "finalizeConfirmedFailure"
    });
    let descriptor = CatalogOperation::lookup("debug.hap", Some(1));
    let failed = events.iter().rev().find(|event| {
        event["kind"] == "stepOutcome"
            && event["payload"]["result"] == "failed"
            && event["payload"]["outcomeCertainty"] == "confirmed"
            && (decided
                || descriptor
                    .and_then(|descriptor| {
                        descriptor
                            .steps
                            .iter()
                            .find(|step| event["stepId"] == step.step_id.as_str())
                    })
                    .is_some_and(|step| !step.optional))
    })?;
    Some(
        if failed["payload"]["semanticCode"] == "confirmedNotExecuted" {
            failure(
                "executionConfirmedNotPerformed",
                "externalTool",
                "runtimeDecisionRequired",
                "submitNewTypedRequestAfterRuntimeProof",
            )
        } else {
            failure(
                "executionFailed",
                "execution",
                "runtimeDecisionRequired",
                "inspectJob",
            )
        },
    )
}

/// Whether Swift's `RuntimeDebugHAPFailureFinalization.derive(record:replay:)`
/// finds a failure finalization: an original failure, and a compensation a
/// send, install or start intent declared.
fn hap_declares_finalization(record: &JobRecord, events: &[Value]) -> bool {
    hap_original_failure(record, events).is_some()
        && events.iter().any(|event| {
            event["kind"] == "stepIntent"
                && event["stepId"]
                    .as_str()
                    .is_some_and(|step| HAP_SOURCE_STEPS.contains(&step))
                && event["payload"]["step"]["compensationDescriptors"]
                    .as_array()
                    .is_some_and(|declared| !declared.is_empty())
        })
}

/// Swift `recordCapabilityOutcome` after a recovered Job is persisted: the
/// use a runtime capability's Job consumed keeps the outcome the Job states.
fn settle_capability(
    record: &JobRecord,
    capabilities: Option<&CapabilityStore>,
    now: fn() -> Option<String>,
) -> Result<(), RecoveryError> {
    let Some(evidence) = record
        .admission_evidence()
        .filter(|evidence| evidence["kind"] == "runtimeCapability")
    else {
        return Ok(());
    };
    let (outcome, state) = if record.outcome_unknown() {
        (UseOutcome::OutcomeUnknown, "waitingForRecovery")
    } else if terminal(&record.state) {
        (UseOutcome::Confirmed, record.state.as_str())
    } else {
        return Ok(());
    };
    // Refused before anything was written when no store was given.
    let store = capabilities.ok_or_else(|| {
        internal(format!(
            "job {} settles a runtime capability use and no capability store was given",
            record.job_id
        ))
    })?;
    store
        .record_outcome(
            evidence["reference"].as_str().unwrap_or_default(),
            record.request["idempotencyKey"]
                .as_str()
                .unwrap_or_default(),
            &record.job_id,
            outcome,
            state,
            &clock(now)?,
        )
        .map_err(|error| {
            internal(format!(
                "authorization lineage could not become durable: {}",
                error.swift()
            ))
        })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn hap_record(failure: Option<Value>) -> JobRecord {
        let bytes = include_bytes!(
            "../../../tests/fixtures/debug-hap/store/jobs/job-e79d1b4e261f4a13d0bfb58a97fbf163/job-record.json"
        );
        let mut record = JobRecord::decode(bytes).unwrap();
        record.set_operation_failure(failure);
        record
    }

    #[test]
    fn a_debug_hap_keeps_its_recorded_failure_or_the_one_its_journal_proves() {
        let executed = failure(
            "executionFailed",
            "execution",
            "runtimeDecisionRequired",
            "inspectJob",
        );
        let kept = hap_record(Some(executed.clone()));
        assert_eq!(hap_original_failure(&kept, &[]), Some(executed.clone()));
        let unknown = hap_record(Some(failure(
            "outcomeUnknown",
            "unknownOutcome",
            "runtimeDecisionRequired",
            "awaitRuntimeReconciliation",
        )));
        assert_eq!(hap_original_failure(&unknown, &[]), None);
        // A required step's confirmed failure is the original failure; an
        // optional one only once a reconcile decided on failure.
        let outcome = |step: &str, code: Option<&str>| {
            let mut payload = json!({"result": "failed", "outcomeCertainty": "confirmed"});
            if let Some(code) = code {
                payload["semanticCode"] = json!(code);
            }
            json!({"kind": "stepOutcome", "stepId": step, "payload": payload})
        };
        let required = CatalogOperation::lookup("debug.hap", Some(1))
            .unwrap()
            .steps
            .iter()
            .find(|step| !step.optional)
            .unwrap()
            .step_id
            .clone();
        let optional = CatalogOperation::lookup("debug.hap", Some(1))
            .unwrap()
            .steps
            .iter()
            .find(|step| step.optional)
            .map(|step| step.step_id.clone());
        assert_eq!(
            hap_original_failure(&unknown, &[outcome(&required, None)]),
            Some(executed.clone())
        );
        assert_eq!(
            hap_original_failure(
                &unknown,
                &[outcome(&required, Some("confirmedNotExecuted"))]
            ),
            Some(failure(
                "executionConfirmedNotPerformed",
                "externalTool",
                "runtimeDecisionRequired",
                "submitNewTypedRequestAfterRuntimeProof",
            ))
        );
        if let Some(optional) = optional {
            assert_eq!(
                hap_original_failure(&unknown, &[outcome(&optional, None)]),
                None
            );
            let decided = json!({"kind": "reconcileOutcome",
                "payload": {"result": "finalizeConfirmedFailure"}});
            assert_eq!(
                hap_original_failure(&unknown, &[outcome(&optional, None), decided]),
                Some(executed)
            );
        }
    }

    #[test]
    fn a_debug_hap_declares_its_failure_finalization_only_through_a_source_step() {
        let failed = hap_record(Some(failure(
            "executionFailed",
            "execution",
            "runtimeDecisionRequired",
            "inspectJob",
        )));
        let intent = |step: &str, declared: Value| {
            json!({"kind": "stepIntent", "stepId": step,
                "payload": {"step": {"compensationDescriptors": declared}}})
        };
        assert!(hap_declares_finalization(
            &failed,
            &[intent(
                "install-hap",
                json!([{"id": "compensation-cleanup-uninstall"}])
            )]
        ));
        assert!(!hap_declares_finalization(
            &failed,
            &[intent("install-hap", json!([]))]
        ));
        assert!(!hap_declares_finalization(
            &failed,
            &[intent("probe-hap", json!([{"id": "compensation-x"}]))]
        ));
        let unknown = hap_record(None);
        assert!(!hap_declares_finalization(
            &unknown,
            &[intent(
                "install-hap",
                json!([{"id": "compensation-cleanup-uninstall"}])
            )]
        ));
    }

    #[test]
    fn an_identical_marker_is_not_added_twice_in_a_row() {
        let mut record = hap_record(None);
        let before = record.timeline.len();
        mark(&mut record, "recovered: journal clean");
        mark(&mut record, "recovered: journal clean");
        assert_eq!(record.timeline.len(), before + 1);
        record.timeline.push("later".into());
        mark(&mut record, "recovered: journal clean");
        assert_eq!(record.timeline.len(), before + 3);
    }
}
