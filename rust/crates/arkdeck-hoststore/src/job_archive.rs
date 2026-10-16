//! A user archive is a durable abandonment decision, never recovery authority.
//! Quiescent host/read-only Jobs can release their resources. An expired,
//! unknown Flash can only archive with every risk and resource hold retained.
//! This writer has no transport or capability-store reference.
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

fn retains_risk(record: &JobRecord, facts: &ReplayFacts) -> bool {
    record.dayu200_flash()
        && record.actual_effect() == Some("destructive")
        && record.outcome_unknown()
        && !facts.required_abandonment_hazards.is_empty()
}

fn retained_hazards(record: &JobRecord, facts: &ReplayFacts) -> Vec<String> {
    if !retains_risk(record, facts) {
        return Vec::new();
    }
    let mut hazards = facts.required_abandonment_hazards.clone();
    hazards.extend([
        "runtimeCapabilityLineageRetained".into(),
        "managedHostProcessStateUnknown".into(),
    ]);
    if record.residues().unwrap_or(0) > 0 {
        hazards.push("cleanupResiduesRetained".into());
    }
    hazards.sort();
    hazards.dedup();
    hazards
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
fn proof_blockers(
    record: &JobRecord,
    facts: &ReplayFacts,
    events: &[Value],
    at: &str,
) -> Vec<&'static str> {
    let mut blockers = Vec::new();
    if facts.has_torn_tail {
        blockers.push("journalNeedsRecovery");
    }
    if retains_risk(record, facts) {
        if !crate::job_owner::flash_recovery::expired_for_retained_archive(record, at) {
            blockers.push("retainedArchiveRequiresExpiredRecoveryBudget");
        }
        if !crate::session_publication::retained_archive_lineage_valid(record, events) {
            blockers.push("retainedArchiveLineageUnavailable");
        }
        // This addition covers the fixed Flash workflow. A compensation
        // lifetime needs its own archive projection, not an omitted descriptor.
        if events.iter().any(|event| {
            event["kind"] == "compensationIntent"
                || (event["kind"] == "stepIntent"
                    && event["payload"]["step"]["compensationDescriptors"]
                        .as_array()
                        .is_none_or(|items| !items.is_empty()))
        }) {
            blockers.push("compensationArchiveProofUnavailable");
        }
        return blockers;
    }
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
            && ((event["payload"]["result"] == "archivedInterrupted"
                && event["payload"]["releaseAuthorized"] == true)
                || (event["payload"]["result"] == "archivedWithHazards"
                    && event["payload"]["releaseAuthorized"] == false))
    })?;
    events.iter().find(|event| {
        event["kind"] == "abandonIntent"
            && event["eventId"] == outcome["payload"]["correlatesToAbandonIntentEventId"]
    })
}
fn valid_intent(intent: &Value, record: &JobRecord, facts: &ReplayFacts) -> bool {
    intent["kind"] == "abandonIntent"
        && if retains_risk(record, facts) {
            intent["payload"]["outcomeCertainty"] == "outcomeUnknown"
                && intent["payload"]["managedProcessState"] == "unknown"
                && intent["payload"]["deviceHazards"] == json!(retained_hazards(record, facts))
        } else {
            intent["payload"]["outcomeCertainty"] == "confirmed"
                && intent["payload"]["managedProcessState"] == "notRunning"
                && intent["payload"]["deviceHazards"]
                    .as_array()
                    .is_some_and(Vec::is_empty)
        }
        && intent["payload"]["userConfirmationId"]
            .as_str()
            .is_some_and(|id| !id.is_empty())
}

/// This historical decision preserves capability lineage. Startup may finish
/// its journal projection without recording a new capability use or outcome.
pub(crate) fn retains_capability_lineage(
    record: &JobRecord,
    facts: &ReplayFacts,
    events: &[Value],
    at: &str,
) -> bool {
    retains_risk(record, facts)
        && (facts.pending_abandonment.is_some() || facts.retained_risk_archive)
        && proof_blockers(record, facts, events, at).is_empty()
        && archive_intent(events, facts).is_some_and(|intent| valid_intent(intent, record, facts))
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
    if facts.pending_abandonment.is_none()
        && !facts.resource_release_authorized
        && !facts.retained_risk_archive
    {
        return Ok(false);
    }
    if !proof_blockers(record, &facts, events, at).is_empty()
        || archive_intent(events, &facts).is_none_or(|intent| !valid_intent(intent, record, &facts))
    {
        return Err(refused(
            "rejected",
            "the durable archive decision lacks its required safety proof",
        ));
    }
    let retained = retains_risk(record, &facts);
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
                if retained {
                    "user requested terminal archive with all risks and holds retained"
                } else {
                    "user requested archive of a confirmed quiescent Job"
                },
                Some(&pending.intent_event_id),
            ),
            "requested" if retained => events::retained_archive_outcome(
                &env,
                &pending.intent_event_id,
                &pending.device_hazards,
            ),
            "requested" => events::abandon_outcome(&env, &pending.intent_event_id),
            "outcomeDurable"
                if pending.release_authorized == Some(true)
                    || (retained
                        && facts.retained_risk_archive
                        && pending.release_authorized == Some(false)) =>
            {
                events::state_transition(
                    &env,
                    "userAbandonRequested",
                    "interrupted",
                    if retained {
                        "durable archive closes the task; all device risks and resource holds remain"
                    } else {
                        "durable archive outcome authorizes resource release"
                    },
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
    if facts.current_state.as_deref() != Some("interrupted")
        || !(facts.resource_release_authorized || (retained && facts.retained_risk_archive))
    {
        return Err(refused(
            "rejected",
            "the archive decision is not durably terminal",
        ));
    }
    record.state = "interrupted".into();
    // The original finished/created timestamp anchors the shared recovery
    // budget. Archival must not move that clock, even if it was absent.
    if !retained && record.finished_at().is_none() {
        record.finish(at);
    }
    let message = if retained {
        "archived with risks retained: original unknown, budget, capability lineage and all resource holds unchanged"
    } else {
        "archived: user decision; no recovery or device cleanup performed"
    };
    if record.timeline.last().is_none_or(|entry| entry != message) {
        record.timeline.push(message.into());
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
        let at = (self.now)().ok_or_else(|| internal("clock unavailable"))?;
        let mut blockers = proof_blockers(&record, &facts, &events, &at);
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
        let continuing = intent.is_some_and(|intent| valid_intent(intent, &record, &facts))
            && (facts.pending_abandonment.is_some()
                || (facts.current_state.as_deref() == Some("interrupted")
                    && (facts.resource_release_authorized || facts.retained_risk_archive)));
        if !continuing
            && (record.state != "waitingForRecovery"
                || facts.current_state.as_deref() != Some("waitingForRecovery")
                || facts.finalized)
        {
            blockers.push("jobNotWaitingForRecovery");
        }
        if intent.is_some_and(|intent| !valid_intent(intent, &record, &facts)) {
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
        } else if snapshot.facts.resource_release_authorized || snapshot.facts.retained_risk_archive
        {
            "finishPublication"
        } else if retains_risk(&snapshot.record, &snapshot.facts) {
            "archiveWithHazards"
        } else {
            "archive"
        };
        Ok(
            json!({"jobId":snapshot.record.job_id, "operation":snapshot.record.operation(),
            "state":snapshot.record.state, "targetId":snapshot.record.request["target"]["targetId"],
            "outcomeUnknown":snapshot.record.outcome_unknown(), "reviewSha256":snapshot.hash,
            "canArchive":snapshot.blockers.is_empty(), "mode":mode, "blockers":snapshot.blockers,
            "retainedHazards":retained_hazards(&snapshot.record, &snapshot.facts),
            "resourceReleaseAuthorized":snapshot.facts.resource_release_authorized,
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
            let intent = if retains_risk(&snapshot.record, &snapshot.facts) {
                events::retained_archive_intent(
                    &env,
                    confirmation,
                    snapshot.facts.last_confirmed_step_id.as_deref(),
                    &retained_hazards(&snapshot.record, &snapshot.facts),
                )
            } else {
                events::abandon_intent(
                    &env,
                    confirmation,
                    snapshot.facts.last_confirmed_step_id.as_deref(),
                )
            };
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
            json!({"jobId":id, "state":"interrupted", "outcomeUnknown":snapshot.record.outcome_unknown(),
            "retainedHazards":retained_hazards(&snapshot.record, &writer.facts()),
            "resourceReleaseAuthorized":writer.facts().resource_release_authorized,
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
        fn empty() -> Self {
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
            Self {
                _removed: Removed(base.clone()),
                path: base,
                jobs,
                sessions,
                claims: StorageClaims::default(),
            }
        }
        fn with_step(with_step: bool) -> Self {
            let fixture = Self::empty();
            let jobs = &fixture.jobs;
            let base = &fixture.path;
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
            fixture
        }
        fn unknown_flash(outstanding: bool) -> Self {
            let fixture = Self::empty();
            let source = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                .join("../../tests/fixtures/flash-run/stories/failures/files/store/jobs/job-7e4b6c8997b64ac9d4ab648851f2f3a5");
            let original = "job-7e4b6c8997b64ac9d4ab648851f2f3a5";
            let bytes = fs::read_to_string(source.join("job-record.json"))
                .unwrap()
                .replace(original, ID);
            let record = JobRecord::decode(bytes.as_bytes()).unwrap();
            fixture.jobs.admit(&record, &"a".repeat(64)).unwrap();
            let directory = fixture.jobs.job_directory(ID).unwrap();
            crate::test_private::create_private_directories(&directory);
            let journal = fs::read_to_string(source.join("journal.jsonl"))
                .unwrap()
                .replace(original, ID);
            let mut writer = JournalWriter::open(&directory, true).unwrap();
            for line in journal.lines() {
                let mut event: Value = serde_json::from_str(line).unwrap();
                if outstanding
                    && event["kind"] == "stepOutcome"
                    && event["payload"]["outcomeCertainty"] == "outcomeUnknown"
                {
                    continue;
                }
                if !outstanding
                    && event["kind"] == "stateTransition"
                    && event["payload"]["to"] == "waitingForRecovery"
                {
                    let facts = writer.facts();
                    let intent = &facts.outstanding_intents[0];
                    let at = event["timestamp"].as_str().unwrap();
                    writer
                        .append(&events::step_outcome(
                            &envelope(ID, &facts, at).unwrap(),
                            &intent.step_id,
                            intent.attempt,
                            &intent.event_id,
                            "failed",
                            "outcomeUnknown",
                            None,
                            None,
                        ))
                        .unwrap();
                }
                event["sequence"] =
                    json!(writer.facts().last_durable_sequence.map_or(0, |n| n + 1));
                writer.append(&event).unwrap();
            }
            fixture.jobs.persist(&record, AT).unwrap();
            fixture
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
            proof_blockers(&record, &facts, &f.journal(), AT)
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

    #[test]
    fn expired_unknown_archive_preserves_every_obligation_and_never_unlocks_flash() {
        for outstanding in [false, true] {
            let f = Fixture::unknown_flash(outstanding);
            let before = f.jobs.read_snapshot(ID).unwrap();
            let capability_root = f.path.join("capabilities");
            crate::test_private::create_private_directory(&capability_root);
            let capabilities =
                crate::capability_store::CapabilityStore::open(&capability_root).unwrap();
            let admission = |campaign| {
                f.jobs.complete_overwrite_admission(
                    &capabilities,
                    "flash.full-restore@1",
                    &before.request["inputs"],
                    before.materialized_identity().unwrap(),
                    before.materialized_binding().unwrap(),
                    AT,
                    campaign,
                )
            };
            for campaign in [None, Some("new-after-archive")] {
                assert!(matches!(admission(campaign),
                    Err(crate::job_owner::flash_recovery::OverwriteRefusal::Blocked(reason))
                    if reason == "completeOverwriteRecovery.sharedFourHourBudgetExpired"));
            }
            let journal = f.jobs.journal_bytes(ID).unwrap();
            let publisher = f.publisher();
            let archive = JobArchiver {
                jobs: &f.jobs,
                now,
                sessions: Some(&publisher),
            };
            let preview = archive.preview(&params()).unwrap();
            assert_eq!(preview["canArchive"], true, "{preview}");
            assert_eq!(preview["mode"], "archiveWithHazards");
            assert_eq!(preview["resourceReleaseAuthorized"], false);
            assert!(preview["retainedHazards"].as_array().unwrap().len() >= 3);
            record_frame("job.archive.preview", &params(), &preview);
            let request = decision(&preview);
            let result = archive.archive(&request).unwrap();
            f.assert_published(&result);
            assert_eq!(result["outcomeUnknown"], true);
            assert_eq!(result["resourceReleaseAuthorized"], false);
            record_frame("job.archive", &request, &result);
            let after = f.jobs.read_snapshot(ID).unwrap();
            let mut original = before.value().unwrap();
            let mut changed = after.value().unwrap();
            for key in ["state", "timeline", "sessionPublicationRecord"] {
                original.as_object_mut().unwrap().remove(key);
                changed.as_object_mut().unwrap().remove(key);
            }
            assert_eq!(
                original, changed,
                "archive cannot change old lineage, outcome or budget"
            );
            let sealed = f.jobs.journal_bytes(ID).unwrap();
            assert!(sealed.starts_with(&journal));
            let replay = ReplayState::replay(&sealed).unwrap().state.facts(false);
            assert!(replay.retained_risk_archive && replay.requires_unknown_finalized_outcome);
            assert!(!replay.resource_release_authorized);
            assert_eq!(replay.outstanding_intents.len(), usize::from(outstanding));
            assert_eq!(replay.unknown_outcomes.len(), usize::from(!outstanding));
            let manifest: Value = serde_json::from_slice(
                &fs::read(
                    f.path
                        .join("Sessions/2026/09")
                        .join(format!("session-{ID}/manifest.json")),
                )
                .unwrap(),
            )
            .unwrap();
            assert_eq!(manifest["outcomeCertainty"], "outcomeUnknown");
            if let Some(path) = std::env::var_os("ARKDECK_ARCHIVE_CONTRACT_RECORD") {
                fs::write(
                    PathBuf::from(path).join(format!("retained-{outstanding}.manifest.json")),
                    serde_json::to_vec_pretty(&manifest).unwrap(),
                )
                .unwrap();
            }
            assert_eq!(
                after.session_publication().unwrap()["proposal"]["outcomeCertainty"],
                "outcomeUnknown"
            );
            assert_eq!(manifest["originalTarget"]["kind"], "unresolved");
            assert_eq!(manifest["toolchain"]["kind"], "unavailable");
            assert_eq!(manifest["steps"][0]["disposition"], "outcomeUnknown");
            for (field, value) in [
                ("/status", json!("succeeded")),
                ("/outcomeCertainty", json!("confirmed")),
                ("/sessionDisposition", json!("finalized")),
                (
                    "/originalTarget/connectKey",
                    json!("invented-current-route"),
                ),
                ("/originalTarget/transport", json!("usb")),
                ("/runtimeAuthority", Value::Null),
                ("/workflow/kind", json!("observe.device@1")),
                ("/toolchain/profileIdentifier", json!("other-profile")),
                ("/recovery/deviceHazards", json!([])),
                ("/recovery/managedHostProcessState", json!("notRunning")),
                (
                    "/recovery/recoveryGuide/automaticRecoveryAvailable",
                    json!(true),
                ),
            ] {
                let mut forged = manifest.clone();
                *forged.pointer_mut(field).unwrap() = value;
                assert!(
                    crate::session_manifest::decode_manifest(&serde_json::to_vec(&forged).unwrap())
                        .is_err(),
                    "archive cannot claim fresh or settled authority: {field}"
                );
            }
            assert_eq!(
                manifest["recovery"]["managedHostProcessState"],
                "stillRunningUnknown"
            );
            assert_eq!(
                manifest["recovery"]["deviceHazards"]
                    .as_array()
                    .unwrap()
                    .len(),
                preview["retainedHazards"].as_array().unwrap().len()
            );
            assert_eq!(
                f.journal().last().unwrap()["payload"]["outcomeCertainty"],
                "outcomeUnknown"
            );
            assert!(
                f.jobs
                    .current_jobs()
                    .unwrap()
                    .iter()
                    .any(|job| job.job_id == ID
                        && job.outcome_unknown
                        && job.state == "interrupted")
            );
            assert_eq!(
                f.jobs.unsettled_flash_jobs_for_loader_adoption().unwrap(),
                [ID]
            );
            assert_eq!(
                f.jobs
                    .unsettled_flash_jobs_for_binding(
                        before.request["target"]["targetId"].as_str().unwrap()
                    )
                    .unwrap(),
                [ID]
            );
            assert!(crate::job_owner::flash_recovery::expired_for_retained_archive(&after, AT));
            for campaign in [None, Some("new-after-archive")] {
                assert!(
                    matches!(admission(campaign), Err(crate::job_owner::flash_recovery::OverwriteRefusal::Blocked(reason))
                    if reason == "completeOverwriteRecovery.explicitCancellationPending")
                );
            }
            assert!(capabilities.lineage().unwrap().is_empty());
            assert!(f.jobs.recovery_epochs().unwrap().is_empty());
            let again = archive.preview(&params()).unwrap();
            assert_eq!(again["mode"], "finishPublication");
            let mut different = decision(&again);
            different.insert("userConfirmationId".into(), json!("another-decision"));
            assert!(archive.archive(&different).is_err());
            f.assert_published(&archive.archive(&decision(&again)).unwrap());
            assert_eq!(f.jobs.journal_bytes(ID).unwrap(), sealed);
        }
    }

    #[test]
    fn retained_archive_rechecks_holds_review_and_original_lineage_before_writing() {
        for case in ["resident", "writer", "changedReview", "torn", "lineage"] {
            let f = Fixture::unknown_flash(true);
            let publisher = f.publisher();
            let archive = JobArchiver {
                jobs: &f.jobs,
                now,
                sessions: Some(&publisher),
            };
            let preview = archive.preview(&params()).unwrap();
            let directory = f.jobs.job_directory(ID).unwrap();
            let mut held = None;
            match case {
                "resident" => f.jobs.hold_resident(f.jobs.read_snapshot(ID).unwrap()),
                "writer" => {
                    let (ready, opened) = std::sync::mpsc::channel();
                    let (release, waiting) = std::sync::mpsc::channel();
                    let thread = std::thread::spawn(move || {
                        let _lock = arkdeck_platform::HostJournal::open(&directory).unwrap();
                        ready.send(()).unwrap();
                        let _ = waiting.recv();
                    });
                    opened
                        .recv_timeout(std::time::Duration::from_secs(5))
                        .unwrap();
                    held = Some((release, thread));
                }
                "changedReview" => f.edit(|value| {
                    value["timeline"]
                        .as_array_mut()
                        .unwrap()
                        .push(json!("new durable risk observation"));
                }),
                "lineage" => {
                    let mut value: Value =
                        serde_json::from_slice(&f.jobs.record_bytes(ID).unwrap()).unwrap();
                    value["materializedStableTargetIdentitySHA256"] = json!("f".repeat(64));
                    crate::test_private::plant_owner_only(
                        &directory.join("job-record.json"),
                        &serde_json::to_vec(&value).unwrap(),
                    );
                }
                "torn" => {
                    use std::io::Write;
                    fs::OpenOptions::new()
                        .append(true)
                        .open(directory.join("journal.jsonl"))
                        .unwrap()
                        .write_all(b"{torn")
                        .unwrap();
                }
                _ => unreachable!(),
            }
            let before = f.jobs.journal_bytes(ID).unwrap();
            let result = archive.archive(&decision(&preview));
            if let Some((release, thread)) = held {
                release.send(()).unwrap();
                thread.join().unwrap();
            }
            assert!(result.is_err(), "{case}");
            assert_eq!(f.jobs.journal_bytes(ID).unwrap(), before, "{case}");
        }
    }

    #[test]
    fn retained_archive_requires_expiry_and_keeps_a_missing_clock_anchor_missing() {
        fn active() -> Option<String> {
            Some("2026-09-25T03:59:59Z".into())
        }
        fn invalid() -> Option<String> {
            Some("invalid".into())
        }
        for clock in [active as fn() -> Option<String>, invalid] {
            let f = Fixture::unknown_flash(true);
            let publisher = f.publisher();
            let archive = JobArchiver {
                jobs: &f.jobs,
                now: clock,
                sessions: Some(&publisher),
            };
            let before = f.jobs.journal_bytes(ID).unwrap();
            let preview = archive.preview(&params()).unwrap();
            assert_eq!(preview["canArchive"], false);
            assert!(archive.archive(&decision(&preview)).is_err());
            assert_eq!(f.jobs.journal_bytes(ID).unwrap(), before);
        }
        let f = Fixture::unknown_flash(true);
        f.edit(|value| {
            value.as_object_mut().unwrap().remove("finishedAtUTC");
        });
        let publisher = f.publisher();
        let archive = JobArchiver {
            jobs: &f.jobs,
            now,
            sessions: Some(&publisher),
        };
        archive
            .archive(&decision(&archive.preview(&params()).unwrap()))
            .unwrap();
        assert!(f.jobs.read_snapshot(ID).unwrap().finished_at().is_none());
    }

    #[test]
    fn every_retained_archive_append_boundary_restarts_without_release_or_new_effects() {
        for cut in 0..=3 {
            let f = Fixture::unknown_flash(true);
            let directory = f.jobs.job_directory(ID).unwrap();
            let before = f.jobs.journal_bytes(ID).unwrap();
            let mut writer = JournalWriter::open(&directory, false).unwrap();
            let mut record = f.jobs.read_snapshot(ID).unwrap();
            let facts = writer.facts();
            writer
                .append(&events::retained_archive_intent(
                    &envelope(ID, &facts, AT).unwrap(),
                    "user-archive-fixture",
                    facts.last_confirmed_step_id.as_deref(),
                    &retained_hazards(&record, &facts),
                ))
                .unwrap();
            let mut count = 0;
            let result = complete_pending_with(
                &mut record,
                &mut writer,
                &f.journal(),
                AT,
                &mut |writer, event| {
                    if count == cut {
                        return Err(internal("injected archive append failure"));
                    }
                    count += 1;
                    writer.append(event).map_err(internal)
                },
            );
            assert_eq!(result.is_ok(), cut == 3);
            assert!(!writer.facts().resource_release_authorized);
            drop(writer);
            crate::recover_active_jobs(&f.jobs, None, now).unwrap();
            let recovered = f.jobs.read_snapshot(ID).unwrap();
            assert_eq!(recovered.state, "interrupted");
            assert!(recovered.outcome_unknown());
            assert_eq!(recovered.finished_at(), Some("2026-09-25T00:00:00Z"));
            assert!(f.jobs.journal_bytes(ID).unwrap().starts_with(&before));
            let events = f.journal();
            assert_eq!(
                events
                    .iter()
                    .filter(|event| event["kind"] == "abandonIntent")
                    .count(),
                1
            );
            assert_eq!(
                events
                    .iter()
                    .filter(|event| event["kind"] == "abandonOutcome")
                    .count(),
                1
            );
            assert_eq!(
                events
                    .iter()
                    .filter(|event| event["kind"] == "stepIntent")
                    .count(),
                1
            );
            assert_eq!(
                events
                    .iter()
                    .filter(|event| event["kind"] == "stepOutcome")
                    .count(),
                0
            );
            let publisher = f.publisher();
            let archive = JobArchiver {
                jobs: &f.jobs,
                now,
                sessions: Some(&publisher),
            };
            f.assert_published(
                &archive
                    .archive(&decision(&archive.preview(&params()).unwrap()))
                    .unwrap(),
            );
            assert_eq!(
                f.jobs.unsettled_flash_jobs_for_loader_adoption().unwrap(),
                [ID]
            );
        }
    }
}
