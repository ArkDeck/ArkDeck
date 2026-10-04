//! A user archive is a durable abandonment decision, never recovery authority.
//! This writer only closes proven, quiescent host/read-only Jobs. Unknown
//! outcomes, mutations, retained hazards and unproved process lifetimes stay
//! parked. It has no transport or capability-store reference.
use crate::job_journal_events::{self as events, Envelope};
use crate::job_journal_replay::{ReplayFacts, ReplayState};
use crate::job_journal_writer::JournalWriter;
use crate::{JobRecord, JobStore, SessionPublisher};
use arkdeck_contract::{WireError, sha256_hex};
use serde_json::{Map, Value, json};

fn refused(code: &str, message: impl Into<String>) -> WireError {
    WireError {
        code: code.into(),
        message: message.into(),
        details: None,
    }
}
fn internal(_: impl std::fmt::Debug) -> WireError {
    refused(
        "internalError",
        "the Runtime could not durably complete the archive decision",
    )
}
fn text<'a>(params: &'a Map<String, Value>, key: &str) -> Result<&'a str, WireError> {
    params
        .get(key)
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty() && s.len() <= 128 && !s.chars().any(char::is_control))
        .ok_or_else(|| {
            refused(
                "invalidParams",
                format!("{key} must be a bounded nonempty string"),
            )
        })
}

struct Snapshot {
    record: JobRecord,
    events: Vec<Value>,
    facts: ReplayFacts,
    hash: String,
    blockers: Vec<&'static str>,
    confirmation: Option<String>,
}

/// No child can remain from these synchronous, fully journaled steps once
/// their outcomes are confirmed. Do not widen this list for detached work,
/// build/signing processes, or a remote process starter without a new proof.
const CLOSED_STEPS: &[&str] = &[
    "probeTool",
    "probeHostTool",
    "probeDevice",
    "probeHDCServer",
    "assertIdentity",
    "preflightStorage",
    "preflightDeviceStorage",
    "verifyArtifact",
    "verifyLocalHash",
    "receiveFile",
    "postprocessArtifact",
    "runDeterministicAnalyzer",
    "inspectWorkspaceSource",
    "readWorkspaceSourceRange",
    "finalizeSession",
];
fn process_closed(step: &Value) -> bool {
    let kind = step["kind"].as_str().unwrap_or_default();
    CLOSED_STEPS.contains(&kind)
        || (kind == "captureRemoteStdout"
            && matches!(
                step["arguments"]["actionId"].as_str(),
                Some("windowInventory" | "boundedHilog")
            ))
        || (kind == "runApprovedRemoteRead"
            && matches!(
                step["arguments"]["actionId"].as_str(),
                Some("deviceModel" | "firmwareBuild")
            ))
}

/// Shared by the live decision and restart completion. A missing fact is a
/// blocker; absence of a writer lock alone is never process-lifetime proof.
fn proof_blockers(record: &JobRecord, facts: &ReplayFacts, events: &[Value]) -> Vec<&'static str> {
    let mut blockers = Vec::new();
    // These operations use the synchronous step runner. A future host-only
    // delegated worker is not quiescent merely because its journal is empty.
    if ![
        "observe.device@1",
        "capture.diagnostics@1",
        "analyzer.extract-crash-signature@1",
        "analyzer.summarize-hilog@1",
        "analyzer.summarize-trace@1",
        "analyzer.analyze-trace@1",
    ]
    .contains(&record.operation())
    {
        blockers.push("managedProcessOrCompensationProofUnavailable");
    }
    if !matches!(record.actual_effect(), Some("hostOnly" | "readOnly")) {
        blockers.push("mutationArchiveProofUnavailable");
    }
    if record.admission_evidence().is_some_and(|a| {
        a["kind"] == "runtimeCapability" || a.get("runtimeCapabilityCorrelation").is_some()
    }) {
        blockers.push("capabilityLineageMustRemainHeld");
    }
    if record.outcome_unknown()
        || !facts.outstanding_intents.is_empty()
        || !facts.unknown_outcomes.is_empty()
        || facts.last_reconcile_outcome_certainty.as_deref() == Some("outcomeUnknown")
        || facts.requires_unknown_finalized_outcome
    {
        blockers.push("outcomeNotConfirmed");
    }
    if record.residues().unwrap_or(0) != 0 || !facts.required_abandonment_hazards.is_empty() {
        blockers.push("unresolvedHazardsMustRemainHeld");
    }
    if facts.has_torn_tail {
        blockers.push("journalNeedsRecovery");
    }
    if events.iter().any(|event| {
        event["kind"] == "compensationIntent"
            || (event["kind"] == "stepIntent" && {
                let step = &event["payload"]["step"];
                !matches!(step["effect"].as_str(), Some("hostOnly" | "readOnly"))
                    || !process_closed(step)
                    || step["compensationDescriptors"]
                        .as_array()
                        .is_none_or(|items| !items.is_empty())
            })
    }) {
        blockers.push("managedProcessOrCompensationProofUnavailable");
    }
    blockers
}

fn archive_intent<'a>(events: &'a [Value], facts: &ReplayFacts) -> Option<&'a Value> {
    if let Some(pending) = &facts.pending_abandonment {
        return events
            .iter()
            .find(|event| event["eventId"] == pending.intent_event_id);
    }
    let outcome = events.iter().rev().find(|event| {
        event["kind"] == "abandonOutcome"
            && event["payload"]["result"] == "archivedInterrupted"
            && event["payload"]["releaseAuthorized"] == true
    })?;
    events.iter().find(|event| {
        event["kind"] == "abandonIntent"
            && event["eventId"] == outcome["payload"]["correlatesToAbandonIntentEventId"]
    })
}
fn valid_intent(intent: &Value) -> bool {
    intent["kind"] == "abandonIntent"
        && intent["payload"]["outcomeCertainty"] == "confirmed"
        && intent["payload"]["managedProcessState"] == "notRunning"
        && intent["payload"]["deviceHazards"]
            .as_array()
            .is_some_and(Vec::is_empty)
        && intent["payload"]["userConfirmationId"]
            .as_str()
            .is_some_and(|id| !id.is_empty())
}
fn envelope(id: &str, facts: &ReplayFacts, at: &str) -> Result<Envelope, WireError> {
    let random = arkdeck_platform::random_bytes::<16>().map_err(internal)?;
    Ok(Envelope {
        event_id: format!("archive-{:032x}", u128::from_ne_bytes(random)),
        sequence: facts.last_durable_sequence.map_or(0, |last| last + 1),
        session_id: format!("session-{id}"),
        job_id: id.into(),
        timestamp: at.into(),
    })
}

/// Completes only the existing user decision, with no provider calls. A
/// failed append leaves the durable prefix and its resource hold in place.
/// Restart invokes this before its normal reconcile/park projection.
pub(crate) fn complete_pending(
    record: &mut JobRecord,
    writer: &mut JournalWriter,
    events: &[Value],
    at: &str,
) -> Result<bool, WireError> {
    complete_pending_with(record, writer, events, at, &mut |writer, event| {
        writer.append(event).map_err(internal)
    })
}
fn complete_pending_with(
    record: &mut JobRecord,
    writer: &mut JournalWriter,
    events: &[Value],
    at: &str,
    append: &mut impl FnMut(&mut JournalWriter, &Value) -> Result<(), WireError>,
) -> Result<bool, WireError> {
    let mut facts = writer.facts();
    if facts.pending_abandonment.is_none() && !facts.resource_release_authorized {
        return Ok(false);
    }
    if !proof_blockers(record, &facts, events).is_empty()
        || archive_intent(events, &facts).is_none_or(|intent| !valid_intent(intent))
    {
        return Err(refused(
            "rejected",
            "the durable archive decision lacks quiescence proof",
        ));
    }
    for _ in 0..3 {
        let Some(pending) = facts.pending_abandonment.clone() else {
            break;
        };
        let env = envelope(&record.job_id, &facts, at)?;
        let event = match pending.phase.as_str() {
            "intentDurable" => events::state_transition(
                &env,
                "waitingForRecovery",
                "userAbandonRequested",
                "user requested archive of a confirmed quiescent Job",
                Some(&pending.intent_event_id),
            ),
            "requested" => events::abandon_outcome(&env, &pending.intent_event_id),
            "outcomeDurable" if pending.release_authorized == Some(true) => {
                events::state_transition(
                    &env,
                    "userAbandonRequested",
                    "interrupted",
                    "durable archive outcome authorizes resource release",
                    pending.outcome_event_id.as_deref(),
                )
            }
            _ => {
                return Err(refused(
                    "rejected",
                    "the durable archive outcome does not authorize release",
                ));
            }
        };
        append(writer, &event)?;
        facts = writer.facts();
    }
    if facts.current_state.as_deref() != Some("interrupted") || !facts.resource_release_authorized {
        return Err(refused(
            "rejected",
            "the archive decision is not durably terminal",
        ));
    }
    record.state = "interrupted".into();
    if record.finished_at().is_none() {
        record.finish(at);
    }
    if record.timeline.last().is_none_or(|entry| {
        entry != "archived: user decision; no recovery or device cleanup performed"
    }) {
        record
            .timeline
            .push("archived: user decision; no recovery or device cleanup performed".into());
    }
    Ok(true)
}

pub struct JobArchiver<'a> {
    pub jobs: &'a JobStore,
    pub now: fn() -> Option<String>,
    pub sessions: Option<&'a SessionPublisher<'a>>,
}
impl JobArchiver<'_> {
    fn snapshot(&self, id: &str) -> Result<Snapshot, WireError> {
        let record = self.jobs.read_snapshot(id)?;
        let bytes = self.jobs.record_bytes(id).map_err(internal)?;
        let journal = self.jobs.journal_bytes(id).map_err(internal)?;
        let replay = ReplayState::replay(&journal).map_err(internal)?;
        let facts = replay.state.facts(replay.torn);
        let events: Vec<Value> = journal[..replay.durable_length]
            .split(|b| *b == b'\n')
            .filter(|line| !line.is_empty())
            .map(serde_json::from_slice)
            .collect::<Result<_, _>>()
            .map_err(internal)?;
        let mut blockers = proof_blockers(&record, &facts, &events);
        if self.sessions.is_none() {
            blockers.push("sessionPublicationUnavailable");
        }
        if self.jobs.holds_resident(id) {
            blockers.push("jobHeldByActiveRuntime");
        }
        let durable = JobRecord::decode(&bytes)?;
        if durable.value()? != record.value()? {
            blockers.push("recordProjectionNotDurable");
        }
        let intent = archive_intent(&events, &facts);
        let continuing = intent.is_some_and(valid_intent)
            && (facts.pending_abandonment.is_some()
                || (facts.current_state.as_deref() == Some("interrupted")
                    && facts.resource_release_authorized));
        if !continuing
            && (record.state != "waitingForRecovery"
                || facts.current_state.as_deref() != Some("waitingForRecovery")
                || facts.finalized)
        {
            blockers.push("jobNotWaitingForRecovery");
        }
        if intent.is_some_and(|intent| !valid_intent(intent)) {
            blockers.push("archiveDecisionNotProven");
        }
        let confirmation = intent
            .and_then(|intent| intent["payload"]["userConfirmationId"].as_str())
            .map(str::to_owned);
        let hash = sha256_hex(
            &serde_json::to_vec(&json!({"version":1,
            "recordSha256":sha256_hex(&bytes), "journalSha256":sha256_hex(&journal),
            "blockers":blockers, "sessionPublisherAvailable":self.sessions.is_some()}))
            .map_err(internal)?,
        );
        Ok(Snapshot {
            record,
            events,
            facts,
            hash,
            blockers,
            confirmation,
        })
    }
    pub fn preview(&self, params: &Map<String, Value>) -> Result<Value, WireError> {
        if params.len() != 1 {
            return Err(refused(
                "invalidParams",
                "archive preview accepts only jobId",
            ));
        }
        let snapshot = self.snapshot(text(params, "jobId")?)?;
        let mode = if !snapshot.blockers.is_empty() {
            "unavailable"
        } else if snapshot.facts.pending_abandonment.is_some() {
            "finishAudit"
        } else if snapshot.facts.resource_release_authorized {
            "finishPublication"
        } else {
            "archive"
        };
        Ok(
            json!({"jobId":snapshot.record.job_id, "operation":snapshot.record.operation(),
            "state":snapshot.record.state, "targetId":snapshot.record.request["target"]["targetId"],
            "outcomeUnknown":snapshot.record.outcome_unknown(), "reviewSha256":snapshot.hash,
            "canArchive":snapshot.blockers.is_empty(), "mode":mode, "blockers":snapshot.blockers,
            "userConfirmationId":snapshot.confirmation, "sessionId":format!("session-{}",snapshot.record.job_id),
            "lastConfirmedStepId":snapshot.facts.last_confirmed_step_id}),
        )
    }
    pub fn archive(&self, params: &Map<String, Value>) -> Result<Value, WireError> {
        if params.len() != 3 {
            return Err(refused(
                "invalidParams",
                "archive requires jobId, expectedReviewSha256 and userConfirmationId",
            ));
        }
        let id = text(params, "jobId")?;
        let expected = text(params, "expectedReviewSha256")?;
        let confirmation = text(params, "userConfirmationId")?;
        if expected.len() != 64
            || !expected
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        {
            return Err(refused(
                "invalidParams",
                "expectedReviewSha256 must be a lowercase SHA-256",
            ));
        }
        // Refuse a torn or blocked snapshot before a writer could repair it.
        let before = self.snapshot(id)?;
        if !before.blockers.is_empty() || before.hash != expected {
            return Err(refused(
                "rejected",
                "archive review is stale or blocked; refresh the Runtime preview",
            ));
        }
        let directory = self.jobs.job_directory(id).map_err(internal)?;
        let mut writer = JournalWriter::open_without_repair(&directory).map_err(internal)?;
        let mut snapshot = self.snapshot(id)?;
        if !snapshot.blockers.is_empty() || snapshot.hash != expected {
            return Err(refused(
                "rejected",
                "archive review changed before the journal was held",
            ));
        }
        if snapshot
            .confirmation
            .as_deref()
            .is_some_and(|original| original != confirmation)
        {
            return Err(refused(
                "rejected",
                "an existing archive must retain its original user confirmation",
            ));
        }
        let at = (self.now)().ok_or_else(|| internal("clock unavailable"))?;
        if snapshot.confirmation.is_none() {
            let env = envelope(id, &snapshot.facts, &at)?;
            let intent = events::abandon_intent(
                &env,
                confirmation,
                snapshot.facts.last_confirmed_step_id.as_deref(),
            );
            writer.append(&intent).map_err(internal)?;
            snapshot.events.push(intent);
        }
        complete_pending(&mut snapshot.record, &mut writer, &snapshot.events, &at)?;
        self.jobs.persist(&snapshot.record, &at).map_err(internal)?;
        let publisher = self
            .sessions
            .ok_or_else(|| internal("publisher unavailable"))?;
        let marker = publisher.publish(&snapshot.record, &mut writer, &directory, &at);
        snapshot.record.set_session_publication(marker.clone());
        self.jobs.persist(&snapshot.record, &at).map_err(internal)?;
        Ok(
            json!({"jobId":id, "state":"interrupted", "outcomeUnknown":false,
            "sessionId":format!("session-{id}"), "sessionPublished":marker["phase"] == "catalogPublished",
            "publication":{"phase":marker["phase"], "failureCode":marker["failure"]["code"],
                "manifestSha256":marker["receipt"]["manifestSHA256"]}, "userConfirmationId":confirmation}),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{SessionStore, StorageClaims, StorageProbe, SystemStorageProbe};
    use std::{fs, path::PathBuf};
    const ID: &str = "job-082b8363fce0462b4571a62147751099";
    const AT: &str = "2026-10-04T06:00:00Z";
    fn now() -> Option<String> {
        Some(AT.into())
    }
    struct Fixture {
        path: PathBuf,
        jobs: JobStore,
        sessions: SessionStore,
        claims: StorageClaims,
        /// Dropped last, once the stores above have closed their files: on
        /// Windows nothing open can be removed.
        _removed: Removed,
    }
    struct Removed(PathBuf);
    impl Drop for Removed {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
    impl Fixture {
        fn new() -> Self {
            Self::with_step(false)
        }
        fn with_step(with_step: bool) -> Self {
            // Session settings use the same canonical local-drive spelling as
            // the production owner; std::canonicalize is verbatim on Windows.
            let base = crate::session_owner::canonical_path(&std::env::temp_dir())
                .unwrap()
                .join(format!(
                    "arkdeck-archive-{:032x}",
                    u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap())
                ));
            for path in [
                base.clone(),
                base.join("jobs-state"),
                base.join("session-owner"),
                base.join("Sessions"),
            ] {
                arkdeck_platform::HostDirectory::open_or_create_private(&path).unwrap();
            }
            let jobs = JobStore::open_owner(&base.join("jobs-state")).unwrap();
            let sessions =
                SessionStore::open(&base.join("session-owner"), &base.join("Sessions")).unwrap();
            let bytes = include_bytes!(
                "../../../tests/fixtures/job-reconcile-analyzer/before/jobs/job-082b8363fce0462b4571a62147751099/job-record.json"
            );
            let mut record = JobRecord::decode(bytes).unwrap();
            jobs.admit(&record, &"a".repeat(64)).unwrap();
            let directory = base.join("jobs-state/jobs").join(ID);
            arkdeck_platform::HostDirectory::open_or_create_private(&base.join("jobs-state/jobs"))
                .unwrap();
            arkdeck_platform::HostDirectory::open_or_create_private(&directory).unwrap();
            let mut writer = JournalWriter::open(&directory, true).unwrap();
            let env = |seq| Envelope {
                event_id: format!("event-{seq}"),
                sequence: seq,
                session_id: format!("session-{ID}"),
                job_id: ID.into(),
                timestamp: AT.into(),
            };
            writer
                .append(&events::job_created(
                    &env(0),
                    "execute",
                    "standardAgent",
                    "CORE-2.0.0",
                ))
                .unwrap();
            for (seq, from, to) in [(1, "queued", "preflight"), (2, "preflight", "running")] {
                writer
                    .append(&events::state_transition(
                        &env(seq),
                        from,
                        to,
                        "fixture safe boundary",
                        None,
                    ))
                    .unwrap();
            }
            if with_step {
                let step = json!({"id":"extract-crash-signature", "kind":"runDeterministicAnalyzer", "effect":"hostOnly",
                    "bindingRequirement":"none", "cancellation":"immediate", "compensationDescriptors":[],
                    "arguments":{"analyzerRef":"crash-signature@1", "inputArtifactId":"ART-990a17a6b9ca251b17028e7c824f7b8b", "artifactId":"crash-signature.json"}});
                let target = events::Target {
                    scope: "host".into(),
                    target_id: "TGT-ORACLE".into(),
                    connect_key: None,
                    identity_snapshot_hash: None,
                };
                writer
                    .append(&events::step_intent(&env(3), &step, &target, 1, None).unwrap())
                    .unwrap();
                writer
                    .append(&events::step_outcome(
                        &env(4),
                        "extract-crash-signature",
                        1,
                        "event-3",
                        "succeeded",
                        "confirmed",
                        None,
                        None,
                    ))
                    .unwrap();
            }
            writer
                .append(&events::state_transition(
                    &env(if with_step { 5 } else { 3 }),
                    "running",
                    "waitingForRecovery",
                    "fixture safe boundary",
                    None,
                ))
                .unwrap();
            record.state = "waitingForRecovery".into();
            jobs.persist(&record, AT).unwrap();
            Self {
                _removed: Removed(base.clone()),
                path: base,
                jobs,
                sessions,
                claims: StorageClaims::default(),
            }
        }
        fn publisher(&self) -> SessionPublisher<'_> {
            SessionPublisher {
                sessions: &self.sessions,
                claims: &self.claims,
                probe: &SystemStorageProbe,
            }
        }
        fn assert_published(&self, result: &Value) {
            let record = self.jobs.read_snapshot(ID).unwrap();
            assert_eq!(
                result["sessionPublished"],
                true,
                "result={result}; durable marker={:?}",
                record.session_publication()
            );
        }
        fn journal(&self) -> Vec<Value> {
            self.jobs
                .journal_bytes(ID)
                .unwrap()
                .split(|b| *b == b'\n')
                .filter(|line| !line.is_empty())
                .map(|line| serde_json::from_slice(line).unwrap())
                .collect()
        }
        fn edit(&self, change: impl FnOnce(&mut Value)) {
            let mut value = self.jobs.read_snapshot(ID).unwrap().value().unwrap();
            change(&mut value);
            let record = JobRecord::decode(&serde_json::to_vec(&value).unwrap()).unwrap();
            self.jobs.persist(&record, AT).unwrap();
        }
    }
    fn params() -> Map<String, Value> {
        json!({"jobId":ID}).as_object().unwrap().clone()
    }
    fn decision(preview: &Value) -> Map<String, Value> {
        json!({"jobId":ID,"expectedReviewSha256":preview["reviewSha256"],"userConfirmationId":"user-archive-fixture"})
            .as_object().unwrap().clone()
    }
    fn append_frame(method: &str, frame: Value) {
        if let Some(path) = std::env::var_os("ARKDECK_ARCHIVE_CONTRACT_RECORD") {
            use std::io::Write;
            static RECORDING: std::sync::Mutex<()> = std::sync::Mutex::new(());
            let _guard = RECORDING.lock().unwrap();
            fs::create_dir_all(&path).unwrap();
            let mut out = fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(PathBuf::from(path).join(format!("{method}.jsonl")))
                .unwrap();
            let mut line = serde_json::to_vec(&frame).unwrap();
            line.push(b'\n');
            out.write_all(&line).unwrap();
        }
    }
    fn record_frame(method: &str, params: &Map<String, Value>, result: &Value) {
        append_frame(
            method,
            json!({"method":method,"protocolVersion":"1.0.0","params":params,"ok":true,"result":result}),
        );
    }
    fn record_error(method: &str, params: &Map<String, Value>, error: &WireError) {
        append_frame(
            method,
            json!({"method":method,"protocolVersion":"1.0.0","params":params,"ok":false,
            "error":{"code":error.code,"message":error.message}}),
        );
    }
    #[test]
    fn system_storage_snapshot_works_for_private_archive_root() {
        let f = Fixture::new();
        let root = arkdeck_platform::HostDirectory::open(&f.path.join("Sessions")).unwrap();
        let snapshot = SystemStorageProbe
            .snapshot(&root)
            .expect("archive Session root capacity");
        assert_eq!(
            snapshot.volume_identity,
            root.export_facts().unwrap().volume_identity
        );
        assert!(!snapshot.read_only);
    }
    #[test]
    fn storage_failure_keeps_the_durable_decision_and_can_finish_its_publication() {
        struct MissingStorage;
        impl crate::StorageProbe for MissingStorage {
            fn snapshot(
                &self,
                _: &arkdeck_platform::HostDirectory,
            ) -> std::io::Result<crate::StorageSnapshot> {
                Err(std::io::Error::other(
                    "synthetic unavailable Session volume",
                ))
            }
        }
        let f = Fixture::new();
        let unavailable = SessionPublisher {
            sessions: &f.sessions,
            claims: &f.claims,
            probe: &MissingStorage,
        };
        let archive = JobArchiver {
            jobs: &f.jobs,
            now,
            sessions: Some(&unavailable),
        };
        let request = decision(&archive.preview(&params()).unwrap());
        let result = archive.archive(&request).unwrap();
        assert_eq!(result["state"], "interrupted");
        assert_eq!(result["sessionPublished"], false);
        assert_eq!(result["publication"]["failureCode"], "storageUnavailable");
        assert!(result["publication"]["manifestSha256"].is_null());
        record_frame("job.archive", &request, &result);
        let publisher = f.publisher();
        let archive = JobArchiver {
            jobs: &f.jobs,
            now,
            sessions: Some(&publisher),
        };
        let preview = archive.preview(&params()).unwrap();
        assert_eq!(preview["mode"], "finishPublication");
        f.assert_published(&archive.archive(&decision(&preview)).unwrap());
        assert_eq!(
            f.journal()
                .iter()
                .filter(|event| event["kind"] == "abandonIntent")
                .count(),
            1
        );
    }
    #[test]
    fn resident_jobs_and_capability_lineage_are_not_archive_authority() {
        let f = Fixture::new();
        let publisher = f.publisher();
        let archive = JobArchiver {
            jobs: &f.jobs,
            now,
            sessions: Some(&publisher),
        };
        let mut record = f.jobs.read_snapshot(ID).unwrap();
        let facts = archive.snapshot(ID).unwrap().facts;
        record.set_admission_evidence(json!({"kind":"runtimeCapability"}));
        assert!(
            proof_blockers(&record, &facts, &f.journal())
                .contains(&"capabilityLineageMustRemainHeld")
        );
        f.jobs.hold_resident(f.jobs.read_snapshot(ID).unwrap());
        let preview = archive.preview(&params()).unwrap();
        assert_eq!(preview["canArchive"], false);
        assert!(
            preview["blockers"]
                .as_array()
                .unwrap()
                .contains(&json!("jobHeldByActiveRuntime"))
        );
        let request = decision(&preview);
        let error = archive.archive(&request).unwrap_err();
        record_error("job.archive", &request, &error);
        let missing = json!({"jobId":"job-no-such-archive"})
            .as_object()
            .unwrap()
            .clone();
        record_error(
            "job.archive.preview",
            &missing,
            &archive.preview(&missing).unwrap_err(),
        );
    }
    #[test]
    fn archive_publishes_the_original_user_decision_and_never_claims_recovery() {
        let f = Fixture::with_step(true);
        let publisher = f.publisher();
        let archive = JobArchiver {
            jobs: &f.jobs,
            now,
            sessions: Some(&publisher),
        };
        let preview = archive.preview(&params()).unwrap();
        assert_eq!(preview["canArchive"], true);
        record_frame("job.archive.preview", &params(), &preview);
        let request = decision(&preview);
        let result = archive.archive(&request).unwrap();
        assert_eq!(result["state"], "interrupted");
        f.assert_published(&result);
        record_frame("job.archive", &request, &result);
        let manifest: Value = serde_json::from_slice(
            &fs::read(
                f.path
                    .join("Sessions/2026/09")
                    .join(format!("session-{ID}/manifest.json")),
            )
            .unwrap(),
        )
        .unwrap();
        assert_eq!(manifest["sessionDisposition"], "archived");
        assert_eq!(
            manifest["recovery"]["userConfirmation"]["confirmationId"],
            "user-archive-fixture"
        );
        assert_eq!(
            manifest["recovery"]["recoveryGuide"]["automaticRecoveryAvailable"],
            false
        );
        assert_eq!(
            manifest["recovery"]["managedHostProcessState"],
            "notRunning"
        );
        assert!(f.jobs.current_jobs().unwrap().is_empty());
        let again = archive.preview(&params()).unwrap();
        assert_eq!(again["mode"], "finishPublication");
        record_frame("job.archive.preview", &params(), &again);
        assert_eq!(
            archive.archive(&decision(&again)).unwrap()["sessionPublished"],
            true
        );
        assert_eq!(
            f.journal()
                .iter()
                .filter(|e| e["kind"] == "abandonIntent")
                .count(),
            1
        );
    }
    #[test]
    fn changed_review_and_unknown_or_mutating_jobs_write_no_abandonment() {
        let f = Fixture::new();
        let publisher = f.publisher();
        let archive = JobArchiver {
            jobs: &f.jobs,
            now,
            sessions: Some(&publisher),
        };
        let before = archive.preview(&params()).unwrap();
        record_frame("job.archive.preview", &params(), &before);
        f.edit(|v| {
            v["timeline"]
                .as_array_mut()
                .unwrap()
                .push(json!("new observation"))
        });
        assert_eq!(
            archive.archive(&decision(&before)).unwrap_err().code,
            "rejected"
        );
        for (key, value, blocker) in [
            ("outcomeUnknown", json!(true), "outcomeNotConfirmed"),
            (
                "actualEffect",
                json!("deviceMutation"),
                "mutationArchiveProofUnavailable",
            ),
            (
                "outstandingResidueCount",
                json!(1),
                "unresolvedHazardsMustRemainHeld",
            ),
        ] {
            let f = Fixture::new();
            let publisher = f.publisher();
            f.edit(|v| v[key] = value);
            let archive = JobArchiver {
                jobs: &f.jobs,
                now,
                sessions: Some(&publisher),
            };
            let preview = archive.preview(&params()).unwrap();
            assert_eq!(preview["canArchive"], false, "{preview}");
            assert!(
                preview["blockers"]
                    .as_array()
                    .unwrap()
                    .contains(&json!(blocker)),
                "{preview}"
            );
            record_frame("job.archive.preview", &params(), &preview);
            let before = f.jobs.journal_bytes(ID).unwrap();
            assert!(archive.archive(&decision(&preview)).is_err());
            assert_eq!(f.jobs.journal_bytes(ID).unwrap(), before);
            assert_eq!(f.jobs.current_jobs().unwrap().len(), 1);
        }
        assert!(!f.journal().iter().any(|e| e["kind"] == "abandonIntent"));
    }
    #[test]
    fn every_durable_archive_cut_completes_on_restart_without_a_second_decision() {
        for cut in 0..4 {
            let f = Fixture::new();
            let directory = f.jobs.job_directory(ID).unwrap();
            let mut writer = JournalWriter::open(&directory, false).unwrap();
            let intent = events::abandon_intent(
                &envelope(ID, &writer.facts(), AT).unwrap(),
                "user-archive-fixture",
                None,
            );
            writer.append(&intent).unwrap();
            let mut record = f.jobs.read_snapshot(ID).unwrap();
            let events = f.journal();
            let mut count = 0;
            let result = complete_pending_with(
                &mut record,
                &mut writer,
                &events,
                AT,
                &mut |writer, event| {
                    if count == cut {
                        return Err(internal("simulated crash before next append"));
                    }
                    count += 1;
                    writer.append(event).map_err(internal)
                },
            );
            assert_eq!(result.is_ok(), cut == 3);
            if cut < 2 {
                assert!(!writer.facts().resource_release_authorized);
            }
            drop(writer);
            crate::recover_active_jobs(&f.jobs, None, now).unwrap();
            let recovered = f.jobs.read_snapshot(ID).unwrap();
            assert_eq!(recovered.state, "interrupted");
            assert!(!recovered.outcome_unknown());
            let events = f.journal();
            assert_eq!(
                events
                    .iter()
                    .filter(|e| e["kind"] == "abandonIntent")
                    .count(),
                1
            );
            assert_eq!(
                events
                    .iter()
                    .filter(|e| e["kind"] == "abandonOutcome")
                    .count(),
                1
            );
            assert!(!events.iter().any(|e| matches!(
                e["kind"].as_str(),
                Some("stepIntent" | "compensationIntent")
            )));
            let publisher = f.publisher();
            let archive = JobArchiver {
                jobs: &f.jobs,
                now,
                sessions: Some(&publisher),
            };
            let preview = archive.preview(&params()).unwrap();
            assert_eq!(preview["userConfirmationId"], "user-archive-fixture");
            f.assert_published(&archive.archive(&decision(&preview)).unwrap());
        }
    }
    #[test]
    fn a_torn_journal_preview_and_stale_apply_do_not_repair_it() {
        use std::io::Write;
        let f = Fixture::new();
        let publisher = f.publisher();
        let archive = JobArchiver {
            jobs: &f.jobs,
            now,
            sessions: Some(&publisher),
        };
        let preview = archive.preview(&params()).unwrap();
        let path = f.jobs.job_directory(ID).unwrap().join("journal.jsonl");
        fs::OpenOptions::new()
            .append(true)
            .open(&path)
            .unwrap()
            .write_all(b"{torn")
            .unwrap();
        let before = fs::read(&path).unwrap();
        let blocked = archive.preview(&params()).unwrap();
        assert_eq!(blocked["canArchive"], false);
        assert!(archive.archive(&decision(&preview)).is_err());
        assert_eq!(fs::read(&path).unwrap(), before);
    }
}
