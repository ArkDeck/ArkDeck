//! Swift `RuntimeJobEngine.runForTargetControl` for an admitted
//! `analyzer.extract-crash-signature@1` Job, as the isolated Rust owner runs
//! it, composed like a Swift engine with no power controller and, where one
//! is given, the standalone daemon's Session publication writer: the running
//! transition, the source lease resolved again,
//! the exact typed action persisted before its write-ahead intent is durable,
//! the analyzer child started only after that intent, Swift's semantic checks,
//! the correlated outcome, the derived Artifact published after it, and the
//! terminal transitions and record, each spelled as Swift writes them. A child
//! whose outcome cannot be observed leaves its intent outstanding and parks
//! the Job in `waitingForRecovery`; nothing is dispatched twice.
//!
//! Only a Job at its admitted `preflight` boundary runs. Swift resumes a
//! `running` Job after its own restart recovery; until recovery is ported
//! (ADR-0009 decisions 2/4, L.1 item 13) the Rust owner refuses it, with the
//! zero-dispatch proof, as it refuses every operation but this analyzer.
use crate::analyzer_output::{self, ANALYZER_REF, ANALYZER_VERSION, DERIVED_NAME, Receipt, Source};
use crate::artifact_publication::{ArtifactPublisher, Product};
use crate::artifact_read_owner::{ArtifactReadStore, LeasedArtifact, swift_string};
use crate::job_journal_events::{self as events, Envelope, Target};
use crate::job_journal_writer::JournalWriter;
use crate::job_owner::JobStore;
use crate::job_plan::AnalyzerProfile;
use crate::job_record::{JobRecord, terminal};
use crate::session_publication::SessionPublisher;
use arkdeck_contract::CATALOG_DIGEST;
use arkdeck_platform::{
    AnalyzerLimits, AnalyzerRunError, AnalyzerTermination, VerifiedSource, VerifiedTool,
};
use serde_json::{Map, Value, json};
use std::ffi::OsString;
use std::path::Path;
use std::time::Duration;

const OPERATION: &str = "analyzer.extract-crash-signature@1";
const STEP: &str = "extract-crash-signature";
const STEP_KIND: &str = "runDeterministicAnalyzer";
const INTENT: &str = "intent-extract-crash-signature";
const OUTCOME: &str = "outcome-extract-crash-signature";
/// Swift `DescriptorBoundProcessDispatcher`'s per-stream capture, which is
/// also the analyzer profile's output byte budget.
const OUTPUT_BYTE_BUDGET: usize = 8 * 1024 * 1024;
const MAXIMUM_SOURCE_BYTES: u64 = 512 * 1024 * 1024;
/// The states Swift `runOwned` drives (a finalizing `debug.hap@1` aside).
const RUNNABLE: [&str; 4] = [
    "preflight",
    "running",
    "recoveringByCompleteOverwrite",
    "resumeAtConfirmedSafeBoundary",
];

/// A `job.run` refusal: its control-plane code, message and details.
#[derive(Debug)]
pub struct RunRefusal {
    pub code: &'static str,
    pub message: String,
    /// The zero-dispatch proof where it holds; Swift's empty details once
    /// what the run did is no longer proven.
    pub details: Map<String, Value>,
}

fn proven(code: &'static str, message: impl Into<String>, job: Option<&str>) -> RunRefusal {
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
fn uncertain() -> RunRefusal {
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

/// Swift `RuntimeDispatchFailure` before a verified receipt.
enum Dispatch {
    Failed(String),
    OutcomeUnknown(String),
}

/// A child that exited: its status, stdout and whether output was dropped.
struct Exited {
    status: i32,
    stdout: Vec<u8>,
    truncated: bool,
}

pub struct JobRunner<'a> {
    pub jobs: &'a JobStore,
    pub artifacts: &'a ArtifactReadStore,
    pub analyzer: Option<&'a AnalyzerProfile>,
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
}

/// One run's durable state: the record as the run advances it and the
/// journal it appends to, whose owner lock it holds.
pub(crate) struct Run {
    pub(crate) record: JobRecord,
    pub(crate) journal: JournalWriter,
    pub(crate) sequence: i64,
    pub(crate) now: fn() -> Option<String>,
}

impl Run {
    pub(crate) fn clock(&self) -> Result<String, RunRefusal> {
        (self.now)().ok_or_else(uncertain)
    }
    fn envelope(&self, event_id: String) -> Result<Envelope, RunRefusal> {
        Ok(Envelope {
            event_id,
            sequence: self.sequence,
            session_id: format!("session-{}", self.record.job_id),
            job_id: self.record.job_id.clone(),
            timestamp: self.clock()?,
        })
    }
    fn append(&mut self, event: Value) -> Result<(), RunRefusal> {
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
    fn outcome(&mut self, result: &str) -> Result<(), RunRefusal> {
        let envelope = self.envelope(OUTCOME.into())?;
        self.append(events::step_outcome(
            &envelope,
            STEP,
            1,
            INTENT,
            result,
            "confirmed",
            None,
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
        if !RUNNABLE.contains(&state.as_str()) {
            return Err(proven(
                "resourceConflict",
                format!("job {id} is {state}, not runnable"),
                None,
            ));
        }
        if record.operation() != OPERATION {
            return Err(proven(
                "rejected",
                format!(
                    "job {id} runs {}, which the Rust Runtime does not execute yet",
                    record.operation()
                ),
                None,
            ));
        }
        if state != "preflight" {
            return Err(proven(
                "resourceConflict",
                format!(
                    "job {id} is {state}; the Rust Runtime resumes no Job before recovery is ported"
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
        if facts.has_torn_tail
            || facts.current_state.as_deref() != Some("preflight")
            || !facts.outstanding_intents.is_empty()
            || !facts.unknown_outcomes.is_empty()
            || facts.finalized
        {
            return Err(proven(
                "resourceConflict",
                format!(
                    "job {id}'s journal has left its admitted preflight boundary; the Rust Runtime \
                     resumes no Job before recovery is ported"
                ),
                None,
            ));
        }
        let mut run = Run {
            record,
            journal,
            sequence: facts.last_durable_sequence.map_or(0, |last| last + 1),
            now: self.now,
        };
        self.execute(&mut run)?;
        run.release(self.jobs, self.sessions, &directory)?;
        Ok(run.record.status())
    }

    /// Swift `runOwned` through `dispatchWithWAL` for the one analyzer step.
    fn execute(&self, run: &mut Run) -> Result<(), RunRefusal> {
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
        let leased = match self.artifacts.lease(&reference) {
            Ok(leased) => leased,
            Err(error) => {
                return self.fail(
                    run,
                    &format!("input Artifact lease became unreadable before {STEP}: {error}"),
                );
            }
        };
        if let Some(reason) = binding_refusal(&leased, &run.record) {
            return self.fail(run, &reason);
        }
        // Swift's typed action needs the profile and re-reads the leased
        // bytes; its refusal escapes the run as an internal failure.
        let Some(profile) = self.analyzer else {
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
        let source = Source {
            artifact_id: &leased.artifact_id,
            sha256: &sha256,
            byte_count,
        };
        let target = run.record.request["target"]["targetId"]
            .as_str()
            .unwrap_or_default()
            .to_owned();
        let step = json!({
            "id": STEP, "kind": STEP_KIND, "effect": "hostOnly", "bindingRequirement": "none",
            "cancellation": "immediate", "compensationDescriptors": [],
            "arguments": {"analyzerRef": ANALYZER_REF, "inputArtifactId": leased.artifact_id,
                "artifactId": DERIVED_NAME},
        });
        let intent = events::step_intent(
            &run.envelope(INTENT.into())?,
            &step,
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
        // The exact typed action is durable before its intent can be.
        run.record.set_recovery(
            Some(STEP),
            Some(INTENT),
            Some(json!({"kind": "analyzer.analyze", "arguments": {
                "analyzerRef": ANALYZER_REF, "analyzerVersion": ANALYZER_VERSION,
                "sourceArtifactId": leased.artifact_id, "sourceSha256": sha256,
                "sourceByteCount": byte_count}})),
        );
        run.persist(self.jobs)?;
        if run.append(intent).is_err() {
            run.record.set_recovery(None, None, None);
            let _ = run.persist(self.jobs);
            return Err(uncertain());
        }
        run.record.timeline.push(format!("intent {STEP}"));
        run.record.add_step_kind(STEP_KIND);
        // Only now may the child start.
        let opened = (self.precise_now)();
        let dispatched = match opened {
            Some(_) => self.dispatch(profile, &leased.path, &source),
            None => Err(Dispatch::Failed(
                "dispatch refused: the Runtime clock is unavailable".into(),
            )),
        };
        let window = opened.zip((self.precise_now)());
        let exited = match dispatched {
            Ok(exited) => exited,
            Err(Dispatch::OutcomeUnknown(reason)) => {
                // The intent stays outstanding: no outcome is invented, and
                // recovery alone may resolve it by readback.
                run.record.timeline.push(format!(
                    "outcomeUnknown {STEP}; durable intent left outstanding"
                ));
                return self.park(run, &reason);
            }
            Err(Dispatch::Failed(reason)) => {
                run.outcome("failed")?;
                run.record.timeline.push(format!("failed {STEP}"));
                run.record.set_recovery(None, None, None);
                return self.fail(run, &reason);
            }
        };
        let receipt = Receipt {
            exit_status: exited.status,
            stdout: &exited.stdout,
            truncated: exited.truncated,
        };
        let verified = match analyzer_output::verify(&receipt, &source, OUTPUT_BYTE_BUDGET) {
            Ok(verified) => verified,
            Err((code, detail)) => {
                run.outcome("failed")?;
                run.record.set_recovery(None, None, None);
                run.record
                    .timeline
                    .push(format!("failed {STEP}: {code}: {detail}"));
                return self.fail(run, &format!("{code}: {detail}"));
            }
        };
        run.outcome("succeeded")?;
        run.record
            .timeline
            .push(format!("verified {STEP} {}", verified.fact_names()));
        run.record.set_recovery(None, None, None);
        // The declared product is published after the correlated outcome.
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
            step_id: STEP,
            name: DERIVED_NAME,
            media_type: "application/json",
            privacy: "standard",
            retention_class: "default",
            source_operation: OPERATION,
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
        match publisher.publish(&product, &contents) {
            Ok(metadata) => run.record.timeline.push(format!(
                "artifact {DERIVED_NAME} -> {}",
                metadata["artifactID"].as_str().unwrap_or_default()
            )),
            Err(error) => {
                // A publication failure is recorded, never swallowed.
                let _ = publisher.record_missing(&product, &error);
                run.record
                    .timeline
                    .push(format!("artifact {DERIVED_NAME} missing: {error}"));
                let reason = format!(
                    "artifact publication failed: {DERIVED_NAME} could not be published: {error}"
                );
                run.record.set_operation_failure(Some(failure(
                    "artifactPublicationFailed",
                    "storage",
                    "notAutomatic",
                    "inspectJob",
                )));
                return self.close(run, &reason);
            }
        }
        run.transition("running", "finalizing", "steps-complete")?;
        run.record.set_operation_failure(None);
        run.transition("finalizing", "succeeded", "finalized")?;
        run.finish()?;
        run.persist(self.jobs)
    }

    /// Swift's `.failed(reason)` lane in `runOwned`.
    fn fail(&self, run: &mut Run, reason: &str) -> Result<(), RunRefusal> {
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
    fn close(&self, run: &mut Run, reason: &str) -> Result<(), RunRefusal> {
        run.persist(self.jobs)?;
        run.transition("running", "finalizing", reason)?;
        run.transition("finalizing", "failed", reason)?;
        run.finish()?;
        run.persist(self.jobs)
    }

    /// Swift's `.outcomeUnknown(reason)` lane: parked, never replayed.
    fn park(&self, run: &mut Run, reason: &str) -> Result<(), RunRefusal> {
        run.record.set_operation_failure(Some(failure(
            "outcomeUnknown",
            "unknownOutcome",
            "runtimeDecisionRequired",
            "awaitRuntimeReconciliation",
        )));
        run.transition(
            "running",
            "waitingForRecovery",
            &format!("outcomeUnknown: {reason}"),
        )?;
        run.record.set_outcome_unknown();
        run.finish()?;
        run.persist(self.jobs)
    }

    /// Swift `DescriptorBoundProcessDispatcher.dispatch` for one analyzer
    /// invocation: the source bound by descriptor first, then the pinned
    /// executable, then the child, which reads the source's inode alias.
    fn dispatch(
        &self,
        profile: &AnalyzerProfile,
        path: &Path,
        source: &Source<'_>,
    ) -> Result<Exited, Dispatch> {
        let verified = VerifiedSource::open(path, source.sha256, source.byte_count)
            .map_err(|_| Dispatch::Failed("analyzer input Artifact identity refused".into()))?;
        let tool = VerifiedTool::open(&profile.executable_path, &profile.executable_sha256)
            .map_err(|error| Dispatch::Failed(format!("dispatch refused: {error}")))?;
        let mut arguments: Vec<OsString> =
            profile.fixed_arguments.iter().map(OsString::from).collect();
        arguments.push(verified.inode_path().into());
        let limits = AnalyzerLimits {
            timeout: Duration::from_secs(profile.timeout_seconds.max(1) as u64),
            capture_bytes: OUTPUT_BYTE_BUDGET,
        };
        match tool.run_analyzer(&arguments, &verified, limits) {
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
                    truncated: execution.truncated,
                }),
                AnalyzerTermination::TimedOut => Err(Dispatch::OutcomeUnknown(
                    "process timed out before completion".into(),
                )),
                AnalyzerTermination::Signalled(signal) => {
                    Err(Dispatch::OutcomeUnknown(signal_death(signal)))
                }
            },
        }
    }
}

/// Swift `validateResolvedInputArtifact` for an analyzer: a host-only
/// request may read an Artifact collected from its own target; any other
/// binding must be the materialized one. The refusal is Swift's
/// interpolation of its `RuntimeJobEngineError`.
fn binding_refusal(leased: &LeasedArtifact, record: &JobRecord) -> Option<String> {
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
            "rejected(ArkDeckRuntime.RuntimeOperationErrorCode.invalidInput, {})",
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
