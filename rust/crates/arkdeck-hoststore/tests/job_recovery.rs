//! The recovery branches the Swift restart oracle
//! (`tests/job_reconcile.rs`) does not reach, over journals written as the
//! Rust runner, canceller and admission write them and cut where a process
//! loss would cut them: an intent left outstanding mid-run, a cancellation or
//! finalization without its terminal transition, a reconcile decision without
//! its transition, an admission without its projection, an unreadable record,
//! a terminal Job named explicitly, and a capability Job recovered without a
//! capability store. Each is checked against the carrier it ports
//! (`RuntimeRecoveryService.replay`, `restoreInitialAdmissionProjectionIfNeeded`,
//! `recover(records:)`).
#![cfg(target_os = "macos")]

mod support;

use arkdeck_hoststore::job_journal_events::{self as events, Envelope, Target};
use arkdeck_hoststore::{
    ArtifactReadStore, JobReconciler, JobRecord, JobStore, JournalWriter, recover_active_jobs,
    recover_jobs,
};
use serde_json::{Map, Value, json};
use std::fs;
use std::os::unix::fs::DirBuilderExt;
use std::path::PathBuf;
use support::fixed_now;

const ADMITTED: &str = "job-082b8363fce0462b4571a62147751099";
const STEP: &str = "extract-crash-signature";
const INTENT: &str = "intent-extract-crash-signature";

struct Root(PathBuf);

impl Root {
    fn new() -> Self {
        let path = PathBuf::from(format!(
            "/private/tmp/arkdeck-job-recovery-{:032x}",
            u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap())
        ));
        for directory in [
            path.clone(),
            path.join("jobs-state"),
            path.join("artifacts"),
        ] {
            fs::DirBuilder::new()
                .mode(0o700)
                .create(&directory)
                .unwrap();
        }
        Self(path)
    }
    fn state(&self) -> PathBuf {
        self.0.join("jobs-state")
    }
    fn job(&self, id: &str) -> PathBuf {
        self.state().join("jobs").join(id)
    }
    fn journal(&self, id: &str) -> Vec<Value> {
        fs::read_to_string(self.job(id).join("journal.jsonl"))
            .unwrap()
            .lines()
            .map(|line| serde_json::from_str(line).unwrap())
            .collect()
    }
    fn record(&self, id: &str) -> Value {
        serde_json::from_slice(&fs::read(self.job(id).join("job-record.json")).unwrap()).unwrap()
    }
    fn version(&self, id: &str) -> Value {
        support::index(&self.state())["rows"]
            .as_array()
            .unwrap()
            .iter()
            .find(|row| row["jobId"] == id)
            .unwrap()["version"]
            .clone()
    }
}

impl Drop for Root {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn fixture_record(path: &str) -> JobRecord {
    JobRecord::decode(&fs::read(support::fixture(path)).unwrap()).unwrap()
}

/// The record with `change` applied to its durable fields.
fn edited(record: &JobRecord, change: impl FnOnce(&mut Value)) -> JobRecord {
    let mut value = record.value().unwrap();
    change(&mut value);
    JobRecord::decode(&serde_json::to_vec(&value).unwrap()).unwrap()
}

fn envelope(id: &str, event: &str, sequence: i64) -> Envelope {
    Envelope {
        event_id: event.into(),
        sequence,
        session_id: format!("session-{id}"),
        job_id: id.into(),
        timestamp: "2026-09-14T00:00:00Z".into(),
    }
}

/// What the Rust admission leaves: the index row, `jobCreated` and
/// `queued -> preflight`, then the record.
fn admit(jobs: &JobStore, root: &Root, record: &JobRecord) -> JournalWriter {
    jobs.admit(record, &"a".repeat(64)).unwrap();
    let directory = root.job(&record.job_id);
    fs::DirBuilder::new()
        .mode(0o700)
        .recursive(true)
        .create(&directory)
        .unwrap();
    let mut journal = JournalWriter::open(&directory, true).unwrap();
    let id = record.job_id.as_str();
    journal
        .append(&events::job_created(
            &envelope(id, "job-created", 0),
            "execute",
            "standardAgent",
            "CORE-2.0.0",
        ))
        .unwrap();
    journal
        .append(&events::state_transition(
            &envelope(id, "to-preflight", 1),
            "queued",
            "preflight",
            "admitted",
            None,
        ))
        .unwrap();
    jobs.persist(record, "2026-09-14T00:00:00Z").unwrap();
    journal
}

fn transition(journal: &mut JournalWriter, id: &str, sequence: i64, from: &str, to: &str) {
    journal
        .append(&events::state_transition(
            &envelope(id, &format!("t-{sequence}"), sequence),
            from,
            to,
            "test",
            None,
        ))
        .unwrap();
}

/// The analyzer step's write-ahead intent, as the runner journals it.
fn intent(journal: &mut JournalWriter, id: &str, sequence: i64) {
    let step = json!({"id": STEP, "kind": "runDeterministicAnalyzer", "effect": "hostOnly",
        "bindingRequirement": "none", "cancellation": "immediate", "compensationDescriptors": [],
        "arguments": {"analyzerRef": "crash-signature@1",
            "inputArtifactId": "ART-990a17a6b9ca251b17028e7c824f7b8b",
            "artifactId": "crash-signature.json"}});
    let target = Target {
        scope: "host".into(),
        target_id: "TGT-ORACLE".into(),
        connect_key: None,
        identity_snapshot_hash: None,
    };
    journal
        .append(
            &events::step_intent(&envelope(id, INTENT, sequence), &step, &target, 1, None).unwrap(),
        )
        .unwrap();
}

fn admitted() -> JobRecord {
    fixture_record(&format!(
        "job-reconcile-analyzer/before/jobs/{ADMITTED}/job-record.json"
    ))
}

fn last(values: &Value) -> &Value {
    values.as_array().unwrap().last().unwrap()
}

#[test]
fn a_start_parks_a_job_whose_intent_is_outstanding_and_nothing_resolves_it() {
    let root = Root::new();
    let jobs = JobStore::open_owner(&root.state()).unwrap();
    let record = admitted();
    let mut journal = admit(&jobs, &root, &record);
    transition(&mut journal, ADMITTED, 2, "preflight", "running");
    intent(&mut journal, ADMITTED, 3);
    drop(journal);
    let running = edited(&record, |value| value["state"] = json!("running"));
    jobs.persist(&running, "2026-09-14T00:00:00Z").unwrap();

    let recovered = recover_active_jobs(&jobs, None, fixed_now).unwrap();
    assert_eq!(recovered.statuses.len(), 1);
    let status = &recovered.statuses[0];
    assert_eq!(
        (
            &status["state"],
            &status["outcomeUnknown"],
            &status["nextAction"]["kind"]
        ),
        (
            &json!("waitingForRecovery"),
            &json!(true),
            &json!("reconcile")
        )
    );
    let journaled = root.journal(ADMITTED);
    assert_eq!(journaled.len(), 5);
    assert_eq!(
        journaled[4],
        json!({"eventId": "recovery-t-4", "jobId": ADMITTED, "kind": "stateTransition",
            "payload": {"from": "running", "reason":
                "durably park unresolved provider intent after restart",
                "to": "waitingForRecovery", "triggerEventId": null},
            "schemaVersion": "1.0.0", "sequence": 4, "sessionId": format!("session-{ADMITTED}"),
            "timestamp": "2026-09-14T00:00:00Z"})
    );
    let parked = root.record(ADMITTED);
    assert_eq!(parked["recoveryStepID"], STEP);
    assert_eq!(
        last(&parked["timeline"]),
        "recovered: outstanding intents or unknown outcomes; no redispatch"
    );
    assert_eq!(root.version(ADMITTED), json!(4));

    // Another start adds no journal record and no second marker.
    recover_active_jobs(&jobs, None, fixed_now).unwrap();
    assert_eq!(root.journal(ADMITTED).len(), 5);
    assert_eq!(root.record(ADMITTED), parked);
    assert_eq!(root.version(ADMITTED), json!(5));

    // Without the exact typed action no reconcile can start, and nothing is
    // written.
    let artifacts = ArtifactReadStore::open(&root.0.join("artifacts")).unwrap();
    let refused = JobReconciler {
        jobs: &jobs,
        artifacts: &artifacts,
        imports: None,
        now: fixed_now,
        sessions: None,
    }
    .handle(&Map::from_iter([("jobId".into(), json!(ADMITTED))]))
    .unwrap_err();
    assert_eq!(
        (
            refused.code.as_str(),
            refused.message.as_str(),
            refused.details
        ),
        (
            "rejected",
            "internalFailure(\"unknown outcome has no persisted exact typed action for \
             job-082b8363fce0462b4571a62147751099\")",
            None
        )
    );
    assert_eq!(root.journal(ADMITTED).len(), 5);
    assert_eq!(root.version(ADMITTED), json!(5));
}

#[test]
fn a_start_completes_a_clean_cancellation_and_an_interrupted_finalization() {
    let root = Root::new();
    let jobs = JobStore::open_owner(&root.state()).unwrap();
    let cancelled = admitted();
    let mut journal = admit(&jobs, &root, &cancelled);
    transition(&mut journal, ADMITTED, 2, "preflight", "cancelRequested");
    drop(journal);
    jobs.persist(
        &edited(&cancelled, |value| {
            value["state"] = json!("cancelRequested")
        }),
        "2026-09-14T00:00:00Z",
    )
    .unwrap();
    let finalized = edited(&admitted(), |value| {
        let id = "job-feedface0000000000000000000000000";
        value["jobID"] = json!(id);
        for request in ["request", "originalSubmissionRequest"] {
            value[request]["idempotencyKey"] = json!("idem-recovery-finalizing");
        }
    });
    let id = finalized.job_id.clone();
    let mut journal = admit(&jobs, &root, &finalized);
    transition(&mut journal, &id, 2, "preflight", "running");
    transition(&mut journal, &id, 3, "running", "finalizing");
    drop(journal);
    jobs.persist(
        &edited(&finalized, |value| value["state"] = json!("running")),
        "2026-09-14T00:00:00Z",
    )
    .unwrap();

    let recovered = recover_active_jobs(&jobs, None, fixed_now).unwrap();
    assert_eq!(recovered.statuses.len(), 2);
    let transitions = |id: &str| -> Vec<(String, String, String)> {
        root.journal(id)
            .iter()
            .filter(|event| {
                event["eventId"]
                    .as_str()
                    .unwrap()
                    .starts_with("recovery-t-")
            })
            .map(|event| {
                let payload = &event["payload"];
                (
                    payload["from"].as_str().unwrap().into(),
                    payload["to"].as_str().unwrap().into(),
                    payload["reason"].as_str().unwrap().into(),
                )
            })
            .collect()
    };
    assert_eq!(
        transitions(ADMITTED),
        [
            (
                "cancelRequested".into(),
                "cancellingAtSafeBoundary".into(),
                "process loss with no outstanding intent is a confirmed safe boundary".into()
            ),
            (
                "cancellingAtSafeBoundary".into(),
                "cancelled".into(),
                "complete durable cancellation after restart".into()
            ),
        ]
    );
    let record = root.record(ADMITTED);
    assert_eq!(record["state"], "cancelled");
    assert_eq!(record["operationFailure"]["code"], "cancelled");
    assert_eq!(record["finishedAtUTC"], "2026-09-14T00:00:00Z");
    assert_eq!(
        last(&record["timeline"]),
        "recovered: completed durable cancellation at journal-confirmed safe boundary; no \
         redispatch"
    );
    assert_eq!(
        transitions(&id),
        [(
            "finalizing".into(),
            "failed".into(),
            "finalization was interrupted before its terminal transition".into()
        )]
    );
    let record = root.record(&id);
    assert_eq!(record["state"], "failed");
    assert_eq!(record["finishedAtUTC"], "2026-09-14T00:00:00Z");
    assert_eq!(
        last(&record["timeline"]),
        "recovered: finalization interrupted before terminal transition; failed without \
         redispatch"
    );

    // Both are terminal now: a start reopens neither, and naming one only
    // marks its clean journal once.
    assert!(
        recover_active_jobs(&jobs, None, fixed_now)
            .unwrap()
            .statuses
            .is_empty()
    );
    let journaled = root.journal(&id).len();
    let named = recover_jobs(&jobs, std::slice::from_ref(&id), None, fixed_now).unwrap();
    assert_eq!(named.statuses[0]["state"], "failed");
    let record = root.record(&id);
    assert_eq!(last(&record["timeline"]), "recovered: journal clean");
    recover_jobs(&jobs, std::slice::from_ref(&id), None, fixed_now).unwrap();
    assert_eq!(root.record(&id), record);
    assert_eq!(root.journal(&id).len(), journaled);
    assert!(
        recover_jobs(&jobs, &["job-absent".into()], None, fixed_now)
            .unwrap_err()
            .0
            .starts_with("jobNotFound(")
    );
}

#[test]
fn a_start_completes_a_reconcile_decision_left_without_its_transition() {
    let root = Root::new();
    let jobs = JobStore::open_owner(&root.state()).unwrap();
    let record = admitted();
    let mut journal = admit(&jobs, &root, &record);
    transition(&mut journal, ADMITTED, 2, "preflight", "running");
    intent(&mut journal, ADMITTED, 3);
    transition(&mut journal, ADMITTED, 4, "running", "waitingForRecovery");
    transition(
        &mut journal,
        ADMITTED,
        5,
        "waitingForRecovery",
        "reconciling",
    );
    let attempt = format!("recovery-{ADMITTED}-6");
    journal
        .append(&events::reconcile_started(
            &envelope(ADMITTED, "reconcile-start-6", 6),
            &attempt,
            "waitingForRecovery",
            5,
            "manual",
        ))
        .unwrap();
    journal
        .append(&events::step_outcome(
            &envelope(ADMITTED, "reconciled-outcome-7", 7),
            STEP,
            1,
            INTENT,
            "failed",
            "confirmed",
            Some("confirmedNotExecuted"),
            None,
        ))
        .unwrap();
    journal
        .append(&events::reconcile_outcome(
            &envelope(ADMITTED, "reconcile-outcome-8", 8),
            None,
            &attempt,
            "finalizeHostOnlyConfirmedFailure",
            "finalizing",
            "confirmed",
            true,
            &["confirmed not executed; original not resent"],
        ))
        .unwrap();
    drop(journal);
    jobs.persist(
        &edited(&record, |value| {
            value["state"] = json!("waitingForRecovery");
            value["outcomeUnknown"] = json!(true);
        }),
        "2026-09-14T00:00:00Z",
    )
    .unwrap();

    recover_active_jobs(&jobs, None, fixed_now).unwrap();
    let journaled = root.journal(ADMITTED);
    assert_eq!(journaled[9]["eventId"], "recovery-t-9");
    assert_eq!(
        journaled[9]["payload"],
        json!({"from": "reconciling", "to": "finalizing", "triggerEventId": "reconcile-outcome-8",
            "reason": "complete durable reconcile decision after restart"})
    );
    assert_eq!(journaled[10]["payload"]["to"], "failed");
    let recovered = root.record(ADMITTED);
    assert_eq!(
        (&recovered["state"], &recovered["outcomeUnknown"]),
        (&json!("failed"), &json!(false))
    );
}

#[test]
fn a_start_restores_only_a_wholly_absent_admission_projection() {
    let root = Root::new();
    let jobs = JobStore::open_owner(&root.state()).unwrap();
    let record = admitted();
    drop(admit(&jobs, &root, &record));
    let journal = fs::read(root.job(ADMITTED).join("journal.jsonl")).unwrap();
    fs::remove_file(root.job(ADMITTED).join("job-record.json")).unwrap();
    fs::remove_file(root.job(ADMITTED).join("journal.jsonl")).unwrap();

    let recovered = recover_active_jobs(&jobs, None, fixed_now).unwrap();
    assert_eq!(recovered.statuses[0]["state"], "preflight");
    let restored = root.journal(ADMITTED);
    assert_eq!(restored.len(), 2);
    assert_eq!(
        restored[1]["payload"]["reason"],
        "recovered committed admission"
    );
    assert_eq!(
        String::from_utf8(journal).unwrap().lines().next(),
        fs::read_to_string(root.job(ADMITTED).join("journal.jsonl"))
            .unwrap()
            .lines()
            .next()
    );
    assert_eq!(
        last(&root.record(ADMITTED)["timeline"]),
        "recovered: journal clean"
    );

    // A journal holding only its admission restores the record alone; a
    // record without its journal is a partial projection, refused unchanged.
    fs::remove_file(root.job(ADMITTED).join("job-record.json")).unwrap();
    recover_active_jobs(&jobs, None, fixed_now).unwrap();
    assert_eq!(root.record(ADMITTED)["state"], "preflight");
    fs::remove_file(root.job(ADMITTED).join("journal.jsonl")).unwrap();
    let version = root.version(ADMITTED);
    let refused = recover_active_jobs(&jobs, None, fixed_now).unwrap_err();
    assert_eq!(
        refused.0,
        format!("internalFailure(\"admitted job {ADMITTED} has a partial durable projection\")")
    );
    assert!(!root.job(ADMITTED).join("journal.jsonl").exists());
    assert_eq!(root.version(ADMITTED), version);
}

#[test]
fn an_unreadable_record_is_quarantined_and_a_capability_job_needs_its_store() {
    let root = Root::new();
    let jobs = JobStore::open_owner(&root.state()).unwrap();
    drop(admit(&jobs, &root, &admitted()));
    fs::write(root.job(ADMITTED).join("job-record.json"), b"{\"jobID\":").unwrap();
    let recovered = recover_active_jobs(&jobs, None, fixed_now).unwrap();
    assert!(recovered.statuses.is_empty());
    assert_eq!(recovered.quarantined.len(), 1);
    assert_eq!(recovered.quarantined[0].0, ADMITTED);
    assert_eq!(
        fs::read(root.job(ADMITTED).join("job-record.json")).unwrap(),
        b"{\"jobID\":"
    );
    assert_eq!(root.version(ADMITTED), json!(2));

    // A Job admitted under a runtime capability is not recovered without
    // the capability store its use outcome lives in: the call fails naming
    // it before anything is written.
    let capability = fixture_record(
        "pointer-input/store/jobs/job-4ac2c3640786ad0e831952ab62bb71bc/job-record.json",
    );
    let id = capability.job_id.clone();
    drop(admit(&jobs, &root, &capability));
    let journal = fs::read(root.job(&id).join("journal.jsonl")).unwrap();
    let version = root.version(&id);
    let refused = recover_jobs(&jobs, std::slice::from_ref(&id), None, fixed_now).unwrap_err();
    assert!(refused.0.contains(&id), "{refused}");
    assert_eq!(
        fs::read(root.job(&id).join("journal.jsonl")).unwrap(),
        journal
    );
    assert_eq!(root.version(&id), version);
}
