//! Swift `RuntimeJobEngine.runForTargetControl` for an admitted analyzer Job
//! (`analyzer.extract-crash-signature@1`, `analyzer.summarize-hilog@1`), as
//! the isolated Rust owner runs it, composed like a Swift engine with no power controller and, where one
//! is given, the standalone daemon's Session publication writer: the running
//! transition, the source lease resolved again,
//! the exact typed action persisted before its write-ahead intent is durable,
//! the analyzer child started only after that intent, Swift's semantic checks,
//! the correlated outcome, the derived Artifact published after it, and the
//! terminal transitions and record, each spelled as Swift writes them. A child
//! whose outcome cannot be observed leaves its intent outstanding and parks
//! the Job in `waitingForRecovery`; nothing is dispatched twice.
//!
//! A cancellation request reaches the run through its [`RunCancellation`].
//! The run makes it durable as Swift's `requestCancel` does, then closes the
//! Job at its last boundary before the intent or, while the child runs,
//! terminates the child's process group and closes the Job once no member is
//! left. A child that finished first, or a group that could not be drained,
//! parks the Job instead. Once the child has finished, a request changes
//! nothing.
//!
//! An analyzer Job runs from its admitted `preflight` boundary only. A
//! device-bound Job is also resumed as Swift's `runOwned` resumes it (ADR-0009
//! decisions 2 and 4, L.1 item 13): at the confirmed safe boundary a
//! reconcile reached (`resumeAtConfirmedSafeBoundary`), from `running` once a
//! restart found nothing outstanding in its journal, and a debug HAP's
//! failure finalization from `finalizing`. The journal must stand exactly at
//! that boundary — no torn tail, no outstanding intent, no unknown outcome,
//! a confirmed decision for the reconciled boundary — or nothing is
//! dispatched; the steps it confirmed are never run again
//! (`device_run.rs`), and a resumed Job continues under the capability use
//! it holds, never a second one (`mutation_execution.rs`).
use crate::analyzer_composition::{self, AnalyzerComposition};
use crate::analyzer_output::{self, Invocation, Receipt, Source};
use crate::artifact_publication::{ArtifactPublisher, Product};
use crate::artifact_read_owner::{ArtifactReadStore, LeasedArtifact, swift_string};
use crate::device_facts::HdcComposition;
use crate::job_cancel::RunCancellation;
use crate::job_journal_events::{self as events, Envelope, Target};
use crate::job_journal_writer::JournalWriter;
use crate::job_owner::JobStore;
use crate::job_record::{JobRecord, terminal};
use crate::session_publication::SessionPublisher;
use arkdeck_contract::CATALOG_DIGEST;
use arkdeck_platform::{
    AnalyzerLimits, AnalyzerRunError, AnalyzerTermination, ToolLimits, ToolRequest, ToolRunError,
    ToolTermination, VerifiedNamespace, VerifiedResource, VerifiedSource, VerifiedTool,
};
use serde_json::{Map, Value, json};
use std::ffi::OsString;
use std::path::Path;
use std::time::Duration;

#[path = "workspace_run.rs"]
mod workspace_run;

const STEP_KIND: &str = "runDeterministicAnalyzer";
/// Swift `DescriptorBoundProcessDispatcher`'s per-stream capture, whatever
/// budget the analyzer profile gives its answer.
const CAPTURE_BYTES: usize = 8 * 1024 * 1024;
const MAXIMUM_SOURCE_BYTES: u64 = 512 * 1024 * 1024;
/// The states Swift `runOwned` drives (a finalizing `debug.hap@1` aside).
const RUNNABLE: [&str; 4] = [
    "preflight",
    "running",
    "recoveringByCompleteOverwrite",
    "resumeAtConfirmedSafeBoundary",
];

/// Whether this Runtime executes an admitted Job of `operation`: the analyzer
/// here, a device-bound operation (`debug.hap@1` among them) through its HDC
/// composition, a Runtime-owned workspace copy, the patches applied to and
/// reverted from a workspace and a workspace build through its workspace
/// composition. Every other Job is refused before its run starts.
pub(crate) fn executes(operation: &str) -> bool {
    analyzer_composition::EXECUTED.contains(&operation)
        || crate::device_run::runs(operation)
        || workspace_run::runs(operation)
}

/// A `job.run` refusal: its control-plane code, message and details.
#[derive(Debug)]
pub struct RunRefusal {
    pub code: &'static str,
    pub message: String,
    /// The zero-dispatch proof where it holds; Swift's empty details once
    /// what the run did is no longer proven.
    pub details: Map<String, Value>,
}

pub(crate) fn proven(
    code: &'static str,
    message: impl Into<String>,
    job: Option<&str>,
) -> RunRefusal {
    let mut details = Map::from_iter([
        ("phase".into(), json!("preAdmission")),
        ("newDispatchCount".into(), json!(0)),
    ]);
    if let Some(job) = job {
        details.insert("jobId".into(), json!(job));
    }
    RunRefusal {
        code,
        message: message.into(),
        details,
    }
}

/// Swift's handler answers any other run failure with one message.
pub(crate) fn uncertain() -> RunRefusal {
    RunRefusal {
        code: "internalError",
        message: "the Runtime could not complete the Job lifecycle request".into(),
        details: Map::new(),
    }
}

/// Swift's precise Runtime clock, which bounds a step's observation window.
pub fn runtime_precise_now() -> Option<String> {
    crate::format_time::utc_precise_now()
}

/// Swift `AgentExecutionIntent.validIdentifier`.
fn valid_identifier(id: &str) -> bool {
    (1..=128).contains(&id.len())
        && id.as_bytes()[0].is_ascii_alphanumeric()
        && id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || b"._-".contains(&byte))
}

/// `RockchipHostProcessDiagnostics.signalDeath`.
fn signal_death(signal: i32) -> String {
    format!(
        "process died on signal {signal}; the child never reached its own semantic boundary. \
         Its crash report is in ~/Library/Logs/DiagnosticReports/ (look for a same-second entry \
         named after the executable)."
    )
}

pub(crate) fn failure(code: &str, category: &str, retryability: &str, recovery: &str) -> Value {
    json!({"schemaVersion": "1.0.0", "code": code, "category": category,
        "retryability": retryability, "recovery": recovery})
}

/// Swift `RuntimeDispatchFailure` before a verified receipt, and the
/// process-group resolution of a cancelled child.
enum Dispatch {
    Failed(String),
    OutcomeUnknown(String),
    Cancelled { drained: bool },
}

/// A child that exited: its status, its output and whether any was dropped.
struct Exited {
    status: i32,
    stdout: Vec<u8>,
    stderr: Vec<u8>,
    truncated: bool,
}

pub struct JobRunner<'a> {
    pub mutation: Option<crate::mutation_execution::MutationExecution<'a>>,
    pub jobs: &'a JobStore,
    pub artifacts: &'a ArtifactReadStore,
    pub imports: Option<&'a crate::ImportUploadStore>,
    /// The analyzers the host composed; an analyzer Job runs the profile its
    /// operation names.
    pub analyzer: Option<&'a dyn AnalyzerComposition>,
    /// Swift `ArtifactQuota`, in bytes.
    pub quota: u64,
    /// Swift `NSHomeDirectory()`, which Artifact redaction replaces.
    pub home: &'a str,
    pub now: fn() -> Option<String>,
    pub precise_now: fn() -> Option<String>,
    /// The standalone daemon's Session publication writer. Without one the
    /// runner composes like a Swift engine that has none, and its Jobs report
    /// no publication record.
    pub sessions: Option<&'a SessionPublisher<'a>>,
    /// The cancellation a canceller reaches while this run lasts; the run's
    /// caller ends it once the run has returned.
    pub cancellation: Option<&'a RunCancellation>,
    /// Swift's `afterAnalyzerCommitLinearization` test hook: given the Job's
    /// identity once its child has finished and its answer is verified.
    pub after_commit: Option<&'a (dyn Fn(&str) + Sync)>,
    /// The HDC composition a device-bound Job runs through; without one no
    /// such Job runs.
    pub hdc: Option<&'a HdcComposition<'a>>,
    /// The workspace composition a workspace Job runs through; without one no
    /// such Job runs.
    pub workspace: Option<&'a crate::WorkspaceComposition>,
}

/// One run's durable state: the record as the run advances it and the
/// journal it appends to, whose owner lock it holds.
pub(crate) struct Run {
    pub(crate) record: JobRecord,
    pub(crate) journal: JournalWriter,
    pub(crate) sequence: i64,
    pub(crate) now: fn() -> Option<String>,
    /// The admission evidence of the capability use this run consumed and
    /// made durable itself, or the one a resumed Job holds and the run took
    /// over. A later mutation of the same run continues under that use;
    /// other evidence on the record is never continued.
    pub(crate) consumed: Option<Value>,
}

impl Run {
    pub(crate) fn clock(&self) -> Result<String, RunRefusal> {
        (self.now)().ok_or_else(uncertain)
    }
    pub(crate) fn envelope(&self, event_id: String) -> Result<Envelope, RunRefusal> {
        let timestamp = self.clock()?;
        Ok(self.envelope_at(event_id, timestamp))
    }
    pub(crate) fn envelope_at(&self, event_id: String, timestamp: String) -> Envelope {
        Envelope {
            event_id,
            sequence: self.sequence,
            session_id: format!("session-{}", self.record.job_id),
            job_id: self.record.job_id.clone(),
            timestamp,
        }
    }
    /// A dispatched step's confirmed outcome, correlated to its intent, at
    /// the time the run read for it.
    pub(crate) fn step_outcome_at(
        &mut self,
        step_id: &str,
        intent_id: &str,
        result: &str,
        semantic_code: Option<&str>,
        timestamp: &str,
    ) -> Result<(), RunRefusal> {
        let envelope = self.envelope_at(format!("outcome-{step_id}"), timestamp.into());
        self.append(events::step_outcome(
            &envelope,
            step_id,
            1,
            intent_id,
            result,
            "confirmed",
            semantic_code,
            None,
        ))
    }
    pub(crate) fn append(&mut self, event: Value) -> Result<(), RunRefusal> {
        self.journal.append(&event).map_err(|_| uncertain())?;
        self.sequence += 1;
        Ok(())
    }
    /// Swift `transition`: journaled and synchronized; the record changes
    /// only in memory until the next persist.
    pub(crate) fn transition(
        &mut self,
        from: &str,
        to: &str,
        reason: &str,
    ) -> Result<(), RunRefusal> {
        let envelope = self.envelope(format!("t-{}", self.sequence))?;
        self.append(events::state_transition(&envelope, from, to, reason, None))?;
        self.record.state = to.into();
        self.record.timeline.push(format!("{from}->{to}"));
        self.record.timeline.push(format!("reason: {reason}"));
        Ok(())
    }
    /// The analyzer step's confirmed outcome, with the semantic code Swift
    /// names for it where it names one.
    fn outcome(
        &mut self,
        step: &str,
        result: &str,
        semantic_code: Option<&str>,
    ) -> Result<(), RunRefusal> {
        let envelope = self.envelope(format!("outcome-{step}"))?;
        self.append(events::step_outcome(
            &envelope,
            step,
            1,
            &format!("intent-{step}"),
            result,
            "confirmed",
            semantic_code,
            None,
        ))
    }
    pub(crate) fn persist(&self, jobs: &JobStore) -> Result<(), RunRefusal> {
        jobs.persist(&self.record, &self.clock()?)
            .map_err(|_| uncertain())
    }
    pub(crate) fn finish(&mut self) -> Result<(), RunRefusal> {
        let now = self.clock()?;
        self.record.finish(&now);
        Ok(())
    }
    /// Swift `statusAndReleaseTerminalRuntime`: a terminal Job whose outcome
    /// is known becomes a Session once its terminal record is durable, and
    /// the record then keeps the publication's marker.
    pub(crate) fn release(
        &mut self,
        jobs: &JobStore,
        sessions: Option<&SessionPublisher<'_>>,
        directory: &Path,
    ) -> Result<(), RunRefusal> {
        if let Some(sessions) = sessions
            && terminal(&self.record.state)
            && !self.record.outcome_unknown()
        {
            let now = self.clock()?;
            let marker = sessions.publish(&self.record, &mut self.journal, directory, &now);
            self.record.set_session_publication(marker);
            if self.persist(jobs).is_err() {
                // The Session, if any, is durable; only the marker was lost,
                // so readers see no publication rather than a receipt.
                self.record
                    .timeline
                    .push("session publication marker could not be persisted".into());
            }
        }
        Ok(())
    }
}

impl JobRunner<'_> {
    /// The terminal (or parked) Job's `arkdeck.job-status/1`, which Swift's
    /// `job.run` answers once its driver returns.
    pub fn handle(&self, params: &Map<String, Value>) -> Result<Value, RunRefusal> {
        let id = match (params.len(), params.get("jobId").and_then(Value::as_str)) {
            (1, Some(id)) if valid_identifier(id) => id,
            _ => {
                return Err(proven(
                    "invalidInput",
                    "job.run requires one exact bounded Job identity",
                    None,
                ));
            }
        };
        let record = match self.jobs.read_snapshot(id) {
            Ok(record) => record,
            Err(error) if ["notFound", "invalidInput"].contains(&error.code.as_str()) => {
                return Err(proven(
                    "resourceNotFound",
                    "the referenced Job does not exist",
                    Some(id),
                ));
            }
            Err(_) => {
                return Err(proven(
                    "recordUnreadable",
                    "the referenced Job record is unreadable",
                    Some(id),
                ));
            }
        };
        // Swift holds every non-terminal Job in memory; a terminal one is
        // answered before its shared driver could start.
        let state = record.state.clone();
        if terminal(&state) {
            return Err(proven(
                "resourceConflict",
                format!("job {id} is {state}, not runnable"),
                Some(id),
            ));
        }
        // Swift continues a `finalizing` debug HAP's failure finalization.
        let finalizing_hap = record.operation() == "debug.hap@1" && state == "finalizing";
        if !RUNNABLE.contains(&state.as_str()) && !finalizing_hap {
            return Err(proven(
                "resourceConflict",
                format!("job {id} is {state}, not runnable"),
                None,
            ));
        }
        let device = crate::device_run::runs(record.operation()) && self.hdc.is_some();
        let workspace = self
            .workspace
            .filter(|_| workspace_run::runs(record.operation()));
        if !analyzer_composition::EXECUTED.contains(&record.operation())
            && !device
            && workspace.is_none()
        {
            return Err(proven(
                "rejected",
                format!(
                    "job {id} runs {}, which the Rust Runtime does not execute yet",
                    record.operation()
                ),
                None,
            ));
        }
        // An analyzer or workspace Job is never resumed here — but a signing
        // Job a reconcile confirmed at its safe boundary, whose products it
        // republished — and a complete-overwrite recovery belongs to the
        // flash lane this Runtime does not hold.
        let resumed_signing = record.operation() == crate::workspace_composition::SIGN
            && state == "resumeAtConfirmedSafeBoundary";
        if state != "preflight"
            && !resumed_signing
            && (!device || state == "recoveringByCompleteOverwrite")
        {
            return Err(proven(
                "resourceConflict",
                format!(
                    "job {id} is {state}; the Rust Runtime resumes no {} Job from it",
                    record.operation()
                ),
                None,
            ));
        }
        if record.catalog_digest() != CATALOG_DIGEST {
            return Err(proven(
                "resourceConflict",
                format!("job {id} was materialized against a different catalog digest"),
                None,
            ));
        }
        let directory = self.jobs.job_directory(id).map_err(|_| uncertain())?;
        let journal = JournalWriter::open(&directory, false).map_err(|_| uncertain())?;
        let facts = journal.facts();
        // The journal must stand at the very boundary the record names: a
        // resumption is never a replay. A debug HAP's failure finalization
        // parks itself on what its journal leaves unresolved, as Swift's does.
        let unresolved =
            !facts.outstanding_intents.is_empty() || !facts.unknown_outcomes.is_empty();
        let decided = state != "resumeAtConfirmedSafeBoundary"
            || facts.last_reconcile_outcome_certainty.as_deref() == Some("confirmed");
        if facts.has_torn_tail
            || facts.current_state.as_deref() != Some(state.as_str())
            || facts.finalized
            || (unresolved && !finalizing_hap)
            || !decided
            || record.outcome_unknown()
        {
            return Err(proven(
                "resourceConflict",
                format!(
                    "job {id}'s journal does not stand at its {state} boundary; nothing was \
                     dispatched"
                ),
                None,
            ));
        }
        let mut run = Run {
            record,
            journal,
            sequence: facts.last_durable_sequence.map_or(0, |last| last + 1),
            now: self.now,
            consumed: None,
        };
        // A resumed Job continues under the use it holds, never a new one.
        if state != "preflight" {
            self.take_over_held_use(&mut run)
                .map_err(|message| proven("rejected", message, Some(id)))?;
        }
        match (self.hdc.filter(|_| device), workspace) {
            (Some(hdc), _) => self.execute_device(&mut run, hdc)?,
            (None, Some(workspace))
                if run.record.operation() == workspace_run::WORKSPACE_OPERATION =>
            {
                self.execute_workspace(&mut run, workspace)?
            }
            (None, Some(workspace)) if run.record.operation() == crate::workspace_build::BUILD => {
                self.execute_workspace_build(&mut run, workspace)?
            }
            (None, Some(workspace))
                if run.record.operation() == crate::workspace_composition::SIGN =>
            {
                self.execute_workspace_sign(&mut run, workspace)?
            }
            (None, Some(workspace))
                if crate::workspace_read::read_step(run.record.operation()).is_some() =>
            {
                self.execute_workspace_read(&mut run, workspace)?
            }
            (None, Some(workspace))
                if run.record.operation() == crate::workspace_checkpoint::CHECKPOINT =>
            {
                self.execute_workspace_checkpoint(&mut run, workspace)?
            }
            (None, Some(workspace)) if run.record.operation() == crate::workspace_sweep::SWEEP => {
                self.execute_workspace_sweep(&mut run, workspace)?
            }
            (None, Some(workspace)) => self.execute_workspace_patch(&mut run, workspace)?,
            (None, None) => self.execute(&mut run)?,
        }
        run.release(self.jobs, self.sessions, &directory)?;
        Ok(run.record.status())
    }

    /// Swift `runOwned` through `dispatchWithWAL` for the one analyzer step.
    fn execute(&self, run: &mut Run) -> Result<(), RunRefusal> {
        let operation = run.record.operation().to_owned();
        let step = analyzer_composition::step(&operation).ok_or_else(uncertain)?;
        let intent_id = format!("intent-{step}");
        let started = run.clock()?;
        run.record.start(&started);
        run.transition("preflight", "running", "steps-start")?;
        // Swift resolves the lease again before the step, and a failure there
        // fails the Job before any intent exists.
        let Some(reference) = run.record.request["inputs"]["sourceArtifactRef"]
            .as_str()
            .map(str::to_owned)
        else {
            return Err(uncertain());
        };
        let resolved = match crate::job_owner::import_references::ImportReference::parse(&reference)
        {
            Ok(Some(reference)) => self
                .imports
                .ok_or_else(|| "Import owner is unavailable".to_owned())
                .and_then(|owner| {
                    owner
                        .resolve_input(self.artifacts, &reference)
                        .map_err(|error| error.message)
                }),
            Ok(None) => self.artifacts.lease(&reference),
            Err(error) => Err(error.message),
        };
        let leased = match resolved {
            Ok(leased) => leased,
            Err(error) => {
                return self.fail(
                    run,
                    &format!("input Artifact lease became unreadable before {step}: {error}"),
                );
            }
        };
        if let Some(reason) = binding_refusal(&leased, &run.record) {
            return self.fail(run, &reason);
        }
        // Swift's typed action needs the profile the operation names and
        // re-reads the leased bytes; its refusal escapes the run as an
        // internal failure.
        let Some(profile) = analyzer_composition::analyzer_for_operation(&operation)
            .and_then(|analyzer_ref| self.analyzer?.profile(analyzer_ref))
        else {
            return Err(uncertain());
        };
        let (Some(sha256), Some(byte_count)) = (
            leased.row["sha256"].as_str().map(str::to_owned),
            leased.row["byteCount"].as_u64(),
        ) else {
            return Err(uncertain());
        };
        if byte_count == 0
            || byte_count > MAXIMUM_SOURCE_BYTES
            || !self.artifacts.payload_matches(&leased)
        {
            return Err(uncertain());
        }
        let Some(lease_path) = leased.path.to_str() else {
            return Err(uncertain());
        };
        let source = Source {
            artifact_id: &leased.artifact_id,
            sha256: &sha256,
            byte_count,
            path: lease_path,
        };
        let empty = Map::new();
        let inputs = run.record.request["inputs"].as_object().unwrap_or(&empty);
        let Ok(invocation) = Invocation::of(profile, inputs, lease_path) else {
            return Err(uncertain());
        };
        let derived = analyzer_composition::derived_artifact_name(&profile.analyzer_ref);
        let target = run.record.request["target"]["targetId"]
            .as_str()
            .unwrap_or_default()
            .to_owned();
        let step_document = json!({
            "id": step, "kind": STEP_KIND, "effect": "hostOnly", "bindingRequirement": "none",
            "cancellation": "immediate", "compensationDescriptors": [],
            "arguments": {"analyzerRef": profile.analyzer_ref,
                "inputArtifactId": leased.artifact_id, "artifactId": derived},
        });
        let intent = events::step_intent(
            &run.envelope(intent_id.clone())?,
            &step_document,
            &Target {
                scope: "host".into(),
                target_id: target.clone(),
                connect_key: None,
                identity_snapshot_hash: None,
            },
            1,
            None,
        )
        .map_err(|_| uncertain())?;
        // Swift's last synchronous boundary before an intent or a child can
        // be installed: a request that reached the run by now closes the Job
        // with zero dispatch.
        if self.cancellation.is_some_and(RunCancellation::pending) {
            self.carry(run)?;
            return self.close_cancelled(run, None);
        }
        // The exact typed action is durable before its intent can be.
        let mut action_arguments = json!({
            "analyzerRef": profile.analyzer_ref, "analyzerVersion": profile.analyzer_version,
            "sourceArtifactId": leased.artifact_id, "sourceSha256": sha256,
            "sourceByteCount": byte_count});
        if let Some(request) = &invocation.analysis {
            action_arguments["requestDigestSha256"] = json!(request.recovery_digest_sha256());
        }
        run.record.set_recovery(
            Some(step),
            Some(&intent_id),
            Some(json!({"kind": "analyzer.analyze", "arguments": action_arguments})),
        );
        run.persist(self.jobs)?;
        if run.append(intent).is_err() {
            run.record.set_recovery(None, None, None);
            let _ = run.persist(self.jobs);
            return Err(uncertain());
        }
        run.record.timeline.push(format!("intent {step}"));
        run.record.add_step_kind(STEP_KIND);
        // Only now may the child start; a request that reaches the run while
        // the child runs terminates it.
        let cancelled = || self.cancellation.is_some_and(RunCancellation::pending);
        let opened = (self.precise_now)();
        let dispatched = match opened {
            Some(_) => self.dispatch(&invocation, &leased.path, &source, &cancelled),
            None => Err(Dispatch::Failed(
                "dispatch refused: the Runtime clock is unavailable".into(),
            )),
        };
        let window = opened.zip((self.precise_now)());
        let exited = match dispatched {
            Ok(exited) => exited,
            Err(Dispatch::Cancelled { drained }) if cancelled() => {
                self.carry(run)?;
                if drained {
                    return self.close_cancelled(run, Some(step));
                }
                run.record.timeline.push(
                    "analyzer cancellation process-group drain unconfirmed; intent retained".into(),
                );
                return self.park(run, "analyzer process-group drain unconfirmed");
            }
            // Only a request stops the child; a stop without one is Swift's
            // unknown outcome.
            Err(Dispatch::Cancelled { .. }) => {
                return self.park(
                    run,
                    "process cancellation occurred without an admitted immediate cancellation",
                );
            }
            Err(Dispatch::OutcomeUnknown(reason)) => {
                // The intent stays outstanding: no outcome is invented, and
                // recovery alone may resolve it by readback.
                run.record.timeline.push(format!(
                    "outcomeUnknown {step}; durable intent left outstanding"
                ));
                return self.park(run, &reason);
            }
            Err(Dispatch::Failed(reason)) => {
                run.outcome(step, "failed", None)?;
                run.record.timeline.push(format!("failed {step}"));
                run.record.set_recovery(None, None, None);
                return self.fail(run, &reason);
            }
        };
        // Swift's success commit: a request that reached the run before its
        // child was seen to finish raced the completion, which proves no
        // drain; one that arrives from now on changes nothing.
        if self.cancellation.is_some_and(RunCancellation::commit) {
            self.carry(run)?;
            run.record.timeline.push(
                "analyzer cancellation raced completion without process-group drain proof".into(),
            );
            run.record.timeline.push(format!(
                "outcomeUnknown {step}; durable intent left outstanding"
            ));
            return self.park(run, "analyzer cancellation lacks process-group drain proof");
        }
        let receipt = Receipt {
            exit_status: exited.status,
            stdout: &exited.stdout,
            stderr: &exited.stderr,
            truncated: exited.truncated,
        };
        let verified = match analyzer_output::verify(&receipt, &source, &invocation) {
            Ok(verified) => verified,
            Err((code, detail)) => {
                run.outcome(step, "failed", None)?;
                run.record.set_recovery(None, None, None);
                run.record
                    .timeline
                    .push(format!("failed {step}: {code}: {detail}"));
                return self.fail(run, &format!("{code}: {detail}"));
            }
        };
        if let Some(hook) = self.after_commit {
            hook(&run.record.job_id);
        }
        let job_id = run.record.job_id.clone();
        let session_id = format!("session-{job_id}");
        let mut binding = json!({"targetID": target});
        if let Some(revision) = run.record.request["target"]["expectedBindingRevision"].as_i64() {
            binding["bindingRevision"] = json!(revision);
        }
        if let Some(identity) = run.record.materialized_identity() {
            binding["stableIdentitySHA256"] = json!(identity);
        }
        let product = Product {
            job_id: &job_id,
            session_id: &session_id,
            step_id: step,
            name: derived,
            media_type: "application/json",
            privacy: "standard",
            retention_class: "default",
            source_operation: &operation,
            provider_id: "analyzer",
            binding,
            observation_window: window,
        };
        let publisher = ArtifactPublisher {
            store: self.artifacts,
            quota: self.quota,
            home: self.home,
            now: self.now,
        };
        let contents = verified.envelope().unwrap_or_else(|| b"{}".to_vec());
        // Swift publishes an ArkTrace product as the exact bytes its
        // validator approved, with the derivation that closes them.
        let derivation = verified.derivation();
        let publish = || match &derivation {
            Some(derivation) => publisher.publish_machine_bytes(&product, &contents, derivation),
            None => publisher.publish(&product, &contents),
        };
        // A publication failure is recorded, never swallowed, and fails the
        // Job with whatever its step has written so far.
        let unpublished = |run: &mut Run, error: String| {
            let _ = publisher.record_missing(&product, &error);
            run.record
                .timeline
                .push(format!("artifact {derived} missing: {error}"));
            run.record.set_operation_failure(Some(failure(
                "artifactPublicationFailed",
                "storage",
                "notAutomatic",
                "inspectJob",
            )));
            self.close(
                run,
                &format!("artifact publication failed: {derived} could not be published: {error}"),
            )
        };
        // Swift makes an ArkTrace product durable before the journal can call
        // its step succeeded: a failure leaves the intent outstanding and the
        // typed action recorded. Its publication line is appended to a record
        // the step then overwrites, so a published product leaves none.
        let publishes_before_outcome = analyzer_composition::publishes_before_outcome(&operation);
        if publishes_before_outcome && let Err(error) = publish() {
            return unpublished(run, error);
        }
        run.outcome(step, "succeeded", None)?;
        run.record
            .timeline
            .push(format!("verified {step} {}", verified.fact_names()));
        run.record.set_recovery(None, None, None);
        // Any other declared product is published after the correlated
        // outcome.
        if !publishes_before_outcome {
            match publish() {
                Ok(metadata) => run.record.timeline.push(format!(
                    "artifact {derived} -> {}",
                    metadata["artifactID"].as_str().unwrap_or_default()
                )),
                Err(error) => return unpublished(run, error),
            }
        }
        run.transition("running", "finalizing", "steps-complete")?;
        run.record.set_operation_failure(None);
        run.transition("finalizing", "succeeded", "finalized")?;
        run.finish()?;
        run.persist(self.jobs)
    }

    /// Swift's `.failed(reason)` lane in `runOwned`.
    pub(crate) fn fail(&self, run: &mut Run, reason: &str) -> Result<(), RunRefusal> {
        run.record.set_operation_failure(Some(failure(
            "executionFailed",
            "execution",
            "runtimeDecisionRequired",
            "inspectJob",
        )));
        self.close(run, reason)
    }

    /// The failure already recorded, persisted, then closed through
    /// `finalizing` to `failed`.
    pub(crate) fn close(&self, run: &mut Run, reason: &str) -> Result<(), RunRefusal> {
        run.persist(self.jobs)?;
        run.transition("running", "finalizing", reason)?;
        run.transition("finalizing", "failed", reason)?;
        run.finish()?;
        run.persist(self.jobs)
    }

    /// Swift's `.outcomeUnknown(reason)` lane: parked from the state the run
    /// has reached, never replayed.
    pub(crate) fn park(&self, run: &mut Run, reason: &str) -> Result<(), RunRefusal> {
        run.record.set_operation_failure(Some(failure(
            "outcomeUnknown",
            "unknownOutcome",
            "runtimeDecisionRequired",
            "awaitRuntimeReconciliation",
        )));
        let from = run.record.state.clone();
        run.transition(
            &from,
            "waitingForRecovery",
            &format!("outcomeUnknown: {reason}"),
        )?;
        run.record.set_outcome_unknown();
        run.finish()?;
        run.persist(self.jobs)
    }

    /// Swift `requestCancel`'s durable intent, written by the run that owns
    /// the Journal; the waiting canceller answers once it is persisted.
    pub(crate) fn carry(&self, run: &mut Run) -> Result<(), RunRefusal> {
        if run.record.state == "running" {
            run.transition(
                "running",
                "cancelRequested",
                "durable client cancellation intent",
            )?;
            run.persist(self.jobs)?;
        }
        if let Some(cancellation) = self.cancellation {
            cancellation.carried();
        }
        Ok(())
    }

    /// Swift `completeCancellationAtSafeBoundary`: a dispatched step's
    /// cancelled outcome, the typed action forgotten, and the Job closed.
    /// `dispatched` names the step whose child was drained.
    fn close_cancelled(&self, run: &mut Run, dispatched: Option<&str>) -> Result<(), RunRefusal> {
        if let Some(step) = dispatched {
            run.outcome(step, "failed", Some("cancelled"))?;
            run.record.timeline.push(format!(
                "cancelled {step}; dispatch reached a confirmed safe boundary before publication"
            ));
        }
        run.record.set_recovery(None, None, None);
        run.transition(
            "cancelRequested",
            "cancellingAtSafeBoundary",
            "dispatch has a confirmed safe boundary",
        )?;
        run.transition(
            "cancellingAtSafeBoundary",
            "cancelled",
            "cancelled intent closed without publication",
        )?;
        run.record.set_operation_failure(Some(failure(
            "cancelled",
            "cancelled",
            "notAutomatic",
            "none",
        )));
        run.finish()?;
        run.persist(self.jobs)
    }

    /// Swift `DescriptorBoundProcessDispatcher.dispatch` for one analyzer
    /// invocation: the source bound by descriptor first, then the pinned
    /// executable, then the child, which reads the source's inode alias and
    /// is stopped once `cancelled` holds.
    fn dispatch(
        &self,
        invocation: &Invocation<'_>,
        path: &Path,
        source: &Source<'_>,
        cancelled: &dyn Fn() -> bool,
    ) -> Result<Exited, Dispatch> {
        let profile = invocation.profile;
        if profile.arktrace_summary.is_some() || profile.arktrace_analysis.is_some() {
            return dispatch_arktrace(invocation, source, cancelled);
        }
        let verified = VerifiedSource::open(path, source.sha256, source.byte_count)
            .map_err(|_| Dispatch::Failed("analyzer input Artifact identity refused".into()))?;
        let tool = VerifiedTool::open(&profile.executable_path, &profile.executable_sha256)
            .map_err(|error| Dispatch::Failed(format!("dispatch refused: {error}")))?;
        let mut arguments: Vec<OsString> =
            profile.fixed_arguments.iter().map(OsString::from).collect();
        arguments.push(verified.inode_path().into());
        let limits = AnalyzerLimits {
            timeout: Duration::from_secs(profile.timeout_seconds.max(1) as u64),
            capture_bytes: CAPTURE_BYTES,
        };
        match tool.run_analyzer(&arguments, &verified, limits, cancelled) {
            Err(AnalyzerRunError::Refused(error)) => {
                Err(Dispatch::Failed(format!("dispatch refused: {error}")))
            }
            Err(AnalyzerRunError::Unobservable(error)) => Err(Dispatch::OutcomeUnknown(format!(
                "dispatch outcome unobservable: {error}"
            ))),
            Ok(execution) => match execution.termination {
                AnalyzerTermination::Exited(status) => Ok(Exited {
                    status,
                    stdout: execution.stdout,
                    stderr: execution.stderr,
                    truncated: execution.truncated,
                }),
                AnalyzerTermination::TimedOut => Err(Dispatch::OutcomeUnknown(
                    "process timed out before completion".into(),
                )),
                AnalyzerTermination::Signalled(signal) => {
                    Err(Dispatch::OutcomeUnknown(signal_death(signal)))
                }
                // Whether a request stopped it is the run's to judge.
                AnalyzerTermination::Cancelled { drained } => Err(Dispatch::Cancelled { drained }),
            },
        }
    }
}

/// Swift `DescriptorBoundProcessDispatcher.dispatch` for an ArkTrace analyzer,
/// whose reviewed CLI is an inner executable of a signed bundle
/// (`.verifiedCanonicalPath`): the source bound by one retained descriptor
/// (`VerifiedRegularFileDescriptor`), then the bundle's owner-only namespace,
/// the pinned trees and files, and the pinned executable spawned suspended at
/// its canonical path, resumed only once its first mapping is the retained
/// inode and the namespace, the pinned files and the source still hold. The
/// child reads the source's inode alias, under the dispatcher's own capture
/// and no environment beyond the clean base. A failure after the source is
/// bound is reported only by its class, as Swift keeps the authorized
/// executable's path out of a trace operation's durable failure.
fn dispatch_arktrace(
    invocation: &Invocation<'_>,
    source: &Source<'_>,
    cancelled: &dyn Fn() -> bool,
) -> Result<Exited, Dispatch> {
    let profile = invocation.profile;
    const REFUSED: &str = "analyzer process identity refused";
    const UNKNOWN: &str = "analyzer process outcome unknown";
    let refused = || Dispatch::Failed(REFUSED.into());
    let bound_source = VerifiedResource::open(source.path, source.sha256, source.byte_count, false)
        .ok()
        .filter(|bound| source.byte_count > 0 && bound.byte_count() == source.byte_count)
        .ok_or_else(|| Dispatch::Failed("analyzer input Artifact identity refused".into()))?;
    let namespace = profile
        .canonical_namespace_root
        .as_deref()
        .map(VerifiedNamespace::open_owner_only)
        .transpose()
        .map_err(|_| refused())?;
    let trees_hold = profile.pinned_trees.iter().all(|tree| {
        crate::hilog_summary::profile_path(&tree.path, false)
            .is_ok_and(|path| arkdeck_platform::tree_matches(&path, &tree.path, &tree.sha256))
    });
    if !trees_hold {
        return Err(refused());
    }
    let mut resources = profile
        .pinned_files
        .iter()
        .map(|pin| {
            let byte_count = pin.byte_count.max(1);
            VerifiedResource::open(&pin.path, &pin.sha256, byte_count, pin.require_executable)
                .ok()
                .filter(|resource| resource.byte_count() == byte_count)
        })
        .collect::<Option<Vec<_>>>()
        .ok_or_else(refused)?;
    // Swift binds the source to the invocation's last argument, the lease
    // path, and hands the child its inode alias in its place.
    let Some((_, leading)) = invocation.arguments.split_last() else {
        return Err(Dispatch::Failed(
            "analyzer input Artifact identity refused".into(),
        ));
    };
    let mut arguments: Vec<OsString> = leading.iter().map(OsString::from).collect();
    arguments.push(bound_source.inode_path().into());
    resources.push(bound_source);
    let tool = VerifiedTool::open(&profile.executable_path, &profile.executable_sha256)
        .map_err(|_| refused())?;
    let bound = || -> std::io::Result<()> {
        if let Some(namespace) = &namespace {
            namespace.revalidate()?;
        }
        resources.iter().try_for_each(VerifiedResource::revalidate)
    };
    let request = ToolRequest {
        arguments: &arguments,
        environment: &[],
        working_directory: None,
        limits: ToolLimits {
            timeout: Duration::from_secs(invocation.timeout_seconds.max(1) as u64),
            capture_bytes: CAPTURE_BYTES,
        },
    };
    match tool.run_tool_at_canonical_path(&request, &bound, cancelled) {
        Err(ToolRunError::Refused(_)) => Err(refused()),
        Err(ToolRunError::Unobservable(_)) => Err(Dispatch::OutcomeUnknown(UNKNOWN.into())),
        Ok(execution) => match execution.termination {
            ToolTermination::Exited(status) => Ok(Exited {
                status,
                stdout: execution.stdout,
                stderr: execution.stderr,
                truncated: execution.truncated,
            }),
            ToolTermination::TimedOut | ToolTermination::Signalled(_) => {
                Err(Dispatch::OutcomeUnknown(UNKNOWN.into()))
            }
            // Whether a request stopped it is the run's to judge.
            ToolTermination::Cancelled { drained } => Err(Dispatch::Cancelled { drained }),
        },
    }
}

/// Swift `validateResolvedInputArtifact` for an analyzer: a host-only
/// request may read an Artifact collected from its own target; any other
/// binding must be the materialized one. The refusal is Swift's
/// interpolation of its `RuntimeJobEngineError`.
pub(crate) fn binding_refusal(leased: &LeasedArtifact, record: &JobRecord) -> Option<String> {
    let binding = &leased.row["bindingSnapshot"];
    let target = &record.request["target"];
    let revision = target
        .get("expectedBindingRevision")
        .filter(|v| !v.is_null());
    if revision.is_none() && binding["targetID"] == target["targetId"] {
        return None;
    }
    let rejected = |message: &str| {
        Some(format!(
            "rejected(ArkDeckCore.RuntimeOperationErrorCode.invalidInput, {})",
            swift_string(message)
        ))
    };
    let mismatch = "Artifact lease target/binding/identity does not match the materialized request";
    if binding["targetID"] != target["targetId"]
        || binding.get("bindingRevision").filter(|v| !v.is_null()) != revision
    {
        return rejected(mismatch);
    }
    let identity = binding.get("stableIdentitySHA256").and_then(Value::as_str);
    match record.materialized_identity() {
        Some(expected) if identity != Some(expected) => rejected(mismatch),
        Some(_) => None,
        None if revision.is_some() || identity.is_some() => {
            rejected("host-only Artifact lease must not claim a device binding or identity")
        }
        None => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::arktrace_profile::ArkTraceContract;
    use crate::job_plan::AnalyzerProfile;
    use std::os::unix::fs::PermissionsExt;

    struct Scratch(std::path::PathBuf);
    impl Drop for Scratch {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn write(path: &Path, bytes: &[u8], mode: u32) {
        std::fs::write(path, bytes).unwrap();
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(mode)).unwrap();
    }

    /// Before any child runs, an ArkTrace dispatch refuses a source that is
    /// not its lease's bytes by the source's own words, and a launch the
    /// runner refuses — here a budget beyond an hour — only by the class
    /// Swift keeps at the trace operations' boundary, whatever the detail.
    #[test]
    fn an_arktrace_dispatch_refuses_by_class_before_any_child() {
        let scratch = Scratch(std::path::PathBuf::from(format!(
            "/private/tmp/arkdeck-job-run-arktrace-{:032x}",
            u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap())
        )));
        std::fs::create_dir(&scratch.0).unwrap();
        std::fs::set_permissions(&scratch.0, std::fs::Permissions::from_mode(0o700)).unwrap();
        let executable = include_bytes!("../../../tests/fixtures/job-run-trace-summary/arktrace");
        let tool = scratch.0.join("arktrace");
        write(&tool, executable, 0o700);
        let source_path = scratch.0.join("trace.htrace");
        write(&source_path, b"answered\n", 0o400);
        let contract = ArkTraceContract {
            tool_version: "0.1.0".into(),
            parser_version: "4.3.7".into(),
            parser_upstream_revision: "6".repeat(40),
            parser_sha256: "5".repeat(64),
            parser_build_recipe_version: "7".repeat(64),
            parser_adapter_version: "1".into(),
            schema_adapter_version: "2".into(),
            index_schema_version: 3,
        };
        let profile = AnalyzerProfile {
            analyzer_ref: "trace-summary@1".into(),
            analyzer_version: "0.1.0+1".into(),
            executable_path: tool.clone(),
            executable_sha256: arkdeck_contract::sha256_hex(executable),
            fixed_arguments: vec!["summary".into()],
            timeout_seconds: 3601,
            output_byte_budget: 8 * 1024 * 1024,
            canonical_namespace_root: None,
            pinned_files: Vec::new(),
            pinned_trees: Vec::new(),
            arktrace_summary: Some(contract),
            arktrace_analysis: None,
        };
        let digest = arkdeck_contract::sha256_hex(b"answered\n");
        let path = source_path.to_str().unwrap();
        let invocation = Invocation::of(&profile, &Map::new(), path).unwrap();
        let source = |sha256: &str| {
            dispatch_arktrace(
                &invocation,
                &Source {
                    artifact_id: "ART-SOURCE",
                    sha256,
                    byte_count: 9,
                    path,
                },
                &|| false,
            )
        };
        let failed = |outcome: Result<Exited, Dispatch>| match outcome {
            Err(Dispatch::Failed(reason)) => reason,
            _ => panic!("not a definite failure"),
        };
        assert_eq!(
            failed(source(&"0".repeat(64))),
            "analyzer input Artifact identity refused"
        );
        assert_eq!(failed(source(&digest)), "analyzer process identity refused");
    }
}
