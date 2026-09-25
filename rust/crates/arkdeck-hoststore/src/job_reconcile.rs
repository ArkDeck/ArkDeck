//! Swift's `job.reconcile` handler case (`AgentDaemon.swift`) over
//! `RuntimeJobEngine.reconcile(jobID:)` / `reconcileOwned(jobID:)` and
//! `finishReconcile`, for the host-only analyzer Jobs this Runtime runs
//! (`analyzer.extract-crash-signature@1`, `analyzer.summarize-hilog@1`) and
//! its device-bound HDC Jobs:
//! ADR-0009 decisions 2 and 4 as the maintainer ruled on 2026-09-19 (design
//! §L.1 item 13).
//!
//! A Job whose outcome is unknown is reconciled against its durable intent,
//! and the original action is never resent: the journal moves to
//! `reconciling` and records the attempt (`reconcileStarted`,
//! `recovery-<job>-<sequence>`). An analyzer Job's source Artifact is
//! resolved again, and the analyzer provider confirms the intent not
//! executed only when that source is the one the intent named. A
//! device-bound Job's Target facts are resolved fresh and validated, and the
//! parked action is materialized again from its record: an action below
//! `deviceMutation` is confirmed not executed, a pointer gesture has no
//! dedicated readback and stays unknown, and a port rule's change is read
//! back once (`job_reconcile_device.rs`). The decision is journaled as Swift
//! journals it (the correlated step outcome, the `reconcileOutcome`, the
//! transitions); the Job then fails with `executionConfirmedNotPerformed`,
//! its capability use settled `safeToReflash`, and is published as a
//! Session; or waits at its confirmed safe boundary, its use still unknown;
//! or stays `waitingForRecovery`. A decision the journal already holds is
//! completed, never taken again. What a failed reconcile has journaled stays
//! resident, as Swift's engine keeps it in memory, while the record file
//! keeps its last durable state.
//!
//! A read-only workspace Job (`workspace.inspect-source@1`,
//! `workspace.read-source-range@1`, `workspace.inspect-git-status@1`,
//! `workspace.inspect-diff@1`) writes nothing: its persisted typed action is
//! materialized and, as Swift's provider answers, confirmed not executed; the
//! Job fails with `executionConfirmedNotPerformed` and is never run again.
//!
//! A workspace sweep (`workspace.sweep-isolated-copies@1`) destroyed what only
//! its findings can say: its persisted typed intent is materialized and, as
//! Swift's provider answers, the decision is that the outcome stays unknown;
//! the Job stays `waitingForRecovery` and a fresh sweep resumes its work.
//!
//! A workspace patch Job (`workspace.apply-patch@1`, `workspace.revert-patch@1`)
//! — or a build or checkpoint —
//! is reconciled as Swift's engine reconciles it: its patch lease resolved
//! again and its persisted typed action materialized, then — the workspace
//! provider having no dedicated readback for a mutation — the decision that
//! the outcome is still unknown, journaled; the Job stays
//! `waitingForRecovery`, its use unknown, and nothing is read from the tree or
//! resent.
//!
//! A terminal Job is not resident in Swift: a writer's confirmed refusal of
//! an unbound source starts its Session publication again, and otherwise
//! the capability outcome a crash lost is repaired from the journal's proof
//! (`job_lineage_repair.rs`); nothing is dispatched.
//!
//! A debug HAP's reconcile keeps its failure: its record is durable before
//! the decision is, and an intent confirmed not executed leaves it
//! `finalizing`, whose failure finalization (`finalizeDebugHAPFailure`) runs
//! at once through the runner — the compensations its succeeded steps
//! declared, under the use the Job consumed — as it does for a debug HAP a
//! restart left `finalizing`. A Job the readback confirms completed waits at
//! its confirmed safe boundary, where `job.run` resumes it.
//!
//! What is not ported is refused with nothing written or dispatched, and
//! answered with its status only where Swift writes nothing: a terminal
//! debug HAP whose lineage a repair would write, a debug HAP parked on a
//! declared compensation, on its compensation identity proof or on a
//! failure decision its journal already holds, a Job parked on an action
//! `job_reconcile_device.rs` does not reconcile, and any other operation. No
//! answer carries details.
use crate::artifact_read_owner::{ArtifactReadStore, swift_string};
use crate::capability_store::{CapabilityStore, UseOutcome};
use crate::device_facts::{self, HdcComposition};
use crate::job_journal_events as events;
use crate::job_journal_writer::{JournalWriter, inspect_journal};
use crate::job_lineage_repair::{self as lineage, CONFIRMED_NOT_EXECUTED, RepairError};
use crate::job_owner::JobStore;
use crate::job_owner::import_references::ImportReference;
use crate::job_record::{JobRecord, STATES, terminal};
use crate::job_run::{JobRunner, Run, RunRefusal, binding_refusal, failure};
use crate::operation_catalog::CatalogOperation;
use crate::session_publication::SessionPublisher;
use arkdeck_contract::WireError;
use serde_json::{Map, Value};
use std::path::PathBuf;

#[path = "job_reconcile_device.rs"]
mod device;

/// The analyzer operations this Runtime runs, which it also reconciles.
fn analyzer(operation: &str) -> bool {
    crate::analyzer_composition::EXECUTED.contains(&operation)
}
/// The read-only workspace operations, which write nothing.
fn workspace_read(operation: &str) -> bool {
    crate::workspace_read::READS.contains(&operation)
}
const HAP: &str = "debug.hap@1";
const NATIVE: &str = "deploy.native-library.app-owned@1";
const APPLY: &str = "workspace.apply-patch@1";
const REVERT: &str = "workspace.revert-patch@1";
const BUILD: &str = crate::workspace_build::BUILD;
const SIGN: &str = crate::workspace_composition::SIGN;
const CHECKPOINT: &str = crate::workspace_checkpoint::CHECKPOINT;
const SWEEP: &str = crate::workspace_sweep::SWEEP;
const TESTS: &str = crate::workspace_tests_symbolize::TESTS;
const SYMBOLIZE: &str = crate::workspace_tests_symbolize::SYMBOLIZE;
/// The workspace mutations: none has a dedicated readback.
const WORKSPACE_MUTATIONS: [&str; 5] = [APPLY, REVERT, BUILD, CHECKPOINT, TESTS];
/// Swift's provider answer for a symbolization whose receipt was lost.
const PROCESS_UNKNOWN: &str = "read/build process completion is not inferable after receipt loss";
/// Swift's provider answer for a sweep whose receipt was lost: which trees
/// it destroyed is readable only from its findings, and an interrupted
/// teardown resumes safely on the next sweep.
const SWEEP_UNKNOWN: &str =
    "sweep outcome is derivable only from its findings; submit a fresh sweep";
/// Swift's engine answers a workspace mutation's reconcile from its provider's
/// dedicated readback, which the workspace provider does not have.
const NO_READBACK: &str = "mutation has no dedicated readback; original not resent";
/// Swift's Manifest proposal beside a Job's record.
const PROPOSAL: &str = "session-manifest.proposal.json";

/// A refusal; Swift's `job.reconcile` sends none with details.
fn refused(code: &str, message: impl Into<String>) -> WireError {
    WireError {
        code: code.into(),
        message: message.into(),
        details: None,
    }
}

/// A `RuntimeJobEngineError`, which Swift's handler answers as `rejected`
/// with its interpolation.
fn engine(case: &str, detail: &str) -> WireError {
    refused("rejected", format!("{case}({})", swift_string(detail)))
}

/// Any other error, which Swift's handler answers as `internalError` with its
/// interpolation.
fn other(message: impl Into<String>) -> WireError {
    refused("internalError", message)
}

fn from_run(refusal: RunRefusal) -> WireError {
    refused(refusal.code, refusal.message)
}

fn from_repair(error: RepairError) -> WireError {
    match error {
        RepairError::Engine(message) => refused("rejected", message),
        RepairError::Other(message) => other(message),
    }
}

/// Swift `ProviderReconcileOutcome`.
enum Decision {
    /// `.confirmedCompleted(summary:)`, with the summary's keys.
    Completed(Vec<String>),
    /// `.confirmedNotExecuted`.
    NotExecuted,
    /// `.stillUnknown(reason:)`.
    Unknown(String),
}

/// Swift `ProviderResolvedInputArtifact`: the source resolved again.
struct Source {
    artifact_id: String,
    sha256: Option<String>,
    byte_count: Option<i64>,
}

/// Swift `AnalyzerRecoveryIdentity`, as a persisted `analyzer.analyze`
/// action materializes it.
struct Identity {
    analyzer_ref: String,
    source_artifact_id: String,
    source_sha256: String,
    source_byte_count: i64,
    request_digest: Option<String>,
}

fn lowercase_sha256(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

/// Swift's interpolation of a `[String]`.
fn swift_array(items: &[String]) -> String {
    let quoted: Vec<String> = items.iter().map(|item| swift_string(item)).collect();
    format!("[{}]", quoted.join(", "))
}

/// Swift `RuntimeSessionPublicationRecord.isUnboundSourceFailure`: the
/// writer's confirmed refusal of an unreadable source, which alone may start
/// a new publication attempt.
fn unbound_source_failure(marker: &Value) -> bool {
    let absent = |key: &str| marker.get(key).is_none_or(Value::is_null);
    marker["failure"]["code"] == "sourceIntegrityFailed"
        && marker["failure"]["certainty"] == "confirmed"
        && marker["phase"] == "awaitingStorage"
        && [
            "receipt",
            "proposal",
            "checkpointSeal",
            "journalSeal",
            "sessionRootIdentity",
        ]
        .iter()
        .all(|key| absent(key))
        && marker["claims"].as_array().is_some_and(Vec::is_empty)
        && marker["relativeSessionPath"] == ""
        && marker["root"]["path"] == ""
        && marker["root"]["device"] == "0"
        && marker["root"]["inode"] == "0"
        && marker["root"]["volumeIdentity"] == ""
        && marker["policyGeneration"] == "0"
}

/// Swift's `DeviceProviderError.unsupportedAction`, which describes itself
/// by its detail alone.
fn unsupported(detail: &str) -> WireError {
    other(detail)
}

/// Swift `PersistedTypedProviderAction.materialize()` for `analyzer.analyze`,
/// which recovery materializes only as its recovery identity.
fn materialize(action: &Value) -> Result<Identity, WireError> {
    let kind = action["kind"].as_str().unwrap_or_default();
    if kind != "analyzer.analyze" {
        return Err(unsupported(&format!(
            "persisted typed provider action kind {kind} is unknown"
        )));
    }
    let empty = Map::new();
    let arguments = action["arguments"].as_object().unwrap_or(&empty);
    let string = |key: &str| {
        arguments
            .get(key)
            .and_then(Value::as_str)
            .map(str::to_owned)
            .ok_or_else(|| unsupported(&format!("persisted {kind} is missing string {key}")))
    };
    let analyzer_ref = string("analyzerRef")?;
    let mut expected = vec![
        "analyzerRef",
        "analyzerVersion",
        "sourceArtifactId",
        "sourceSha256",
        "sourceByteCount",
    ];
    let request_digest = if analyzer_ref == "trace-analysis@1" {
        expected.push("requestDigestSha256");
        Some(string("requestDigestSha256")?)
    } else {
        None
    };
    if arguments.len() != expected.len() || !expected.iter().all(|key| arguments.contains_key(*key))
    {
        return Err(unsupported(
            "persisted analyzer.analyze has a non-closed recovery identity",
        ));
    }
    let analyzer_version = string("analyzerVersion")?;
    let source_artifact_id = string("sourceArtifactId")?;
    let source_sha256 = string("sourceSha256")?;
    let source_byte_count = arguments
        .get("sourceByteCount")
        .and_then(Value::as_i64)
        .ok_or_else(|| {
            unsupported(&format!(
                "persisted {kind} is missing integer sourceByteCount"
            ))
        })?;
    if analyzer_ref.is_empty()
        || analyzer_version.is_empty()
        || source_artifact_id.is_empty()
        || source_byte_count <= 0
        || !lowercase_sha256(&source_sha256)
        || request_digest
            .as_deref()
            .is_some_and(|digest| !lowercase_sha256(digest))
    {
        return Err(unsupported(
            "persisted analyzer.analyze has an invalid recovery identity",
        ));
    }
    Ok(Identity {
        analyzer_ref,
        source_artifact_id,
        source_sha256,
        source_byte_count,
        request_digest,
    })
}

/// Swift `AnalyzerProvider.reconcile`: analysis writes nothing outside its
/// own derived Artifact, so its intent is confirmed not executed once the
/// source resolved again is exactly the one the intent named.
fn analyzer_reconcile(identity: &Identity, source: Option<&Source>) -> Decision {
    if identity.analyzer_ref == "trace-analysis@1"
        && !identity
            .request_digest
            .as_deref()
            .is_some_and(lowercase_sha256)
    {
        return Decision::Unknown("analyzer reconcile request identity is incomplete".into());
    }
    match source {
        Some(source)
            if source.artifact_id == identity.source_artifact_id
                && source.sha256.as_deref() == Some(identity.source_sha256.as_str())
                && source.byte_count == Some(identity.source_byte_count) =>
        {
            Decision::NotExecuted
        }
        _ => Decision::Unknown("analyzer reconcile source identity does not match".into()),
    }
}

/// A Job the reconcile holds: its run state (record, journal, next sequence)
/// and Swift's `jobs[jobID]`, the record as the engine last stored it, which
/// stays resident when the reconcile fails ahead of its record.
struct Held {
    run: Run,
    stored: JobRecord,
    directory: PathBuf,
    /// The journal moved since the record was last durable.
    ahead: bool,
}

impl Held {
    fn open(
        record: JobRecord,
        directory: PathBuf,
        now: fn() -> Option<String>,
    ) -> Result<Self, WireError> {
        let journal =
            JournalWriter::open(&directory, false).map_err(|error| other(format!("{error}")))?;
        let sequence = journal
            .facts()
            .last_durable_sequence
            .map_or(0, |last| last + 1);
        Ok(Self {
            stored: record.clone(),
            run: Run {
                record,
                journal,
                sequence,
                now,
                consumed: None,
            },
            directory,
            ahead: false,
        })
    }

    fn append(&mut self, event: Value) -> Result<(), WireError> {
        self.run.append(event).map_err(from_run)?;
        self.ahead = true;
        Ok(())
    }

    /// Swift `transition(&runtime, …)`: journaled and synchronized, then the
    /// record's state and timeline, and the runtime stored.
    fn transition(
        &mut self,
        from: &str,
        to: &str,
        reason: &str,
        trigger: Option<&str>,
    ) -> Result<(), WireError> {
        let envelope = self
            .run
            .envelope(format!("t-{}", self.run.sequence))
            .map_err(from_run)?;
        self.append(events::state_transition(
            &envelope, from, to, reason, trigger,
        ))?;
        self.run.record.state = to.into();
        self.run.record.timeline.push(format!("{from}->{to}"));
        self.run.record.timeline.push(format!("reason: {reason}"));
        self.store();
        Ok(())
    }

    fn store(&mut self) {
        self.stored = self.run.record.clone();
    }

    /// Swift `persistRuntimeRecord`, then the runtime stored.
    fn persist(&mut self, jobs: &JobStore) -> Result<(), WireError> {
        self.run.persist(jobs).map_err(from_run)?;
        self.ahead = false;
        self.store();
        Ok(())
    }

    /// Swift `statusAndReleaseTerminalRuntime`: a terminal Job whose outcome
    /// is known is published as a Session.
    fn release(
        mut self,
        jobs: &JobStore,
        sessions: Option<&SessionPublisher<'_>>,
    ) -> Result<Value, WireError> {
        self.run
            .release(jobs, sessions, &self.directory)
            .map_err(from_run)?;
        Ok(self.run.record.status())
    }

    /// Every complete record of the journal, in order (Swift
    /// `DurableJournalRecovery.inspect(url:).events`).
    fn events(&self, jobs: &JobStore) -> Result<Vec<Value>, WireError> {
        journal_events(jobs, &self.run.record.job_id)
    }
}

fn journal_events(jobs: &JobStore, job_id: &str) -> Result<Vec<Value>, WireError> {
    let bytes = jobs
        .journal_bytes(job_id)
        .map_err(|error| other(format!("{error}")))?;
    let durable = bytes
        .iter()
        .rposition(|byte| *byte == b'\n')
        .map_or(0, |last| last + 1);
    bytes[..durable]
        .split(|byte| *byte == b'\n')
        .filter(|line| !line.is_empty())
        .map(|line| {
            serde_json::from_slice(line)
                .map_err(|_| other("sequenceViolation(\"the Job Journal cannot be replayed\")"))
        })
        .collect()
}

/// The recovery attempt a start left without its decision, if any.
fn unfinished_attempt(events: &[Value]) -> Option<String> {
    let completed: Vec<&str> = events
        .iter()
        .filter(|event| event["kind"] == "reconcileOutcome")
        .filter_map(|event| event["payload"]["recoveryAttemptId"].as_str())
        .collect();
    events
        .iter()
        .rev()
        .filter(|event| event["kind"] == "reconcileStarted")
        .filter_map(|event| event["payload"]["recoveryAttemptId"].as_str())
        .find(|attempt| !completed.contains(attempt))
        .map(str::to_owned)
}

pub struct JobReconciler<'a> {
    pub jobs: &'a JobStore,
    pub artifacts: &'a ArtifactReadStore,
    pub imports: Option<&'a crate::ImportUploadStore>,
    pub now: fn() -> Option<String>,
    /// The standalone daemon's Session publication writer, as the runner's.
    pub sessions: Option<&'a SessionPublisher<'a>>,
    /// The HDC composition a device-bound Job's fresh facts come from and its
    /// dedicated readback is dispatched through, as the runner's. Without
    /// one no device-bound Job whose outcome is unknown is reconciled.
    pub hdc: Option<&'a HdcComposition<'a>>,
    /// The capability store whose use outcomes a reconcile settles (Swift
    /// `recordCapabilityOutcome`) and repairs. Without one no Job admitted
    /// under a runtime capability is reconciled where Swift would write it.
    pub capabilities: Option<&'a CapabilityStore>,
    /// The runner a debug HAP's failure finalization runs through, composed
    /// over the same owners and HDC composition (Swift
    /// `finalizeDebugHAPFailure`). Without one no debug HAP is reconciled
    /// where Swift would finalize it.
    pub runner: Option<&'a JobRunner<'a>>,
}

/// Whether this Runtime reconciles a Job of `operation` in `state`: the
/// analyzer, and the device-bound operations it runs — but a terminal debug
/// HAP, whose own lineage repair is not ported.
fn reconciled(operation: &str, state: &str) -> bool {
    analyzer(operation)
        || workspace_read(operation)
        || operation == SWEEP
        || operation == SYMBOLIZE
        || operation == SIGN
        || WORKSPACE_MUTATIONS.contains(&operation)
        || (crate::device_run::runs(operation) && !(operation == HAP && terminal(state)))
}

impl JobReconciler<'_> {
    /// Swift's `job.reconcile`: the reconciled Job's `arkdeck.job-status/1`.
    pub fn handle(&self, params: &Map<String, Value>) -> Result<Value, WireError> {
        let Some(id) = params.get("jobId").and_then(Value::as_str) else {
            return Err(refused("invalidParams", "jobId is required"));
        };
        let record = self.read(id)?;
        if !reconciled(record.operation(), &record.state) {
            return unported(record);
        }
        if terminal(&record.state) {
            return self.released(record);
        }
        if let Some(refusal) = self.device_refusal(&record)? {
            return Err(refused("rejected", refusal));
        }
        self.resident(record)
    }

    /// Why this owner does not reconcile a device-bound Job whose outcome is
    /// unknown (or a debug HAP left `finalizing`), refused before anything is
    /// written: no HDC composition to resolve the Target's facts through, no
    /// capability store for a use the reconcile settles, no runner for a
    /// debug HAP's failure finalization, a debug HAP lane this Runtime does
    /// not port, or a parked action whose reconcile is not ported.
    fn device_refusal(&self, record: &JobRecord) -> Result<Option<String>, WireError> {
        let operation = record.operation();
        let hap_finalizing =
            operation == HAP && record.state == "finalizing" && !record.outcome_unknown();
        if analyzer(operation)
            || workspace_read(operation)
            || operation == SWEEP
            || operation == SYMBOLIZE
            || (!record.outcome_unknown() && !hap_finalizing)
        {
            return Ok(None);
        }
        let refusal = |what: String| {
            Some(format!(
                "job {} {what}; nothing was dispatched or written",
                record.job_id
            ))
        };
        // A signing Job's reconcile reads back its own product; a confirmed
        // one is republished through the runner, before its step completes.
        if operation == SIGN {
            if self.runner.and_then(|runner| runner.workspace).is_none() {
                return Ok(refusal(format!(
                    "runs {operation}, and this owner holds no runner to republish its product"
                )));
            }
            return Ok(None);
        }
        // A workspace mutation's reconcile reads its own records only; it
        // needs no device facts, only the store its use is settled in.
        if WORKSPACE_MUTATIONS.contains(&operation) {
            if lineage::runtime_capability(record) && self.capabilities.is_none() {
                return Ok(refusal(
                    "settles a runtime capability use, and this owner holds no capability store"
                        .into(),
                ));
            }
            return Ok(None);
        }
        if self.hdc.is_none() {
            return Ok(refusal(format!(
                "runs {operation}, and this owner holds no HDC composition to reconcile it"
            )));
        }
        if lineage::runtime_capability(record) && self.capabilities.is_none() {
            return Ok(refusal(
                "settles a runtime capability use, and this owner holds no capability store".into(),
            ));
        }
        if operation == HAP {
            if self.runner.is_none() {
                return Ok(refusal(format!(
                    "runs {operation}, and this owner holds no runner to finalize its failure"
                )));
            }
            if hap_finalizing {
                return Ok(None);
            }
            if let Some(lane) = self.unported_hap_lane(record)? {
                return Ok(refusal(format!(
                    "waits on {lane}, which the Rust Runtime does not reconcile yet"
                )));
            }
        }
        let kind = record
            .recovery_action()
            .map(|action| action["kind"].as_str().unwrap_or_default());
        Ok(match kind {
            Some(kind) if !device::ported(kind) => refusal(format!(
                "waits on {kind}, which the Rust Runtime does not reconcile yet"
            )),
            _ => None,
        })
    }

    /// The debug HAP recovery lanes Swift's `reconcileOwned` runs that this
    /// Runtime does not port, read from the record and the journal alone: a
    /// reconcile of a declared compensation's own intent, the identity proof
    /// of a compensation that never had one, and the completion of a failure
    /// decision the journal already holds.
    fn unported_hap_lane(&self, record: &JobRecord) -> Result<Option<&'static str>, WireError> {
        let Some(intent) = record.recovery_intent() else {
            return Ok(Some("its declared compensation's identity proof"));
        };
        let events = journal_events(self.jobs, &record.job_id)?;
        if events
            .iter()
            .any(|event| event["eventId"] == intent && event["kind"] == "compensationIntent")
        {
            return Ok(Some("a declared compensation"));
        }
        let directory = self
            .jobs
            .job_directory(&record.job_id)
            .map_err(|error| other(format!("{error:?}")))?;
        let facts = inspect_journal(&directory).map_err(|error| other(format!("{error}")))?;
        let decided = events
            .last()
            .is_some_and(|last| last["kind"] == "reconcileOutcome")
            || (facts.current_state.as_deref() == Some("finalizing")
                && facts.last_reconcile_outcome_certainty.as_deref() == Some("confirmed"));
        Ok(decided.then_some("the failure decision its journal holds"))
    }

    /// The answer to `job.reconcile` while a run of the Job holds it: that
    /// run alone decides the Job, so its status is answered and nothing is
    /// written, as Swift answers a Job its live executor holds.
    pub fn status(&self, params: &Map<String, Value>) -> Result<Value, WireError> {
        let Some(id) = params.get("jobId").and_then(Value::as_str) else {
            return Err(refused("invalidParams", "jobId is required"));
        };
        Ok(self.read(id)?.status())
    }

    /// Swift `recordForRead` and the handler's spellings of its refusals.
    fn read(&self, id: &str) -> Result<JobRecord, WireError> {
        match self.jobs.read_snapshot(id) {
            Ok(record) => Ok(record),
            Err(error) if matches!(error.code.as_str(), "notFound" | "invalidInput") => {
                Err(refused("notFound", format!("unknown job {id}")))
            }
            Err(error)
                if error
                    .message
                    .starts_with("the referenced Job record is unreadable") =>
            {
                Err(engine("jobRecordUnreadable", id))
            }
            Err(_) => Err(engine(
                "internalFailure",
                &format!("Runtime job history index is unreadable for {id}"),
            )),
        }
    }

    fn clock(&self) -> Result<String, WireError> {
        (self.now)().ok_or_else(|| other("the Runtime clock is unavailable"))
    }

    /// Swift's non-resident branch of `reconcileOwned`: a terminal Job. A
    /// writer's confirmed refusal of an unbound source starts its Session
    /// publication again; otherwise the capability outcome a crash lost is
    /// repaired from the journal's proof (a Job under the default read-only
    /// policy has none to repair), and nothing is dispatched.
    fn released(&self, record: JobRecord) -> Result<Value, WireError> {
        let id = record.job_id.clone();
        let retry = record.session_publication().is_some_and(|marker| {
            unbound_source_failure(marker)
                && marker["sessionID"] == format!("session-{id}")
                && marker["catalogDigest"] == record.catalog_digest()
        }) && !record.outcome_unknown();
        if !retry {
            if lineage::repairs_lineage(&record) && self.capabilities.is_none() {
                return Err(refused(
                    "rejected",
                    format!(
                        "job {id} settles a runtime capability use, and this owner holds no \
                         capability store; nothing was dispatched or written"
                    ),
                ));
            }
            lineage::repair_safe_to_reflash(self.jobs, self.capabilities, &record, self.now)
                .map_err(from_repair)?;
            lineage::repair_cancelled(self.capabilities, &record, self.now).map_err(from_repair)?;
            return Ok(record.status());
        }
        let directory = self
            .jobs
            .job_directory(&id)
            .map_err(|error| other(format!("{error:?}")))?;
        let replay = inspect_journal(&directory).map_err(|error| other(format!("{error}")))?;
        let proposal_absent = matches!(
            std::fs::symlink_metadata(directory.join(PROPOSAL)),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound
        );
        if replay.requires_recovery
            || replay.finalized
            || replay.current_state.as_deref() != Some(record.state.as_str())
            || !proposal_absent
        {
            return Ok(record.status());
        }
        Held::open(record, directory, self.now)?.release(self.jobs, self.sessions)
    }

    /// Swift's resident branch of `reconcileOwned` for a Job that is not
    /// terminal, with what a failure has journaled kept resident. A Job whose
    /// outcome is known and that is no stuck cancellation is answered as it
    /// is: the lineage repair Swift calls there needs a failed Job.
    fn resident(&self, record: JobRecord) -> Result<Value, WireError> {
        // Swift continues a debug HAP's failure finalization first.
        if record.operation() == HAP && record.state == "finalizing" && !record.outcome_unknown() {
            let directory = self
                .jobs
                .job_directory(&record.job_id)
                .map_err(|error| other(format!("{error:?}")))?;
            let mut held = Held::open(record, directory, self.now)?;
            self.finalize_hap_failure(&mut held)?;
            return held.release(self.jobs, self.sessions);
        }
        let settles = matches!(
            record.state.as_str(),
            "cancelRequested" | "cancellingAtSafeBoundary"
        );
        if !record.outcome_unknown() && !settles {
            return Ok(record.status());
        }
        let directory = self
            .jobs
            .job_directory(&record.job_id)
            .map_err(|error| other(format!("{error:?}")))?;
        let mut held = Held::open(record, directory, self.now)?;
        let result = if held.run.record.outcome_unknown() {
            self.reconcile_unknown(&mut held)
        } else {
            self.settle_cancellation(&mut held)
        };
        match result {
            Ok(Some(status)) => Ok(status),
            Ok(None) => held.release(self.jobs, self.sessions),
            Err(error) => {
                if held.ahead {
                    self.jobs.hold_resident(held.stored);
                }
                Err(error)
            }
        }
    }

    /// Swift `finalizeDebugHAPFailure` for a debug HAP the reconcile holds
    /// `finalizing`: it takes over the use the Job consumed, then its failure
    /// finalization concludes through the runner, which settles that use.
    fn finalize_hap_failure(&self, held: &mut Held) -> Result<(), WireError> {
        let (Some(runner), Some(hdc)) = (self.runner, self.hdc) else {
            return Err(other(
                "the Runtime runner is unavailable for a debug HAP's finalization",
            ));
        };
        runner
            .take_over_held_use(&mut held.run)
            .map_err(|message| refused("rejected", message))?;
        runner
            .conclude_hap_failure(&mut held.run, hdc)
            .map_err(from_run)?;
        held.ahead = false;
        held.store();
        Ok(())
    }

    /// Swift's settlement of a cancellation whose executor no longer exists:
    /// nothing uncertain happened, so no device work is needed.
    fn settle_cancellation(&self, held: &mut Held) -> Result<Option<Value>, WireError> {
        if held.run.record.state == "cancelRequested" {
            held.transition(
                "cancelRequested",
                "cancellingAtSafeBoundary",
                "cancellation executor did not survive; settling on reconcile",
                None,
            )?;
        }
        held.transition(
            "cancellingAtSafeBoundary",
            "cancelled",
            "no executor remains to carry the durable cancellation intent",
            None,
        )?;
        held.run.record.set_operation_failure(Some(failure(
            "cancelled",
            "cancelled",
            "notAutomatic",
            "none",
        )));
        held.run.record.finish(&self.clock()?);
        held.persist(self.jobs)?;
        Ok(None)
    }

    /// Swift `reconcileOwned` from its outcome-unknown gate: `Some(status)`
    /// when the Job stays resident, `None` when it is to be released.
    fn reconcile_unknown(&self, held: &mut Held) -> Result<Option<Value>, WireError> {
        let id = held.run.record.job_id.clone();
        let mut events = held.events(self.jobs)?;
        let mut facts = held.run.journal.facts();

        // Finish a reconcile decision that was already durable when the
        // process stopped: no readback and no dispatch is needed.
        if let Some(last) = events
            .last()
            .filter(|last| last["kind"] == "reconcileOutcome")
            && let Some(next) = last["payload"]["nextState"]
                .as_str()
                .filter(|next| STATES.contains(next))
        {
            let (next, trigger) = (next.to_owned(), last["eventId"].as_str().map(str::to_owned));
            held.transition(
                "reconciling",
                &next,
                "complete durable reconcile decision",
                trigger.as_deref(),
            )?;
            events = held.events(self.jobs)?;
            facts = held.run.journal.facts();
        }
        let confirmed = facts.last_reconcile_outcome_certainty.as_deref() == Some("confirmed");
        let current = facts.current_state.clone();
        if current.as_deref() == Some("resumeAtConfirmedSafeBoundary") && confirmed {
            let record = &mut held.run.record;
            record.clear_outcome_unknown();
            record.set_recovery(None, None, None);
            record.state = "resumeAtConfirmedSafeBoundary".into();
            record
                .timeline
                .push("reconciled: durable confirmed completion".into());
            held.persist(self.jobs)?;
            return Ok(Some(held.run.record.status()));
        }
        if current.as_deref() == Some("finalizing") && confirmed {
            held.transition(
                "finalizing",
                "failed",
                "reconciliation confirmed the original action did not complete",
                None,
            )?;
            let record = &mut held.run.record;
            record.clear_outcome_unknown();
            record.set_recovery(None, None, None);
            record.finish(&self.clock()?);
            held.persist(self.jobs)?;
            lineage::record_capability_outcome(
                &held.run.record,
                self.capabilities,
                UseOutcome::SafeToReflash,
                "failed",
                self.now,
            )
            .map_err(from_repair)?;
            return Ok(None);
        }
        if !facts.unknown_outcomes.is_empty() {
            held.run.record.timeline.push(
                "reconcile refused: legacy outcomeUnknown event cannot be rewritten; original \
                 not resent"
                    .into(),
            );
            held.persist(self.jobs)?;
            return Ok(Some(held.run.record.status()));
        }
        let record = &held.run.record;
        let (Some(step), Some(action), Some(intent)) = (
            record.recovery_step().map(str::to_owned),
            record.recovery_action().cloned(),
            record.recovery_intent().map(str::to_owned),
        ) else {
            return Err(engine(
                "internalFailure",
                &format!("unknown outcome has no persisted exact typed action for {id}"),
            ));
        };
        match current.as_deref() {
            Some("waitingForRecovery") => {
                held.transition(
                    "waitingForRecovery",
                    "reconciling",
                    "begin exact typed provider reconciliation",
                    None,
                )?;
                events = held.events(self.jobs)?;
                facts = held.run.journal.facts();
            }
            Some("reconciling") => {}
            state => {
                return Err(engine(
                    "internalFailure",
                    &format!(
                        "unknown outcome journal is {}, not at a recovery boundary",
                        state.unwrap_or("missing")
                    ),
                ));
            }
        }
        let attempt = match unfinished_attempt(&events) {
            Some(attempt) => attempt,
            None => {
                let sequence = held.run.sequence;
                let attempt = format!("recovery-{id}-{sequence}");
                let envelope = held
                    .run
                    .envelope(format!("reconcile-start-{sequence}"))
                    .map_err(from_run)?;
                held.append(events::reconcile_started(
                    &envelope,
                    &attempt,
                    "waitingForRecovery",
                    facts.last_durable_sequence.unwrap_or(0),
                    "manual",
                ))?;
                held.run
                    .record
                    .timeline
                    .push(format!("reconcile started {step}"));
                held.store();
                events = held.events(self.jobs)?;
                attempt
            }
        };
        let operation = held.run.record.operation().to_owned();
        let Some(descriptor) = operation
            .rsplit_once('@')
            .and_then(|(name, version)| CatalogOperation::lookup(name, version.parse().ok()))
        else {
            return Err(engine(
                "internalFailure",
                &format!("catalog operation vanished for {id}"),
            ));
        };
        // Only a debug HAP's compensation keeps its original failure; any
        // other Job's compensation intent ends here, whether its facts
        // resolve or not.
        let compensation = || {
            engine(
                "internalFailure",
                "compensation lost original operation failure",
            )
        };
        let exact_kind = |events: &[Value]| {
            events
                .iter()
                .find(|event| event["eventId"] == intent.as_str())
                .map(|event| event["kind"].clone())
        };
        let exact = |events: &[Value]| match exact_kind(events) {
            None => Err(engine(
                "internalFailure",
                "persisted reconciliation action has no matching intent",
            )),
            Some(kind) if kind == "compensationIntent" => Err(compensation()),
            Some(_) => Ok(()),
        };
        let resolution = events.iter().rev().find(|event| {
            matches!(
                event["kind"].as_str(),
                Some("stepOutcome" | "compensationOutcome")
            ) && event["payload"]["correlatesToIntentEventId"] == intent.as_str()
                && event["payload"]["outcomeCertainty"] == "confirmed"
        });
        let durable = resolution.map(|resolution| {
            if resolution["payload"]["result"] == "succeeded" {
                Decision::Completed(vec!["source".into()])
            } else {
                Decision::NotExecuted
            }
        });
        if operation == SIGN {
            return self
                .reconcile_signing(held, &events, &action, &intent, &step, &attempt, durable);
        }
        if descriptor.binding() == "none" && WORKSPACE_MUTATIONS.contains(&operation.as_str()) {
            // A workspace mutation: its input lease resolved again and its
            // persisted typed action materialized, then — as Swift's engine
            // has no dedicated readback for it — the intent stays unknown.
            // Nothing is read from the tree and nothing is resent.
            self.resolve_source(&held.run.record)?;
            if operation == BUILD {
                crate::workspace_build::BuildAction::materialize(&action)
                    .map(|_| ())
                    .map_err(|detail| unsupported(&detail))?;
            } else if operation == CHECKPOINT {
                crate::workspace_checkpoint::CheckpointAction::materialize(&action)
                    .map(|_| ())
                    .map_err(|detail| unsupported(&detail))?;
            } else if operation == TESTS {
                crate::workspace_tests_symbolize::PresetAction::materialize(&action)
                    .map(|_| ())
                    .map_err(|detail| unsupported(&detail))?;
            } else {
                crate::workspace_patch::PatchAction::materialize(&action)
                    .map(|_| ())
                    .map_err(|detail| unsupported(&detail))?;
            }
            exact(&events)?;
            let decision = durable.unwrap_or_else(|| Decision::Unknown(NO_READBACK.into()));
            return self.finish(held, &events, &intent, &step, &attempt, decision, None);
        }
        if workspace_read(&operation) {
            // A read writes nothing, so there is no external effect for the
            // reconcile to confirm: Swift's provider confirms it not executed,
            // and it is never run again.
            self.resolve_source(&held.run.record)?;
            crate::workspace_read::ReadAction::materialize(&action)
                .map_err(|detail| unsupported(&detail))?;
            exact(&events)?;
            let decision = durable.unwrap_or(Decision::NotExecuted);
            return self.finish(held, &events, &intent, &step, &attempt, decision, None);
        }
        if operation == SYMBOLIZE {
            // A symbolization's child left nothing behind to read: Swift's
            // provider cannot infer whether it completed, so the intent stays
            // unknown and nothing is resent.
            self.resolve_source(&held.run.record)?;
            crate::workspace_tests_symbolize::PresetAction::materialize(&action)
                .map_err(|detail| unsupported(&detail))?;
            exact(&events)?;
            let decision = durable.unwrap_or_else(|| Decision::Unknown(PROCESS_UNKNOWN.into()));
            return self.finish(held, &events, &intent, &step, &attempt, decision, None);
        }
        if operation == SWEEP {
            // What a sweep destroyed is derivable only from its findings, so
            // Swift's provider neither confirms nor denies it: the intent
            // stays unknown, nothing is read back or resent, and a fresh
            // sweep resumes whatever this one left.
            self.resolve_source(&held.run.record)?;
            crate::workspace_sweep::SweepIntent::materialize(&action)
                .map_err(|detail| unsupported(&detail))?;
            exact(&events)?;
            let decision = durable.unwrap_or_else(|| Decision::Unknown(SWEEP_UNKNOWN.into()));
            return self.finish(held, &events, &intent, &step, &attempt, decision, None);
        }
        if descriptor.binding() == "none" {
            // A host-only reconcile inspects only its Job-owned input: no
            // device facts are resolved.
            let source = self.resolve_source(&held.run.record)?;
            let identity = materialize(&action)?;
            exact(&events)?;
            let decision =
                durable.unwrap_or_else(|| analyzer_reconcile(&identity, source.as_ref()));
            return self.finish(held, &events, &intent, &step, &attempt, decision, None);
        }
        // A device-bound action keeps the fresh-facts gate: the Target's facts
        // resolved again and validated for the request's binding.
        let hdc = self.hdc.ok_or_else(|| {
            other("the Runtime HDC composition is unavailable for a device-bound reconcile")
        })?;
        let target = &held.run.record.request["target"];
        let target_id = target["targetId"].as_str().unwrap_or_default().to_owned();
        let revision = target["expectedBindingRevision"].as_i64();
        let fresh = hdc.facts(&target_id).map_err(other).and_then(|facts| {
            device_facts::validate(&facts, &target_id, revision)
                .map(|()| facts)
                .map_err(|reason| other(format!("failed({})", swift_string(reason))))
        });
        let facts = match fresh {
            Ok(facts) => facts,
            Err(_) if exact_kind(&events).is_some_and(|kind| kind == "compensationIntent") => {
                return Err(compensation());
            }
            Err(error) => return Err(error),
        };
        // Swift `resolvedInputArtifact`: a debug HAP's entry package or a
        // native deployment's library, resolved again and still bound.
        self.resolve_source(&held.run.record)?;
        let parked = device::materialize(&action)?;
        exact(&events)?;
        let decision =
            durable.unwrap_or_else(|| device::decide(&parked, hdc, &facts, &id, &step, &attempt));
        self.finish(
            held,
            &events,
            &intent,
            &step,
            &attempt,
            decision,
            Some(facts.binding_revision),
        )
    }

    /// Swift's reconcile of a host-only signing intent: the unsigned HAP's
    /// lease resolved again, the persisted action materialized, then the
    /// provider's readback — nothing written is not executed, a record
    /// without its product stays unknown, and a product is read back (its
    /// record, or `verify-app` once more) and never signed again. A product
    /// confirmed that way is republished with its source's binding before
    /// the step is marked complete; a known terminal Job's attempt directory
    /// is then removed.
    #[allow(clippy::too_many_arguments)]
    fn reconcile_signing(
        &self,
        held: &mut Held,
        events: &[Value],
        action: &Value,
        intent: &str,
        step: &str,
        attempt: &str,
        durable: Option<Decision>,
    ) -> Result<Option<Value>, WireError> {
        use crate::workspace_composition::{SignReconcile, WorkspaceComposition};
        let (Some(runner), Some(workspace)) =
            (self.runner, self.runner.and_then(|runner| runner.workspace))
        else {
            return Err(other(
                "the Runtime runner is unavailable to republish a signed product",
            ));
        };
        let (_, source_binding) = runner.sign_lease(&held.run).map_err(other)?;
        let parked = crate::workspace_composition::materialize_sign_action(action)
            .map_err(|detail| unsupported(&detail))?;
        if !events.iter().any(|event| event["eventId"] == intent) {
            return Err(engine(
                "internalFailure",
                "persisted reconciliation action has no matching intent",
            ));
        }
        let decision = match durable {
            Some(decision) => decision,
            None => match WorkspaceComposition::reconcile_sign(&parked) {
                SignReconcile::NotExecuted => Decision::NotExecuted,
                SignReconcile::Unknown(reason) => Decision::Unknown(reason),
                SignReconcile::Completed(_) => {
                    let recovered = arkdeck_provider_workspace::signer::recovered_receipt(&parked)
                        .map_err(|error| other(error.to_string()))?;
                    runner
                        .publish_signed(
                            &mut held.run,
                            &source_binding,
                            &recovered.summary,
                            &recovered,
                            None,
                        )
                        .map_err(other)?;
                    Decision::Completed(recovered.summary.keys().cloned().collect())
                }
            },
        };
        let answer = self.finish(held, events, intent, step, attempt, decision, None)?;
        if terminal(&held.run.record.state) && !held.run.record.outcome_unknown() {
            workspace.cleanup_sign(&held.run.record.job_id);
        }
        Ok(answer)
    }

    /// Swift `resolvedInputArtifact(jobID:)`: the lease the operation's input
    /// names (an analyzer's source, a debug HAP's entry package, a native
    /// deployment's library) resolved again, then checked against the
    /// materialized request.
    fn resolve_source(&self, record: &JobRecord) -> Result<Option<Source>, WireError> {
        let input = match record.operation() {
            operation if analyzer(operation) => "sourceArtifactRef",
            HAP => "hapArtifactLease",
            NATIVE => "libraryArtifactLease",
            APPLY => "patchArtifactRef",
            SIGN => "unsignedHapArtifactLease",
            SYMBOLIZE => "dumpArtifactRef",
            _ => return Ok(None),
        };
        let Some(lease) = record.request["inputs"][input].as_str() else {
            return Ok(None);
        };
        let leased = match ImportReference::parse(lease) {
            Ok(Some(reference)) => self
                .imports
                .ok_or_else(|| other("Import owner is unavailable"))?
                .resolve_input(self.artifacts, &reference)
                .map_err(|error| other(error.message))?,
            Ok(None) => self.artifacts.lease(lease).map_err(other)?,
            Err(error) => return Err(other(error.message)),
        };
        // A symbolization reads a crash another target captured: Swift checks
        // that exact product instead of the request's own binding.
        let refusal = if record.operation() == SYMBOLIZE {
            let target = &record.request["target"];
            crate::workspace_tests_symbolize::dump_refusal(
                &leased.row,
                target["targetId"].as_str().unwrap_or_default(),
                target["expectedBindingRevision"].as_i64(),
            )
        } else {
            binding_refusal(&leased, record)
        };
        if let Some(reason) = refusal {
            return Err(refused("rejected", reason));
        }
        Ok(Some(Source {
            sha256: leased.row["sha256"].as_str().map(str::to_owned),
            byte_count: leased.row["byteCount"].as_i64(),
            artifact_id: leased.artifact_id,
        }))
    }

    /// Swift `finishReconcile` for a workflow step that is not a debug HAP's:
    /// the decision journaled, its record written and its capability use
    /// settled, `Some(status)` for a Job that stays resident. The binding
    /// revision is the fresh facts' for a device-bound step, and none for a
    /// host-only one.
    #[allow(clippy::too_many_arguments)]
    fn finish(
        &self,
        held: &mut Held,
        events: &[Value],
        intent: &str,
        step: &str,
        attempt: &str,
        decision: Decision,
        binding_revision: Option<i64>,
    ) -> Result<Option<Value>, WireError> {
        let Some(exact) = events.iter().find(|event| event["eventId"] == intent) else {
            return Err(engine("internalFailure", "reconcile intent disappeared"));
        };
        let dispatched = exact["payload"]["step"]["id"]
            .as_str()
            .unwrap_or_default()
            .to_owned();
        let durable = events.iter().any(|event| {
            matches!(
                event["kind"].as_str(),
                Some("stepOutcome" | "compensationOutcome")
            ) && event["payload"]["correlatesToIntentEventId"] == intent
                && event["payload"]["outcomeCertainty"] == "confirmed"
        });
        let confirmed_not_performed = || {
            failure(
                "executionConfirmedNotPerformed",
                "externalTool",
                "runtimeDecisionRequired",
                "submitNewTypedRequestAfterRuntimeProof",
            )
        };
        // A debug HAP's record is durable before its decision is, carrying
        // the failure an intent confirmed not executed leaves it with: its
        // failure finalization keeps that failure whatever happens after.
        let hap = held.run.record.operation() == HAP;
        if hap {
            if matches!(decision, Decision::NotExecuted) {
                held.run
                    .record
                    .set_operation_failure(Some(confirmed_not_performed()));
            }
            held.persist(self.jobs)?;
        }
        // The correlated outcome, unless the journal already holds one.
        let outcome =
            |held: &mut Held, result: &str, code: Option<&str>| -> Result<(), WireError> {
                if durable {
                    return Ok(());
                }
                let sequence = held.run.sequence;
                let envelope = held
                    .run
                    .envelope(format!("reconciled-outcome-{sequence}"))
                    .map_err(from_run)?;
                held.append(events::step_outcome(
                    &envelope,
                    &dispatched,
                    1,
                    intent,
                    result,
                    "confirmed",
                    code,
                    None,
                ))
            };
        let host_only = binding_revision.is_none();
        let (next, result, certainty, safe, decided_revision, detail) = match &decision {
            Decision::Completed(keys) => {
                outcome(held, "succeeded", None)?;
                let mut keys = keys.clone();
                keys.sort();
                (
                    "resumeAtConfirmedSafeBoundary",
                    if host_only {
                        "resumeHostOnlyAtConfirmedSafeBoundary"
                    } else {
                        "resumeAtConfirmedSafeBoundary"
                    },
                    "confirmed",
                    true,
                    binding_revision,
                    format!("confirmed completed {}", swift_array(&keys)),
                )
            }
            Decision::NotExecuted => {
                outcome(held, "failed", Some(CONFIRMED_NOT_EXECUTED))?;
                (
                    "finalizing",
                    if host_only {
                        "finalizeHostOnlyConfirmedFailure"
                    } else {
                        "finalizeConfirmedFailure"
                    },
                    "confirmed",
                    true,
                    binding_revision,
                    "confirmed not executed; original not resent".to_owned(),
                )
            }
            Decision::Unknown(reason) => (
                "waitingForRecovery",
                "waitingForRecovery",
                "outcomeUnknown",
                false,
                None,
                reason.clone(),
            ),
        };
        let decided = format!("reconcile-outcome-{}", held.run.sequence);
        let envelope = held.run.envelope(decided.clone()).map_err(from_run)?;
        held.append(events::reconcile_outcome(
            &envelope,
            decided_revision,
            attempt,
            result,
            next,
            certainty,
            safe,
            &[detail.as_str()],
        ))?;
        held.transition(
            "reconciling",
            next,
            &format!("persist exact typed reconcile decision: {detail}"),
            Some(&decided),
        )?;
        // Swift records no capability outcome for a confirmed completion: the
        // use stays as it is until the Job resumes.
        let settled = match &decision {
            Decision::Completed(_) => None,
            Decision::NotExecuted => Some((UseOutcome::SafeToReflash, "failed")),
            Decision::Unknown(_) => Some((UseOutcome::OutcomeUnknown, "waitingForRecovery")),
        };
        match decision {
            Decision::Completed(_) => {
                let record = &mut held.run.record;
                record.clear_outcome_unknown();
                record.clear_finished();
                record.set_operation_failure(None);
                record.set_recovery(None, None, None);
                record
                    .timeline
                    .push(format!("reconciled: confirmed completed {step}"));
            }
            Decision::NotExecuted => {
                held.run.record.clear_outcome_unknown();
                held.run
                    .record
                    .set_operation_failure(Some(confirmed_not_performed()));
                // A debug HAP stays `finalizing` for its failure finalization.
                if !hap {
                    held.transition(
                        "finalizing",
                        "failed",
                        &format!("reconciliation confirmed {step} did not complete"),
                        None,
                    )?;
                    let now = self.clock()?;
                    let record = &mut held.run.record;
                    record.set_recovery(None, None, None);
                    record.finish(&now);
                }
                held.run
                    .record
                    .timeline
                    .push(format!("reconciled: confirmed not executed {step}"));
            }
            Decision::Unknown(_) => {
                held.run.record.set_outcome_unknown();
                held.run
                    .record
                    .timeline
                    .push(format!("reconcile inconclusive: {detail}"));
            }
        }
        held.persist(self.jobs)?;
        // Swift `finalizeDebugHAPFailure`, which settles the use itself.
        if hap && next == "finalizing" {
            self.finalize_hap_failure(held)?;
            return Ok(None);
        }
        if let Some((outcome, state)) = settled {
            lineage::record_capability_outcome(
                &held.run.record,
                self.capabilities,
                outcome,
                state,
                self.now,
            )
            .map_err(from_repair)?;
        }
        if terminal(&held.run.record.state) && !held.run.record.outcome_unknown() {
            return Ok(None);
        }
        Ok(Some(held.run.record.status()))
    }
}

/// A Job this Runtime does not reconcile yet (a terminal debug HAP, whose
/// own lineage repair is not ported, or a Job of an operation it does not
/// run): its status where Swift's reconcile writes nothing for it, and
/// otherwise a refusal with nothing written.
fn unported(record: JobRecord) -> Result<Value, WireError> {
    let state = record.state.as_str();
    let writes = if terminal(state) {
        record
            .session_publication()
            .is_some_and(unbound_source_failure)
            || lineage::repairs_lineage(&record)
    } else {
        record.outcome_unknown()
            || matches!(state, "cancelRequested" | "cancellingAtSafeBoundary")
            || (record.operation() == HAP && state == "finalizing")
    };
    if !writes {
        return Ok(record.status());
    }
    Err(refused(
        "rejected",
        format!(
            "job {} runs {}, which the Rust Runtime does not reconcile yet; nothing was \
             dispatched or written",
            record.job_id,
            record.operation()
        ),
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn identity(source: &str, sha256: &str, count: i64) -> Identity {
        Identity {
            analyzer_ref: "crash-signature@1".into(),
            source_artifact_id: source.into(),
            source_sha256: sha256.into(),
            source_byte_count: count,
            request_digest: None,
        }
    }

    #[test]
    fn the_analyzer_confirms_non_execution_only_for_the_source_its_intent_named() {
        let sha = "a".repeat(64);
        let named = identity("ART-1", &sha, 30);
        let same = Source {
            artifact_id: "ART-1".into(),
            sha256: Some(sha.clone()),
            byte_count: Some(30),
        };
        assert!(matches!(
            analyzer_reconcile(&named, Some(&same)),
            Decision::NotExecuted
        ));
        for other in [
            Source {
                artifact_id: "ART-2".into(),
                sha256: Some(sha.clone()),
                byte_count: Some(30),
            },
            Source {
                artifact_id: "ART-1".into(),
                sha256: Some("b".repeat(64)),
                byte_count: Some(30),
            },
            Source {
                artifact_id: "ART-1".into(),
                sha256: Some(sha.clone()),
                byte_count: Some(31),
            },
        ] {
            assert!(matches!(
                analyzer_reconcile(&named, Some(&other)),
                Decision::Unknown(reason) if reason == "analyzer reconcile source identity does not match"
            ));
        }
        assert!(matches!(
            analyzer_reconcile(&named, None),
            Decision::Unknown(_)
        ));
    }

    #[test]
    fn a_persisted_action_materializes_only_as_its_closed_recovery_identity() {
        let sha = "c".repeat(64);
        let action = json!({"kind": "analyzer.analyze", "arguments": {
            "analyzerRef": "crash-signature@1", "analyzerVersion": "arkdeck-fault-log-ledger@1",
            "sourceArtifactId": "ART-1", "sourceSha256": sha, "sourceByteCount": 30}});
        let materialized = materialize(&action).unwrap();
        assert_eq!(materialized.source_byte_count, 30);
        let mut extra = action.clone();
        extra["arguments"]["future"] = json!(true);
        let mut uppercase = action.clone();
        uppercase["arguments"]["sourceSha256"] = json!("C".repeat(64));
        let mut empty = action.clone();
        empty["arguments"]["sourceByteCount"] = json!(0);
        let mut foreign = action;
        foreign["kind"] = json!("hdc.shell");
        for (refused, message) in [
            (
                extra,
                "persisted analyzer.analyze has a non-closed recovery identity",
            ),
            (
                uppercase,
                "persisted analyzer.analyze has an invalid recovery identity",
            ),
            (
                empty,
                "persisted analyzer.analyze has an invalid recovery identity",
            ),
            (
                foreign,
                "persisted typed provider action kind hdc.shell is unknown",
            ),
        ] {
            let Err(error) = materialize(&refused) else {
                panic!("{refused}");
            };
            assert_eq!(
                (error.code.as_str(), error.message.as_str()),
                ("internalError", message)
            );
        }
    }

    #[test]
    fn only_the_writers_confirmed_unbound_refusal_starts_a_publication_again() {
        let marker = json!({"sessionID": "session-job-a", "catalogDigest": "d",
            "policyGeneration": "0",
            "root": {"path": "", "device": "0", "inode": "0", "volumeIdentity": ""},
            "relativeSessionPath": "", "claims": [], "phase": "awaitingStorage",
            "failure": {"code": "sourceIntegrityFailed", "certainty": "confirmed",
                "detail": "the Job Journal does not open with its own creation facts"}});
        assert!(unbound_source_failure(&marker));
        let mut storage = marker.clone();
        storage["failure"]["code"] = json!("storageUnavailable");
        let mut bound = marker.clone();
        bound["policyGeneration"] = json!("1");
        let mut proposed = marker;
        proposed["proposal"] = json!({"manifestSHA256": "e"});
        for other in [storage, bound, proposed] {
            assert!(!unbound_source_failure(&other), "{other}");
        }
    }

    #[test]
    fn an_attempt_without_its_decision_is_the_one_continued() {
        let started = |attempt: &str| json!({"kind": "reconcileStarted", "payload": {"recoveryAttemptId": attempt}});
        let decided = |attempt: &str| json!({"kind": "reconcileOutcome", "payload": {"recoveryAttemptId": attempt}});
        assert_eq!(unfinished_attempt(&[]), None);
        assert_eq!(
            unfinished_attempt(&[started("recovery-a-6")]).as_deref(),
            Some("recovery-a-6")
        );
        assert_eq!(
            unfinished_attempt(&[started("recovery-a-6"), decided("recovery-a-6")]),
            None
        );
        assert_eq!(
            unfinished_attempt(&[
                started("recovery-a-6"),
                decided("recovery-a-6"),
                started("recovery-a-9"),
            ])
            .as_deref(),
            Some("recovery-a-9")
        );
        assert_eq!(swift_array(&["source".into()]), "[\"source\"]");
    }
}
